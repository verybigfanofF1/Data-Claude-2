# Roblox Claude Bridge

Połączenie **Roblox Studio ↔ Claude**. Claude widzi całą grę otwartą w Studio i może ją edytować na żywo:
budować mapy, tworzyć i poprawiać skrypty, zmieniać właściwości dowolnych obiektów, uruchamiać testy gry
i czytać błędy z okna Output – a wszystko da się cofnąć zwykłym `Ctrl+Z`.

```
┌──────────────┐   MCP (stdio)   ┌──────────────────────┐   HTTP localhost   ┌───────────────────────┐
│    Claude    │ ◄─────────────► │  roblox-claude-bridge │ ◄────────────────► │ Plugin w Roblox Studio │
│ (Code/Desktop)│                 │  (serwer MCP, Node)   │   long-polling     │  ClaudeBridge.server   │
└──────────────┘                 └──────────────────────┘                    └───────────────────────┘
                                   + baza API Roblox (wszystkie klasy, właściwości, enumy)
```

- **Serwer MCP** (`src/`) – udostępnia Claude'owi narzędzia (tools) i trzyma most HTTP na `127.0.0.1:44755`.
- **Plugin Studio** (`plugin/ClaudeBridge.server.lua`) – odbiera polecenia, wykonuje je w Studio i odsyła wyniki.
- **Refleksja API** – serwer pobiera aktualny zrzut API Roblox, dzięki czemu Claude i plugin znają typy
  każdej właściwości (Vector3, Color3, CFrame, Enum…) i poprawnie konwertują wartości.

## Instalacja

Wymagania: Windows lub macOS z Roblox Studio, [Node.js](https://nodejs.org) 18+.

```bash
git clone <to repo> roblox-claude-bridge
cd roblox-claude-bridge
npm install
npm run install-plugin      # kopiuje plugin do folderu Plugins Roblox Studio
```

Ręcznie: skopiuj `plugin/ClaudeBridge.server.lua` do folderu pluginów
(Studio → zakładka **Plugins** → **Plugins Folder**) i zrestartuj Studio.

### Podłączenie do Claude

**Claude Code** (w katalogu tego repo plik `.mcp.json` jest już gotowy), albo globalnie:

```bash
claude mcp add roblox-studio -- node /pełna/ścieżka/do/roblox-claude-bridge/src/index.js
```

**Claude Desktop** – `claude_desktop_config.json` (Settings → Developer → Edit Config):

```json
{
  "mcpServers": {
    "roblox-studio": {
      "command": "node",
      "args": ["C:\\ścieżka\\do\\roblox-claude-bridge\\src\\index.js"]
    }
  }
}
```

### macOS – krok po kroku

> **macOS 12 Monterey i starsze:** Claude Code (terminal) wymaga macOS 13+, a Node.js 24 – macOS 13.5+.
> Używaj **Claude Desktop** (macOS 11+) i **Node.js 22 LTS** (`https://nodejs.org/dist/latest-v22.x/`, plik `.pkg`).

1. Zainstaluj Node.js (na macOS 13.5+ może być najnowszy LTS, na starszych – 22 LTS).
2. Pobierz to repo (ZIP z GitHuba) i rozpakuj, np. do folderu domowego.
3. W Terminalu:

```bash
cd ~/roblox-claude-bridge     # folder z rozpakowanym projektem
bash install-mac.sh
```

Skrypt instaluje zależności, kopiuje plugin do `~/Documents/Roblox/Plugins` i dopisuje serwer do
`~/Library/Application Support/Claude/claude_desktop_config.json` z **pełną ścieżką** do `node`
(aplikacje z Docka nie widzą `PATH` z terminala – stąd typowy błąd `spawn node ENOENT`).
Inne ustawienia w configu zostają, a stary plik jest zapisany jako `.backup`.

Potem zamknij Claude Desktop całkowicie (`Cmd+Q`) i otwórz ponownie.

### Pierwsze uruchomienie

1. Uruchom Claude (serwer MCP startuje automatycznie).
2. Otwórz place w Roblox Studio. W zakładce **Plugins** pojawi się pasek **Claude** z przyciskami
   **Connect** (włącz/wyłącz połączenie) i **Status** (panel z logiem poleceń).
3. Przy pierwszym połączeniu Studio zapyta o zgodę na połączenia HTTP do `127.0.0.1` – kliknij **Allow**.
   Jeśli status pokazuje „Enable HTTP”, włącz *Game Settings → Security → Allow HTTP Requests*.
4. Napisz do Claude, np. *„Sprawdź połączenie ze Studio i pokaż, co jest w grze”*.

## Co Claude potrafi

| Narzędzie | Do czego służy |
|---|---|
| `studio_status` | Czy Studio jest podłączone, nazwa gry, pozycja kamery, zaznaczenie |
| `get_tree` | Drzewo obiektów (Explorer) – całej gry albo wybranej gałęzi |
| `find_instances` | Szukanie po nazwie, klasie (`IsA`), tagu, atrybucie |
| `get_properties` / `set_properties` | Odczyt i zmiana **dowolnych** właściwości, atrybutów i tagów |
| `create_instance`, `clone_instance`, `move_instance`, `delete_instances` | Tworzenie, kopiowanie, przenoszenie, usuwanie obiektów |
| `read_script`, `write_script`, `edit_script` | Czytanie i edycja skryptów (Script, LocalScript, ModuleScript) |
| `run_luau` | Wykonanie dowolnego kodu Luau w Studio (budowanie proceduralne, masowe zmiany…) |
| `batch` | Wiele operacji naraz jako **jeden krok cofania** |
| `playtest` | Start (`play` / `run`) i zatrzymanie testu gry |
| `get_output` | Okno Output – printy, ostrzeżenia, błędy skryptów |
| `terrain` | Teren: wypełnianie blokiem / kulą / cylindrem / klinem, czyszczenie |
| `insert_asset` | Wstawianie modeli z biblioteki Roblox po ID |
| `get_selection` / `set_selection` | Zaznaczenie w Explorerze |
| `undo` / `redo` | Cofnij / ponów |
| `get_class_info`, `search_classes`, `get_enum` | Dokumentacja API Roblox: właściwości, metody, eventy, enumy |

### Testowanie gry przez Claude

Podczas testu (`playtest` → `play`) plugin działa w trzech „kontekstach”:
`edit` (edytowany place), `server` i `client` (uruchomiona gra). Każde narzędzie przyjmuje parametr
`context`, więc Claude może np. czytać `get_output` z serwera, sprawdzać pozycję gracza na kliencie
albo wykonać `run_luau` w działającej grze – a potem zatrzymać test i poprawić skrypty.

## Przykładowe polecenia

- *„Zbuduj obby z 15 platform o rosnącej trudności, z checkpointami i zabijającymi kafelkami lawy.”*
- *„Dodaj system monet: monety rozrzucone po mapie, licznik w leaderstats i GUI z liczbą monet.”*
- *„Zmień oświetlenie na zachód słońca i dodaj mgłę.”*
- *„Przejrzyj wszystkie skrypty w ServerScriptService i napraw błędy z okna Output.”*
- *„Uruchom test gry, sprawdź czy nie ma błędów i zatrzymaj go.”*
- *„Pokoloruj wszystkie części w Workspace.Map na losowe pastelowe kolory.”*

## Format wartości

Wartości są konwertowane według prawdziwego typu właściwości (z API Roblox):

| Typ | Przykład |
|---|---|
| Vector3 | `[0, 5, 0]` |
| Color3 | `"#ff8800"` lub `[255, 136, 0]` lub `[1, 0.5, 0]` |
| CFrame | `[0, 5, 0]`, `{"position":[0,5,0],"rotation":[0,90,0]}`, `{"position":[...],"lookAt":[...]}` |
| UDim2 | `[0.5, 0, 0.5, 0]` (xScale, xOffset, yScale, yOffset) |
| Enum | `"Neon"` lub `"Enum.Material.Neon"` |
| Odwołanie do obiektu | `"Workspace.Car.Body"` (np. dla `PrimaryPart`) |
| Specjalne klucze | `$attributes`, `$tags`, `$addTags`, `$pivot` (przesuń model), `$scale` (skaluj model) |

## Konfiguracja

| Zmienna | Domyślnie | Opis |
|---|---|---|
| `ROBLOX_BRIDGE_PORT` | `44755` | Port mostu HTTP (zmieniasz też `DEFAULT_PORT` na górze pliku pluginu) |
| `ROBLOX_API_DUMP_URL` | Roblox-Client-Tracker | Skąd pobierać zrzut API Roblox |
| `ROBLOX_BRIDGE_CACHE` | `~/.cache/roblox-claude-bridge` | Cache zrzutu API (odświeżany co 7 dni) |
| `ROBLOX_BRIDGE_OFFLINE` | – | `1` = nie pobieraj API z sieci |

## Bezpieczeństwo

- Most nasłuchuje tylko na `127.0.0.1` – nie jest dostępny z sieci.
- Plugin ma uprawnienia pluginu Studio (pełny dostęp do otwartego place'a) – tak jak każdy plugin.
  Wszystkie zmiany trafiają do historii cofania; mimo to rób kopie / używaj wersji place'a przy dużych zmianach.
- Połączenie możesz w każdej chwili wyłączyć przyciskiem **Connect** w pasku Claude.

## Rozwiązywanie problemów

- **„Roblox Studio is not connected”** – sprawdź, czy przycisk **Connect** jest aktywny i czy zezwolono na HTTP.
- **Port zajęty** – działa już inna instancja serwera (np. drugie okno Claude). Zamknij ją albo ustaw inny
  `ROBLOX_BRIDGE_PORT` (i ten sam port w pluginie).
- **Jedno okno Studio naraz** – przy kilku otwartych place'ach polecenia trafią do tego, który ostatnio się połączył.
- **DataStore w teście** – włącz *Game Settings → Security → Enable Studio Access to API Services*.

## Rozwój

```bash
npm test          # testy mostu, serwera MCP i pluginu (plugin w Luau z atrapą API Roblox;
                  # wymaga binarki `luau` z github.com/luau-lang/luau/releases w PATH lub LUAU_BIN)
npm start         # ręczne uruchomienie serwera (stdio)
```

Protokół mostu: plugin wysyła `POST /poll {context}` i dostaje listę `{id, op, args}`;
wyniki odsyła przez `POST /result {results: [{id, ok, data | error}]}`.
Nowe polecenie = handler w `plugin/ClaudeBridge.server.lua` (`handlers.<op>`) + wpis w `src/tools.js`.
