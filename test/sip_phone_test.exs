defmodule SipPhoneTest do
  use ExUnit.Case

  alias SipPhone.SIP.Message

  # doctest'ы SipPhone.hello/0 и публичного API Message (@doc-примеры с iex>)
  doctest SipPhone
  doctest SipPhone.SIP.Message

  test "greets the world" do
    assert SipPhone.hello() == :world
  end
end
