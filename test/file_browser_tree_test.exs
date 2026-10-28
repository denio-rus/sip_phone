defmodule FileTreeFixture do
  @moduledoc """
  Каркас тестов отображения файлового дерева «Проводника».

  `SipPhone.Web.FileBrowser.root/0` вычисляется как каталог на уровень выше
  cwd, поэтому фикстура строится в `<tmp>/probe/` с подкаталогом `app/`
  («каталог приложения»): `with_tree/1` делает `File.cd!(probe/app)` и на время
  теста корнем дерева становится `probe/`. После теста cwd восстанавливается,
  временный каталог удаляется — даже если ассершн упал.

  Дерево фикстуры:

      probe/                 <- FileBrowser.root() при cwd = probe/app
        app/mix.exs          <- «каталог приложения», имитирует sip_phone/
        README.md            <- видимый файл
        src/handler.ex       <- видимая папка
        .claude/             <- единственная видимая dot-папка (фича «Показ скрытых папок»)
        .secrets/            <- скрытая папка, должна оставаться невидимой
        .hidden_file         <- скрытый файл, невидим (исключение — только для папок)
        deps/, _build/       <- технические каталоги, скрыты намеренно
  """

  @tree %{
    "app/mix.exs" => "defmodule App.MixProject",
    "README.md" => "видимый файл",
    "src/handler.ex" => "defmodule Handler",
    ".claude/settings.json" => "{}",
    ".claude/commands/run.md" => "# run",
    ".secrets/keys.txt" => "secret",
    ".hidden_file" => "dot file",
    "deps/some_dep/README" => "dep",
    "_build/dev/lib/app/app.beam" => "beam"
  }

  @doc """
  Собрать фикстуру, выполнить `fun.(tree_root)` с cwd внутри `app/` и
  убрать всё за собой. Возвращает результат `fun`.
  """
  def with_tree(fun) when is_function(fun, 1) do
    tmp = Path.join(System.tmp_dir!(), "file_tree_fixture_#{:erlang.unique_integer([:positive])}")
    tree_root = Path.join(tmp, "probe")

    for {rel, content} <- @tree do
      path = Path.join(tree_root, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end

    prev = File.cwd!()
    File.cd!(Path.join(tree_root, "app"))

    try do
      fun.(tree_root)
    after
      File.cd!(prev)
      File.rm_rf!(tmp)
    end
  end

  @doc "Имена записей из `{:ok, entries}` в порядке вывода."
  def names({:ok, entries}), do: Enum.map(entries, & &1.name)
end

defmodule SipPhone.Web.FileBrowserTreeTest do
  @moduledoc """
  Тесты отображения файлового дерева (`SipPhone.Web.FileBrowser` + эндпоинт
  «Проводника»): каркас проверяет текущие контракты вывода (видимые записи,
  порядок, фильтрация `deps`/`_build`), секция фичи — «Показ скрытых папок в
  дереве файлов»: из dot-записей виден только каталог `.claude`, прочие
  скрытые папки и файлы скрыты.
  """
  use ExUnit.Case, async: false

  alias SipPhone.Web.FileBrowser

  # cwd — общий на весь BEAM ресурс, фикстуры переключают его: только async: false

  describe "каркас: отображение видимых записей" do
    test "корень дерева — каталог на уровень выше приложения" do
      FileTreeFixture.with_tree(fn tree_root ->
        assert FileBrowser.root() == tree_root
      end)
    end

    test "видимые папки и файлы попадают в дерево" do
      FileTreeFixture.with_tree(fn _root ->
        names = FileBrowser.list(".") |> FileTreeFixture.names()

        assert "src" in names
        assert "README.md" in names
        refute "deps" in names
        refute "_build" in names
      end)
    end

    test "порядок вывода: каталоги первыми, затем файлы, алфавитно" do
      FileTreeFixture.with_tree(fn _root ->
        {:ok, entries} = FileBrowser.list(".")

        # app/ — тоже видимая папка, как sip_phone/ в реальном дереве;
        # .claude — единственная пропущенная dot-запись (фича), сортируется
        # первой среди каталогов
        assert Enum.map(entries, & &1.name) == [".claude", "app", "src", "README.md"]
        assert Enum.map(entries, & &1.type) == ["dir", "dir", "dir", "file"]
      end)
    end

    test "контракт записи: name/type/size" do
      FileTreeFixture.with_tree(fn _root ->
        {:ok, entries} = FileBrowser.list(".")
        file = Enum.find(entries, &(&1.name == "README.md"))

        assert file.type == "file"
        assert is_integer(file.size) and file.size > 0
      end)
    end

    test "выход за корень дерева запрещён" do
      FileTreeFixture.with_tree(fn _root ->
        assert {:error, :forbidden} = FileBrowser.list("../../etc")
      end)
    end
  end

  describe "фича «Показ скрытых папок в дереве файлов»" do
    # Из dot-записей в дереве виден только каталог .claude; прочие скрытые
    # папки и файлы отсекаются как раньше.

    test "папка .claude видна в корне дерева" do
      FileTreeFixture.with_tree(fn _root ->
        names = FileBrowser.list(".") |> FileTreeFixture.names()

        assert ".claude" in names,
               "скрытая папка .claude не отображается в дереве: #{inspect(names)}"
      end)
    end

    test "прочие скрытые папки не видны в корне дерева" do
      FileTreeFixture.with_tree(fn _root ->
        names = FileBrowser.list(".") |> FileTreeFixture.names()

        refute ".secrets" in names
      end)
    end

    test "исключение распространяется только на папки — скрытые файлы не видны" do
      FileTreeFixture.with_tree(fn _root ->
        names = FileBrowser.list(".") |> FileTreeFixture.names()

        refute ".hidden_file" in names
      end)
    end

    test "содержимое .claude раскрывается как обычная папка" do
      FileTreeFixture.with_tree(fn _root ->
        names = FileBrowser.list(".claude") |> FileTreeFixture.names()

        assert "settings.json" in names
        assert "commands" in names
      end)
    end

    test "папка .claude реального проекта видна в дереве" do
      root = FileBrowser.root()

      if File.dir?(Path.join(root, ".claude")) do
        names = FileBrowser.list(".") |> FileTreeFixture.names()

        assert ".claude" in names,
               "в реальном дереве (#{root}) папка .claude не отображается: #{inspect(names)}"
      else
        IO.puts(:stderr, "Пропущено: в #{root} нет каталога .claude")
      end
    end
  end
end
