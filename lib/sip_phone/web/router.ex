defmodule SipPhone.Web.Router do
  @moduledoc """
  HTTP/WS-слой: тонкие POST/GET-эндпоинты над `SipPhone.SIP.Stack`
  (`/api/register`, `/api/call`, …), статика из `priv/static`,
  сгенерированная документация на `/docs` и upgrade на `SipPhone.Web.WS`
  для `/ws`. Перечень маршрутов — в README.
  """

  use Plug.Router

  alias SipPhone.SIP.Stack
  alias SipPhone.Web.FileBrowser

  # HTML-документация ex_doc генерируется в doc/ у корня проекта, вне priv,
  # поэтому корень отдачи — абсолютный путь от исходников роутера
  # (lib/sip_phone/web -> doc/); {app, path} в Plug.Static резолвится
  # относительно каталога приложения в _build и сюда не подходит.
  @doc_dir Path.expand("../../../doc", __DIR__)

  plug(Plug.Static,
    at: "/",
    from: {:sip_phone, "priv/static"},
    only: ~w(index.html log.html docs.html app.js log.js style.css)
  )

  # страницы ExDoc ссылаются на свои ассеты относительно себя,
  # поэтому префикс /docs для них прозрачен (doc/dist/… ложится на него сам)
  plug(Plug.Static, at: "/docs", from: @doc_dir)

  plug(:match)
  plug(Plug.Parsers, parsers: [:urlencoded, :json], json_decoder: Jason)
  plug(:dispatch)

  get("/", do: send_page(conn, "index.html"))
  get("/log", do: send_page(conn, "log.html"))

  get "/docs" do
    if File.dir?(@doc_dir) do
      send_page(conn, "docs.html")
    else
      conn
      |> put_resp_header("content-type", "text/html; charset=utf-8")
      |> send_resp(200, """
      <!DOCTYPE html>
      <html lang="ru" data-theme="light">
      <head><meta charset="utf-8"><title>Документация — SIP-телефон</title>
      <link rel="stylesheet" href="/style.css"></head>
      <body><main class="phone"><section class="card">
      <h2>Документация не сгенерирована</h2>
      <p>Выполните <code>mix docs</code> в каталоге проекта и обновите страницу.</p>
      <p><a href="/">← Назад к телефону</a></p>
      </section></main></body>
      </html>
      """)
    end
  end

  get "/api/state" do
    json(conn, 200, Stack.state())
  end

  get "/api/log" do
    json(conn, 200, Stack.log())
  end

  # проводник проекта: список каталога и превью файла (path — относительный)
  get "/api/fs" do
    case FileBrowser.list(Map.get(conn.query_params, "path", "")) do
      {:ok, entries} -> json(conn, 200, entries)
      {:error, :forbidden} -> json(conn, 403, %{ok: false, error: "путь за пределами проекта"})
      {:error, _} -> json(conn, 404, %{ok: false, error: "каталог не найден"})
    end
  end

  get "/api/fs/file" do
    case FileBrowser.read(Map.get(conn.query_params, "path", "")) do
      {:ok, info} -> json(conn, 200, info)
      {:error, :forbidden} -> json(conn, 403, %{ok: false, error: "путь за пределами проекта"})
      {:error, _} -> json(conn, 404, %{ok: false, error: "файл не найден"})
    end
  end

  post "/api/register" do
    %{"server" => server, "number" => number, "password" => password} = conn.body_params

    case Stack.register(server, number, password) do
      :ok -> json(conn, 200, %{ok: true})
      {:error, reason} -> json(conn, 400, %{ok: false, error: to_string(reason)})
    end
  end

  post "/api/unregister" do
    Stack.unregister()
    json(conn, 200, %{ok: true})
  end

  post "/api/call" do
    number = Map.get(conn.body_params, "number", "")

    case Stack.call_number(number) do
      :ok -> json(conn, 200, %{ok: true})
      {:error, reason} -> json(conn, 400, %{ok: false, error: to_string(reason)})
    end
  end

  post("/api/answer", do: simple(Stack.answer(), conn))
  post("/api/reject", do: simple(Stack.reject(), conn))
  post("/api/cancel", do: simple(Stack.cancel(), conn))
  post("/api/hangup", do: simple(Stack.hangup(), conn))

  match "/ws" do
    WebSockAdapter.upgrade(conn, SipPhone.Web.WS, [], timeout: :infinity)
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp simple(:ok, conn), do: json(conn, 200, %{ok: true})
  defp simple({:error, reason}, conn), do: json(conn, 400, %{ok: false, error: to_string(reason)})

  defp send_page(conn, name) do
    conn
    |> put_resp_header("content-type", "text/html; charset=utf-8")
    |> send_resp(200, File.read!(static_path(name)))
  end

  defp json(conn, code, term) do
    conn
    |> put_resp_header("content-type", "application/json; charset=utf-8")
    |> send_resp(code, Jason.encode!(term))
  end

  defp static_path(name) do
    Path.join(:code.priv_dir(:sip_phone) |> to_string(), "static/" <> name)
  end
end
