defmodule Vigil.ParserTest do
  use ExUnit.Case, async: true

  alias Vigil.Parser

  @fixtures Path.expand("../fixtures/vault", __DIR__)

  defp parse(rel_path) do
    content = File.read!(Path.join(@fixtures, rel_path))
    {:ok, file} = Parser.parse(rel_path, content, %{})
    file
  end

  test "slug/1 transliterates German umlauts" do
    assert Parser.slug("Wärmepumpen-Überlegung") == "waermepumpen-ueberlegung"
    assert Parser.slug("böse-datei-ümläute") == "boese-datei-uemlaeute"
  end

  test "terra-speed.md parses without crash and has expected chunks" do
    file = parse("bike/terra-speed.md")
    assert file.type == :reference
    assert file.title == "WTB Terra Speed 40C"

    ids = Enum.map(file.chunks, & &1.id)
    assert ids == ["bike/terra-speed.md#masse", "bike/terra-speed.md#erfahrung-schotter"]
  end

  test "via-carolina.md: H1 creates no chunk, pre-H2 text becomes fragmentless chunk, ### is its own chunk" do
    file = parse("bike/via-carolina.md")
    assert file.type == :event
    assert file.title == "Via Carolina"

    ids = Enum.map(file.chunks, & &1.id)

    assert ids == [
             "bike/via-carolina.md",
             "bike/via-carolina.md#fueling",
             "bike/via-carolina.md#zweite-haelfte",
             "bike/via-carolina.md#gear"
           ]

    zweite = Enum.find(file.chunks, &(&1.id == "bike/via-carolina.md#zweite-haelfte"))
    assert zweite.heading_path == ["Fueling", "Zweite Hälfte"]

    fueling = Enum.find(file.chunks, &(&1.id == "bike/via-carolina.md#fueling"))
    refute String.contains?(fueling.body, "Koffein")

    pre = Enum.find(file.chunks, &(&1.id == "bike/via-carolina.md"))
    assert pre.heading_path == []
    assert "terra-speed" in pre.links
  end

  test "file without any heading yields a single fragmentless chunk (ID = path)" do
    file = parse("training/notiz-ohne-alles.md")
    assert length(file.chunks) == 1
    [chunk] = file.chunks
    assert chunk.id == "training/notiz-ohne-alles.md"
    assert chunk.heading_path == []
    assert "via-carolina" in chunk.links
    assert file.type == :reference
  end

  test "unknown frontmatter field is tolerated; umlaut heading slug is correct" do
    file = parse("home/böse-datei-ümläute.md")
    assert file.type == :reference

    [chunk] = file.chunks
    assert chunk.id == "home/böse-datei-ümläute.md#waermepumpen-ueberlegung"
  end

  test "wikilinks with display text extract only the target part" do
    file = parse("bike/via-carolina.md")
    pre = Enum.find(file.chunks, &(&1.id == "bike/via-carolina.md"))
    assert pre.links == ["terra-speed"]
  end

  test "duplicate headings within a file get -2, -3 suffixes" do
    content = """
    ---
    type: reference
    ---
    # Doppelt

    ## Wiederholung
    erste

    ## Wiederholung
    zweite

    ## Wiederholung
    dritte
    """

    {:ok, file} = Parser.parse("x/doppelt.md", content, %{})
    ids = Enum.map(file.chunks, & &1.id)

    assert ids == [
             "x/doppelt.md#wiederholung",
             "x/doppelt.md#wiederholung-2",
             "x/doppelt.md#wiederholung-3"
           ]
  end

  test "defensive parsing: missing frontmatter, unparsable YAML, invalid type never crash" do
    assert {:ok, %{type: :reference}} = Parser.parse("x/no-fm.md", "kein frontmatter hier", %{})

    assert {:ok, %{type: :reference}} =
             Parser.parse("x/bad-yaml.md", "---\n:::not yaml:::\n---\n# T\ntext", %{})

    assert {:ok, %{type: :reference}} =
             Parser.parse("x/bad-type.md", "---\ntype: quatsch\n---\n# T\ntext", %{})
  end

  test "event without offset on starts/ends is treated as reference" do
    content = """
    ---
    type: event
    starts: 2026-07-10T17:00:00
    ends: 2026-07-12T20:00:00
    ---
    # E
    text
    """

    {:ok, file} = Parser.parse("x/e.md", content, %{})
    assert file.type == :reference
  end
end
