defmodule Vigil.OAuth.RedirectUriTest do
  use ExUnit.Case, async: true

  alias Vigil.OAuth.RedirectUri

  test "valid_candidate?/1 accepts https and loopback http, rejects everything else" do
    assert RedirectUri.valid_candidate?("https://claude.ai/api/mcp/auth_callback")
    assert RedirectUri.valid_candidate?("http://localhost/callback")
    assert RedirectUri.valid_candidate?("http://127.0.0.1/callback")
    refute RedirectUri.valid_candidate?("http://evil.example.com/cb")
    refute RedirectUri.valid_candidate?("ftp://x/y")
    refute RedirectUri.valid_candidate?("not a url")
  end

  test "matches?/2 requires an exact string match for https" do
    registered = ["https://claude.ai/api/mcp/auth_callback"]
    assert RedirectUri.matches?(registered, "https://claude.ai/api/mcp/auth_callback")
    refute RedirectUri.matches?(registered, "https://claude.ai/api/mcp/auth_callback/")
    refute RedirectUri.matches?(registered, "https://evil.tld/api/mcp/auth_callback")
  end

  test "matches?/2 ignores the port for loopback http on both localhost and 127.0.0.1" do
    registered = ["http://localhost/callback", "http://127.0.0.1/callback"]
    assert RedirectUri.matches?(registered, "http://localhost:3118/callback")
    assert RedirectUri.matches?(registered, "http://127.0.0.1:9999/callback")
    refute RedirectUri.matches?(registered, "http://localhost:3118/other")
    refute RedirectUri.matches?(registered, "http://evil.tld:3118/callback")
  end
end
