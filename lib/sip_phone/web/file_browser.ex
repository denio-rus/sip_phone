defmodule SipPhone.Web.FileBrowser do
  @moduledoc """
  Read-only просмотр файлов проекта для web-секции «Проводник».
  Корень дерева — каталог, содержащий приложение (на уровень выше cwd,
  куда сервер ставит run.sh): так в дереве видны документы проекта, а не
  только Mix-каталог. Защита от выхода за корень: `..` и абсолютные пути
  после нормализации отсекаются.
  """

  @tech_dirs ~w(deps _build)
  # фича «Показ скрытых папок»: из dot-записей в дереве остаётся только этот
  # каталог (настройки агентов проекта должны быть видны в «Проводнике»)
  @visible_hidden_dirs ~w(.claude)
  @preview_limit 256 * 1024

  @type entry :: %{name: String.t(), type: String.t(), size: non_neg_integer()}

  @typedoc "Превью файла: `content` только для текстовых файлов (бинарным — nil)."
  @type preview :: %{
          path: String.t(),
          size: non_neg_integer(),
          binary: boolean(),
          truncated: boolean(),
          content: String.t() | nil
        }

  @doc "Корень дерева — каталог проекта (на уровень выше каталога приложения)."
  @spec root() :: String.t()
  # на уровень выше cwd (sip_phone/), чтобы «Проводник» показывал и документы
  # проекта (work_log.md, постановка), а не только дерево Mix-приложения
  def root, do: Path.dirname(File.cwd!())

  @doc """
  Список содержимого каталога относительно корня проекта ("" — корень).
  Каталоги первыми, затем файлы, в алфавитном порядке; скрытые (с точки)
  записи пропускаются — исключение только для каталога `.claude`
  (`@visible_hidden_dirs`); технические записи (deps, _build) — всегда.
  """
  @spec list(String.t() | nil) :: {:ok, [entry()]} | {:error, term()}
  def list(rel) do
    with {:ok, path} <- resolve(rel) do
      case File.ls(path) do
        {:ok, names} ->
          entries =
            names
            |> Enum.map(&entry_info(path, &1))
            |> Enum.reject(&is_nil/1)
            |> Enum.filter(&visible?/1)
            |> Enum.sort_by(&{&1.type != "dir", &1.name})

          {:ok, entries}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Чтение файла для превью: до 256 КБ (`@preview_limit`), с флагами binary
  (нечитаемый как UTF-8 текст) и truncated (обрезан ли вывод).
  """
  @spec read(String.t() | nil) :: {:ok, preview()} | {:error, :forbidden | :not_found}
  def read(rel) do
    with {:ok, path} <- resolve(rel) do
      if File.regular?(path), do: preview(path, rel), else: {:error, :not_found}
    end
  end

  defp preview(path, rel) do
    size = File.stat!(path).size
    {:ok, raw} = File.read(path)
    chunk = binary_part(raw, 0, min(byte_size(raw), @preview_limit))

    if binary?(chunk) do
      {:ok, %{path: rel, size: size, binary: true, truncated: false, content: nil}}
    else
      {:ok,
       %{
         path: rel,
         size: size,
         binary: false,
         truncated: byte_size(raw) > @preview_limit,
         content: chunk
       }}
    end
  end

  # путь после нормализации обязан остаться внутри корня проекта
  defp resolve(rel) do
    root = root()
    full = Path.expand(rel || ".", root)

    cond do
      full != root and !String.starts_with?(full, root <> "/") -> {:error, :forbidden}
      not File.exists?(full) -> {:error, :not_found}
      true -> {:ok, full}
    end
  end

  # фильтрация по готовой записи: тип уже известен, исключение — только папки
  defp visible?(%{type: "dir", name: name}), do: not hidden?(name) or name in @visible_hidden_dirs
  defp visible?(%{name: name}), do: not hidden?(name)

  defp hidden?(name), do: String.starts_with?(name, ".")

  defp entry_info(dir, name) do
    full = Path.join(dir, name)

    cond do
      File.dir?(full) ->
        if name in @tech_dirs, do: nil, else: %{name: name, type: "dir", size: 0}

      File.regular?(full) ->
        %{name: name, type: "file", size: File.stat!(full).size}

      true ->
        nil
    end
  end

  defp binary?(chunk), do: !String.valid?(chunk) or :binary.match(chunk, <<0>>) != :nomatch
end
