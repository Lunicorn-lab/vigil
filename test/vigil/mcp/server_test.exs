defmodule Vigil.MCP.ServerTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias Vigil.Store
  alias Vigil.MCP.Server
  alias Vigil.OAuth

  setup do
    vault = Vigil.FixtureVault.build()
    on_exit(fn -> Vigil.FixtureVault.cleanup(vault) end)
    start_supervised!({Store, vault_path: vault, exclude: [], git_remote: "origin"})
    start_supervised!(Vigil.MCP.Envelope)

    oauth = Vigil.OAuthCase.setup!()

    token = OAuth.Token.random()

    OAuth.Store.put_token(token, %{
      aud: oauth.resource,
      expires_at: System.system_time(:second) + 3600
    })

    %{vault: vault, token: token}
  end

  defp post(token, body, headers \\ []) do
    conn =
      conn(:post, "/mcp", Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")

    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    Server.call(conn, Server.init([]))
  end

  test "request without a token gets 401 with a WWW-Authenticate challenge" do
    conn =
      conn(:post, "/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "ping"}))
      |> put_req_header("content-type", "application/json")

    conn = Server.call(conn, Server.init([]))
    assert conn.status == 401
    assert conn.resp_body == ""
    [challenge] = get_resp_header(conn, "www-authenticate")
    assert challenge =~ "resource_metadata="
    assert challenge =~ "scope=\"vault\""
  end

  test "request with an unknown token gets 401", %{token: token} do
    conn =
      conn(:post, "/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "ping"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer falsch#{token}")

    conn = Server.call(conn, Server.init([]))
    assert conn.status == 401
  end

  test "initialize returns instructions and a session id header", %{token: token} do
    conn =
      post(token, %{
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: %{protocolVersion: "2025-11-25"}
      })

    assert conn.status == 200
    [session_id] = get_resp_header(conn, "mcp-session-id")
    assert session_id != ""

    body = Jason.decode!(conn.resp_body)
    assert body["result"]["instructions"] =~ "Deutsch"
    assert body["result"]["protocolVersion"] == "2025-11-25"
  end

  test "unknown method returns JSON-RPC -32601", %{token: token} do
    conn =
      post(token, %{jsonrpc: "2.0", id: 7, method: "resources/list"}, [{"mcp-session-id", "abc"}])

    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == -32601
  end

  test "tools/list contains exactly ten tools", %{token: token} do
    conn =
      post(token, %{jsonrpc: "2.0", id: 2, method: "tools/list"}, [{"mcp-session-id", "abc"}])

    body = Jason.decode!(conn.resp_body)
    assert length(body["result"]["tools"]) == 10
  end

  test "tools/call search returns an envelope alongside the result", %{token: token} do
    conn =
      post(
        token,
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

  test "second call in the same session gets the time-only envelope", %{token: token} do
    post(
      token,
      %{jsonrpc: "2.0", id: 1, method: "tools/call", params: %{name: "reload", arguments: %{}}},
      [
        {"mcp-session-id", "session-b"}
      ]
    )

    conn =
      post(
        token,
        %{jsonrpc: "2.0", id: 2, method: "tools/call", params: %{name: "reload", arguments: %{}}},
        [
          {"mcp-session-id", "session-b"}
        ]
      )

    body = Jason.decode!(conn.resp_body)
    text = hd(body["result"]["content"])["text"]
    payload = Jason.decode!(text)
    assert Map.has_key?(payload, "_t")
  end

  test "current always gets only the time envelope, even as the first call", %{token: token} do
    conn =
      post(
        token,
        %{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{name: "current", arguments: %{}}
        },
        [
          {"mcp-session-id", "session-c"}
        ]
      )

    body = Jason.decode!(conn.resp_body)
    payload = Jason.decode!(hd(body["result"]["content"])["text"])
    assert Map.has_key?(payload, "_t")
    refute Map.has_key?(payload, "_")

    conn2 =
      post(
        token,
        %{jsonrpc: "2.0", id: 2, method: "tools/call", params: %{name: "reload", arguments: %{}}},
        [
          {"mcp-session-id", "session-c"}
        ]
      )

    payload2 = Jason.decode!(hd(Jason.decode!(conn2.resp_body)["result"]["content"])["text"])
    assert Map.has_key?(payload2, "_t")
    refute Map.has_key?(payload2, "_")
  end

  test "tool errors set isError and return a plain German message", %{token: token} do
    conn =
      post(
        token,
        %{
          jsonrpc: "2.0",
          id: 4,
          method: "tools/call",
          params: %{
            name: "create",
            arguments: %{path: "bike/terra-speed.md", type: "reference", content: "# X\nx"}
          }
        },
        [{"mcp-session-id", "session-d"}]
      )

    body = Jason.decode!(conn.resp_body)
    result = body["result"]
    assert result["isError"] == true
    assert hd(result["content"])["text"] =~ "existiert bereits"
  end

  test "an access token with the wrong audience is rejected", %{} do
    bad_token = OAuth.Token.random()

    OAuth.Store.put_token(bad_token, %{
      aud: "https://andere.tld/mcp",
      expires_at: System.system_time(:second) + 3600
    })

    conn = post(bad_token, %{jsonrpc: "2.0", id: 1, method: "ping"})
    assert conn.status == 401
  end

  test "a refresh token presented as an access token is rejected" do
    refresh = OAuth.Token.random()

    OAuth.Store.put_token(refresh, %{
      type: :refresh,
      client_id: "abc",
      aud: "https://vault.factory-lab.org/mcp",
      expires_at: System.system_time(:second) + 3600
    })

    conn = post(refresh, %{jsonrpc: "2.0", id: 1, method: "ping"})
    assert conn.status == 401
  end

  test "an expired access token is rejected and removed" do
    expired = OAuth.Token.random()

    OAuth.Store.put_token(expired, %{
      aud: "https://vault.factory-lab.org/mcp",
      expires_at: System.system_time(:second) - 1
    })

    conn = post(expired, %{jsonrpc: "2.0", id: 1, method: "ping"})
    assert conn.status == 401
    assert OAuth.Store.get_token(expired) == :error
  end
end
