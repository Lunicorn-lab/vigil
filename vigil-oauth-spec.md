# vigil — OAuth 2.1 Spezifikation (v1.1)

Erweiterung der vigil-Spec. Ziel: `https://vault.factory-lab.org/mcp` als Custom Connector in claude.ai (Web, Desktop, iOS) und in Claude Code nutzbar machen.

Der statische Bearer Token aus v1.0 wird **ersetzt**, nicht ergänzt.

---

## 0. Warum

Anthropic-Doku, Stand Juli 2026: *„User-pasted bearer tokens (`static_bearer`) are **not yet supported**."* Unterstützt werden `oauth_dcr`, `oauth_cimd`, `oauth_anthropic_creds` (nur auf Anfrage) und `none`.

Da der Server öffentlich über einen Cloudflare Tunnel erreichbar ist, scheidet `none` aus. Also: **vigil wird sein eigener OAuth-2.1-Autorisierungsserver.**

Es gibt genau **einen Nutzer** (Daniel). Das vereinfacht fast alles — es gibt keine Nutzerverwaltung, keine Rollen, keine Mandanten. „User consent" ist eine Seite, auf der Daniel ein Passwort eingibt und auf „Zulassen" klickt.

---

## 1. Architektur-Entscheidungen (nicht verhandelbar)

**Autorisierungsserver und Resource Server sind derselbe Prozess.** Issuer ist `https://vault.factory-lab.org` (aus `VIGIL_ISSUER`), Resource ist `https://vault.factory-lab.org/mcp`.

**Access Tokens sind opak, keine JWTs.** Ein 32-Byte-Zufallswert, hex-kodiert. Da Aussteller und Prüfer derselbe Prozess sind, bringt ein JWT keinen Vorteil — nur eine Signaturbibliothek als Dependency und eine Klasse von Fehlern (falsche `aud`-Claims), die bei einem Lookup nicht existieren kann. Die Audience wird beim Ausstellen gespeichert und beim Prüfen verglichen.

**Persistenz über `:dets`.** Tokens und registrierte Clients müssen einen Neustart überleben, sonst muss Daniel nach jedem Deploy neu autorisieren. `:dets` ist in OTP enthalten, keine Dependency. Eine Datei, drei Tabellen.

**Beide Registrierungswege werden unterstützt:** DCR für claude.ai, CIMD für Claude Code. Der Aufwand für CIMD ist gering und Claude Code nutzt es.

---

## 2. Endpunkte

Alle unter demselben Bandit-Router wie `/mcp`.

| Pfad | Methode | Zweck |
|---|---|---|
| `/.well-known/oauth-protected-resource` | GET | RFC 9728, Resource Metadata |
| `/.well-known/oauth-protected-resource/mcp` | GET | dito (Pfad-Variante, identischer Body) |
| `/.well-known/oauth-authorization-server` | GET | RFC 8414, AS Metadata |
| `/oauth/register` | POST | RFC 7591, Dynamic Client Registration |
| `/oauth/authorize` | GET | Consent-Seite (HTML) |
| `/oauth/authorize` | POST | Consent-Formular, erzeugt Code, redirected |
| `/oauth/token` | POST | Code → Access Token, Refresh → Access Token |
| `/mcp` | POST | wie bisher, aber neue Auth-Prüfung |

Kein `/oauth/revoke`, kein Introspection-Endpunkt. Nicht nötig.

---

## 3. Discovery-Dokumente

### `GET /.well-known/oauth-protected-resource`

Auch unter `/.well-known/oauth-protected-resource/mcp` mit identischem Inhalt ausliefern (Clients probieren beide Pfade).

```json
{
  "resource": "https://vault.factory-lab.org/mcp",
  "authorization_servers": ["https://vault.factory-lab.org"],
  "scopes_supported": ["vault"],
  "bearer_methods_supported": ["header"]
}
```

`Content-Type: application/json`. Kein Auth. **Muss** ohne Token erreichbar sein.

### `GET /.well-known/oauth-authorization-server`

```json
{
  "issuer": "https://vault.factory-lab.org",
  "authorization_endpoint": "https://vault.factory-lab.org/oauth/authorize",
  "token_endpoint": "https://vault.factory-lab.org/oauth/token",
  "registration_endpoint": "https://vault.factory-lab.org/oauth/register",
  "scopes_supported": ["vault"],
  "response_types_supported": ["code"],
  "grant_types_supported": ["authorization_code", "refresh_token"],
  "code_challenge_methods_supported": ["S256"],
  "token_endpoint_auth_methods_supported": ["none"],
  "client_id_metadata_document_supported": true
}
```

**`code_challenge_methods_supported` ist Pflicht.** Fehlt es, verweigern Clients laut Spec die Verbindung.

**`token_endpoint_auth_methods_supported: ["none"]`** — alle unsere Clients sind Public Clients (PKCE statt Client Secret). Der Wert `"none"` ist zusätzlich Voraussetzung dafür, dass Claude CIMD wählt.

---

## 4. Der 401-Challenge

Jeder unautorisierte Zugriff auf `/mcp`:

```http
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer resource_metadata="https://vault.factory-lab.org/.well-known/oauth-protected-resource", scope="vault"
```

Body leer. **Ohne diesen Header findet der Client den Autorisierungsserver nicht** und meldet „Couldn't reach the MCP server".

---

## 5. Client-Registrierung

### DCR — `POST /oauth/register`

Kein Auth. Request (RFC 7591), relevante Felder:

```json
{
  "client_name": "Claude",
  "redirect_uris": ["https://claude.ai/api/mcp/auth_callback"],
  "grant_types": ["authorization_code", "refresh_token"],
  "response_types": ["code"],
  "token_endpoint_auth_method": "none"
}
```

Antwort `201 Created`:

```json
{
  "client_id": "<uuid4>",
  "client_name": "Claude",
  "redirect_uris": [...],
  "grant_types": ["authorization_code", "refresh_token"],
  "response_types": ["code"],
  "token_endpoint_auth_method": "none",
  "client_id_issued_at": 1783670000
}
```

**Kein `client_secret`.** Public Client.

Gespeichert wird in `:dets` unter `{client_id, %{name, redirect_uris, issued_at}}`.

**Redirect-URI-Validierung bei der Registrierung:** Jede URI muss entweder `https://` sein, oder Host `localhost` bzw. `127.0.0.1` mit `http://`. Sonst `400` mit `{"error": "invalid_redirect_uri"}`.

### CIMD — URL als `client_id`

Ist `client_id` eine `https://`-URL (Claude Code nutzt `https://claude.ai/oauth/claude-code-client-metadata`), dann:

1. Dokument per HTTPS holen (Timeout 5 s, max. 64 KB).
2. `client_id` im Dokument **muss** exakt der URL entsprechen. Sonst `invalid_client`.
3. Pflichtfelder prüfen: `client_id`, `client_name`, `redirect_uris`.
4. Ergebnis 1 Stunde in ETS cachen (Key = URL).
5. **SSRF-Schutz:** Nur `https`, kein Redirect folgen, und die aufgelöste IP darf nicht in `127.0.0.0/8`, `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16`, `::1`, `fc00::/7` liegen. Sonst `invalid_client`.

Für den Fetch reicht `:httpc` aus OTP — keine neue Dependency.

---

## 6. Redirect-URI-Matching (der Teil, an dem es scheitert)

Beim `/authorize`-Request wird die übergebene `redirect_uri` gegen die registrierten geprüft:

- **HTTPS-URIs:** exakter String-Vergleich. Für claude.ai also exakt `https://claude.ai/api/mcp/auth_callback`.
- **Loopback-URIs:** Claude Code nutzt einen **ephemeren Port**, z. B. `http://localhost:3118/callback`. Registriert ist nur `http://localhost/callback` bzw. `http://127.0.0.1/callback`. Also: Schema, Host und Pfad müssen exakt passen, **der Port wird ignoriert**. Das gilt für `localhost` **und** `127.0.0.1`.

Kein Präfix-Matching, keine Wildcards, kein Ignorieren des Pfads. Bei Nichtübereinstimmung: `400` mit HTML-Fehlerseite, **kein Redirect** (Open-Redirect-Schutz).

---

## 7. `/oauth/authorize`

### GET — Consent-Seite

Query-Parameter:

| Parameter | Pflicht | Prüfung |
|---|---|---|
| `response_type` | ja | muss `code` sein |
| `client_id` | ja | registriert (DCR) oder gültige CIMD-URL |
| `redirect_uri` | ja | siehe Sektion 6 |
| `code_challenge` | ja | vorhanden, nicht leer |
| `code_challenge_method` | ja | muss `S256` sein, sonst `400` |
| `state` | nein | unverändert zurückgeben |
| `resource` | nein | wenn vorhanden, muss es `https://vault.factory-lab.org/mcp` sein |
| `scope` | nein | ignoriert; es gibt nur `vault` |

Fehlt oder passt `redirect_uri` bzw. `client_id` nicht → HTML-Fehlerseite, **kein Redirect**. Alle anderen Fehler → Redirect mit `error=invalid_request`.

Die Seite ist minimales HTML (EEx, inline im Modul, kein Template-Verzeichnis):

- Überschrift: *„vigil — Zugriff erlauben?"*
- Zeigt: `client_name`, und **prominent den Hostnamen der `redirect_uri`** (Spec-Anforderung; bei `localhost` zusätzlich ein Warnhinweis).
- Ein Passwortfeld.
- Buttons „Zulassen" / „Ablehnen".
- Hidden Fields für alle Query-Parameter.

### POST — Consent verarbeiten

- Passwort gegen `VIGIL_AUTH_PASSWORD` prüfen, mit `Plug.Crypto.secure_compare/2`. Falsch → Seite erneut, Fehlermeldung, **kein** Redirect. Nach 5 Fehlversuchen aus derselben IP innerhalb 15 Minuten: `429`, weitere 15 Minuten gesperrt (Zähler in ETS).
- „Ablehnen" → Redirect mit `error=access_denied&state=...`
- „Zulassen" → Authorization Code erzeugen: 32 Byte Zufall, hex.

Gespeichert in `:dets` (`:auth_codes`):

```elixir
{code, %{
  client_id: ...,
  redirect_uri: ...,
  code_challenge: ...,
  resource: "https://vault.factory-lab.org/mcp",
  expires_at: now + 60      # Sekunden
}}
```

Dann `302` auf `redirect_uri` mit `?code=...&state=...`.

---

## 8. `/oauth/token`

`Content-Type: application/x-www-form-urlencoded`. Kein Client-Auth (Public Client). Antworten immer `Cache-Control: no-store`.

### `grant_type=authorization_code`

Parameter: `code`, `redirect_uri`, `client_id`, `code_verifier`, optional `resource`.

Prüfungen, in dieser Reihenfolge:

1. Code existiert → sonst `invalid_grant`
2. **Code sofort löschen** (One-Time-Use, auch bei folgenden Fehlern)
3. `expires_at` nicht überschritten → sonst `invalid_grant`
4. `client_id` identisch zum gespeicherten → sonst `invalid_grant`
5. `redirect_uri` identisch zum gespeicherten → sonst `invalid_grant`
6. PKCE: `Base.url_encode64(:crypto.hash(:sha256, code_verifier), padding: false) == code_challenge` → sonst `invalid_grant`
7. Falls `resource` mitgeschickt: muss dem gespeicherten entsprechen → sonst `invalid_target`

Antwort `200`:

```json
{
  "access_token": "<64 hex chars>",
  "token_type": "Bearer",
  "expires_in": 3600,
  "refresh_token": "<64 hex chars>",
  "scope": "vault"
}
```

Speichern in `:dets` (`:tokens`):

```elixir
{access_token, %{aud: "https://vault.factory-lab.org/mcp", expires_at: now + 3600}}
{refresh_token, %{type: :refresh, client_id: ..., aud: ..., expires_at: now + 30*86400}}
```

### `grant_type=refresh_token`

Parameter: `refresh_token`, `client_id`, optional `resource`.

1. Existiert, ist `type: :refresh`, nicht abgelaufen, `client_id` passt → sonst `invalid_grant`
2. **Rotation ist Pflicht** (Public Client): altes Refresh Token löschen, neues ausgeben.
3. Neues Access Token ausgeben.

**Wichtig:** Bei ungültigem oder abgelaufenem Refresh Token **muss** der Fehlercode `invalid_grant` sein — nicht `invalid_request`, nicht etwas Eigenes. Claude erneuert Tokens reaktiv beim 401 und proaktiv bis zu fünf Minuten vor Ablauf; ein falscher Fehlercode bricht die Erneuerung.

### Fehlerformat (RFC 6749)

```http
HTTP/1.1 400 Bad Request
Content-Type: application/json

{"error": "invalid_grant", "error_description": "..."}
```

Zulässige Werte: `invalid_request`, `invalid_client`, `invalid_grant`, `unsupported_grant_type`, `invalid_target`. `invalid_client` → HTTP `401`.

---

## 9. Token-Prüfung an `/mcp`

Bei jedem Request:

1. `Authorization: Bearer <token>` vorhanden → sonst 401 mit Challenge (Sektion 4)
2. Token in `:tokens` → sonst 401 mit Challenge
3. Kein `type: :refresh` → sonst 401 (Refresh Tokens sind keine Access Tokens)
4. `expires_at > now` → sonst 401 mit Challenge; abgelaufenen Eintrag löschen
5. **`aud == VIGIL_RESOURCE`** → sonst 401. Diese Prüfung ist von der Spec zwingend gefordert („MCP servers MUST validate that access tokens were issued specifically for them as the intended audience").

Der Vergleich des Token-Strings läuft über `Plug.Crypto.secure_compare/2` — der `:dets`-Lookup selbst ist ein Hash-Lookup und damit unkritisch, aber der Vergleich der gefundenen Werte nicht.

**Der Bearer-Token-Code aus v1.0 (`VIGIL_BEARER_TOKEN`) wird ersatzlos entfernt.** Kein Fallback, kein Dual-Mode. Ein Server mit zwei Auth-Pfaden hat zwei Angriffsflächen und einen Pfad, den niemand testet.

---

## 10. Aufräumen

Ein `GenServer` (`Vigil.OAuth.Janitor`), Intervall 5 Minuten:

- Abgelaufene Auth Codes löschen
- Abgelaufene Access und Refresh Tokens löschen
- Rate-Limit-Zähler älter als 15 Minuten löschen

Kein Cron, kein Oban. `Process.send_after/3`.

---

## 11. Persistenz

Eine `:dets`-Datei, Pfad aus `VIGIL_STATE_FILE` (Default `/var/lib/vigil/oauth.dets`). Drei logische Tabellen — der Einfachheit halber drei separate `:dets`-Dateien im selben Verzeichnis:

- `oauth_clients.dets`
- `oauth_codes.dets`
- `oauth_tokens.dets`

Beim Start öffnen, beim Beenden schließen (`terminate/2`). `:dets.sync/1` nach jedem Schreibvorgang — die Schreibrate ist niedrig genug, dass das egal ist, und ein verlorenes Token nach einem Absturz kostet Daniel eine Neuautorisierung.

Dateirechte `0600`, Eigentümer `vigil`.

---

## 12. Konfiguration

```
VIGIL_ISSUER=https://vault.factory-lab.org
VIGIL_RESOURCE=https://vault.factory-lab.org/mcp
VIGIL_AUTH_PASSWORD=<secret>
VIGIL_STATE_DIR=/var/lib/vigil
```

`VIGIL_BEARER_TOKEN` entfällt.

**Startprüfung:** Fehlt `VIGIL_AUTH_PASSWORD` oder ist es kürzer als 12 Zeichen → Abbruch mit klarer Meldung. Ein öffentlich erreichbarer Autorisierungsserver ohne Passwort ist ein offenes Tor zum Vault.

---

## 13. Nicht-Ziele

- Kein Multi-User, keine Registrierung, keine Passwort-Wiederherstellung
- Keine Scopes über `vault` hinaus, kein Step-Up-Flow, kein `insufficient_scope`
- Kein JWT, keine Signaturschlüssel, keine JWKS
- Kein `client_credentials`-Grant (von Anthropic ausdrücklich nicht unterstützt)
- Kein `client_secret` — alle Clients sind Public Clients mit PKCE
- Kein Token-Revocation-Endpunkt (Daniel löscht die `.dets`-Datei)
- Keine OpenID-Connect-Discovery (`/.well-known/openid-configuration` bleibt 404; die OAuth-Variante genügt)
- Kein Session-Cookie nach dem Login — jeder `/authorize` verlangt das Passwort erneut. Das passiert selten genug.

---

## 14. Tests

Ergänzend zu Sektion 13 der Haupt-Spec.

**Discovery:** Beide `oauth-protected-resource`-Pfade liefern identisches JSON und `200` ohne Auth. `oauth-authorization-server` enthält `code_challenge_methods_supported: ["S256"]`, `token_endpoint_auth_methods_supported: ["none"]` und `client_id_metadata_document_supported: true`.

**Challenge:** `POST /mcp` ohne Token → `401`, Header enthält `resource_metadata=` und `scope="vault"`.

**DCR:** Registrierung mit `https://claude.ai/api/mcp/auth_callback` → `201`, kein `client_secret` im Body. Registrierung mit `http://evil.example.com/cb` → `400 invalid_redirect_uri`. Mit `http://localhost/callback` → `201`.

**Redirect-Matching:** Registriert `http://localhost/callback`; `/authorize` mit `http://localhost:3118/callback` wird akzeptiert, mit `http://localhost:3118/other` abgelehnt, mit `http://evil.tld/callback` abgelehnt (HTML-Fehlerseite, **kein** 302).

**PKCE:** Vollständiger Flow mit korrektem `code_verifier` → Access Token. Mit falschem `code_verifier` → `invalid_grant`, Code ist danach auch mit korrektem Verifier nicht mehr einlösbar (One-Time-Use).

**`code_challenge_method=plain`** → `400`.

**Audience:** Access Token mit `aud` = `https://andere.tld/mcp` (direkt in `:dets` geschrieben) → `/mcp` antwortet `401`.

**Refresh:** Refresh Token einlösen → neues Access **und** neues Refresh Token; das alte Refresh Token ist danach ungültig (`invalid_grant`). Abgelaufenes Refresh Token → Fehlercode exakt `invalid_grant`.

**Refresh Token als Access Token** an `/mcp` → `401`.

**Passwort:** Falsches Passwort → kein Redirect, kein Code erzeugt. Sechster Fehlversuch innerhalb 15 Minuten → `429`.

**CIMD:** `client_id` = URL, die ein Dokument mit abweichender `client_id` liefert → `invalid_client`. `client_id` = URL, die auf `127.0.0.1` auflöst → `invalid_client` (SSRF).

**Persistenz:** Token ausstellen, Prozess neu starten, `/mcp` mit demselben Token → `200`.

**Janitor:** Abgelaufener Code verschwindet aus `:dets` nach einem Janitor-Lauf (Zeit als Argument injizieren, nicht schlafen).

---

## 15. Definition of Done

1. `mix test` grün, alle Tests aus Sektion 14.
2. `curl -i -X POST https://vault.factory-lab.org/mcp` → `401` mit `WWW-Authenticate`-Header.
3. `curl https://vault.factory-lab.org/.well-known/oauth-protected-resource` → `200`, korrektes JSON.
4. In claude.ai: Custom Connector mit URL `https://vault.factory-lab.org/mcp` hinzufügen, ohne Client ID und Secret. „Verbinden" öffnet die vigil-Consent-Seite, Passwort eingeben, „Zulassen" → Connector zeigt „Verbunden".
5. In der Claude-iOS-App: derselbe Connector ist verfügbar, `current` liefert ein Ergebnis.
6. `claude mcp add vigil https://vault.factory-lab.org/mcp --scope user --transport http` (**ohne** `--header`) → OAuth-Flow im Browser, danach `claude mcp list` zeigt „Connected".
7. Neustart des Dienstes → beide Clients funktionieren ohne Neuautorisierung.

---

## 16. Bau-Reihenfolge

1. `Vigil.OAuth.Store` — `:dets`, Clients/Codes/Tokens, reine Funktionen, `now` als Argument.
2. Discovery-Endpunkte + 401-Challenge. Danach findet Claude den AS bereits — guter Zwischenstand zum Testen.
3. `/oauth/register` (DCR) + Redirect-URI-Validierung.
4. `/oauth/authorize` GET/POST + Consent-Seite + PKCE-Speicherung.
5. `/oauth/token` beide Grants + Rotation.
6. Token-Prüfung an `/mcp`, alten Bearer-Pfad entfernen.
7. CIMD (nur nötig für Claude Code — claude.ai läuft schon nach Schritt 6).
8. Janitor.

Nach Schritt 6 ist der Connector in claude.ai und auf dem iPhone nutzbar. Das ist das eigentliche Ziel.

---

## 17. Hinweis für den Agent

Die MCP-Autorisierungsspezifikation entwickelt sich. Diese Spec beruht auf der Fassung vom 2025-11-25 und Anthropics Connector-Doku, Stand Juli 2026. **Vor der Implementierung prüfen:**

- `https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization`
- `https://claude.com/docs/connectors/building/authentication`

Insbesondere die Callback-URL `https://claude.ai/api/mcp/auth_callback` und die Liste der unterstützten Auth-Typen. Wenn die Doku etwas anderes sagt als diese Spec, hat die Doku recht — dann melden, nicht raten.

Anthropics ausgehender Verkehr kommt aus `160.79.104.0/21`. Falls je eine IP-Beschränkung nötig wird: das ist der Bereich.
