#!/bin/bash
# Roblox Claude Bridge - instalator dla macOS.
# Uruchom w Terminalu z folderu projektu:   bash install-mac.sh
set -e
cd "$(dirname "$0")"

echo "== Roblox Claude Bridge: instalacja =="

if ! command -v node >/dev/null 2>&1; then
  echo
  echo "BŁĄD: Brak Node.js."
  echo "Pobierz instalator Node.js 22 LTS (plik .pkg) ze strony:"
  echo "  https://nodejs.org/dist/latest-v22.x/"
  echo "(na macOS 12 Monterey NIE instaluj Node 24 – wymaga macOS 13.5)."
  echo "Po instalacji zamknij i otwórz Terminal, a potem uruchom ten skrypt ponownie."
  exit 1
fi

NODE_MAJOR=$(node -p "process.versions.node.split('.')[0]")
if [ "$NODE_MAJOR" -lt 18 ]; then
  echo "BŁĄD: Node.js $(node -v) jest za stary – potrzebny 18 lub nowszy (zalecany 22 LTS)."
  exit 1
fi
echo "✓ Node.js $(node -v)  ($(command -v node))"

echo "→ Instaluję zależności (npm install)..."
npm install --no-fund --no-audit --omit=dev
echo "✓ Zależności zainstalowane"

echo "→ Instaluję plugin do Roblox Studio..."
node scripts/install-plugin.js

echo "→ Konfiguruję Claude Desktop..."
node scripts/setup-claude-desktop.js

echo "→ Test serwera..."
if node -e "import('./src/index.js').then(() => process.exit(0)).catch(e => { console.error(e); process.exit(1) })"; then
  echo "✓ Serwer działa"
else
  echo "BŁĄD: serwer nie startuje – skopiuj komunikat powyżej i wyślij go Claude."
  exit 1
fi

cat <<'EOF'

== Gotowe! ==
1. Zamknij Claude Desktop całkowicie (Cmd+Q) i otwórz go ponownie.
2. Zamknij i otwórz ponownie Roblox Studio, otwórz dowolny place.
3. W Studio: zakładka Plugins → pasek "Claude" → przycisk "Connect".
   Gdy Studio zapyta o dostęp do 127.0.0.1 – kliknij "Allow".
4. W Claude Desktop napisz:  "Sprawdź połączenie z Roblox Studio"
EOF
