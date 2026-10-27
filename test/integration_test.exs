ExUnit.start()

defmodule FakeSIPServer do
  @moduledoc """
  Минимальный SIP-сервер для интеграционного теста: REGISTER (401 + digest,
  затем 200), INVITE -> 180 -> 200, BYE/CANCEL -> 200.
  """

  def start(port) do
    spawn(fn ->
      {:ok, sock} = :gen_udp.open(port, [:binary, active: true])
      loop(sock)
    end)
  end

  def loop(sock) do
    receive do
      {:udp, ^sock, ip, from_port, data} ->
        handle_packet(sock, ip, from_port, data)
        loop(sock)

      :stop ->
        :gen_udp.close(sock)
    end
  end

  defp handle_packet(sock, ip, from_port, data) do
    [head | _] = String.split(data, "\r\n")

    cond do
      String.starts_with?(head, "REGISTER") ->
        if String.contains?(data, "Authorization:") do
          send_resp(sock, ip, from_port, data, 200, "OK", [
            {"contact", "<sip:100@127.0.0.1:5080>;expires=300"}
          ])
        else
          send_resp(sock, ip, from_port, data, 401, "Unauthorized", [
            {"www-authenticate",
             ~s[Digest realm="test", nonce="abc123", algorithm=MD5, qop="auth"]}
          ])
        end

      String.starts_with?(head, "INVITE") ->
        send_resp(sock, ip, from_port, data, 180, "Ringing", [])
        Process.sleep(50)

        send_resp(
          sock,
          ip,
          from_port,
          data,
          200,
          "OK",
          [{"contact", "<sip:101@127.0.0.1:#{from_port}>"}, {"content-type", "application/sdp"}],
          "v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\nt=0 0\r\nm=audio 40000 RTP/AVP 0\r\n"
        )

      String.starts_with?(head, "BYE") ->
        send_resp(sock, ip, from_port, data, 200, "OK", [])

      String.starts_with?(head, "CANCEL") ->
        send_resp(sock, ip, from_port, data, 200, "OK", [])

      true ->
        :ok
    end
  end

  defp send_resp(sock, ip, port, req, code, reason, extra_headers, body \\ "") do
    headers =
      for name <- ["Via", "From", "To", "Call-ID", "CSeq"] do
        {name, extract(req, name)}
      end ++ extra_headers ++ [{"Content-Length", to_string(byte_size(body))}]

    hd_ = Enum.map_join(headers, "", fn {k, v} -> "#{k}: #{v}\r\n" end)
    :gen_udp.send(sock, ip, port, "SIP/2.0 #{code} #{reason}\r\n" <> hd_ <> "\r\n" <> body)
  end

  defp extract(req, name) do
    case Regex.run(~r/^#{name}: (.*)\r$/im, req) do
      [_, v] -> String.trim(v)
      _ -> ""
    end
  end
end

defmodule IntegrationTest do
  use ExUnit.Case, async: false

  alias SipPhone.SIP.Stack

  @server_port 5090
  @phone_ip {127, 0, 0, 1}
  @phone_port 5080

  setup_all do
    pid = FakeSIPServer.start(@server_port)
    Process.register(pid, :fake_sip_srv)
    on_exit(fn -> if pid != nil, do: send(pid, :stop) end)
    :ok
  end

  setup do
    ensure_registered()
    ensure_idle()
    :ok
  end

  defp ensure_registered do
    case Stack.state().registration do
      r when r in ["registered", "registering"] -> :ok
      _ -> Stack.register("127.0.0.1:#{@server_port}", "100", "secret")
    end

    wait_state(:registration, "registered", 6000)
  end

  defp ensure_idle do
    case Stack.state().call do
      "active" -> Stack.hangup()
      "calling" -> Stack.cancel()
      "incoming" -> Stack.reject()
      _ -> :ok
    end

    wait_state(:call, "idle", 8000)
  end

  defp eventually(fun, timeout \\ 4000, step \\ 50) do
    end_t = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, end_t, step)
  end

  defp do_eventually(fun, end_t, step) do
    case fun.() do
      true ->
        :ok

      false ->
        if System.monotonic_time(:millisecond) > end_t do
          flunk("таймаут ожидания условия, текущее состояние: #{inspect(Stack.state())}")
        else
          Process.sleep(step)
          do_eventually(fun, end_t, step)
        end
    end
  end

  # ждёт финальный SIP-ответ, пропуская provisional (100/180/183...)
  defp recv_final(sock, timeout \\ 3000) do
    receive do
      {:udp, ^sock, _, _, data} ->
        if data =~ ~r/^SIP\/2\.0 1\d\d/, do: recv_final(sock, timeout), else: data
    after
      timeout -> flunk("ожидание финального SIP-ответа истекло")
    end
  end

  defp wait_state(field, value, timeout \\ 4000) do
    eventually(fn -> Stack.state()[field] == value end, timeout)
  end

  test "1. регистрация: 401 -> digest -> 200" do
    :ok = Stack.register("127.0.0.1:#{@server_port}", "100", "secret")
    wait_state(:registration, "registered")
  end

  test "2. исходящий вызов: INVITE -> 180 -> 200 -> ACK -> active" do
    :ok = Stack.call_number("101")
    assert Stack.state().call == "calling"
    wait_state(:call, "active")
    assert Stack.state().remote == "101"
  end

  test "3. завершение разговора: BYE -> idle" do
    :ok = Stack.call_number("101")
    wait_state(:call, "active")
    :ok = Stack.hangup()
    wait_state(:call, "idle")
  end

  test "4. входящий вызов: INVITE -> 100 -> answer 200 -> ACK -> BYE от абонента -> idle" do
    {:ok, sock} = :gen_udp.open(5091, [:binary, active: true])

    invite =
      "INVITE sip:100@127.0.0.1:#{@phone_port} SIP/2.0\r\n" <>
        "Via: SIP/2.0/UDP 127.0.0.1:5091;branch=z9hG4bKfake1\r\n" <>
        "From: <sip:101@127.0.0.1>;tag=fakefrom1\r\n" <>
        "To: <sip:100@127.0.0.1>\r\n" <>
        "Call-ID: fake-incoming-1@127.0.0.1\r\n" <>
        "CSeq: 1 INVITE\r\n" <>
        "Contact: <sip:101@127.0.0.1:5091>\r\n" <>
        "Content-Type: application/sdp\r\n" <>
        "Content-Length: 0\r\n\r\n"

    :gen_udp.send(sock, @phone_ip, @phone_port, invite)

    assert_receive {:udp, ^sock, _, _, resp100}, 3000
    assert resp100 =~ "100 Trying"

    # телефон обязан дать 180 Ringing — иначе у звонящего нет гудка
    assert_receive {:udp, ^sock, _, _, resp180}, 3000
    assert resp180 =~ "180 Ringing"

    wait_state(:call, "incoming")
    assert Stack.state().remote == "101"

    :ok = Stack.answer()
    resp200 = recv_final(sock)
    assert resp200 =~ "200 OK"
    wait_state(:call, "active")

    tag = extract_tag(resp200)

    ack =
      "ACK sip:100@127.0.0.1 SIP/2.0\r\n" <>
        "Via: SIP/2.0/UDP 127.0.0.1:5091;branch=z9hG4bKack1\r\n" <>
        "From: <sip:101@127.0.0.1>;tag=fakefrom1\r\n" <>
        "To: <sip:100@127.0.0.1>#{tag}\r\n" <>
        "Call-ID: fake-incoming-1@127.0.0.1\r\n" <>
        "CSeq: 1 ACK\r\nContent-Length: 0\r\n\r\n"

    :gen_udp.send(sock, @phone_ip, @phone_port, ack)
    Process.sleep(200)

    bye =
      "BYE sip:100@127.0.0.1:#{@phone_port} SIP/2.0\r\n" <>
        "Via: SIP/2.0/UDP 127.0.0.1:5091;branch=z9hG4bKbye1\r\n" <>
        "From: <sip:101@127.0.0.1>;tag=fakefrom1\r\n" <>
        "To: <sip:100@127.0.0.1>#{tag}\r\n" <>
        "Call-ID: fake-incoming-1@127.0.0.1\r\n" <>
        "CSeq: 2 BYE\r\nContent-Length: 0\r\n\r\n"

    :gen_udp.send(sock, @phone_ip, @phone_port, bye)
    assert_receive {:udp, ^sock, _, _, bye_resp}, 3000
    assert bye_resp =~ "200 OK"
    wait_state(:call, "idle")
    :gen_udp.close(sock)
  end

  test "5. отклонение входящего: INVITE -> 486 -> idle" do
    {:ok, sock} = :gen_udp.open(5092, [:binary, active: true])

    invite =
      "INVITE sip:100@127.0.0.1:#{@phone_port} SIP/2.0\r\n" <>
        "Via: SIP/2.0/UDP 127.0.0.1:5092;branch=z9hG4bKfake2\r\n" <>
        "From: <sip:102@127.0.0.1>;tag=fakefrom2\r\n" <>
        "To: <sip:100@127.0.0.1>\r\n" <>
        "Call-ID: fake-incoming-2@127.0.0.1\r\n" <>
        "CSeq: 1 INVITE\r\n" <>
        "Contact: <sip:102@127.0.0.1:5092>\r\n" <>
        "Content-Type: application/sdp\r\n" <>
        "Content-Length: 0\r\n\r\n"

    :gen_udp.send(sock, @phone_ip, @phone_port, invite)
    assert_receive {:udp, ^sock, _, _, "SIP/2.0 100" <> _}, 3000
    wait_state(:call, "incoming")

    :ok = Stack.reject()
    # 180 Ringing до reject — ждём именно финальный ответ
    busy = recv_final(sock)
    assert busy =~ "486"
    wait_state(:call, "idle")
    :gen_udp.close(sock)
  end

  test "6. отмена исходящего (CANCEL) и разговор не зависает" do
    :ok = Stack.call_number("103")
    assert Stack.state().call == "calling"
    :ok = Stack.cancel()

    # fake-сервер отвечает на INVITE 200 раньше, чем доходит CANCEL —
    # телефон обязан пережить гонку (ACK+BYE) и вернуться в idle
    wait_state(:call, "idle", 6000)
  end

  test "7. веб: страница и API на 8212" do
    assert http_get("/") =~ "SIP-"
    assert {:ok, _} = Jason.decode(http_get("/api/state"))
    assert http_get("/log") =~ "SIP-"
    assert http_get("/style.css") =~ "--bg"
  end

  test "8. проводник: дерево проекта, превью файла, traversal запрещён" do
    # корень дерева — каталог, содержащий приложение (документы + sip_phone/);
    # deps/_build/скрытые не показываются нигде в дереве
    {:ok, entries} = Jason.decode(http_get("/api/fs"))
    names = Enum.map(entries, & &1["name"])
    assert "sip_phone" in names and "work_log.md" in names
    refute ".claude" in names

    {:ok, sub} = Jason.decode(http_get("/api/fs?path=sip_phone"))
    sub_names = Enum.map(sub, & &1["name"])
    assert "lib" in sub_names and "priv" in sub_names and "test" in sub_names
    refute "deps" in sub_names
    refute "_build" in sub_names

    # выход за корень проекта отсекается на нормализации пути
    assert {403, _} = http_raw("/api/fs?path=../etc")
    assert {403, _} = http_raw("/api/fs/file?path=../../etc/passwd")

    {:ok, info} = Jason.decode(http_get("/api/fs/file?path=sip_phone/mix.exs"))
    assert info["binary"] == false
    assert info["truncated"] == false
    assert info["content"] =~ "SipPhone.MixProject"

    assert {404, _} = http_raw("/api/fs/file?path=no_such_file.exs")
  end

  test "9. документация: ссылка на главной, /docs, раздача doc/" do
    assert http_get("/") =~ ~s|href="/docs"|

    # doc/ — артефакт `mix docs` (в .gitignore), поведение роута зависит от его наличия
    if File.dir?("doc") do
      bar = http_get("/docs")
      assert bar =~ "docs-bar"
      assert bar =~ "/docs/sip_phone.epub"

      assert http_get("/docs/llms.txt") =~ "sip_phone v"
      assert http_get("/docs/index.html") =~ "ExDoc"
    else
      assert http_get("/docs") =~ "mix docs"
    end
  end

  defp http_get(path) do
    {200, body} = http_raw(path)
    body
  end

  defp http_raw(path) do
    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", 8212, [:binary, active: false, packet: :raw])
    :ok = :gen_tcp.send(sock, "GET #{path} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    data = collect(sock, "")
    :gen_tcp.close(sock)
    [status_line | rest] = String.split(data, "\r\n")
    [_, code | _] = String.split(status_line, " ")
    [_head, body] = String.split(Enum.join(rest, "\r\n"), "\r\n\r\n", parts: 2)
    {String.to_integer(code), body}
  end

  defp collect(sock, acc) do
    case :gen_tcp.recv(sock, 0, 2000) do
      {:ok, chunk} -> collect(sock, acc <> chunk)
      {:error, :closed} -> acc
      {:error, _} -> acc
    end
  end

  defp extract_tag(resp) do
    case Regex.run(~r/^To: .*?(;tag=[^;\r\n]+)/im, resp) do
      [_, tag] -> tag
      _ -> ""
    end
  end
end
