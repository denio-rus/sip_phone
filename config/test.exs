import Config

# Тестовые значения по умолчанию отличаются от боевых (5080/8212), чтобы
# `mix test` поднимал своё приложение параллельно с запущенным ./run.sh —
# без утилизации портов. Переменные окружения перекрывают как обычно.

config :sip_phone,
  sip_port: String.to_integer(System.get_env("SIP_PHONE_SIP_PORT") || "5180"),
  web_port: String.to_integer(System.get_env("SIP_PHONE_WEB_PORT") || "8312")
