defmodule SipPhone.Application do
  @moduledoc """
  Точка входа OTP-приложения: поднимает супервизор с PubSub, кольцевым
  буфером лога, SIP-стеком и HTTP-сервером Cowboy. Порт веб-интерфейса —
  из `:sip_phone, :web_port` (`SIP_PHONE_WEB_PORT`, боевая норма 8212;
  в test-окружении свои значения, чтобы `mix test` не конфликтовал с
  запущенным `./run.sh`).
  """

  use Application

  @impl true
  def start(_type, _args) do
    web_port = Application.fetch_env!(:sip_phone, :web_port)

    children = [
      SipPhone.PubSub,
      SipPhone.SIP.LogBuffer,
      SipPhone.SIP.Stack,
      {Plug.Cowboy, scheme: :http, plug: SipPhone.Web.Router, options: [port: web_port]}
    ]

    opts = [strategy: :one_for_one, name: SipPhone.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
