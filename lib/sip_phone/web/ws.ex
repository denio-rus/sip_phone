defmodule SipPhone.Web.WS do
  @moduledoc """
  WebSocket для страниц интерфейса: толкает SIP-лог и состояние телефона.
  Лог — push через PubSub; состояние опрашивается каждые 400 мс (дёшево и
  надёжно: не нужно втыкать broadcast в каждую ветку стейт-машины).
  """

  @behaviour WebSock

  alias SipPhone.SIP.{LogBuffer, Stack}

  @status_interval 400

  @impl true
  def init(_opts) do
    SipPhone.PubSub.subscribe()
    schedule_status()
    current = Stack.state()

    messages = [
      {:text, Jason.encode!(%{type: "state", data: current})},
      {:text, Jason.encode!(%{type: "log_history", entries: LogBuffer.all()})}
    ]

    {:push, messages, %{last_status: current}}
  end

  @impl true
  def handle_in({_text, _opts}, state), do: {:ok, state}

  @impl true
  def handle_info({:sip_log, entry}, state) do
    {:push, {:text, Jason.encode!(%{type: "sip_log", entry: entry})}, state}
  end

  def handle_info(:status_tick, state) do
    schedule_status()
    current = Stack.state()

    if current == state.last_status do
      {:ok, state}
    else
      {:push, {:text, Jason.encode!(%{type: "state", data: current})},
       %{state | last_status: current}}
    end
  end

  def handle_info(_other, state), do: {:ok, state}

  defp schedule_status, do: Process.send_after(self(), :status_tick, @status_interval)
end
