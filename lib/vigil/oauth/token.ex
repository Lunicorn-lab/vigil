defmodule Vigil.OAuth.Token do
  @moduledoc false

  @doc "32 random bytes, hex-encoded (64 chars). Used for auth codes, access and refresh tokens."
  def random do
    :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
  end

  @doc "RFC 7636 S256 PKCE check."
  def pkce_valid?(code_verifier, code_challenge)
      when is_binary(code_verifier) and is_binary(code_challenge) do
    computed = :crypto.hash(:sha256, code_verifier) |> Base.url_encode64(padding: false)
    Plug.Crypto.secure_compare(computed, code_challenge)
  end

  def pkce_valid?(_verifier, _challenge), do: false
end
