defmodule SipPhone.SIP.LogBuffer do
  @moduledoc """
  Кольцевой буфер SIP-сообщений (ETS) — история для окна лога:
  новые WS-клиенты получают её при подключении.
  """
  use GenServer

  @table __MODULE__
  @limit 300

  @typedoc """
  Запись журнала: SIP-сообщение (`dir` = `"in"` / `"out"`) или служебная строка
  (`"info"`). `first` — краткое описание для ленты, `raw` — исходный текст.
  """
  @type entry :: %{
          required(:ts) => non_neg_integer(),
          required(:dir) => String.t(),
          required(:peer) => String.t(),
          required(:first) => String.t(),
          required(:raw) => String.t(),
          optional(atom()) => term()
        }

  @doc "Запускает GenServer триммера под именем `#{inspect(__MODULE__)}`."
  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc """
  Добавить запись в буфер; сверх лимита в #{@limit} самые старые выбрасываются.
  Safe no-op, если таблица ещё не создана.
  """
  @spec push(entry()) :: :ok
  def push(entry) do
    case :ets.whereis(@table) do
      :undefined ->
        :ok

      _ ->
        idx = :erlang.unique_integer([:monotonic])
        :ets.insert(@table, {idx, entry})
        GenServer.cast(__MODULE__, :trim)
        :ok
    end
  end

  @doc "Вся история от старых записей к новым (пустой список без запущенной таблицы)."
  @spec all() :: [entry()]
  def all do
    case :ets.whereis(@table) do
      :undefined ->
        []

      _ ->
        @table
        |> :ets.tab2list()
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(&elem(&1, 1))
    end
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :bag, :public, read_concurrency: true])
    {:ok, 0}
  end

  @impl true
  def handle_cast(:trim, count) when count < @limit, do: {:noreply, count + 1}

  def handle_cast(:trim, _count) do
    all = :ets.tab2list(@table) |> Enum.sort_by(&elem(&1, 0))
    excess = length(all) - @limit

    if excess > 0 do
      for obj <- Enum.take(all, excess), do: :ets.delete_object(@table, obj)
    end

    {:noreply, 1}
  end
end
