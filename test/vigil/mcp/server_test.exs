defmodule Vigil.MCP.ServerTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias Vigil.Store
  alias Vigil.MCP.Server

  @token "test-token"

  setup do
    vault = Vigil.FixtureVault.build()
    on_exit(fn -> Vigil.FixtureVault.cleanup(vault) end)
    start_supervised!({Store, vault_path: vault, exclude: [], git_remote: "origin"})
    start_supervised!(Vigil.MCP.Envelope)

    prev = Application.get_env(:vigil, :bearer_token)
    Application.put_env(:vigil, :bearer_token, @token)
    on_exit(fn -> Application.put_env(:vigil, :bearer_token, prev) end)

    :ok
  end

  defp post(body, headers \\ []) do
    conn =
      conn(:post, "/mcp", Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{@token}")

    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    Server.call(conn, Server.init([]))
  end

  test "request without a bearer token gets 401" do
    conn =
      conn(:post, "/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "ping"}))
      |> put_req_header("content-type", "application/json")

    conn = Server.call(conn, Server.init([]))
    assert conn.status == 401
    assert conn.resp_body == ""
  end

  test "request with a wrong bearer token gets 401" do
    conn =
      conn(:post, "/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "ping"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer falsch")

    conn = Server.call(conn, Server.init([]))
    assert conn.status == 401
  end

  test "initialize returns instructions and a session id header" do
    conn = post(%{jsonrpc: "2.0", id: 1, method: "initialize", params: %{protocolVersion: "2025-11-25"}})
    assert conn.status == 200
    [session_id] = get_resp_header(conn, "mcp-session-id")
    assert session_id != ""

    body = Jason.decode!(conn.resp_body)
    assert body["result"]["instructions"] =~ "Deutsch"
    assert body["result"]["protocolVersion"] == "2025-11-25"
  end

  test "unknown method returns JSON-RPC -32601" do
    conn = post(%{jsonrpc: "2.0", id: 7, method: "resources/list"}, [{"mcp-session-id", "abc"}])
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == -32601
  end

  test "tools/list contains exactly ten tools" do
    conn = post(%{jsonrpc: "2.0", id: 2, method: "tools/list"}, [{"mcp-session-id", "abc"}])
    body = Jason.decode!(conn.resp_body)
    assert length(body["result"]["tools"]) == 10
  end

  test "tools/call search returns an envelope alongside the result" do
    conn =
      post(
        %{
          jsonrpc: "2.0",
          id: 3,
          method: "tools/call",
          params: %{name: "search", arguments: %{query: "reifen", domain: "bike"}}
        },
        [{"mcp-session-id", "session-a"}]
      )

    body = Jason.decode!(conn.resp_body)
    text = hd(body["result"]["content"])["text"]
    payload = Jason.decode!(text)
    assert is_list(payload["result"])
    assert Map.has_key?(payload, "_")
  end

  test "second call in the same session gets the time-only envelope" do
    post(%{jsonrpc: "2.0", id: 1, method: "tools/call", params: %{name: "reload", arguments: %{}}}, [
      {"mcp-session-id", "session-b"}
    ])

    conn =
      post(%{jsonrpc: "2.0", id: 2, method: "tools/call", params: %{name: "reload", arguments: %{}}}, [
        {"mcp-session-id", "session-b"}
      ])

    body = Jason.decode!(conn.resp_body)
    text = hd(body["result"]["content"])["text"]
    payload = Jason.decode!(text)
    assert Map.has_key?(payload, "_t")
  end

  test "current always gets only the time envelope, even as the first call" do
    conn =
      post(%{jsonrpc: "2.0", id: 1, method: "tools/call", params: %{name: "current", arguments: %{}}}, [
        {"mcp-session-id", "session-c"}
      ])

    body = Jason.decode!(conn.resp_body)
    payload = Jason.decode!(hd(body["result"]["content"])["text"])
    assert Map.has_key?(payload, "_t")
    refute Map.has_key?(payload, "_")

    conn2 =
      post(%{jsonrpc: "2.0", id: 2, method: "tools/call", params: %{name: "reload", arguments: %{}}}, [
        {"mcp-session-id", "session-c"}
      ])

    payload2 = Jason.decode!(hd(Jason.decode!(conn2.resp_body)["result"]["content"])["text"])
    assert Map.has_key?(payload2, "_t")
    refute Map.has_key?(payload2, "_")
  end

  test "tool errors set isError and return a plain German message" do
    conn =
      post(
        %{
          jsonrpc: "2.0",
          id: 4,
          method: "tools/call",
          params: %{name: "create", arguments: %{path: "bike/terra-speed.md", type: "reference", content: "# X\nx"}}
        },
        [{"mcp-session-id", "session-d"}]
      )

    body = Jason.decode!(conn.resp_body)
    result = body["result"]
    assert result["isError"] == true
    assert hd(result["content"])["text"] =~ "existiert bereits"
  end
end
