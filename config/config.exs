import Config

# Боевые значения портов; перекрываются переменными окружения
# SIP_PHONE_SIP_PORT / SIP_PHONE_WEB_PORT (Elixir отслеживает System.get_env
# в config и перекомпилирует его при смене значения).

config :sip_phone,
  sip_port: String.to_integer(System.get_env("SIP_PHONE_SIP_PORT") || "5080"),
  web_port: String.to_integer(System.get_env("SIP_PHONE_WEB_PORT") || "8212")

if Mix.env() == :test do
  import_config "test.exs"
end
