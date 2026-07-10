#!/usr/bin/env bash
# Legt einen frischen vigil-Vault an. Wird einmal von Hand ausgeführt, nie vom Server.
# Idempotent: erneuter Aufruf legt nur Fehlendes an, überschreibt nichts.
set -euo pipefail

VAULT_DIR="${1:-.}"
DOMAINS=(gear training projects home admin journal skills)

mkdir -p "$VAULT_DIR"
cd "$VAULT_DIR"

if [ ! -d .git ]; then
  git init
  echo "git-Repository initialisiert in $VAULT_DIR"
fi

for domain in "${DOMAINS[@]}"; do
  mkdir -p "$domain"
done

if [ ! -f _domains.yml ]; then
  cat > _domains.yml <<'EOF'
gear:      "Material: Rad, Komponenten, Ausrüstung, Wartung"
training:  "Körper: Planung, Ernährung, Recovery, Metriken"
projects:  "Software-Projekte. Ein Unterordner pro Projekt, Hauptnote = Projektname"
home:      "Haus, WEG, Energie, Handwerk"
admin:     "Finanzen, Versicherung, Verträge, Behörden"
journal:   "Chronologisch, erscheint nicht in der Default-Suche"
EOF
  echo "_domains.yml angelegt"
else
  echo "_domains.yml existiert bereits, unangetastet"
fi

if [ ! -f .gitignore ]; then
  cat > .gitignore <<'EOF'
.obsidian/
.DS_Store
EOF
  echo ".gitignore angelegt"
fi

mkdir -p projects/vigil
if [ ! -f projects/vigil/vigil.md ]; then
  cat > projects/vigil/vigil.md <<'EOF'
---
type: reference
---
# vigil

Elixir-Server, der diesen Vault liest und über MCP als Gedächtnis-Backend für Claude dient.
EOF
  echo "projects/vigil/vigil.md angelegt"
fi

for domain in "${DOMAINS[@]}"; do
  if [ -z "$(find "$domain" -mindepth 1 -not -name '.gitkeep' -print -quit 2>/dev/null)" ]; then
    touch "$domain/.gitkeep"
  fi
done

if ! git diff --cached --quiet 2>/dev/null || [ -n "$(git status --porcelain)" ]; then
  git add -A
  git commit -m "init vault" || echo "Nichts zu committen"
else
  echo "Keine Änderungen zu committen"
fi

echo
echo "Fertig. Remote noch setzen, z.B.:"
echo "  git remote add origin git@gitea.example.com:daniel/vault.git"
echo "  git push -u origin main"
