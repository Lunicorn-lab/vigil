defmodule Vigil.OAuth.ConsentPage do
  @moduledoc "Minimal inline-EEx consent page. No template directory, no assets."

  @template """
  <!DOCTYPE html>
  <html lang="de">
  <head>
  <meta charset="utf-8">
  <title>vigil — Zugriff erlauben?</title>
  <style>
  body { font-family: system-ui, sans-serif; max-width: 32rem; margin: 4rem auto; padding: 0 1rem; }
  .warn { color: #a33; font-weight: bold; }
  .err { color: #a33; }
  input[type=password] { width: 100%; padding: .5rem; font-size: 1rem; box-sizing: border-box; }
  button { padding: .5rem 1rem; font-size: 1rem; margin-right: .5rem; margin-top: 1rem; }
  </style>
  </head>
  <body>
  <h1>vigil — Zugriff erlauben?</h1>
  <p><strong><%= client_name %></strong> möchte auf deinen Vault zugreifen.</p>
  <p>Redirect-Host: <strong><%= redirect_host %></strong></p>
  <%= if loopback do %>
  <p class="warn">Achtung: lokale Redirect-Adresse (localhost/127.0.0.1) — jeder lokale Prozess auf diesem Rechner kann sich als dieser Client ausgeben.</p>
  <% end %>
  <%= if error do %>
  <p class="err"><%= error %></p>
  <% end %>
  <form method="post" action="/oauth/authorize">
  <%= for {k, v} <- hidden_fields do %>
  <input type="hidden" name="<%= k %>" value="<%= v %>">
  <% end %>
  <input type="password" name="password" placeholder="Passwort" autofocus required>
  <p>
  <button type="submit" name="decision" value="allow">Zulassen</button>
  <button type="submit" name="decision" value="deny">Ablehnen</button>
  </p>
  </form>
  </body>
  </html>
  """

  @doc """
  Renders the consent page. `client_name` and hidden field values are treated
  as untrusted (client-registration-controlled) and HTML-escaped.
  """
  def render(
        %{client_name: client_name, redirect_uri: redirect_uri, hidden_fields: hidden_fields} =
          params
      ) do
    redirect_host = URI.parse(redirect_uri).host || redirect_uri
    loopback = redirect_host in ["localhost", "127.0.0.1"]

    escaped_hidden =
      Enum.map(hidden_fields, fn {k, v} -> {k, escape(to_string(v))} end)

    bindings = [
      client_name: escape(client_name),
      redirect_host: escape(redirect_host),
      loopback: loopback,
      error: Map.get(params, :error) && escape(params.error),
      hidden_fields: escaped_hidden
    ]

    EEx.eval_string(@template, bindings)
  end

  defp escape(value), do: Plug.HTML.html_escape(value)
end
