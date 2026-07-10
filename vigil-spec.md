# vigil — Spezifikation

Ein Elixir-Server, der einen Markdown-Vault liest, wie spät es ist weiß, und über MCP als Gedächtnis-Backend für Claude dient.

Diese Spec ist vollständig. Sie enthält alle Entscheidungen. Bei Unklarheiten gilt: die kleinere Lösung ist die richtige.

---

## 1. Philosophie (bestimmt jede Implementierungsentscheidung)

1. **Nur Ableitbares wird gespeichert.** Status, Alter, Backlinks — alles wird berechnet, nie in Dateien geschrieben. Ein gespeicherter Status ist ein `now`, das eingefroren wurde und lügt.
2. **Ein Schreiber.** Nur vigil schreibt in den Vault. Obsidian und alle anderen Clients sind read-only. Daraus folgt: kein Merge, kein Locking-Protokoll, kein Konflikt-Handling.
3. **Git ist die Metadaten-Datenbank.** Erstellungsdatum = erster Commit. Provenienz = Commit-Author. Historie = `git log`. Kein Frontmatter-Feld für etwas, das Git schon weiß.
4. **Der Kontext ist der Engpass, nicht die CPU.** Jedes Tool gibt so wenig Tokens wie möglich zurück. Suche liefert Karten, nicht Inhalte. Reads liefern Abschnitte, nicht Dateien.
5. **Der Server hat keine Meinung.** Er berechnet Funktionen über den Daten. Er fasst nichts zusammen, interpretiert nichts, schreibt nichts von sich aus.

---

## 2. Systemkontext

```
claude.ai / Claude App (iOS)
        │  MCP over Streamable HTTP + Bearer Token
        ▼
Cloudflare Tunnel (vault.<domain>)
        ▼
LXC Container (Proxmox, Debian 12, unprivilegiert)
  ├── vigil (Elixir Release, systemd)
  └── /var/lib/vigil/vault/   ← Git-Clone
        │  push/pull
        ▼
Gitea (Proxmox, bestehende Instanz)
        │  pull (read-only)
        ▼
Obsidian Desktop / iPhone (nur Anzeige, Graph View, Mermaid)
```

- **Claude Code auf dem Mac Studio** verbindet sich über dieselbe HTTP-URL. Optional später: zweite Instanz lokal als stdio (gleicher Code, andere Config) — nicht Teil von v1.
- Der Vault ist **privat** (Gitea). Der vigil-Quellcode kann public sein; Vault-Pfad, Token und ntfy-URL liegen ausschließlich in der Config, nie im Code.

---

## 3. Vault-Konvention

### Ordner

```
vault/
├── _domains.yml     ← Beschreibung der Domänen (siehe unten)
├── gear/
├── training/
├── projects/
│   ├── vigil/
│   │   ├── vigil.md         ← Hauptnote, trägt den Projektnamen
│   │   └── vigil-ranking.md
│   └── ironlog/
│       └── ironlog.md
├── home/
├── admin/
├── journal/         ← Sonderrolle bei der Suche (siehe Sektion 4)
└── skills/          ← NICHT Teil des Wissens (siehe unten)
```

- **Die Domänen sind nicht fest verdrahtet.** Eine Domäne ist jedes Verzeichnis direkt unter `VIGIL_VAULT_PATH`, außer `skills/`, außer allem in `VIGIL_EXCLUDE`, und außer allem, was mit `.` oder `_` beginnt. Der Server legt niemals Ordner an.
- Die oben gezeigten sind ein Beispielstand, kein Schema. Notes liegen **flach** in ihrer Domäne, genau eine Ebene.
- **Ausnahme `projects/`:** Der Name `projects` ist der einzige, den der Code kennt. Diese Domäne darf **genau eine Unterebene** — ein Ordner pro Projekt. Begründung: Ein Projekt ist ein Namensraum mit scharfer Grenze, kein Thema; es gibt keine Zweifelsfälle wie "Reifen: gear oder training?". Tiefere Verschachtelung (`projects/vigil/docs/`) ist verboten.
  - Die Hauptnote eines Projekts heißt wie das Projekt: `projects/vigil/vigil.md`. **Kein `readme.md`** — sonst kollidieren die Wikilink-Slugs mehrerer Projekte, da Links über den Datei-Stem auflösen.
  - Weitere Notes: `projects/vigil/vigil-ranking.md`. Präfix empfohlen, nicht erzwungen.
- `journal/` ist der einzige Ordner für chronologische Einträge (Datum im Dateinamen: `2026-07-13.md`) und der einzige mit einer Sonderregel in der Suche.
- **Start:** Der Server loggt gefundene Domänen, Anzahl Notes und Anzahl Chunks. Ein leerer Vault ist gültig — kein Fehler, keine Beispieldateien.

### `_domains.yml` — Beschreibung, keine Konfiguration

Liegt im Vault-Root. Wird beim Start und bei `reload` gelesen und **an die MCP-`instructions` angehängt**, damit Claude beim `create` nicht raten muss, wohin eine Note gehört.

```yaml
gear:      "Material: Rad, Komponenten, Ausrüstung, Wartung"
training:  "Körper: Planung, Ernährung, Recovery, Metriken"
projects:  "Software-Projekte. Ein Unterordner pro Projekt, Hauptnote = Projektname"
home:      "Haus, WEG, Energie, Handwerk"
admin:     "Finanzen, Versicherung, Verträge, Behörden"
journal:   "Chronologisch, erscheint nicht in der Default-Suche"
```

- Fehlt die Datei: Warnung ins Log, `instructions` ohne Domänenbeschreibung, alles funktioniert weiter.
- Steht ein Key drin, für den kein Ordner existiert: Warnung, Key wird ignoriert.
- Existiert ein Ordner, der nicht in der Datei steht: er ist trotzdem eine Domäne (Datei ist Beschreibung, nicht Whitelist), Warnung ins Log.
- **Der Server schreibt diese Datei nie.** Kein Tool ändert sie. Neue Domäne = Daniel legt Ordner an und ergänzt die Datei. Grund: Ordnerstruktur ist Daniels Entscheidung, nicht Claudes.
- Der führende `_` sorgt dafür, dass die Datei selbst nie als Domäne oder Note geparst wird.

### `VIGIL_EXCLUDE` — die harte Grenze

Kommagetrennte Liste von Ordnernamen, die **nicht geparst** werden. Nicht gefiltert — nicht gelesen. Kein ETS-Eintrag, kein Chunk, kein Backlink, nichts, was ein Bug versehentlich zurückgeben könnte. Wie `skills/`, nur konfigurierbar.

Der Unterschied zu einem Flag in `_domains.yml` ist wesentlich: Eine Umgebungsvariable kann der Prozess nicht ändern, eine Datei im Vault schon. Wer eine Domäne wirklich vor Claude verbergen will, nutzt `VIGIL_EXCLUDE` — nicht eine Markierung in einer Datei, die Claude lesen kann.

Default: leer.

### `skills/` — ein Repo, zwei Systeme

`skills/` enthält Claude-Code-Skills (Markdown mit `name`/`description`-Frontmatter). Sie werden auf dem Mac Studio per Symlink nach `~/.claude/skills` gemountet und dort vom Dateisystem geladen — **nicht über MCP**.

Für vigil gilt: **`skills/` wird nicht geparst.** Kein Chunking, kein `type`, keine Suche, keine Backlinks, kein Auftauchen in `search`. Der Ordner ist für Store und Parser unsichtbar. Zugriff ausschließlich über die drei `skill_*`-Tools (Sektion 5).

Grund: Eine Note ist eine Aussage über die Welt und altert. Ein Skill ist eine Anweisung an Claude und altert nicht. Sie teilen sich ein Git-Repo, sonst nichts.

### Frontmatter — genau ein Pflichtfeld

```yaml
---
type: reference | decision | event
---
```

- **`reference`** — altert nicht. Fakten über die Welt ("Terra Speed hat 40mm").
- **`decision`** — altert immer. Fakten über Daniel ("ich fahre Terra Speed"). Implizites Verfallsdatum, ohne dass eines gespeichert wird.
- **`event`** — durchläuft Phasen. **Nur** `event` darf zusätzlich haben:

```yaml
---
type: event
starts: 2026-07-10T17:00:00+02:00
ends: 2026-07-12T20:00:00+02:00
---
```

- Weitere Frontmatter-Felder sind **verboten** in v1. Der Parser toleriert unbekannte Felder (kein Crash), aber vigil erzeugt keine und wertet keine aus.
- Kein `status`, kein `valid_until`, kein `provenance`, kein `tags`. Alles davon ist entweder ableitbar oder wurde bewusst verworfen.
- **Defensiv:** Fehlendes Frontmatter, unparsbares YAML, fehlendes oder ungültiges `type` (etwa `type: quatsch`) → Warnung ins Log mit Pfad und Grund, Note wird trotzdem geparst und wie `type: reference` behandelt. Der Server startet immer, nichts geht verloren, nichts crasht.

### Abgeleitete Metadaten (nie gespeichert, immer berechnet)

| Metadatum | Quelle |
|---|---|
| Titel | erste H1, sonst Dateiname (ohne `.md`, Bindestriche zu Leerzeichen) |
| Domäne | Ordner |
| Erstellt (`asserted`) | erster Git-Commit der Datei |
| Zuletzt geändert | letzter Git-Commit der Datei |
| Backlinks | invertierte `[[wikilink]]`-Sammlung |
| Event-Phase | Funktion von `starts`/`ends` und `now` |
| Autor je Änderung | Git-Commit-Author |

**Wichtig — Git-Metadaten werden beim Parsen einmalig ermittelt und im Chunk-Struct mitgeführt.** Niemals `git log` während einer Suche oder eines Reads aufrufen. Beim Voll-Parse **ein** Aufruf für alle Dateien:

```
git log --format="%H%x00%aI%x00%an" --name-only --diff-filter=AM --reverse
```

Daraus baut der Parser eine Map `pfad → {created_at, updated_at, last_author}`. Bei `create`/`append`/`replace_section` wird nur der Eintrag der geänderten Datei aktualisiert (aus dem soeben erzeugten Commit, kein erneutes `git log`).

---

## 4. Architektur (Elixir)

### Module

```
lib/vigil/
├── application.ex      # Supervisor: Store, MCP.Server
├── store.ex            # GenServer — hält Chunks in ETS, serialisiert Writes
├── parser.ex           # Datei → Frontmatter + Chunks + Links
├── git.ex              # System.cmd-Wrapper: add/commit/push/log
└── mcp/
    ├── server.ex       # Bandit + Plug, Streamable HTTP, JSON-RPC
    ├── tools.ex        # Tool-Definitionen + Dispatch
    └── envelope.ex     # Zeit-Envelope, Session-Delta-Tracking
```

### Dependencies — vollständige Liste

```elixir
{:bandit, "~> 1.5"},
{:jason, "~> 1.4"},
{:yaml_elixir, "~> 2.9"},
{:tzdata, "~> 1.1"},
{:plug, "~> 1.16"}
```

(`plug` bringt `Plug.Crypto.secure_compare/2` und den Router mit; Bandit spricht Plug direkt.)

**Zeitzone:** In `config/config.exs`: `config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase`. Alle Zeitrechnung (`current`, Envelope, relative Zeiten) läuft in `Europe/Berlin` (Config: `VIGIL_TZ`, Default `Europe/Berlin`). Frontmatter-Timestamps sind ISO 8601 **mit Offset** — ohne Offset wird die Note beim Parsen mit Warnung als fehlerhaft geloggt und wie `reference` behandelt.

**Bewusst nicht dabei:** Phoenix, Ecto, `file_system`, libgraph, jede Vector-/Embedding-Lib, jede Git-Lib (Git läuft über `System.cmd/3`).

### Store

- GenServer, hält zwei ETS-Tabellen:
  - `:chunks` (`:set`) — Key: Chunk-ID, Value: Chunk-Struct
  - `:links` (`:bag`) — `{ziel_slug, quelle_chunk_id}` für Backlinks
- **Start:** `git pull`, dann kompletter Parse des Vaults in ETS.
- **Nach jedem Write:** betroffene Datei neu parsen (kein Voll-Reload).
- **Kein File-Watcher.** vigil ist der einzige Schreiber; externe Änderungen (z. B. Gitea-Web-UI) werden nur bei Neustart oder via `reload`-Tool aufgenommen. Diese Annahme ist dokumentiert und bewusst.
- Alle Writes laufen als `handle_call` durch den Store — der GenServer **ist** der Lock.

### Chunking

- **Ein Chunk beginnt bei jeder Überschrift der Level `##` bis `####` und endet vor der nächsten Überschrift gleichen oder höheren Rangs.** Eine `###`-Überschrift innerhalb eines `##`-Abschnitts ist ein **eigener** Chunk (kein verschachtelter Einschluss). Jede Zeile des Bodys gehört zu genau einem Chunk.
- **Die H1 erzeugt keinen Chunk.** Sie ist der Titel der Datei. Text zwischen H1 und der ersten `##` (bzw. Text in einer Datei ganz ohne Überschriften) wird zu einem Chunk mit der ID = Pfad ohne Fragment, `heading_path: []`.
- Enthält eine Datei weder H1 noch Text vor der ersten `##`, gibt es keinen fragmentlosen Chunk.
- Chunk-ID: `pfad#heading-slug`, z. B. `bike/via-carolina.md#fueling`. Slug-Regeln, exakt: lowercase; `ä→ae, ö→oe, ü→ue, ß→ss`; Leerzeichen → `-`; alle übrigen Zeichen außer `[a-z0-9-]` entfernen; Mehrfach-`-` zu einem zusammenfassen; führende/abschließende `-` strippen. Kollision innerhalb einer Datei: Suffix `-2`, `-3`.
- `heading_path`: Liste der Überschriften-Texte von der obersten `##` bis zur eigenen, z. B. `["Fueling", "Zweite Hälfte"]` für eine `###` unter einer `##`. Nur zur Anzeige (Titel im Suchergebnis: `Dateititel › Fueling › Zweite Hälfte`); die Chunk-ID nutzt **nur** den Slug der eigenen Überschrift.
- **Wikilink-Auflösung:** Das Ziel von `[[terra-speed]]` ist der Slug des Datei-Stems (Dateiname ohne `.md`, gleiche Slug-Regeln), domänenübergreifend aufgelöst. Nicht auflösbare Links (Datei existiert nicht) bleiben in der `:links`-Tabelle unter ihrem Slug erhalten — sie werden Backlinks, sobald die Datei entsteht. `[[link|Anzeigetext]]`-Syntax: nur der Teil vor `|` ist das Ziel.
- Jeder Chunk speichert: `path`, `heading` (eigener Text), `heading_path`, `line_range`, `body`, `body_downcased`, `links`, `type` und `starts`/`ends` (aus dem Frontmatter der Datei kopiert), `created_at`, `updated_at`.
- Binaries > 64 Byte sind auf der BEAM refcounted — ETS-Reads kopieren große Bodies nicht. Kein zusätzliches Caching bauen.

### Suche

- Literal-Match über Chunk-Bodies und Headings mit `:binary.match/2` (Boyer-Moore). **Kein Regex** für Standardsuche; `:re` nur falls je ein Pattern-Tool nachgerüstet wird.
- **Die Query ist eine Phrase**, exakt wie eingegeben. Kein Token-Split, kein UND/ODER. `"terra speed"` findet nur zusammenhängendes `terra speed`.
- **Case-insensitiv:** Jeder Chunk hält zusätzlich eine downcased Kopie von Body und Headings (beim Parsen erzeugt, in ETS neben dem Original); die Query wird downcased. Match läuft gegen die Kopie, Preview kommt aus dem Original.
- Filter **vor** dem Match: `domain` (Ordnername, beliebig), `type`.
- **`journal/` ist per Default ausgeblendet.** Chunks aus `journal/` erscheinen nur, wenn `domain: "journal"` explizit gesetzt ist. Grund: chronologische Einträge würden echte Notes verdrängen.
- `limit`: Default 10, hartes Maximum 25 (größere Werte werden gekappt, kein Fehler).
- Ranking (einfacher Score, kein BM25). Alle Teilscores auf der downcased Query:
  - Query kommt im **Dateititel** vor: +10
  - Query kommt in einer Überschrift des `heading_path` vor: +5
  - Query kommt im Body vor: +1 je Vorkommen, gedeckelt bei 5
  - `type` des Chunks == `prefer`: +5
  - Score 0 → kein Treffer, fliegt raus
  - Tiebreaker: höheres `updated_at` gewinnt (aus dem gecachten Git-Metadatum, **kein** `git log` zur Suchzeit)
- Rückgabe: **nur** `id`, `title` (`Dateititel › Heading › Subheading`), `type`, `score`, `preview`. Preview-Regel: Body des Chunks, Zeilenumbrüche durch Leerzeichen ersetzt, Markdown-Syntaxzeichen (`#*_[]`) entfernt, auf 120 Zeichen gekürzt (an Wortgrenze, `…` angehängt). Nie Bodies.

---

## 5. MCP-Tools

Transport: Streamable HTTP unter `/mcp`. Auth: statischer Bearer Token aus der Config — Header `Authorization: Bearer <token>`, Vergleich mit `Plug.Crypto.secure_compare/2`, jede Anfrage geprüft, fehlend/falsch → HTTP 401 ohne Body. Der Server **vergibt** die `Mcp-Session-Id` in der `initialize`-Response (UUIDv4) und erwartet sie in allen Folge-Requests der Session.

### Pfad-Validierung (gilt für jeden Pfad- und Namensparameter)

Bevor irgendein Tool auf das Dateisystem zugreift:

1. Pfad darf **kein** `..`, kein führendes `/`, keine Backslashes, keine NUL-Bytes enthalten.
2. `Path.expand/2` gegen `VIGIL_VAULT_PATH` auflösen; das Ergebnis muss mit `VIGIL_VAULT_PATH <> "/"` beginnen. Sonst `isError`.
3. Für `create`/`append`/`replace_section`:
   - Erste Komponente darf **nicht** `skills` sein, nicht in `VIGIL_EXCLUDE` stehen, nicht mit `.` oder `_` beginnen.
   - Der Ordner muss **existieren**. Wird nie angelegt. Sonst `isError` mit der Liste vorhandener Domänen.
   - Normalfall: genau **zwei** Komponenten (Domäne + Dateiname), Endung `.md`.
   - Nur wenn die erste Komponente `projects` ist: auch **drei** Komponenten erlaubt (`projects/<projekt>/<datei>.md`). Der Projektordner muss existieren. Mehr als drei Komponenten sind immer `isError`.
4. Für `skill_*`: `name` darf nur `[a-z0-9_-]` enthalten (nach optionalem Strippen von `.md`). Sonst `isError`.

Verletzung liefert immer `isError` mit `"Ungültiger Pfad"` — nie einen Stacktrace, nie den aufgelösten absoluten Pfad.

### Protokoll-Umfang

Das MCP-Protokoll wird **von Hand implementiert** — keine MCP-Library als Dependency (der Bestand an Elixir-MCP-Libraries ist jung und instabil; das benötigte Subset ist klein). Vor der Implementierung die aktuelle MCP-Spezifikation prüfen (modelcontextprotocol.io, Streamable-HTTP-Transport) — insbesondere die aktuelle Protokollversion für die Version-Negotiation. Implementiert wird genau dieses Subset:

- `initialize` — Protokollversion aushandeln, `serverInfo`, `capabilities: { tools: {} }`, und das `instructions`-Feld (Inhalt: Sektion 8)
- `notifications/initialized` — entgegennehmen, ignorieren
- `tools/list` — die zehn Tools mit JSON-Schema (aus den Parametertabellen dieser Spec ableiten). **Descriptions maximal ein Satz pro Tool und pro Parameter, keine Beispiele, keine Erklärung der `type`-Semantik** — die steht in `instructions` und würde sich sonst verdoppeln. Grund: `tools/list` landet in *jeder* Session im Kontextfenster; jedes überflüssige Wort kostet bei jedem Gespräch.
- `tools/call` — Dispatch an Vigil.MCP.Tools
- `ping` — beantworten

Alles andere (resources, prompts, sampling, roots) wird **nicht** implementiert; unbekannte Methoden bekommen JSON-RPC `-32601`. Session-Identifikation über den `Mcp-Session-Id`-Header gemäß Streamable-HTTP-Spec — dieser Header ist der Key für den Envelope-State (Sektion 6).

Fehlerformat für Tool-Fehler: `tools/call`-Result mit `isError: true` und einer prägnanten deutschen Fehlermeldung als Text-Content (z. B. `"Datei existiert bereits: bike/terra-speed.md"`), kein JSON-RPC-Error — der gehört nur zu Protokollfehlern.

### `search`

```json
{ "query": "string (Phrase, exakt)", "domain": "Ordnername (optional)",
  "type": "reference|decision|event (optional)", "prefer": "type-Hint (optional)",
  "limit": 10 }
```

`domain` ist ein freier Ordnername, keine Enum — die Domänen ergeben sich aus dem Vault. `journal` erscheint nur, wenn es explizit gesetzt ist. Antwort: Trefferliste (siehe Ranking). Max ~200 Tokens bei limit=10.

### `read`

```json
{ "id": "pfad#heading-slug ODER pfad", "backlinks": false }
```

- Mit Fragment: genau dieser Chunk, plus abgeleitete Metadaten (erstellt, zuletzt geändert).
- Ohne Fragment: Frontmatter + Inhaltsverzeichnis (Heading-Liste mit Chunk-IDs) + abgeleitete Metadaten. **Kein Body**, auch nicht der erste Abschnitt — Inhalte werden immer gezielt über die Chunk-ID nachgelesen.
- `backlinks: true` (Default `false`) hängt die Chunk-IDs an, die hierher verlinken. Opt-in, weil sie meist ungenutzt Kontext kosten.

### `create`

```json
{ "path": "domäne/dateiname.md", "type": "reference|decision|event",
  "content": "Markdown-Body", "starts": "ISO (nur event)", "ends": "ISO (nur event)" }
```

- Der **Server erzeugt das Frontmatter** aus den Parametern — `content` ist nur der Body und darf keinen eigenen Frontmatter-Block enthalten (sonst `isError`). `content` muss mit einer H1 (`# Titel`) beginnen (sonst `isError` mit Hinweis).
- Schlägt fehl, wenn die Datei existiert.
- **Duplikat-Schutz, deterministisch:** Vor dem Anlegen führt der Server intern `search` aus mit den Wörtern des Dateinamen-Stems (Tokens > 3 Zeichen, `-`-getrennt). Jeder Treffer mit Titel-Treffer (Score ≥ 10) in **derselben Domäne** → Abbruch mit `isError` und der Kandidatenliste. `force: true` überspringt die Prüfung.
- Pfad muss eine existierende Domäne sein (siehe Pfad-Validierung), genau eine Ebene. `starts`/`ends` sind Pflicht bei `type: event`, verboten bei anderen Typen (jeweils `isError`).
- Der interne Duplikat-`search` durchsucht auch `journal/`, wenn dort angelegt wird.

### `append`

```json
{ "path": "...", "heading": "Abschnittsname (optional)", "content": "..." }
```

Anhängen: ohne `heading` ans Dateiende. Mit `heading`: existiert der Abschnitt bereits (Slug-Vergleich), wird ans **Ende dieses Abschnitts** angehängt; sonst neuer `##`-Abschnitt am Dateiende. Heading-Level ist immer `##` — tiefere Gliederung entsteht nur durch `create`/`replace_section`-Inhalte.

### `replace_section`

```json
{ "id": "pfad#heading-slug", "content": "..." }
```

Ersetzt den Body **genau eines** Chunks: alle Zeilen von direkt nach der Überschrift bis vor die nächste Überschrift gleichen oder höheren Rangs (identisch zur Chunk-Grenze beim Parsen). Die Überschrift selbst bleibt unverändert. Untergeordnete Überschriften (z. B. `###` unter einem ersetzten `##`) sind **eigene Chunks** und werden **nicht** mitersetzt. Rest der Datei bleibt byte-identisch. `content` darf keine Überschriften enthalten, die den Rang der Ziel-Überschrift erreichen oder übertreffen (sonst `isError` — sonst würde die Datei beim nächsten Parse anders zerfallen).

Kein Tool kann eine ganze Datei überschreiben oder löschen. Löschen passiert manuell via Git — bewusst.

### `current`

```json
{ }
```

Antwort:

```json
{
  "now": "2026-07-09T11:20:00+02:00",
  "active":   [ { "id": "...", "title": "...", "ends_in": "2d 8h" } ],
  "upcoming": [ { "id": "bike/via-carolina.md", "title": "Via Carolina", "starts_in": "28h" } ],
  "recently_past": [ { "id": "...", "title": "...", "ended": "3d ago" } ]
}
```

- Nur `type: event`. `upcoming`: nächste 30 Tage. `recently_past`: letzte 7 Tage.
- Ein `event` ohne gültiges `starts` **und** `ends` (fehlend, ohne Offset, oder `ends < starts`): Warnung ins Log, Note wird wie `reference` behandelt, taucht nie in `current` auf. Nicht crashen.
- Relative Zeiten als Strings, keine ISO-Timestamps (Token-Ersparnis). ISO nur im `now`-Feld.
- Reine Funktion von ETS + `now` — nichts wird gespeichert.

### `reload`

```json
{ }
```

`git pull` + Voll-Parse. Für den Fall externer Änderungen (Gitea-Web-UI).

### `skill_list`

```json
{ }
```

Antwort: Liste aus Dateiname und `description` (aus dem Skill-Frontmatter). **Kein Body.** Existiert `skills/` nicht oder ist leer: leere Liste, kein Fehler.

### `skill_read`

```json
{ "name": "tdd" }
```

Kompletter Inhalt von `skills/<name>.md` (mit oder ohne `.md` im Parameter). Nicht gefunden → `isError` mit der Liste vorhandener Namen.

### `skill_write`

```json
{ "name": "tdd", "content": "vollständiger Dateiinhalt inkl. Frontmatter" }
```

Schreibt `skills/<name>.md` (anlegen oder ersetzen), Commit, Push. `content` muss ein Frontmatter mit `name` und `description` enthalten, sonst `isError`.

**Regel (gehört in `instructions`):** `skill_write` wird ausschließlich auf ausdrückliche Anweisung von Daniel aufgerufen. Claude legt niemals proaktiv Skills an oder ändert sie — auch nicht, wenn es naheliegend erscheint. Kontrolle im Nachhinein: `git log skills/ --author=vigil`.

Die `skill_*`-Tools berühren den Store nicht (kein ETS-Eintrag, kein Reparse). Sie sind reine Dateioperationen plus Git.

---

## 6. Zeit-Envelope

Jede Tool-Response enthält zusätzlich genau eines dieser Felder:

| Feld | Wann | Inhalt |
|---|---|---|
| `"_"` | erste Response der Session | `"Do 09.07. 11:20 \| via-carolina in 28h"` — Wochentag, Datum, Zeit, plus aktive/nahe Events (7-Tage-Horizont), eine Zeile |
| `"_t"` | jede weitere Response, nichts geändert | `"11:47"` — nur Uhrzeit |
| `"_!"` | ein Event hat während der Session die Phase gewechselt | `"via-carolina jetzt aktiv"` |

- **Platzierung:** Jedes Tool-Result ist ein JSON-Objekt, das als Text-Content im `tools/call`-Result zurückgegeben wird. Der Envelope ist ein Top-Level-Feld dieses JSON-Objekts, neben dem eigentlichen `result`. Nicht in `_meta`, nicht als separater Content-Block — er muss im Text stehen, den das Modell liest.
- **Ausnahme `current`:** Diese Response bekommt immer nur `"_t"` (Uhrzeit), nie `"_"` oder `"_!"` — alles andere stünde ohnehin im Ergebnis. Sie zählt aber als erster Call der Session, d. h. der nächste andere Tool-Call bekommt `"_t"`, nicht `"_"`.
- Session = `Mcp-Session-Id`-Header. Der Envelope-State (was zuletzt gesendet wurde) lebt pro Session in einer ETS-Tabelle (`:sessions`), Delta-Vergleich bei jedem Call. Sessions ohne Aktivität > 24h werden beim nächsten Zugriff verworfen (frische `"_"`-Zeile).
- Ziel: < 10 Tokens pro Response im Normalfall. Der Envelope ist der Grund, warum Claude nie wieder rät, wie spät es ist.

---

## 7. Git-Protokoll

- **Start:** `git pull --ff-only`. Schlägt der Pull fehl (kein Netz, Gitea down), wird das geloggt und der Server startet trotzdem mit dem lokalen Stand. Ist `VIGIL_VAULT_PATH` kein Git-Repo oder existiert nicht: Start abbrechen mit klarer Fehlermeldung.
- Jeder Write: `git add <datei>` → `git commit` → `git push origin main`. Sofort, kein Batching.
- **Schreibformat:** UTF-8, LF-Zeilenenden, genau ein abschließender Newline am Dateiende. Frontmatter mit `---` in eigener Zeile davor und danach.
- **Reihenfolge bei Writes:** erst Datei schreiben und committen, dann ETS aktualisieren (Reparse der Datei), dann pushen. Schlägt der Push fehl, bleibt der lokale Commit bestehen und das Tool liefert `isError` mit Hinweis, dass die Änderung lokal gespeichert, aber nicht gepusht ist. Nicht zurückrollen.
- Commit-Author: `vigil <vigil@local>`, gesetzt per `-c user.name=vigil -c user.email=vigil@local` am Aufruf (nicht in der Repo-Config, damit manuelle Commits deine Identität behalten). Damit ist `git log --author=vigil` die Provenienz-Abfrage — jede Zeile im Vault ist eindeutig Claude oder Daniel zuzuordnen.
- Commit-Message: `<tool>: <pfad> — <erste ~50 Zeichen des Inhalts oder Heading>`.
- **Kein** `git merge`, **kein** Rebase, **keine** Konfliktauflösung im Code. Der Mensch schaut nach.
- Git-Aufrufe via `System.cmd("git", args, cd: vault_path, stderr_to_stdout: true)`. Exit-Code prüfen, stderr im Fehlerfall ins Log.

---

## 8. Schreibregeln (gehören ins MCP `instructions`-Feld)

Der Server sendet bei der MCP-Initialisierung diese Instructions — sie gelten für jede Claude-Instanz, die je in den Vault schreibt:

> **Stimme:** Daniels Formulierungen wörtlich übernehmen, nicht glätten. Was er gesagt hat, in seinen Worten — im Zweifel roher zitieren als eleganter zusammenfassen. Eigene Einordnungen und Vorschläge explizit als solche kennzeichnen ("Vorschlag von Claude: …"). Der Vault muss in fünf Jahren nach Daniel klingen, nicht nach Claude.
>
> **Sprache:** Deutsch. Englische Fachbegriffe bleiben englisch, wie gesprochen. Keine Übersetzungen in eine Richtung.
>
> **Atomarität:** Jeder Abschnitt muss für sich stehen können — er wird einzeln retrieved. Kein "wie oben erwähnt", keine Pronomen mit Bezug außerhalb des Abschnitts.
>
> **Sparsamkeit:** Vor `create` immer `search`. Lieber `append` an Bestehendes als neue Note. Keine Zusammenfassungen von Dingen, die schon im Vault stehen.
>
> **type:** `reference` = Fakt über die Welt (altert nicht). `decision` = Fakt über Daniel (altert). `event` = hat starts/ends. Im Zweifel `decision`.
>
> **Skills:** `skill_write` nur auf ausdrückliche Anweisung. Niemals proaktiv Skills anlegen oder ändern — auch nicht, wenn es naheliegt. Skills sind Anweisungen an Claude; sie zu schreiben ist Daniels Entscheidung, nicht Claudes.

---

## 9. Konfiguration

Alles über Environment-Variablen (Release-kompatibel, `config/runtime.exs`):

```
VIGIL_VAULT_PATH=/var/lib/vigil/vault
VIGIL_BEARER_TOKEN=<secret>
VIGIL_PORT=4000
VIGIL_GIT_REMOTE=origin
VIGIL_TZ=Europe/Berlin
VIGIL_EXCLUDE=            # kommagetrennt, z.B. "work,private" — wird nie geparst
```

Kein Secret, kein Pfad, keine URL im Quellcode. Der Code ist so geschrieben, als wäre das Repo public.

---

## 10. Deployment

- **Ziel:** unprivilegierter LXC auf Proxmox, Debian 12, systemd-Unit.
- **Artefakt:** Elixir Release (`mix release`), kein Mix/Hex auf dem Zielsystem, kein Docker.
- **Deploy-Trigger:** Git-Tag im Code-Repo → CI baut Release → SSH-Copy in den LXC → `systemctl restart vigil`. **Kein** Auto-Pull bei jedem Commit — deployt wird bewusst.
- systemd: `Restart=on-failure`, `User=vigil`, Environment-File für die Config.
- Cloudflare Tunnel im selben LXC (`cloudflared` als zweite systemd-Unit) → `vault.<domain>` → `localhost:4000`.
- Kein Hot Code Upgrade. Neustart dauert < 1s, der Zustand kommt komplett aus Git.

---

## 11. Init-Script (für Daniel, nicht für den Server)

`scripts/init_vault.sh` — legt einen frischen Vault an. Wird **einmal von Hand** ausgeführt, nie vom Server aufgerufen. Der Server macht keine Struktur.

Was es tut:

1. `git init` im Zielverzeichnis, falls kein Repo.
2. Legt die Domänen-Ordner an (Liste oben im Script als Variable, editierbar): `gear training projects home admin journal skills`.
3. Schreibt `_domains.yml` mit den Beschreibungen (Heredoc im Script).
4. Schreibt `.gitignore` (`.obsidian/`, `.DS_Store`).
5. Legt `projects/vigil/vigil.md` als erste Note an — `type: reference`, H1 `# vigil`, ein Absatz Zweck. (Die inhaltliche Note über Entscheidungen und Verworfenes schreibt Claude später via `create`.)
6. Legt in jeder leeren Domäne eine `.gitkeep` an, damit Git die Ordner überträgt.
7. `git add -A && git commit -m "init vault"` — Author bleibt Daniels Git-Identität.
8. Gibt aus, welches Remote noch zu setzen ist (`git remote add origin …`), setzt es nicht selbst.

Idempotent: erneuter Aufruf legt nur Fehlendes an, überschreibt nichts. Existierende `_domains.yml` bleibt unangetastet.

---

## 12. Explizite Nicht-Ziele (v1)

Nicht bauen, auch nicht "vorbereiten":

- Kein `:digraph` / Graph-Layer — `links`/Backlinks in ETS reichen; ein Graph kommt erst, wenn eine konkrete Query ihn braucht
- Kein Vector Store, keine Embeddings, keine semantische Suche
- Kein Kurator, kein Scheduler, kein Cron, keine Notifications, kein ntfy
- Keine automatischen Zusammenfassungen oder Journal-Einträge — nur explizite Tool-Calls schreiben
- Kein Phoenix, kein Ecto, keine Datenbank
- Kein LLM-Aufruf im Server
- Kein File-Watcher
- Kein Multi-User, keine Rechteverwaltung über den einen Bearer Token hinaus
- Kein Löschen/Überschreiben ganzer Dateien über Tools
- **Kein `create_domain`-Tool.** Ordner legt Daniel an (`mkdir` oder Init-Script). Der Server erzeugt keine Struktur, weil er sonst über sein eigenes Ordnungssystem entscheidet.
- **Kein Schreibzugriff auf `_domains.yml`.** Sie wird nur gelesen.
- **Kein Audit-Log.** Kein Protokoll der Tool-Calls, weder als Datei noch in ETS. Writes stehen in der Git-Historie, Reads sind uninteressant. Nur der Standard-`Logger` (Warnungen, Fehler, Start-Zusammenfassung), landet via systemd in `journalctl`.

---

## 13. Tests

### Versionen

Elixir ≥ 1.17, OTP ≥ 26. In `mix.exs` festnageln, `.tool-versions` (asdf) ins Repo.

### Fixtures — `test/fixtures/vault/` (Pflicht, genau diese Fälle)

Die Domänennamen im Test-Vault (`bike/`, `garten/`, …) sind bewusst andere als in Daniels echtem Vault — Domänen sind dynamisch, der Code darf keinen Namen außer `projects` kennen.

**`bike/terra-speed.md`** — der Normalfall:

```markdown
---
type: reference
---
# WTB Terra Speed 40C

## Maße
40mm Breite, ~450g, TCS tubeless.

## Erfahrung Schotter
Läuft ruhig auf festem Schotter. Zitat Daniel: "auf Asphalt hat's genervt".
```

**`bike/via-carolina.md`** — Event mit Zeiten, verschachtelte Headings:

```markdown
---
type: event
starts: 2026-07-10T17:00:00+02:00
ends: 2026-07-12T20:00:00+02:00
---
# Via Carolina

328 km Prag → Nürnberg. Reifen: [[terra-speed|Terra Speed]].

## Fueling
Grundlast über den Tag.

### Zweite Hälfte
525mg Koffein, konzentriert.

## Gear
Rahmentasche, keine Satteltasche.
```

Erwartete Chunks: `bike/via-carolina.md` (Text vor erster `##`), `#fueling`, `#zweite-haelfte`, `#gear`. Die H1 erzeugt keinen Chunk. `heading_path` von `#zweite-haelfte` ist `["Fueling", "Zweite Hälfte"]`.

**`training/notiz-ohne-alles.md`** — der Härtefall: **kein Frontmatter, keine Überschrift**, nur zwei Absätze Fließtext mit einem `[[via-carolina]]`-Link und dem Wort "Überführungsetappe" (Umlaut im Body).

**`home/böse-datei-ümläute.md`** — Umlaute im Datei­namen, Frontmatter mit **unbekanntem Zusatzfeld** (`tags: [test]`), eine Überschrift `## Wärmepumpen-Überlegung` (Umlaut-Slug: `waermepumpen-ueberlegung`).

**`projects/vigil/vigil.md`** und **`projects/vigil/vigil-ranking.md`** — Unterebene. Erste Datei: `type: reference`, H1 `# vigil`, Link `[[vigil-ranking]]`. Zweite: `type: decision`, H1 `# vigil — Ranking`.

**`garten/hochbeet.md`** — beliebige Domäne, beweist Dynamik: `type: reference`, eine H1, kein Link.

**`_domains.yml`** — im Fixture-Root, beschreibt `bike`, `training`, `projects` (nicht `garten` und nicht `home` — testet die "Ordner ohne Key"-Warnung) und einen Key `phantom` ohne Ordner (testet die "Key ohne Ordner"-Warnung).

**`skills/tdd.md`** — außerhalb des Wissens:

```markdown
---
name: tdd
description: Use when implementing a feature or fixing a bug that needs test coverage.
---
# TDD

1. Failing Test
2. Minimaler Code
3. Refactor
```

### Pflicht-Testfälle

**Parser:** alle vier Wissens-Fixtures parsen ohne Crash; Chunk-IDs deterministisch; Umlaut-Slugs korrekt; H1 erzeugt **keinen** Chunk; Text zwischen H1 und erster `##` wird fragmentloser Chunk; `###` unter `##` ist eigener Chunk mit korrektem `heading_path`; Datei ohne Heading ergibt einen Chunk mit ID = Pfad; unbekanntes Frontmatter-Feld wird toleriert und ignoriert; Wikilinks aus allen Fixtures extrahiert (inkl. `[[a|b]]`); doppelte Headings in einer Datei bekommen `-2`-Suffix (fünfte Mini-Fixture inline im Test).

**Sicherheit:** `create` mit `path: "../../etc/passwd"`, `"/etc/passwd"`, `"bike/../../x.md"`, `"skills/x.md"` → jeweils `isError`, keine Datei angelegt. `skill_read("../bike/terra-speed")` → `isError`. Fehlermeldung enthält nie einen absoluten Pfad.

**Git-Metadaten:** `created_at`/`updated_at` stammen aus dem einmaligen `git log` beim Parse; eine Suche über 100 Chunks löst **null** zusätzliche Git-Prozesse aus (Test z. B. über einen Zähler-Mock von `Vigil.Git`).

**Skills-Isolation:** `skills/tdd.md` erscheint **nicht** in `search`, hat keinen ETS-Chunk, taucht in keinem Backlink auf. `skill_list` liefert `tdd` mit Description; `skill_read("tdd")` und `skill_read("tdd.md")` liefern beide den Body; `skill_read("gibtsnicht")` → `isError` mit Namensliste; `skill_write` ohne `description` im Frontmatter → `isError`; `skill_write` erzeugt Commit, löst aber **keinen** Reparse aus.

**Suche:** Treffer in Titel schlägt Treffer in Body; `domain`-Filter greift; `prefer`-Hint hebt `type`; leeres Ergebnis ist leere Liste, kein Fehler; Preview ≤ 120 Zeichen; Query `"terra speed"` findet den zusammenhängenden Ausdruck, aber nicht eine Note, die nur `terra` und weit entfernt `speed` enthält; ein Chunk aus `journal/` erscheint nicht ohne `domain: "journal"`, mit Filter aber schon.

**Domänen dynamisch:** Ein Fixture-Ordner `garten/` (eine Note, `type: reference`) wird ohne Codeänderung als Domäne erkannt und ist durchsuchbar; `create` in einen nicht existierenden Ordner → `isError` mit Domänenliste; `.obsidian/`, `.git/`, `_domains.yml` werden ignoriert; leerer Vault → Start ohne Fehler, `search` liefert leere Liste.

**projects-Unterebene:** `projects/vigil/vigil.md` und `projects/vigil/vigil-ranking.md` werden geparst, `domain` beider ist `projects`; `create("projects/vigil/x.md")` in existierendem Projektordner ist erlaubt; `create("projects/neu/x.md")` ohne existierenden Ordner → `isError`; `create("projects/vigil/docs/x.md")` → `isError` (zu tief); `create("gear/unter/x.md")` → `isError` (nur `projects` darf Tiefe); `[[vigil]]` löst auf `projects/vigil/vigil.md` auf.

**`_domains.yml`:** Inhalt landet in `instructions`; fehlende Datei → Warnung, Server startet; Key ohne Ordner → Warnung, ignoriert; Ordner ohne Key → trotzdem Domäne, Warnung; kein Tool kann die Datei schreiben.

**`VIGIL_EXCLUDE`:** Mit `VIGIL_EXCLUDE=work` existiert `work/` auf der Platte, aber `search` über jeden dort vorkommenden Begriff liefert nichts, `:chunks` enthält keinen Eintrag mit `work/`-Pfad, `read("work/x.md")` → `isError`, `create("work/y.md")` → `isError`.

**Defensives Parsen:** Note mit unparsbarem YAML-Frontmatter, Note mit `type: quatsch`, Note ganz ohne Frontmatter → alle drei landen in ETS, werden wie `reference` behandelt, erzeugen je eine Log-Warnung, keine wirft.

**current():** mit injiziertem `now` vor/während/nach Via Carolina → upcoming/active/past; `event` ohne `ends` oder mit `ends < starts` → Warnung, Note als `reference` behandelt, taucht nie in `current` auf; relative Zeitformatierung (`"28h"`, `"2d 8h"`).

**Envelope:** Call 1 → `"_"`, Call 2 → `"_t"`; injizierte Zeit über die Event-Grenze → `"_!"`; `current` liefert immer nur `"_t"`, auch als erster Call der Session; zwei parallele Sessions haben getrennten State.

**Git (Integrationstest gegen temporäres bare Repo):** `create` erzeugt Commit mit Author `vigil` und pusht; `create` auf existierende Datei → `isError`; `append` unter existierendem Heading landet am Ende dieses Abschnitts, nicht am Dateiende; `replace_section` auf `##`-Chunk lässt darunterliegende `###`-Abschnitte unangetastet und den Rest der Datei byte-identisch; `replace_section` mit einer `##` im `content` → `isError`; Push-Fehler → `isError`, lokaler Commit bleibt.

**HTTP:** ohne Token → 401; `initialize` liefert `instructions`; unbekannte Methode → `-32601`; `tools/list` enthält exakt zehn Tools.

### Definition of Done

1. `mix test` grün, alle Pflicht-Testfälle oben implementiert.
2. `search("reifen", domain: "bike")` liefert gerankte Chunk-Treffer mit Previews, keine Bodies.
3. `read("bike/via-carolina.md#fueling")` liefert genau diesen Abschnitt; `read("bike/via-carolina.md")` liefert TOC ohne Body; `backlinks: true` hängt Backlink-IDs an, Default nicht.
4. `create` → Datei existiert, Commit mit Author `vigil` in Gitea sichtbar, Push erfolgt, ETS aktualisiert.
5. `current()` klassifiziert ein Test-Event korrekt als upcoming/active/past relativ zu einem injizierten `now` (Zeit ist überall ein **Argument**, nie `DateTime.utc_now()` tief in der Logik — sonst untestbar).
6. Zeit-Envelope: erste Response `"_"`, zweite `"_t"`, Phasenwechsel während der Session erzeugt `"_!"` (Test mit injizierter Zeit).
7. Anfrage ohne/mit falschem Bearer Token → 401.
8. Release startet im LXC via systemd, überlebt Neustart, MCP-Handshake über den Tunnel funktioniert von claude.ai aus.

---

## 14. Bau-Reihenfolge (Empfehlung)

1. `scripts/init_vault.sh` — damit es überhaupt einen Vault gibt.
2. Fixtures anlegen (Sektion 13) — sie sind die Spec in ausführbarer Form.
3. `Vigil.Parser` — pur, ohne Server, testgetrieben gegen die Fixtures. Hier entscheidet sich die Qualität.
4. `Vigil.Store` — ETS, Laden, `_domains.yml`, `VIGIL_EXCLUDE`, Suche mit Ranking.
5. `Vigil.Git` + Write-Tools (gegen temporäres bare Repo testen).
6. MCP-Transport + Envelope.
7. Release + LXC + Tunnel.
