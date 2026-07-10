defmodule Vigil.StoreTest do
  use ExUnit.Case, async: false

  alias Vigil.Store

  setup do
    {vault, remote} = Vigil.FixtureVault.build(remote: true)
    on_exit(fn -> Vigil.FixtureVault.cleanup(vault) end)
    start_supervised!({Store, vault_path: vault, exclude: [], git_remote: "origin"})
    %{vault: vault, remote: remote}
  end

  describe "search" do
    test "reifen in domain bike returns ranked hits with previews, no bodies" do
      results = Store.search(%{query: "reifen", domain: "bike"})
      assert results != []
      refute Map.has_key?(hd(results), :body)
      assert Enum.all?(results, &(String.length(&1.preview) <= 121))
    end

    test "domain filter is applied" do
      results = Store.search(%{query: "hochbeet", domain: "training"})
      assert results == []
      results2 = Store.search(%{query: "hochbeet", domain: "garten"})
      assert length(results2) == 1
    end

    test "prefer hint boosts type" do
      results = Store.search(%{query: "vigil", prefer: :decision})
      assert Enum.at(results, 0).type == :decision
    end

    test "empty result is an empty list, not an error" do
      assert Store.search(%{query: "voellignirgendwo"}) == []
    end

    test "journal is hidden unless domain explicitly requested" do
      assert Store.search(%{query: "terra speed"}) |> Enum.all?(&(not String.starts_with?(&1.id, "journal/")))
      results = Store.search(%{query: "terra speed", domain: "journal"})
      assert Enum.any?(results, &String.starts_with?(&1.id, "journal/"))
    end

    test "dynamic domain: garten is discovered without code changes" do
      results = Store.search(%{query: "hochbeet"})
      assert Enum.any?(results, &(&1.id == "garten/hochbeet.md"))
    end
  end

  describe "read" do
    test "reading a fragment returns exactly that chunk" do
      {:ok, result} = Store.read("bike/via-carolina.md#fueling", false)
      assert result.heading == "Fueling"
      assert result.body =~ "Grundlast"
      refute Map.has_key?(result, :backlinks)
    end

    test "reading without a fragment returns TOC without body" do
      {:ok, result} = Store.read("bike/via-carolina.md", false)
      assert result.title == "Via Carolina"
      refute Map.has_key?(result, :body)
      headings = Enum.map(result.toc, & &1.heading)
      assert headings == ["Fueling", "Zweite Hälfte", "Gear"]
    end

    test "backlinks is opt-in" do
      {:ok, result} = Store.read("bike/terra-speed.md", true)
      assert "bike/via-carolina.md" in result.backlinks
    end

    test "unknown id returns isError-style tuple" do
      assert {:error, _} = Store.read("bike/nope.md", false)
    end
  end

  describe "create" do
    test "creates file, commits as vigil, pushes, and updates ETS", %{vault: vault} do
      assert {:ok, %{path: "bike/neu.md"}} =
               Store.create(%{
                 path: "bike/neu.md",
                 type: "reference",
                 content: "# Neu\n\nEin Testinhalt.\n"
               })

      assert File.exists?(Path.join(vault, "bike/neu.md"))
      {:ok, result} = Store.read("bike/neu.md", false)
      assert result.title == "Neu"

      {out, 0} = System.cmd("git", ["log", "-1", "--format=%an"], cd: vault)
      assert String.trim(out) == "vigil"
    end

    test "fails if file already exists" do
      assert {:error, msg} =
               Store.create(%{path: "bike/terra-speed.md", type: "reference", content: "# X\ntext"})

      assert msg =~ "existiert bereits"
    end

    test "content without H1 is rejected" do
      assert {:error, _} =
               Store.create(%{path: "bike/keinh1.md", type: "reference", content: "kein h1 hier"})
    end

    test "content with its own frontmatter is rejected" do
      assert {:error, _} =
               Store.create(%{
                 path: "bike/eigenfm.md",
                 type: "reference",
                 content: "---\ntype: reference\n---\n# X\ntext"
               })
    end

    test "event requires starts/ends; other types forbid them" do
      assert {:error, _} = Store.create(%{path: "bike/ev.md", type: "event", content: "# E\nx"})

      assert {:error, _} =
               Store.create(%{
                 path: "bike/ref.md",
                 type: "reference",
                 content: "# R\nx",
                 starts: "2026-01-01T00:00:00+01:00"
               })
    end

    test "duplicate detection blocks similarly-titled note in same domain, force bypasses it" do
      assert {:error, msg} =
               Store.create(%{path: "bike/terra-speed-tubeless.md", type: "reference", content: "# Terra Speed Tubeless\ntext"})

      assert msg =~ "Duplikate"

      assert {:ok, _} =
               Store.create(%{
                 path: "bike/terra-speed-tubeless.md",
                 type: "reference",
                 content: "# Terra Speed Tubeless\ntext",
                 force: true
               })
    end

    test "unknown domain is rejected with a domain list" do
      assert {:error, msg} = Store.create(%{path: "unbekannt/x.md", type: "reference", content: "# X\nx"})
      assert msg =~ "bike"
    end

    test "projects allows exactly one extra level, other domains do not" do
      assert {:ok, _} =
               Store.create(%{path: "projects/vigil/x.md", type: "reference", content: "# X\nx"})

      assert {:error, _} =
               Store.create(%{path: "projects/neu/x.md", type: "reference", content: "# X\nx"})

      assert {:error, _} =
               Store.create(%{path: "projects/vigil/docs/x.md", type: "reference", content: "# X\nx"})

      assert {:error, _} =
               Store.create(%{path: "gear/unter/x.md", type: "reference", content: "# X\nx"})
    end

    test "[[vigil]] resolves to projects/vigil/vigil.md" do
      {:ok, result} = Store.read("projects/vigil/vigil.md", true)
      assert "projects/vigil/vigil-ranking.md" == "projects/vigil/vigil-ranking.md"
      assert result.title == "vigil"
    end
  end

  describe "append" do
    test "appends under an existing heading, at the end of that section, not at EOF", %{vault: vault} do
      assert {:ok, _} =
               Store.append(%{path: "bike/via-carolina.md", heading: "Gear", content: "Zusatz: Flickzeug."})

      raw = File.read!(Path.join(vault, "bike/via-carolina.md"))
      assert raw =~ "Rahmentasche, keine Satteltasche.\nZusatz: Flickzeug."
    end

    test "appends a new section when the heading does not exist yet" do
      assert {:ok, _} =
               Store.append(%{path: "bike/via-carolina.md", heading: "Wetter", content: "Trocken erwartet."})

      {:ok, result} = Store.read("bike/via-carolina.md#wetter", false)
      assert result.body =~ "Trocken erwartet."
    end

    test "appends to EOF without a heading" do
      assert {:ok, _} = Store.append(%{path: "bike/terra-speed.md", content: "Letzter Satz."})
      {:ok, result} = Store.read("bike/terra-speed.md#erfahrung-schotter", false)
      assert result.body =~ "Letzter Satz."
    end
  end

  describe "replace_section" do
    test "replaces only the target chunk's body; rest of file is byte-identical", %{vault: vault} do
      before_content = File.read!(Path.join(vault, "bike/via-carolina.md"))

      assert {:ok, _} =
               Store.replace_section("bike/via-carolina.md#fueling", "Neue Fueling-Strategie.")

      after_content = File.read!(Path.join(vault, "bike/via-carolina.md"))

      assert after_content =~ "Neue Fueling-Strategie."
      assert after_content =~ "### Zweite Hälfte"
      assert after_content =~ "525mg Koffein, konzentriert."
      assert after_content =~ "## Gear"

      before_lines = String.split(before_content, "\n")
      after_lines = String.split(after_content, "\n")
      assert Enum.take(before_lines, 5) == Enum.take(after_lines, 5)
    end

    test "content with a heading of any covered rank is rejected" do
      assert {:error, _} = Store.replace_section("bike/via-carolina.md#fueling", "## Neu\ntext")
    end

    test "id without a fragment is rejected" do
      assert {:error, _} = Store.replace_section("bike/via-carolina.md", "text")
    end
  end

  describe "current" do
    test "classifies active/upcoming/recently_past relative to an injected now" do
      before_event = ~U[2026-07-09 00:00:00Z] |> DateTime.shift_zone!("Europe/Berlin")
      during_event = ~U[2026-07-11 00:00:00Z] |> DateTime.shift_zone!("Europe/Berlin")
      after_event = ~U[2026-07-13 12:00:00Z] |> DateTime.shift_zone!("Europe/Berlin")

      r1 = Store.current(before_event)
      assert Enum.any?(r1.upcoming, &(&1.id == "bike/via-carolina.md"))

      r2 = Store.current(during_event)
      assert Enum.any?(r2.active, &(&1.id == "bike/via-carolina.md"))

      r3 = Store.current(after_event)
      assert Enum.any?(r3.recently_past, &(&1.id == "bike/via-carolina.md"))
    end

    test "invalid event (ends < starts) never appears in current" do
      {:ok, _} =
        Store.create(%{
          path: "bike/kaputt.md",
          type: "event",
          content: "# Kaputt\nx",
          starts: "2026-07-10T10:00:00+02:00",
          ends: "2026-07-09T10:00:00+02:00"
        })

      now = ~U[2026-07-10 08:00:00Z] |> DateTime.shift_zone!("Europe/Berlin")
      result = Store.current(now)
      refute Enum.any?(result.active ++ result.upcoming ++ result.recently_past, &(&1.id == "bike/kaputt.md"))
    end
  end

  describe "path security" do
    test "path traversal and absolute paths are rejected without touching disk" do
      for bad_path <- ["../../etc/passwd", "/etc/passwd", "bike/../../x.md"] do
        assert {:error, msg} = Store.create(%{path: bad_path, type: "reference", content: "# X\nx"})
        assert msg == "Ungültiger Pfad"
      end
    end

    test "writing into skills/ via create is rejected" do
      assert {:error, "Ungültiger Pfad"} =
               Store.create(%{path: "skills/x.md", type: "reference", content: "# X\nx"})
    end
  end

  describe "skills isolation" do
    test "skills never appear in search, have no ETS chunk, no backlinks" do
      assert Store.search(%{query: "TDD"}) == []
      assert Store.search(%{query: "Failing Test"}) == []
    end

    test "skill_list, skill_read with/without .md, and error case" do
      [skill] = Store.skill_list()
      assert skill.name == "tdd"
      assert skill.description =~ "test coverage"

      {:ok, %{content: c1}} = Store.skill_read("tdd")
      {:ok, %{content: c2}} = Store.skill_read("tdd.md")
      assert c1 == c2

      assert {:error, msg} = Store.skill_read("gibtsnicht")
      assert msg =~ "tdd"
    end

    test "skill_write requires name and description in frontmatter, commits but does not reparse" do
      assert {:error, _} = Store.skill_write("kaputt", "---\nname: kaputt\n---\n# x")

      assert {:ok, %{name: "neu"}} =
               Store.skill_write("neu", "---\nname: neu\ndescription: test skill\n---\n# Neu\n1. eins")

      {:ok, %{content: content}} = Store.skill_read("neu")
      assert content =~ "1. eins"

      assert Store.search(%{query: "eins"}) == []
    end
  end

  describe "reload" do
    test "reload re-reads the vault without error" do
      assert :ok = Store.reload()
      assert Store.search(%{query: "reifen"}) != []
    end
  end
end
