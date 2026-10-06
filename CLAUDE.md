# Roblox Claude Bridge

MCP server (Node, `src/`) + Roblox Studio plugin (Luau, `plugin/ClaudeBridge.server.lua`).
Claude ↔ MCP stdio ↔ `src/index.js` ↔ HTTP long-poll on 127.0.0.1:44755 ↔ Studio plugin.

- `src/bridge.js` – HTTP bridge, per-context (edit/server/client) command queues.
- `src/tools.js` – MCP tool definitions + server instructions (value formats, Roblox conventions).
- `src/reflection.js` – Roblox API dump (classes, property types, enums), cached in ~/.cache.
- Plugin op names (`handlers.<op>`) must match `op` in `src/tools.js` and `OPERATION_NAMES` (batch).

Commands: `npm test` (Node test runner, fake plugin), `npm run install-plugin`.
Never write to stdout in the server – it is the MCP channel; log to stderr.
Luau check: `luau-compile --text plugin/ClaudeBridge.server.lua` (from luau-lang/luau releases).

## Using it (when connected to Studio)
Start with `studio_status` and `get_tree`; use `get_class_info` when unsure; prefer `batch` for builds;
after writing scripts run `playtest` → `get_output` (context "server"/"client") → `playtest stop`.
