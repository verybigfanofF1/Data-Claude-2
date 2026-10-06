// Runs the Studio plugin inside the standalone Luau runtime against a mocked Roblox API.
// Needs the `luau` binary (https://github.com/luau-lang/luau/releases): on PATH or via LUAU_BIN.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const luau = process.env.LUAU_BIN || "luau";
const hasLuau = spawnSync(luau, ["--help"]).error === undefined;

test("plugin handlers work against a mocked Studio API", { skip: !hasLuau && "luau binary not found" }, () => {
  const mock = fs.readFileSync(path.join(root, "test/plugin/mock.luau"), "utf8");
  const plugin = fs.readFileSync(path.join(root, "plugin/ClaudeBridge.server.lua"), "utf8");
  const cases = fs.readFileSync(path.join(root, "test/plugin/cases.luau"), "utf8");
  const source = `${plugin}\n${cases}`;
  assert.ok(!source.includes("]======]"));
  // Load the plugin through loadstring so the mocked globals (typeof, game, ...) are really used.
  const harness =
    `local env = (function()\n${mock}\nend)()\n` +
    `local fn, err = loadstring([======[${source}]======], "=ClaudeBridge")\n` +
    `if not fn then error(err) end\n` +
    `setfenv(fn, env)\nfn()\n`;
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "claude-bridge-"));
  const file = path.join(dir, "harness.luau");
  fs.writeFileSync(file, harness);
  const result = spawnSync(luau, [file], { encoding: "utf8" });
  fs.rmSync(dir, { recursive: true, force: true });
  const output = `${result.stdout}${result.stderr}`;
  assert.equal(result.status, 0, output);
  assert.match(output, / 0 failed/);
});
