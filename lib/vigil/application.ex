defmodule Vigil.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:vigil, :autostart, true) do
        [
          {Vigil.Store,
           vault_path: Application.fetch_env!(:vigil, :vault_path),
           exclude: Application.fetch_env!(:vigil, :exclude),
           git_remote: Application.fetch_env!(:vigil, :git_remote)},
          Vigil.MCP.Envelope,
          {Bandit, plug: Vigil.MCP.Server, port: Application.fetch_env!(:vigil, :port)}
        ]
      else
        []
      end

    opts = [strategy: :one_for_one, name: Vigil.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
