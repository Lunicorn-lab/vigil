defmodule Vigil.MCP.Tools do
  @moduledoc false

  alias Vigil.Store

  @type_enum ["reference", "decision", "event"]

  @doc "Tool definitions for `tools/list`."
  def definitions do
    [
      %{
        name: "search",
        description: "Durchsucht Chunk-Bodies und Überschriften nach einer Phrase.",
        inputSchema: %{
          type: "object",
          properties: %{
            query: %{type: "string", description: "Exakte Suchphrase."},
            domain: %{type: "string", description: "Domäne, auf die gefiltert wird."},
            type: %{type: "string", enum: @type_enum, description: "Filtert nach Chunk-Typ."},
            prefer: %{type: "string", enum: @type_enum, description: "Bevorzugt einen Typ im Ranking."},
            limit: %{type: "integer", description: "Maximale Trefferzahl (Default 10, Max 25)."}
          },
          required: ["query"]
        }
      },
      %{
        name: "read",
        description: "Liest einen Chunk oder das Inhaltsverzeichnis einer Note.",
        inputSchema: %{
          type: "object",
          properties: %{
            id: %{type: "string", description: "pfad#heading-slug oder pfad."},
            backlinks: %{type: "boolean", description: "Hängt verlinkende Chunk-IDs an."}
          },
          required: ["id"]
        }
      },
      %{
        name: "create",
        description: "Legt eine neue Note an.",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "domäne/dateiname.md."},
            type: %{type: "string", enum: @type_enum, description: "Frontmatter-Typ der Note."},
            content: %{type: "string", description: "Markdown-Body, beginnend mit einer H1."},
            starts: %{type: "string", description: "ISO-Zeit, nur bei type: event."},
            ends: %{type: "string", description: "ISO-Zeit, nur bei type: event."},
            force: %{type: "boolean", description: "Überspringt die Duplikat-Prüfung."}
          },
          required: ["path", "type", "content"]
        }
      },
      %{
        name: "append",
        description: "Hängt Inhalt an eine bestehende Note an.",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "domäne/dateiname.md."},
            heading: %{type: "string", description: "Abschnittsname; ohne Angabe ans Dateiende."},
            content: %{type: "string", description: "Anzuhängender Markdown-Text."}
          },
          required: ["path", "content"]
        }
      },
      %{
        name: "replace_section",
        description: "Ersetzt den Body genau eines Chunks.",
        inputSchema: %{
          type: "object",
          properties: %{
            id: %{type: "string", description: "pfad#heading-slug."},
            content: %{type: "string", description: "Neuer Body ohne eigene Überschriften."}
          },
          required: ["id", "content"]
        }
      },
      %{
        name: "current",
        description: "Gibt die aktuelle Zeit sowie aktive/nahe Events zurück.",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "reload",
        description: "Führt git pull aus und parst den Vault neu.",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "skill_list",
        description: "Listet verfügbare Skills mit Description, ohne Body.",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "skill_read",
        description: "Liest den vollständigen Inhalt eines Skills.",
        inputSchema: %{
          type: "object",
          properties: %{name: %{type: "string", description: "Skill-Name, mit oder ohne .md."}},
          required: ["name"]
        }
      },
      %{
        name: "skill_write",
        description: "Legt einen Skill an oder ersetzt ihn; nur auf ausdrückliche Anweisung.",
        inputSchema: %{
          type: "object",
          properties: %{
            name: %{type: "string", description: "Skill-Name, mit oder ohne .md."},
            content: %{type: "string", description: "Vollständiger Dateiinhalt inkl. Frontmatter."}
          },
          required: ["name", "content"]
        }
      }
    ]
  end

  @doc "Dispatches a `tools/call` to the Store. Returns `{:ok, result}` or `{:error, message}`."
  def dispatch("search", args) do
    with {:ok, query} <- require_string(args, "query") do
      Store.search(%{
        query: query,
        domain: opt_string(args, "domain"),
        type: opt_type_atom(args, "type"),
        prefer: opt_type_atom(args, "prefer"),
        limit: opt_integer(args, "limit", 10)
      })
      |> ok()
    end
  end

  def dispatch("read", args) do
    with {:ok, id} <- require_string(args, "id") do
      Store.read(id, opt_bool(args, "backlinks", false))
    end
  end

  def dispatch("create", args) do
    with {:ok, path} <- require_string(args, "path"),
         {:ok, type} <- require_string(args, "type"),
         {:ok, content} <- require_string(args, "content") do
      Store.create(%{
        path: path,
        type: type,
        content: content,
        starts: opt_string(args, "starts"),
        ends: opt_string(args, "ends"),
        force: opt_bool(args, "force", false)
      })
    end
  end

  def dispatch("append", args) do
    with {:ok, path} <- require_string(args, "path"),
         {:ok, content} <- require_string(args, "content") do
      Store.append(%{path: path, heading: opt_string(args, "heading"), content: content})
    end
  end

  def dispatch("replace_section", args) do
    with {:ok, id} <- require_string(args, "id"),
         {:ok, content} <- require_string(args, "content") do
      Store.replace_section(id, content)
    end
  end

  def dispatch("current", _args) do
    ok(Store.current())
  end

  def dispatch("reload", _args) do
    Store.reload()
    ok(%{reloaded: true})
  end

  def dispatch("skill_list", _args) do
    ok(Store.skill_list())
  end

  def dispatch("skill_read", args) do
    with {:ok, name} <- require_string(args, "name") do
      Store.skill_read(name)
    end
  end

  def dispatch("skill_write", args) do
    with {:ok, name} <- require_string(args, "name"),
         {:ok, content} <- require_string(args, "content") do
      Store.skill_write(name, content)
    end
  end

  def dispatch(other, _args), do: {:error, "Unbekanntes Tool: #{other}"}

  defp ok(value), do: {:ok, value}

  defp require_string(args, key) do
    case Map.get(args, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, "Fehlender oder ungültiger Parameter: #{key}"}
    end
  end

  defp opt_string(args, key), do: Map.get(args, key)

  defp opt_bool(args, key, default) do
    case Map.get(args, key) do
      nil -> default
      v when is_boolean(v) -> v
      _ -> default
    end
  end

  defp opt_integer(args, key, default) do
    case Map.get(args, key) do
      nil -> default
      v when is_integer(v) -> v
      v when is_binary(v) -> String.to_integer(v)
      _ -> default
    end
  end

  defp opt_type_atom(args, key) do
    case Map.get(args, key) do
      "reference" -> :reference
      "decision" -> :decision
      "event" -> :event
      _ -> nil
    end
  end
end
