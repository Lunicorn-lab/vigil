import Config

config :vigil,
  vault_path: System.get_env("VIGIL_VAULT_PATH", Path.expand("test/fixtures/vault", File.cwd!())),
  bearer_token: System.get_env("VIGIL_BEARER_TOKEN", "dev-token"),
  port: String.to_integer(System.get_env("VIGIL_PORT", "4000")),
  git_remote: System.get_env("VIGIL_GIT_REMOTE", "origin"),
  tz: System.get_env("VIGIL_TZ", "Europe/Berlin"),
  exclude:
    System.get_env("VIGIL_EXCLUDE", "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
