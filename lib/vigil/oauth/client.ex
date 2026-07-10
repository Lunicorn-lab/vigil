defmodule Vigil.OAuth.Client do
  @moduledoc """
  Resolves a `client_id` to `%{client_id:, name:, redirect_uris:}` — either a
  DCR-registered client (looked up in `:dets`) or an `https://` CIMD URL
  (fetched and validated). Returns `{:ok, client}` or `:error`.
  """

  alias Vigil.OAuth.{Store, Cimd}

  def resolve(client_id, now \\ System.system_time(:second)) do
    case Store.get_client(client_id) do
      {:ok, attrs} ->
        {:ok, %{client_id: client_id, name: attrs.name, redirect_uris: attrs.redirect_uris}}

      :error ->
        if String.starts_with?(client_id, "https://") do
          Cimd.fetch(client_id, now)
        else
          :error
        end
    end
  end
end
