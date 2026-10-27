defmodule SipPhone.PubSub do
  @moduledoc """
  Простейший pub/sub на Registry. Подписчики получают все сообщения.
  """

  @registry __MODULE__
  @topic "events"

  @doc false
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    Supervisor.child_spec(
      {Registry, keys: :duplicate, name: @registry},
      id: __MODULE__
    )
  end

  @doc """
  Подписаться на все события (SIP-лог и т. п.). Возвращает кортеж `Registry.register/3`.
  """
  @spec subscribe() :: {:ok, term()} | {:error, term()}
  def subscribe, do: Registry.register(@registry, @topic, nil)

  @doc """
  Доставить сообщение всем подписчикам (`send/2`, без ожидания).
  """
  @spec broadcast(term()) :: :ok
  def broadcast(message) do
    Registry.dispatch(@registry, @topic, fn entries ->
      for {pid, _} <- entries, do: send(pid, message)
    end)

    :ok
  end
end
