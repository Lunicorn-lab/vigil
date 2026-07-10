# vigil

Elixir-Server, der einen Markdown-Vault liest, wie spät es ist weiß, und über MCP
als Gedächtnis-Backend für Claude dient. Siehe [`vigil-spec.md`](vigil-spec.md)
für die vollständige Spezifikation.

## Entwicklung

```bash
mix deps.get
mix test
```

Für einen lokalen Testlauf gegen einen frischen Vault:

```bash
./scripts/init_vault.sh /tmp/mein-vault
cd /tmp/mein-vault && git remote add origin <gitea-url> && git push -u origin main
cd -

VIGIL_VAULT_PATH=/tmp/mein-vault \
VIGIL_BEARER_TOKEN=dev-token \
VIGIL_PORT=4000 \
mix run --no-halt
```

## Konfiguration

Alle Werte über Environment-Variablen (siehe `config/runtime.exs`):

| Variable | Default | Zweck |
|---|---|---|
| `VIGIL_VAULT_PATH` | `test/fixtures/vault` | Pfad zum Git-Clone des Vaults |
| `VIGIL_BEARER_TOKEN` | `dev-token` | Bearer-Token für `/mcp` |
| `VIGIL_PORT` | `4000` | HTTP-Port |
| `VIGIL_GIT_REMOTE` | `origin` | Remote-Name für Push |
| `VIGIL_TZ` | `Europe/Berlin` | Zeitzone für `current`, Envelope, relative Zeiten |
| `VIGIL_EXCLUDE` | leer | Kommagetrennte Ordnernamen, die nie geparst werden |

## Release & Deployment

```bash
MIX_ENV=prod mix release
```

Das Release nach `/opt/vigil` auf den Ziel-LXC kopieren, `deploy/vigil.env.example`
nach `/etc/vigil/vigil.env` kopieren und ausfüllen, dann:

```bash
sudo cp deploy/vigil.service /etc/systemd/system/vigil.service
sudo systemctl daemon-reload
sudo systemctl enable --now vigil
```

Cloudflare Tunnel läuft als zweite systemd-Unit (`deploy/cloudflared.service`)
und leitet `vault.<domain>` auf `localhost:4000`.

Deploy-Trigger ist bewusst manuell: Git-Tag im Code-Repo → CI baut Release →
SSH-Copy in den LXC → `systemctl restart vigil`. Kein Auto-Pull bei jedem Commit.

## Architektur

```
lib/vigil/
├── application.ex   # Supervisor: Store, Envelope, MCP.Server
├── store.ex          # GenServer — ETS-Chunks/Links/Files, Suche, Writes
├── parser.ex         # Datei → Frontmatter + Chunks + Links
├── search.ex          # reine Ranking-Funktionen
├── git.ex             # System.cmd-Wrapper: add/commit/push/log
├── time_fmt.ex        # relative Zeitformatierung
└── mcp/
    ├── server.ex      # Bandit + Plug, Streamable HTTP, JSON-RPC
    ├── tools.ex        # Tool-Definitionen + Dispatch
    └── envelope.ex     # Zeit-Envelope, Session-Delta-Tracking
```
