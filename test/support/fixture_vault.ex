defmodule Vigil.FixtureVault do
  @moduledoc "Builds a throwaway git-backed copy of test/fixtures/vault for tests."

  @source Path.expand("../fixtures/vault", __DIR__)

  @doc """
  Copies the fixture vault into a fresh temp dir, git-inits it on branch `main`
  with a fixed author/date, and optionally adds a bare remote (`remote: true`)
  so writes can be pushed.

  Returns the vault path (and the remote path, if requested).
  """
  def build(opts \\ []) do
    tmp = Path.join(System.tmp_dir!(), "vigil_test_#{System.unique_integer([:positive])}")
    File.cp_r!(@source, tmp)

    git!(tmp, ["init", "-q"])
    git!(tmp, ["symbolic-ref", "HEAD", "refs/heads/main"])
    git!(tmp, ["config", "user.name", "Daniel"])
    git!(tmp, ["config", "user.email", "daniel@local"])
    git!(tmp, ["add", "-A"])

    git!(
      tmp,
      ["commit", "-q", "-m", "fixtures: initial vault"],
      env: [
        {"GIT_AUTHOR_DATE", "2026-01-01T10:00:00+01:00"},
        {"GIT_COMMITTER_DATE", "2026-01-01T10:00:00+01:00"}
      ]
    )

    if Keyword.get(opts, :remote, false) do
      remote = tmp <> "_remote.git"
      git!(nil, ["init", "-q", "--bare", remote])
      git!(tmp, ["remote", "add", "origin", remote])
      git!(tmp, ["push", "-q", "-u", "origin", "main"])
      {tmp, remote}
    else
      tmp
    end
  end

  def cleanup(path) when is_binary(path) do
    File.rm_rf(path)
    File.rm_rf(path <> "_remote.git")
  end

  defp git!(cwd, args, opts \\ []) do
    env = Keyword.get(opts, :env, [])
    base = [stderr_to_stdout: true]
    base = if cwd, do: base ++ [cd: cwd], else: base
    base = if env != [], do: base ++ [env: env], else: base

    case System.cmd("git", args, base) do
      {out, 0} -> out
      {out, code} -> raise "git #{Enum.join(args, " ")} failed (#{code}): #{out}"
    end
  end
end
