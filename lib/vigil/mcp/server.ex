defmodule Vigil.MCP.Server do
  @moduledoc false
  use Plug.Router

  alias Vigil.MCP.{Tools, Envelope}
  alias Vigil.Store

  @protocol_version "2025-11-25"

  plug :match
  plug :authenticate
  plug :dispatch

  @base_instructions """
  Stimme: Daniels Formulierungen wörtlich übernehmen, nicht glätten. Was er gesagt hat, in seinen Worten — im Zweifel roher zitieren als eleganter zusammenfassen. Eigene Einordnungen und Vorschläge explizit als solche kennzeichnen ("Vorschlag von Claude: …"). Der Vault muss in fünf Jahren nach Daniel klingen, nicht nach Claude.

  Sprache: Deutsch. Englische Fachbegriffe bleiben englisch, wie gesprochen. Keine Übersetzungen in eine Richtung.

  Atomarität: Jeder Abschnitt muss für sich stehen können — er wird einzeln retrieved. Kein "wie oben erwähnt", keine Pronomen mit Bezug außerhalb des Abschnitts.

  Sparsamkeit: Vor create immer search. Lieber append an Bestehendes als neue Note. Keine Zusammenfassungen von Dingen, die schon im Vault stehen.

  type: reference = Fakt über die Welt (altert nicht). decision = Fakt über Daniel (altert). event = hat starts/ends. Im Zweifel decision.

  Skills: skill_write nur auf ausdrückliche Anweisung. Niemals proaktiv Skills anlegen oder ändern — auch nicht, wenn es naheliegt. Skills sind Anweisungen an Claude; sie zu schreiben ist Daniels Entscheidung, nicht Claudes.
  """

  defp authenticate(conn, _opts) do
    expected = Application.fetch_env!(:vigil, :bearer_token)

    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         true <- Plug.Crypto.secure_compare(token, expected) do
      conn
    else
      _ ->
        conn
        |> send_resp(401, "")
        |> halt()
    end
  end

  post "/mcp" do
    handle_mcp(conn)
  end

  get "/mcp" do
    send_resp(conn, 405, "")
  end

  delete "/mcp" do
    send_resp(conn, 405, "")
  end

  match _ do
    send_resp(conn, 404, "")
  end

  defp handle_mcp(conn) do
    with {:ok, protocol_version_ok?, conn} <- check_protocol_version(conn),
         true <- protocol_version_ok?,
         {:ok, body, conn} <- Plug.Conn.read_body(conn),
         {:ok, msg} <- Jason.decode(body) do
      handle_message(conn, msg)
    else
      false ->
        send_resp(conn, 400, "")

      {:error, %Jason.DecodeError{}} ->
        send_json(conn, 200, %{jsonrpc: "2.0", id: nil, error: %{code: -32700, message: "Parse error"}})

      {:error, _} ->
        send_resp(conn, 400, "")
    end
  end

  defp check_protocol_version(conn) do
    case get_req_header(conn, "mcp-protocol-version") do
      [] -> {:ok, true, conn}
      [@protocol_version] -> {:ok, true, conn}
      [_other] -> {:ok, false, conn}
    end
  end

  defp handle_message(conn, %{"method" => "initialize"} = msg) do
    session_id = new_session_id()

    result = %{
      protocolVersion: @protocol_version,
      serverInfo: %{name: "vigil", version: Application.spec(:vigil, :vsn) |> to_string()},
      capabilities: %{tools: %{}},
      instructions: instructions_text()
    }

    conn
    |> put_resp_header("mcp-session-id", session_id)
    |> send_json(200, %{jsonrpc: "2.0", id: msg["id"], result: result})
  end

  defp handle_message(conn, %{"method" => "notifications/initialized"}) do
    send_resp(conn, 202, "")
  end

  defp handle_message(conn, %{"method" => "ping"} = msg) do
    with_session(conn, fn _session_id ->
      send_json(conn, 200, %{jsonrpc: "2.0", id: msg["id"], result: %{}})
    end)
  end

  defp handle_message(conn, %{"method" => "tools/list"} = msg) do
    with_session(conn, fn _session_id ->
      send_json(conn, 200, %{jsonrpc: "2.0", id: msg["id"], result: %{tools: Tools.definitions()}})
    end)
  end

  defp handle_message(conn, %{"method" => "tools/call"} = msg) do
    with_session(conn, fn session_id ->
      params = msg["params"] || %{}
      name = params["name"]
      arguments = params["arguments"] || %{}

      result = Tools.dispatch(name, arguments)
      body = build_tool_call_result(name, result, session_id)
      send_json(conn, 200, %{jsonrpc: "2.0", id: msg["id"], result: body})
    end)
  end

  defp handle_message(conn, msg) do
    if Map.has_key?(msg, "id") do
      send_json(conn, 200, %{
        jsonrpc: "2.0",
        id: msg["id"],
        error: %{code: -32601, message: "Method not found"}
      })
    else
      send_resp(conn, 202, "")
    end
  end

  defp with_session(conn, fun) do
    case get_req_header(conn, "mcp-session-id") do
      [session_id] when session_id != "" -> fun.(session_id)
      _ -> send_resp(conn, 400, "")
    end
  end

  defp build_tool_call_result(name, {:ok, value}, session_id) do
    envelope = envelope_for(name, session_id)
    text = Jason.encode!(Map.merge(%{result: value}, envelope))
    %{content: [%{type: "text", text: text}]}
  end

  defp build_tool_call_result(_name, {:error, message}, _session_id) do
    %{content: [%{type: "text", text: message}], isError: true}
  end

  defp envelope_for("current", session_id), do: Envelope.for_current(session_id)
  defp envelope_for(_name, session_id), do: Envelope.for_call(session_id)

  defp send_json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(payload))
  end

  defp instructions_text do
    @base_instructions <> "\n\n## Domänen (_domains.yml)\n\n```yaml\n" <> Store.instructions_domains_text() <> "\n```"
  end

  defp new_session_id do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    c = Bitwise.band(c, 0x0FFF) |> Bitwise.bor(0x4000)
    d = Bitwise.band(d, 0x3FFF) |> Bitwise.bor(0x8000)

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> IO.iodata_to_binary()
  end
end
