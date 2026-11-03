import Config

# Тестовые значения по умолчанию отличаются от боевых (5080/8212), чтобы
# `mix test` поднимал своё приложение параллельно с запущенным ./run.sh —
# без утилизации портов. Переменные окружения перекрывают как обычно.

config :sip_phone,
  sip_port: String.to_integer(System.get_env("SIP_PHONE_SIP_PORT") || "5180"),
  web_port: String.to_integer(System.get_env("SIP_PHONE_WEB_PORT") || "8312")

# T1=20 мс вместо боевого 500: транзакционный лестница §17 (ретрансляты и
# таймаут 64·T1) проигрывается тестами за миллисекунды, а не за 32 секунды
config :sip_phone, t1_ms: 20
