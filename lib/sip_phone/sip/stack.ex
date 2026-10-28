defmodule SipPhone.SIP.Stack do
  @moduledoc """
  SIP User-Agent: регистрация (REGISTER + digest auth), исходящие и входящие
  вызовы (INVITE/ACK/CANCEL/BYE). Транспорт — UDP. Транзакции упрощённые:
  ретрансляция запросов до финального ответа, ретрансляция финальных ответов
  на INVITE до ACK.

  Локальный UDP-порт — из `:sip_phone, :sip_port` (`SIP_PHONE_SIP_PORT`,
  боевая норма 5080; в test-окружении своё — см. `config/test.exs`).

  Все отправленные/полученные сообщения публикуются через `SipPhone.PubSub`
  как `{:sip_log, entry}`; состояние опрашивается через `state/0`
  (WS-клиенты поллют его — см. `SipPhone.Web.WS`).
  """

  use GenServer
  require Logger

  import SipPhone.SIP.Message, only: [header: 2, header_param: 3, addr_uri: 2]

  alias SipPhone.PubSub
  alias SipPhone.SIP.LogBuffer
  alias SipPhone.SIP.Message

  @t1_ms 500
  @max_retries 15
  @expires 300

  @typedoc """
  Причина отказа — человекочитаемая строка на русском (её показывает UI).
  """
  @type reason :: String.t()

  @typedoc "Результат команды: принято к исполнению или отказ."
  @type result :: :ok | {:error, reason()}

  @typedoc "Публичный снимок состояния телефона (`state/0`), пароля там нет."
  @type public_state :: %{
          registration: String.t(),
          reg_error: reason() | nil,
          call: String.t(),
          call_error: reason() | nil,
          remote: String.t() | nil,
          server: String.t(),
          number: String.t() | nil,
          local_endpoint: String.t()
        }

  # ------------------------------------------------------------------ API

  @doc false
  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc """
  Начать регистрацию: REGISTER без пароля → повтор с digest при 401/407.
  `server` — `"host[:port]"` (порт по умолчанию 5060). Прогресс и итог —
  в `state/0` и в логе.
  """
  @spec register(String.t(), String.t(), String.t()) :: result()
  def register(server, number, password),
    do: GenServer.call(__MODULE__, {:register, server, number, password})

  @doc "Снять номер с регистрации (REGISTER `Expires: 0`, при необходимости с digest)."
  @spec unregister() :: result()
  def unregister, do: GenServer.call(__MODULE__, :unregister)

  @doc "Исходящий вызов: INVITE (с кэшированным digest, см. work_log §8), ответ — асинхронно."
  @spec call_number(String.t()) :: result()
  def call_number(number), do: GenServer.call(__MODULE__, {:call, number})

  @doc "Ответить на входящий вызов (200 OK с SDP)."
  @spec answer() :: result()
  def answer, do: GenServer.call(__MODULE__, :answer)

  @doc "Отклонить входящий вызов (486 Busy Here)."
  @spec reject() :: result()
  def reject, do: GenServer.call(__MODULE__, :reject)

  @doc "Отменить исходящий вызов (CANCEL; при гонке с 200 OK — ACK + немедленный BYE)."
  @spec cancel() :: result()
  def cancel, do: GenServer.call(__MODULE__, :cancel)

  @doc "Завершить разговор (BYE)."
  @spec hangup() :: result()
  def hangup, do: GenServer.call(__MODULE__, :hangup)

  @doc "Снимок состояния для UI: регистрация, линия, абонент, аккаунт."
  @spec state() :: public_state()
  def state, do: GenServer.call(__MODULE__, :state)

  @doc "История SIP-сообщений (из `SipPhone.SIP.LogBuffer`), старые → новые."
  @spec log() :: [LogBuffer.entry()]
  def log, do: GenServer.call(__MODULE__, :log)

  # ------------------------------------------------------------ Callbacks

  @impl true
  def init(_) do
    port = Application.fetch_env!(:sip_phone, :sip_port)
    {:ok, socket} = :gen_udp.open(port, [:binary, active: true])
    {:ok, local_port} = :inet.port(socket)
    store_local_endpoint("127.0.0.1", local_port)

    state = %{
      socket: socket,
      local_port: local_port,
      local_ip: ~c"127.0.0.1",
      # {host_string, port}
      server: nil,
      number: nil,
      password: nil,
      reg_status: :unregistered,
      reg_error: nil,
      # %{call_id, from_tag, cseq} — диалог регистрации (повтор с auth идёт в нём же)
      reg_dialog: nil,
      reg_expires: @expires,
      call_status: :idle,
      call_error: nil,
      call: nil,
      # аутентификация
      # challenge текущего REGISTER-диалога
      auth: nil,
      # последний challenge сервера — подставляем в INVITE заранее
      auth_cache: nil,
      auth_tries: 0,
      # транзакции клиента: branch -> %{msg, target, timer, retries, kind}
      client_tx: %{},
      # ожидающий ответа сервера транзакция INVITE (наш INVITE ожидающий ACK)
      # %{iodata, target, timer, call_id, summary}
      pending_final: nil,
      # наш финальный ответ не отправлен: ретранслируем 180 Ringing на INVITE
      # %{iodata, target, timer, call_id, retries}
      prov: nil,
      # branch текущей REGISTER
      reg_tx: nil,
      reg_recheck: nil,
      log: [],
      cseq: 10
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:state, _f, state), do: {:reply, public_state(state), state}
  def handle_call(:log, _f, state), do: {:reply, LogBuffer.all(), state}

  def handle_call({:register, server, number, password}, _f, state) do
    with {:ok, {host, port}} <- parse_server(server),
         {:ok, ip} <- resolve_host(host),
         {:ok, local_ip} <- detect_local_ip(ip) do
      store_local_endpoint(local_ip, state.local_port)

      state = %{
        state
        | number: number,
          password: password,
          server: {host, port},
          local_ip: ip,
          auth_cache: nil
      }

      {:reply, :ok, start_registration(state)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:unregister, _f, %{reg_status: status} = state)
      when status in [:registered, :registering] do
    {:reply, :ok, start_registration(%{state | reg_expires: 0})}
  end

  def handle_call(:unregister, _f, state),
    do: {:reply, :ok, %{state | reg_status: :unregistered, reg_error: nil}}

  def handle_call({:call, number}, _f, %{reg_status: :registered} = state) do
    case state.call_status do
      :idle -> {:reply, :ok, start_outgoing_call(state, number)}
      _ -> {:reply, {:error, "уже есть активный вызов"}, state}
    end
  end

  def handle_call({:call, _}, _f, state),
    do: {:reply, {:error, "номер не зарегистрирован"}, state}

  def handle_call(:answer, _f, %{call_status: :incoming} = state),
    do: {:reply, :ok, answer_incoming(state)}

  def handle_call(:answer, _f, state),
    do: {:reply, {:error, "нет входящего вызова"}, state}

  def handle_call(:reject, _f, %{call_status: :incoming} = state),
    do: {:reply, :ok, reject_incoming(state)}

  def handle_call(:reject, _f, state),
    do: {:reply, {:error, "нет входящего вызова"}, state}

  def handle_call(:cancel, _f, %{call_status: :calling} = state),
    do: {:reply, :ok, cancel_outgoing(state)}

  def handle_call(:cancel, _f, state),
    do: {:reply, {:error, "нет исходящего вызова"}, state}

  def handle_call(:hangup, _f, %{call_status: :active} = state),
    do: {:reply, :ok, hangup_active(state)}

  def handle_call(:hangup, _f, state),
    do: {:reply, {:error, "нет разговора"}, state}

  # --------------------------------------------------------------- UDP in

  @impl true
  def handle_info({:udp, _sock, ip, port, data}, state) do
    case Message.parse(data) do
      {:ok, msg} ->
        log_in(msg, ip, port)
        handle_message(msg, {ip, port}, state)

      {:error, reason} ->
        info_log("не разобрано UDP-сообщение (#{inspect(reason)}): #{inspect(data, limit: 200)}")
        {:noreply, state}
    end
  end

  # Ретрансляция клиентского запроса
  def handle_info({:tx_retry, branch}, state) do
    case Map.get(state.client_tx, branch) do
      nil ->
        {:noreply, state}

      tx ->
        :gen_udp.send(state.socket, elem(tx.target, 0), elem(tx.target, 1), tx.iodata)

        if tx.retries + 1 >= @max_retries do
          info_log("нет ответа на #{tx.method}, операция прервана по таймауту")
          state = %{state | client_tx: Map.delete(state.client_tx, branch)}
          {:noreply, fail_operation(tx.kind, state)}
        else
          timer = Process.send_after(self(), {:tx_retry, branch}, @t1_ms * 2 * tx.retries_factor)
          next_factor = min(tx.retries_factor * 2, 16)

          {:noreply,
           %{
             state
             | client_tx:
                 Map.put(state.client_tx, branch, %{
                   tx
                   | retries: tx.retries + 1,
                     retries_factor: next_factor,
                     timer: timer
                 })
           }}
        end
    end
  end

  # Ретрансляция нашего финального ответа на INVITE до получения ACK
  def handle_info({:final_retry, call_id}, %{pending_final: %{call_id: call_id} = pf} = state) do
    :gen_udp.send(state.socket, elem(pf.target, 0), elem(pf.target, 1), pf.iodata)
    timer = Process.send_after(self(), {:final_retry, call_id}, @t1_ms * 2)
    {:noreply, %{state | pending_final: %{pf | timer: timer}}}
  end

  def handle_info({:final_retry, _}, state), do: {:noreply, state}

  # ретрансляция 180 Ringing, пока не отправлен финальный ответ (Timer G, ~Timer B по длительности)
  def handle_info({:prov_retry, call_id}, %{prov: %{call_id: call_id} = p} = state) do
    if p.retries >= @max_retries do
      {:noreply, %{state | prov: nil}}
    else
      send_raw(p.iodata, p.target, state, "180 Ringing (ретрансляция) → #{peer_str(p.target)}")
      timer = Process.send_after(self(), {:prov_retry, call_id}, @t1_ms * 4)
      {:noreply, %{state | prov: %{p | timer: timer, retries: p.retries + 1}}}
    end
  end

  def handle_info({:prov_retry, _}, state), do: {:noreply, state}

  def handle_info(:re_register, %{reg_status: st} = state) when st in [:registered, :registering],
    do: {:noreply, start_registration(state)}

  def handle_info(:re_register, state), do: {:noreply, state}

  def handle_info(_other, state), do: {:noreply, state}

  # Останавливаем таймеры при завершении
  @impl true
  def terminate(_reason, state) do
    for %{timer: t} <- Map.values(state.client_tx), t, do: Process.cancel_timer(t)

    case state.pending_final do
      %{timer: t} when not is_nil(t) -> Process.cancel_timer(t)
      _ -> :ok
    end

    :ok
  end

  # ------------------------------------------------------ Обработка ответов

  defp handle_message(%Message{type: :response} = msg, from, state),
    do: handle_response(msg, from, state)

  defp handle_message(%Message{type: :request} = msg, from, state),
    do: handle_request(msg, from, state)

  defp handle_response(msg, from, state) do
    case Message.cseq(msg) do
      {_n, method} ->
        branch = Message.branch(msg) || ""

        case method do
          "REGISTER" ->
            case Map.pop(state.client_tx, branch) do
              {nil, _} ->
                {:noreply, state}

              {tx, txs} ->
                if tx.timer, do: Process.cancel_timer(tx.timer)
                handle_register_response(%{state | client_tx: txs}, msg, from)
            end

          "INVITE" ->
            handle_invite_response(msg, from, state)

          "BYE" ->
            {:noreply, finish_tx_kind(:bye, state)}

          "CANCEL" ->
            {:noreply, finish_tx("cancel-" <> branch, state)}

          _ ->
            {:noreply, state}
        end

      nil ->
        {:noreply, state}
    end
  end

  # завершает клиентскую транзакцию (отменяет ретрансляцию)
  defp finish_tx(branch, %{client_tx: txs} = state) do
    case Map.pop(txs, branch) do
      {nil, _} ->
        state

      {%{timer: t}, txs} ->
        if t, do: Process.cancel_timer(t)
        %{state | client_tx: txs}
    end
  end

  defp finish_tx_kind(kind, %{client_tx: txs} = state) do
    {to_del, rest} = Enum.split_with(txs, fn {_k, tx} -> tx.kind == kind end)
    for {_, %{timer: t}} <- to_del, t, do: Process.cancel_timer(t)
    %{state | client_tx: Map.new(rest)}
  end

  # ---------------------------------------------------- Регистрация (UAC)

  defp handle_register_response(state, msg, _from) do
    code = msg.status_code

    cond do
      code in [401, 407] and state.auth_tries < 2 ->
        header_name = if code == 401, do: "www-authenticate", else: "proxy-authenticate"

        case parse_challenge(header(msg, header_name)) do
          nil ->
            registration_failed("сервер прислал 401 без корректного challenge", state)

          auth ->
            info_log("требуется аутентификация (#{code}), повторяю REGISTER с паролем")
            state = %{state | auth: auth, auth_tries: state.auth_tries + 1, auth_cache: auth}
            {:noreply, send_register(state)}
        end

      code in [401, 407] ->
        registration_failed("аутентификация не пройдена (#{code} #{msg.reason})", state)

      code >= 200 and code < 300 ->
        if state.reg_expires == 0 do
          info_log("номер снят с регистрации")

          {:noreply,
           %{
             state
             | reg_status: :unregistered,
               reg_error: nil,
               auth: nil,
               reg_dialog: nil,
               reg_expires: @expires
           }}
        else
          expires = register_expires(msg)

          info_log(
            "регистрация успешна: #{state.number}@#{server_host(state)} (expires #{expires}s)"
          )

          timer = Process.send_after(self(), :re_register, max(30_000, (expires - 20) * 1000))

          {:noreply,
           %{state | reg_status: :registered, reg_error: nil, reg_recheck: timer, auth: nil}}
        end

      code >= 300 ->
        registration_failed("#{code} #{msg.reason}", state)

      true ->
        # 1xx — промежуточный, ждём финальный
        {:noreply, state}
    end
  end

  defp registration_failed(reason, state) do
    info_log("регистрация не удалась: #{reason}")
    {:noreply, %{state | reg_status: :failed, reg_error: reason}}
  end

  defp start_registration(%{server: nil} = state), do: state
  defp start_registration(%{number: nil} = state), do: state

  defp start_registration(state) do
    state = cancel_reg_tx(state)

    state = %{
      state
      | reg_status: :registering,
        reg_error: nil,
        auth: nil,
        auth_tries: 0,
        reg_dialog: nil
    }

    send_register(state)
  end

  defp cancel_reg_tx(%{client_tx: txs} = state) do
    {to_del, rest} = Enum.split_with(txs, fn {_k, tx} -> tx.kind == :register end)

    for {_, %{timer: t}} <- to_del, t, do: Process.cancel_timer(t)
    %{state | client_tx: Map.new(rest)}
  end

  defp send_register(state) do
    # повторный REGISTER с Authorization идёт в том же диалоге (Call-ID, From tag),
    # иначе nksip-регистраторы (ECSS и др.) снова выдают 401
    dialog =
      state.reg_dialog ||
        %{call_id: new_call_id(state), from_tag: new_tag(), cseq: state.cseq}

    cseq = dialog.cseq + 1
    branch = new_branch()
    host = server_host(state)
    uri = "sip:#{host}"

    base =
      %Message{
        type: :request,
        method: "REGISTER",
        uri: uri,
        headers: []
      }
      |> put_via(branch)
      |> Message.put_header("max-forwards", "70")
      |> Message.put_header("from", "<sip:#{state.number}@#{host}>;tag=#{dialog.from_tag}")
      |> Message.put_header("to", "<sip:#{state.number}@#{host}>")
      |> Message.put_header("call-id", dialog.call_id)
      |> Message.put_header("cseq", "#{cseq} REGISTER")
      |> Message.put_header("contact", contact_uri(state))
      |> Message.put_header("expires", to_string(state.reg_expires))
      |> Message.put_header("user-agent", user_agent())
      |> Message.put_header("content-length", "0")

    base =
      if state.auth do
        auth = digest_auth(state.auth, "REGISTER", uri, state)
        Message.put_header(base, "authorization", auth)
      else
        base
      end

    state = %{state | cseq: cseq, reg_dialog: %{dialog | cseq: cseq}}
    put_client_tx(state, branch, :register, base, server_target(state))
  end

  defp register_expires(msg) do
    case header_param(msg, "contact", "expires") do
      nil -> @expires
      v -> String.to_integer(v)
    end
  rescue
    _ -> @expires
  end

  # ------------------------------------------------------- Вызовы (UAC)

  defp start_outgoing_call(state, number) do
    call = %{
      direction: :out,
      remote: to_string(number),
      call_id: new_call_id(state),
      local_tag: new_tag(),
      remote_tag: nil,
      cseq: state.cseq + 1,
      branch: new_branch(),
      target: server_target(state),
      dialog_target: server_target(state),
      canceled: false,
      auth_tries: 0
    }

    # если challenge уже известен (проходили 401 на регистрацию) — сразу шлём
    # Authorization: обычно ECSS принимает и первый INVITE проходит без 401
    invite = build_invite(state, call, state.auth_cache)
    state = put_client_tx(%{state | cseq: call.cseq}, call.branch, :invite, invite, call.target)
    %{state | call: call, call_status: :calling, call_error: nil}
  end

  defp build_invite(state, call, challenge) do
    ruri = "sip:#{call.remote}@#{server_host(state)}"

    msg =
      %Message{type: :request, method: "INVITE", uri: ruri}
      |> put_via(call.branch)
      |> Message.put_header("max-forwards", "70")
      |> Message.put_header(
        "from",
        "<sip:#{state.number}@#{server_host(state)}>;tag=#{call.local_tag}"
      )
      |> Message.put_header("to", "<sip:#{call.remote}@#{server_host(state)}>")
      |> Message.put_header("call-id", call.call_id)
      |> Message.put_header("cseq", "#{call.cseq} INVITE")
      |> Message.put_header("contact", contact_uri(state))
      |> Message.put_header("content-type", "application/sdp")
      |> Message.put_header("user-agent", user_agent())

    body = build_sdp(state)

    msg =
      msg
      |> Map.put(:body, body)
      |> Message.put_header("content-length", to_string(byte_size(body)))

    if challenge do
      Message.put_header(msg, "authorization", digest_auth(challenge, "INVITE", ruri, state))
    else
      msg
    end
  end

  defp handle_invite_response(msg, from, %{call: %{direction: :out} = call} = state) do
    code = msg.status_code

    cond do
      code < 200 ->
        {:noreply, state}

      code < 300 ->
        remote_tag = header_param(msg, "to", "tag")
        state = finish_tx(call.branch, state)

        if call.canceled do
          # гонка CANCEL/200: ACK + немедленный BYE
          state = send_ack(msg, call, from, state)
          {:noreply, hangup_active(%{state | call: %{call | remote_tag: remote_tag}})}
        else
          target = dialog_target(msg, from, state)
          state = send_ack(msg, call, target, state)
          info_log("установлено соединение с #{call.remote}")

          {:noreply,
           %{
             state
             | call: %{call | remote_tag: remote_tag, dialog_target: target},
               call_status: :active
           }}
        end

      code in [401, 407] and not call.canceled and call.auth_tries < 2 ->
        # сервер требует аутентификацию вызова: ACK + повтор INVITE в том же
        # диалоге (тот же Call-ID/From tag, новый CSeq и branch) с Authorization
        state = send_ack_stateless(msg, call, from, state)
        state = finish_tx(call.branch, state)
        hdr = if code == 401, do: "www-authenticate", else: "proxy-authenticate"

        case parse_challenge(header(msg, hdr)) do
          nil ->
            info_log("сервер прислал #{code} без корректного challenge")

            {:noreply,
             %{state | call: nil, call_status: :idle, call_error: "сбой аутентификации вызова"}}

          challenge ->
            info_log("требуется аутентификация вызова (#{code}), повторяю INVITE с паролем")
            cseq = state.cseq + 1
            branch = new_branch()
            call = %{call | cseq: cseq, branch: branch, auth_tries: call.auth_tries + 1}
            invite = build_invite(state, call, challenge)

            state =
              put_client_tx(
                %{state | cseq: cseq, auth_cache: challenge},
                branch,
                :invite,
                invite,
                call.target
              )

            {:noreply, %{state | call: call}}
        end

      true ->
        # финальный неуспешный: ACK + разбор
        state = send_ack_stateless(msg, call, from, state)
        state = finish_tx(call.branch, state)

        reason =
          cond do
            code == 487 and call.canceled -> "вызов отменён"
            code in [401, 407] -> "аутентификация вызова не пройдена (#{code})"
            true -> "вызов не состоялся: #{code} #{msg.reason}"
          end

        if code != 487, do: info_log(reason)
        {:noreply, %{state | call: nil, call_status: :idle, call_error: reason}}
    end
  end

  defp handle_invite_response(_msg, _from, state), do: {:noreply, state}

  defp cancel_outgoing(%{call: %{direction: :out} = call} = state) do
    info_log("отменяю исходящий вызов (CANCEL)")
    cseq_n = call.cseq

    cancel =
      %Message{type: :request, method: "CANCEL", uri: "sip:#{call.remote}@#{server_host(state)}"}
      |> put_via(call.branch)
      |> Message.put_header("max-forwards", "70")
      |> Message.put_header(
        "from",
        "<sip:#{state.number}@#{server_host(state)}>;tag=#{call.local_tag}"
      )
      |> Message.put_header("to", "<sip:#{call.remote}@#{server_host(state)}>")
      |> Message.put_header("call-id", call.call_id)
      |> Message.put_header("cseq", "#{cseq_n} CANCEL")
      |> Message.put_header("user-agent", user_agent())
      |> Message.put_header("content-length", "0")

    state = put_client_tx(state, "cancel-" <> call.branch, :cancel, cancel, call.target)
    %{state | call: %{call | canceled: true}}
  end

  defp hangup_active(%{call: call} = state) do
    cseq = state.cseq + 1

    bye =
      %Message{
        type: :request,
        method: "BYE",
        uri: dialog_uri(call, state)
      }
      |> put_via("bye-" <> rand_hex(6))
      |> Message.put_header("max-forwards", "70")
      |> Message.put_header(
        "from",
        "<sip:#{state.number}@#{server_host(state)}>;tag=#{call.local_tag}"
      )
      |> Message.put_header(
        "to",
        "<sip:#{call.remote}@#{server_host(state)}>" <> tag_suffix(call.remote_tag)
      )
      |> Message.put_header("call-id", call.call_id)
      |> Message.put_header("cseq", "#{cseq} BYE")
      |> Message.put_header("user-agent", user_agent())
      |> Message.put_header("content-length", "0")

    info_log("завершаю разговор (BYE)")

    state =
      put_client_tx(%{state | cseq: cseq}, "bye-" <> call.call_id, :bye, bye, call.dialog_target)

    %{state | call: nil, call_status: :idle, call_error: nil}
  end

  defp tag_suffix(nil), do: ""
  defp tag_suffix(tag), do: ";tag=#{tag}"

  defp dialog_uri(%{direction: :out, remote: r}, state), do: "sip:#{r}@#{server_host(state)}"
  defp dialog_uri(%{direction: :in, remote_contact: uri}, _state) when is_binary(uri), do: uri
  defp dialog_uri(%{direction: :in, remote: r}, state), do: "sip:#{r}@#{server_host(state)}"
  # -------------------------------------------------- Входящие запросы (UAS)

  defp handle_request(%Message{method: "INVITE"} = msg, from, state) do
    cond do
      # ретрансляция того же INVITE (сервер не успел получить 100 Trying) —
      # отвечаем тем же 100 Trying, а не сбрасываем вызов
      state.call_status == :incoming and state.call != nil and
          Message.header(msg, "call-id") == state.call.call_id ->
        case state.prov do
          %{iodata: iodata} ->
            send_raw(iodata, from, state, "180 Ringing (ретрансляция INVITE) → #{peer_str(from)}")

          nil ->
            trying = build_response(msg, 100, "Trying", state) |> without_contact()

            send_raw(
              Message.to_iodata(trying),
              from,
              state,
              "100 Trying (ретрансляция) → #{peer_str(from)}"
            )
        end

        {:noreply, state}

      state.call_status != :idle ->
        info_log("входящий вызов отклонён: линия занята (486)")

        state2 =
          send_final_to_invite(build_response(msg, 486, "Busy Here", state), from, state, "486")

        {:noreply, state2}

      true ->
        remote = msg |> addr_uri("from") |> then(&(&1 || "unknown")) |> Message.user_of()
        tag = new_tag()

        call = %{
          direction: :in,
          remote: remote,
          call_id: Message.header(msg, "call-id"),
          local_tag: tag,
          remote_tag: header_param(msg, "from", "tag"),
          cseq: elem(Message.cseq(msg) || {0, "INVITE"}, 0),
          invite: msg,
          invite_from: from,
          dialog_target: dialog_target(msg, from, state),
          remote_contact: contact_of(msg, from)
        }

        # 100 Trying
        trying = build_response(msg, 100, "Trying", state) |> without_contact()
        send_raw(Message.to_iodata(trying), from, state, "100 Trying → #{peer_str(from)}")

        # 180 Ringing — звонящий должен слышать гудок; ретранслируем до финального ответа
        ringing = build_response(msg, 180, "Ringing", state) |> without_contact()
        state = start_ringing(ringing, from, state, call.call_id)

        info_log("входящий вызов от #{remote}")
        {:noreply, %{state | call: call, call_status: :incoming, call_error: nil}}
    end
  end

  defp handle_request(%Message{method: "ACK"} = msg, _from, state) do
    call_id = Message.header(msg, "call-id")

    case state.pending_final do
      %{call_id: cid} = pf when not is_nil(cid) ->
        if cid == call_id do
          if pf.timer, do: Process.cancel_timer(pf.timer)
          info_log("получен ACK на наш финальный ответ")
          {:noreply, %{state | pending_final: nil}}
        else
          {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  defp handle_request(%Message{method: "BYE"} = msg, from, %{call: call} = state)
       when call != nil and state.call_status in [:active, :incoming] do
    info_log("собеседник завершил вызов (BYE)")
    ok = build_response(msg, 200, "OK", state) |> without_contact()
    send_raw(Message.to_iodata(ok), from, state, "200 OK на BYE → #{peer_str(from)}")
    state = clear_prov(state)
    {:noreply, %{state | call: nil, call_status: :idle, call_error: nil}}
  end

  defp handle_request(%Message{method: "BYE"} = msg, from, state) do
    send_response(build_response(msg, 481, "Call/Transaction Does Not Exist", state), from, state)
    {:noreply, state}
  end

  defp handle_request(
         %Message{method: "CANCEL"} = msg,
         from,
         %{call: %{direction: :in} = call} = state
       ) do
    if Message.header(msg, "call-id") == call.call_id do
      send_response(build_response(msg, 200, "OK", state), from, state)

      case state.call_status do
        :incoming ->
          info_log("входящий вызов отменён звонящим (CANCEL)")
          gone = build_response(call.invite, 487, "Request Terminated", state)
          # 487 ретранслируется до ACK
          state = send_final_to_invite(gone, call.invite_from, state, "487")

          {:noreply,
           %{state | call: nil, call_status: :idle, call_error: "входящий вызов отменён"}}

        _ ->
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  defp handle_request(%Message{method: "CANCEL"} = msg, from, state) do
    ok = build_response(msg, 200, "OK", state) |> without_contact()
    send_raw(Message.to_iodata(ok), from, state, "200 OK на CANCEL → #{peer_str(from)}")
    {:noreply, state}
  end

  defp handle_request(%Message{method: "OPTIONS"} = msg, from, state) do
    ok =
      build_response(msg, 200, "OK", state)
      |> without_contact()
      |> Message.put_header("allow", "INVITE, ACK, CANCEL, BYE, OPTIONS")

    send_raw(Message.to_iodata(ok), from, state, "200 OK на OPTIONS → #{peer_str(from)}")
    {:noreply, state}
  end

  defp handle_request(%Message{method: method} = msg, from, state) do
    send_response(build_response(msg, 405, "Method Not Allowed", state), from, state)
    info_log("метод #{method} не поддерживается (405)")
    {:noreply, state}
  end

  defp handle_request(_malformed, _from, state), do: {:noreply, state}

  # ------------------------------------------------- Ответ на входящий INVITE

  defp answer_incoming(%{call: %{direction: :in} = call} = state) do
    info_log("отвечаю на вызов от #{call.remote} (200 OK)")
    sdp = build_sdp(state)

    # To из входящего INVITE (добавляем наш tag); если заголовка нет — собираем заново
    to_hdr =
      Message.header(call.invite, "to") ||
        "<sip:#{state.number}@#{server_host(state)}>"

    ok =
      build_response(call.invite, 200, "OK", state)
      |> Message.put_header("to", to_hdr <> ";tag=#{call.local_tag}")
      |> Message.put_header("contact", contact_uri(state))
      |> Message.put_header("content-type", "application/sdp")
      |> Message.put_header("content-length", to_string(byte_size(sdp)))
      |> Map.put(:body, sdp)

    state = send_final_to_invite(ok, call.invite_from, state, "200 OK")
    %{state | call_status: :active, call_error: nil}
  end

  defp reject_incoming(%{call: %{direction: :in} = call} = state) do
    info_log("отклоняю входящий вызов от #{call.remote} (486)")
    busy = build_response(call.invite, 486, "Busy Here", state)
    state = send_final_to_invite(busy, call.invite_from, state, "486")
    %{state | call: nil, call_status: :idle, call_error: "вызов отклонён"}
  end

  # ------------------------------------------------------------- Отправка

  # клиентская транзакция: отправить + ретранслировать до финального ответа
  defp put_client_tx(state, key, kind, %Message{} = msg, target) do
    iodata = Message.to_iodata(msg)
    send_raw(iodata, target, state, "#{msg |> Message.summary()} → #{peer_str(target)}")
    timer = Process.send_after(self(), {:tx_retry, key}, @t1_ms * 2)

    tx = %{
      kind: kind,
      method: msg.method,
      iodata: iodata,
      target: target,
      timer: timer,
      retries: 0,
      retries_factor: 1
    }

    %{state | client_tx: Map.put(state.client_tx, key, tx)}
  end

  defp send_request_stateless(msg, target, state) do
    iodata = Message.to_iodata(msg)
    send_raw(iodata, target, state, "#{Message.summary(msg)} → #{peer_str(target)}")
  end

  # финальный ответ на INVITE: ретранслируем до ACK
  defp send_final_to_invite(%Message{} = msg, target, state, summary) do
    iodata = Message.to_iodata(msg)
    send_raw(iodata, target, state, "#{summary} → #{peer_str(target)}")
    call_id = call_id_of(msg)
    timer = Process.send_after(self(), {:final_retry, call_id}, @t1_ms * 2)
    pf = %{iodata: iodata, target: target, timer: timer, call_id: call_id}
    put_pending_final(state, pf)
  end

  defp put_pending_final(state, pf) do
    case state.pending_final do
      %{timer: t} when not is_nil(t) -> Process.cancel_timer(t)
      _ -> :ok
    end

    # финальный ответ отправлен — 180 Ringing больше не ретранслируем
    state = clear_prov(state)
    %{state | pending_final: pf}
  end

  # 180 Ringing: отправить и ретранслировать до финального ответа
  defp start_ringing(%Message{} = ringing, from, state, call_id) do
    iodata = Message.to_iodata(ringing)
    send_raw(iodata, from, state, "180 Ringing → #{peer_str(from)}")
    timer = Process.send_after(self(), {:prov_retry, call_id}, @t1_ms * 2)
    prov = %{iodata: iodata, target: from, timer: timer, call_id: call_id, retries: 0}
    info_log("отправлен 180 Ringing — ждём ответа пользователя")
    %{state | prov: prov}
  end

  defp clear_prov(%{prov: %{timer: t}} = state) do
    if t, do: Process.cancel_timer(t)
    %{state | prov: nil}
  end

  defp clear_prov(state), do: state

  defp call_id_of(msg), do: Message.header(msg, "call-id")

  defp send_ack(%Message{} = invite_200, call, target, state) do
    cseq = elem(Message.cseq(invite_200) || {call.cseq, "INVITE"}, 0)

    ack =
      %Message{
        type: :request,
        method: "ACK",
        uri: dialog_uri(%{call | dialog_target: target}, state)
      }
      |> put_via(new_branch())
      |> Message.put_header("max-forwards", "70")
      |> Message.put_header(
        "from",
        "<sip:#{state.number}@#{server_host(state)}>;tag=#{call.local_tag}"
      )
      |> Message.put_header(
        "to",
        "<sip:#{call.remote}@#{server_host(state)}>" <>
          tag_suffix(header_param(invite_200, "to", "tag"))
      )
      |> Message.put_header("call-id", call.call_id)
      |> Message.put_header("cseq", "#{cseq} ACK")
      |> Message.put_header("user-agent", user_agent())
      |> Message.put_header("content-length", "0")

    send_request_stateless(ack, target, state)
    state
  end

  defp send_ack_stateless(failure_3xx, call, from, state) do
    send_ack(failure_3xx, call, from, state)
  end

  defp send_response(msg, target, state) do
    send_raw(
      Message.to_iodata(msg),
      target,
      state,
      "#{Message.summary(msg)} → #{peer_str(target)}"
    )
  end

  defp send_raw(iodata, {ip, port}, state, log_line) do
    :gen_udp.send(state.socket, ip, port, iodata)

    broadcast_log(%{
      dir: "out",
      peer: peer_str({ip, port}),
      first: log_line,
      raw: IO.iodata_to_binary(iodata)
    })
  end

  # ------------------------------------------------------- Сборка ответов

  defp build_response(req, code, reason, _state) do
    %Message{
      type: :response,
      status_code: code,
      reason: reason,
      headers: []
    }
    |> then(fn m ->
      Enum.reduce(["via", "from", "to", "call-id", "cseq"], m, fn h, acc ->
        case Message.header(req, h) do
          nil -> acc
          v -> Message.put_header(acc, h, v)
        end
      end)
    end)
    |> Message.put_header("user-agent", user_agent())
    |> Message.put_header("content-length", "0")
  end

  defp without_contact(msg), do: msg

  defp put_via(msg, branch) do
    {ip_str, port} = local_endpoint()
    Message.put_header(msg, "via", "SIP/2.0/UDP #{ip_str}:#{port};branch=#{branch};rport")
  end

  defp local_endpoint do
    :persistent_term.get({__MODULE__, :local}, {"127.0.0.1", 5080})
  end

  defp store_local_endpoint(ip_str, port) do
    :persistent_term.put({__MODULE__, :local}, {ip_str, port})
  end

  # --------------------------------------------------------- Digest auth

  @doc false
  def parse_challenge(nil), do: nil

  def parse_challenge(header) do
    header = String.replace_prefix(header, "Digest ", "")

    params =
      header
      |> then(&Regex.scan(~r/(\w+)=(?:"([^"]*)"|([^",\s]+))/, &1))
      |> Enum.reduce(%{}, fn [_, k | rest], acc ->
        Map.put(acc, String.downcase(k), List.last(rest) || "")
      end)

    if Map.has_key?(params, "nonce"), do: params, else: nil
  end

  defp digest_auth(challenge, method, uri, state) do
    realm = Map.get(challenge, "realm", "")
    nonce = Map.get(challenge, "nonce", "")
    qop = Map.get(challenge, "qop")
    opaque = Map.get(challenge, "opaque")

    ha1 = md5hex("#{state.number}:#{realm}:#{state.password}")
    ha2 = md5hex("#{method}:#{uri}")

    {response, extra} =
      if qop && String.contains?(qop, "auth") do
        cnonce = rand_hex(8)
        nc = "00000001"
        resp = md5hex("#{ha1}:#{nonce}:#{nc}:#{cnonce}:auth:#{ha2}")
        {resp, ~s[,qop=auth,nc=#{nc},cnonce="#{cnonce}"]}
      else
        {md5hex("#{ha1}:#{nonce}:#{ha2}"), ""}
      end

    opaque_part = if opaque, do: ~s[,opaque="#{opaque}"], else: ""

    "Digest " <>
      ~s[username="#{state.number}", realm="#{realm}", nonce="#{nonce}", uri="#{uri}", response="#{response}"#{extra}#{opaque_part}, algorithm=MD5]
  end

  defp md5hex(str), do: :crypto.hash(:md5, str) |> Base.encode16(case: :lower)

  # ----------------------------------------------------------------- SDP

  @doc false
  def build_sdp(_state) do
    {ip_str, port} = local_endpoint()
    sess_id = rand_int_str()

    # аудио не передаём: порт 9 (discard), только сигнализация
    "v=0\r\n" <>
      "o=sipphone #{sess_id} 2 IN IP4 #{ip_str}\r\n" <>
      "s=sip_phone\r\n" <>
      "c=IN IP4 #{ip_str}\r\n" <>
      "t=0 0\r\n" <>
      "m=audio #{port} RTP/AVP 0 8 101\r\n" <>
      "a=rtpmap:0 PCMU/8000\r\n" <>
      "a=rtpmap:8 PCMA/8000\r\n" <>
      "a=rtpmap:101 telephone-event/8000\r\n" <>
      "a=inactive\r\n"
  end

  # ------------------------------------------------------------- Утилиты

  defp parse_server(server) do
    server = String.trim(server)

    {host, port} =
      case String.split(server, ":") do
        [h] -> {h, 5060}
        [h, p] -> {h, String.to_integer(p)}
        _ -> {nil, nil}
      end

    if host in [nil, ""] do
      {:error, "не указан адрес SIP-сервера"}
    else
      {:ok, {host, port}}
    end
  rescue
    _ -> {:error, "некорректный адрес сервера"}
  end

  defp resolve_host(host) do
    case :inet.getaddr(String.to_charlist(host), :inet) do
      {:ok, ip} -> {:ok, ip}
      {:error, _} -> {:error, "не удалось разрешить адрес сервера #{host}"}
    end
  end

  # локальный IP интерфейса, через который ходим до сервера
  defp detect_local_ip(server_ip) do
    case :gen_udp.open(0, active: false) do
      {:ok, s} ->
        result =
          with :ok <- :gen_udp.connect(s, server_ip, 5060),
               {:ok, {ip, _}} <- :inet.sockname(s) do
            {:ok, to_string(:inet.ntoa(ip))}
          end

        :gen_udp.close(s)
        result

      _ ->
        {:ok, "127.0.0.1"}
    end
  end

  defp server_host(%{server: {h, _}}), do: h
  defp server_host(_), do: "localhost"

  defp server_target(%{server: {h, p}} = state) do
    case resolve_host(h) do
      {:ok, ip} -> {ip, p}
      {:error, _} -> {{127, 0, 0, 1}, p} |> tap(fn _ -> state end)
    end
  end

  defp server_target(_), do: {{127, 0, 0, 1}, 5060}

  defp contact_uri(state) do
    {ip_str, port} = local_endpoint()
    expires_part = if state.reg_expires == 0, do: ";expires=0", else: ""
    "<sip:#{state.number}@#{ip_str}:#{port};transport=udp#{expires_part}>"
  end

  # цель в диалоге: Contact из 200 OK (или входящего INVITE), иначе — источник пакета
  defp dialog_target(msg, from, state) do
    case addr_uri(msg, "contact") do
      nil ->
        from

      uri ->
        case sip_uri_hostport(uri) do
          {:ok, {host, port}} ->
            case resolve_host(host) do
              {:ok, ip} -> {ip, port}
              {:error, _} -> from
            end

          :error ->
            from
        end
        |> tap(fn _ -> state end)
    end
  end

  defp contact_of(msg, from) do
    case addr_uri(msg, "contact") do
      nil ->
        nil

      uri ->
        uri
        |> tap(fn _ -> from end)
    end
  end

  @doc false
  def sip_uri_hostport(uri) do
    authority =
      uri
      |> String.replace(~r/^sips?:/i, "")
      |> String.split(";")
      |> hd()
      |> String.split("@")
      |> List.last()

    case String.split(authority, ":") do
      [host] ->
        port =
          case :inet.getaddr(String.to_charlist(host), :inet) do
            {:ok, _} -> 5060
            _ -> 5060
          end

        {:ok, {host, port}}

      [host, p] ->
        case Integer.parse(p) do
          {port, _} -> {:ok, {host, port}}
          :error -> :error
        end

      _ ->
        :error
    end
  end

  defp peer_str({ip, port}), do: "#{:inet.ntoa(ip)}:#{port}"

  defp new_branch, do: "z9hG4bK" <> rand_hex(12)
  defp new_tag, do: rand_hex(8)

  defp new_call_id(_state) do
    {ip, port} = local_endpoint()
    rand_hex(12) <> "@" <> ip <> ":" <> to_string(port)
  end

  defp rand_hex(n), do: :crypto.strong_rand_bytes(n) |> Base.encode16(case: :lower)
  defp rand_int_str, do: System.system_time(:millisecond) |> div(1) |> Integer.to_string()
  defp user_agent, do: "ElixirSipPhone/0.1"

  # -------------------------------------------------- Лог и состояние API

  defp log_in(msg, ip, port) do
    broadcast_log(%{
      dir: "in",
      peer: "#{:inet.ntoa(ip)}:#{port}",
      first: Message.summary(msg),
      raw: Message.to_binary(msg)
    })
  end

  defp info_log(text) do
    broadcast_log(%{dir: "info", peer: "", first: text, raw: text})
  end

  defp broadcast_log(entry) do
    entry = Map.merge(%{ts: System.system_time(:millisecond)}, entry)
    LogBuffer.push(entry)
    PubSub.broadcast({:sip_log, entry})
  end

  defp public_state(state) do
    server =
      case state.server do
        {h, p} -> "#{h}:#{p}"
        nil -> ""
      end

    %{
      registration: to_string(state.reg_status),
      reg_error: state.reg_error,
      call: to_string(state.call_status),
      call_error: state.call_error,
      remote: (state.call && state.call.remote) || nil,
      server: server,
      number: state.number,
      local_endpoint: local_endpoint() |> then(fn {ip, port} -> "#{ip}:#{port}" end)
    }
  end

  # фиксация целевого диалога ACK для ACK по contact: target может быть {ip,port}
  defp fail_operation(:register, state),
    do: %{state | reg_status: :failed, reg_error: "сервер не отвечает"}

  defp fail_operation(:invite, %{call_status: :calling} = state),
    do: %{state | call: nil, call_status: :idle, call_error: "сервер/абонент не отвечает"}

  defp fail_operation(_, state), do: state
end
