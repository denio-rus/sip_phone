defmodule SipPhone.Application do
  @moduledoc """
  Точка входа OTP-приложения: поднимает супервизор с PubSub, кольцевым
  буфером лога, SIP-стеком и HTTP-сервером Cowboy. Порт веб-интерфейса —
  из `SIP_PHONE_WEB_PORT` (по умолчанию 8212).
  """

  use Application

  @impl true
  def start(_type, _args) do
    web_port = String.to_integer(System.get_env("SIP_PHONE_WEB_PORT", "8212"))

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
