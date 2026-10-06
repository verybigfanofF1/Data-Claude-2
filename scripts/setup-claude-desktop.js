#!/usr/bin/env node
// Adds the roblox-studio MCP server to Claude Desktop's config, using absolute paths
// (GUI apps on macOS don't inherit the terminal's PATH, so a bare "node" would fail).
// Keeps every other server in the config and saves a backup first.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

function configPath() {
  if (process.env.CLAUDE_DESKTOP_CONFIG) return process.env.CLAUDE_DESKTOP_CONFIG;
  if (process.platform === "darwin")
    return path.join(os.homedir(), "Library", "Application Support", "Claude", "claude_desktop_config.json");
  if (process.platform === "win32") return path.join(process.env.APPDATA || "", "Claude", "claude_desktop_config.json");
  return path.join(os.homedir(), ".config", "Claude", "claude_desktop_config.json");
}

const serverScript = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "src", "index.js");
const file = configPath();

let config = {};
if (fs.existsSync(file)) {
  const text = fs.readFileSync(file, "utf8");
  if (text.trim()) {
    try {
      config = JSON.parse(text);
    } catch (err) {
      console.error(`Cannot parse ${file}: ${err.message}\nFix or delete that file and run this again.`);
      process.exit(1);
    }
  }
  fs.copyFileSync(file, `${file}.backup`);
}

config.mcpServers ??= {};
config.mcpServers["roblox-studio"] = { command: process.execPath, args: [serverScript] };

fs.mkdirSync(path.dirname(file), { recursive: true });
fs.writeFileSync(file, JSON.stringify(config, null, 2) + "\n");
console.log(`Claude Desktop config updated: ${file}`);
console.log(`  node:   ${process.execPath}`);
console.log(`  server: ${serverScript}`);
