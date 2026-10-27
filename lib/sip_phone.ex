defmodule SipPhone do
  @moduledoc """
  Корневой модуль SIP-телефона с веб-интерфейсом. Приложения-фичи здесь нет —
  вся логика в `SipPhone.SIP.Stack` (SIP-стейт-машина) и `SipPhone.Web.Router`
  (HTTP/WS). Модуль оставлен как точка входа для doctest'ов и общего обзора.
  """

  @doc """
  Функция-заглушка из каркаса `mix new`; живёт только как sanity-проверка
  того, что doctest'ы исполняются.

  ## Examples

      iex> SipPhone.hello()
      :world

  """
  def hello do
    :world
  end
end
