import Config

config :vigil,
  vault_path: System.get_env("VIGIL_VAULT_PATH", Path.expand("test/fixtures/vault", File.cwd!())),
  port: String.to_integer(System.get_env("VIGIL_PORT", "4000")),
  git_remote: System.get_env("VIGIL_GIT_REMOTE", "origin"),
  tz: System.get_env("VIGIL_TZ", "Europe/Berlin"),
  exclude:
    System.get_env("VIGIL_EXCLUDE", "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "")),
  issuer: System.get_env("VIGIL_ISSUER", "http://localhost:4000"),
  resource: System.get_env("VIGIL_RESOURCE", "http://localhost:4000/mcp"),
  auth_password: System.get_env("VIGIL_AUTH_PASSWORD"),
  state_dir: System.get_env("VIGIL_STATE_DIR", Path.expand("tmp/oauth_state", File.cwd!()))
