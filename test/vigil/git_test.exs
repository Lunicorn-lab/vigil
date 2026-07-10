defmodule Vigil.GitTest do
  use ExUnit.Case, async: true

  alias Vigil.Git

  setup do
    vault = Vigil.FixtureVault.build(remote: true)
    {tmp, remote} = vault

    on_exit(fn ->
      Vigil.FixtureVault.cleanup(tmp)
      File.rm_rf(remote)
    end)

    {:ok, vault: tmp, remote: remote}
  end

  test "log_metadata returns created_at/updated_at/last_author from a single git log call", %{
    vault: vault
  } do
    meta = Git.log_metadata(vault)

    assert %{created_at: %DateTime{}, updated_at: %DateTime{}, last_author: "Daniel"} =
             meta["bike/terra-speed.md"]
  end

  test "add_commit authors as vigil and push succeeds", %{vault: vault} do
    File.write!(Path.join(vault, "bike/neu.md"), "---\ntype: reference\n---\n# Neu\ntext\n")

    assert {:ok, %{updated_at: %DateTime{}, last_author: "vigil"}} =
             Git.add_commit(vault, "bike/neu.md", "create: bike/neu.md")

    assert :ok = Git.push(vault, "origin")

    {out, 0} = System.cmd("git", ["log", "-1", "--format=%an <%ae>"], cd: vault)
    assert String.trim(out) == "vigil <vigil@local>"
  end

  test "push failure is reported without losing the local commit", %{vault: vault} do
    File.write!(Path.join(vault, "bike/neu2.md"), "---\ntype: reference\n---\n# Neu2\ntext\n")
    {:ok, _} = Git.add_commit(vault, "bike/neu2.md", "create: bike/neu2.md")

    assert {:error, _reason} = Git.push(vault, "nonexistent-remote")

    {out, 0} = System.cmd("git", ["log", "-1", "--format=%s"], cd: vault)
    assert String.trim(out) == "create: bike/neu2.md"
  end
end
