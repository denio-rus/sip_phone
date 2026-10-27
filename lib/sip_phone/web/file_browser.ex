defmodule SipPhone.Web.FileBrowser do
  @moduledoc """
  Read-only просмотр файлов проекта для web-секции «Проводник».
  Корень дерева — каталог, содержащий приложение (на уровень выше cwd,
  куда сервер ставит run.sh): так в дереве видны документы проекта, а не
  только Mix-каталог. Защита от выхода за корень: `..` и абсолютные пути
  после нормализации отсекаются.
  """

  @tech_dirs ~w(deps _build)
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
  и технические записи (deps, _build) пропускаются.
  """
  @spec list(String.t() | nil) :: {:ok, [entry()]} | {:error, term()}
  def list(rel) do
    with {:ok, path} <- resolve(rel) do
      case File.ls(path) do
        {:ok, names} ->
          entries =
            names
            |> Enum.reject(&hidden?/1)
            |> Enum.map(&entry_info(path, &1))
            |> Enum.reject(&is_nil/1)
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
      if File.regular?(path) do
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
      else
        {:error, :not_found}
      end
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
