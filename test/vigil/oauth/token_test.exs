defmodule Vigil.OAuth.TokenTest do
  use ExUnit.Case, async: true

  alias Vigil.OAuth.Token

  test "random/0 returns 64 lowercase hex chars and is not constant" do
    a = Token.random()
    b = Token.random()
    assert String.length(a) == 64
    assert a =~ ~r/^[0-9a-f]{64}$/
    assert a != b
  end

  test "pkce_valid?/2 verifies the S256 challenge" do
    verifier = "some-random-verifier-string-1234567890"
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    assert Token.pkce_valid?(verifier, challenge)
    refute Token.pkce_valid?("wrong-verifier", challenge)
    refute Token.pkce_valid?(verifier, "wrong-challenge")
  end
end
