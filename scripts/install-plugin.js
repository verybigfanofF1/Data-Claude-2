#!/usr/bin/env node
// Copies the Claude Bridge plugin into the local Roblox Studio Plugins folder.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const source = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "plugin", "ClaudeBridge.server.lua");

function pluginsDir() {
  if (process.env.ROBLOX_PLUGINS_DIR) return process.env.ROBLOX_PLUGINS_DIR;
  if (process.platform === "win32" && process.env.LOCALAPPDATA) return path.join(process.env.LOCALAPPDATA, "Roblox", "Plugins");
  if (process.platform === "darwin") return path.join(os.homedir(), "Documents", "Roblox", "Plugins");
  return null;
}

const dir = pluginsDir();
if (!dir) {
  console.error("Roblox Studio runs only on Windows/macOS. Set ROBLOX_PLUGINS_DIR or copy the file manually:\n  " + source);
  process.exit(1);
}
fs.mkdirSync(dir, { recursive: true });
const target = path.join(dir, "ClaudeBridge.server.lua");
fs.copyFileSync(source, target);
console.log(`Installed plugin -> ${target}\nRestart Roblox Studio (or reload plugins) to load it.`);
