// Restart scenarios seen with Claude Desktop: it starts the server, kills it ~2s later and starts it again.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { StudioBridge } from "../src/bridge.js";

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

test("a new bridge takes the port over from an older instance", async () => {
  const older = new StudioBridge({ port: 0 });
  assert.equal(await older.start(), true);
  const port = older.port;

  const newer = new StudioBridge({ port });
  assert.equal(await newer.start(), true, "newer instance should get the port");
  assert.match(older.listenError.message, /newer roblox-claude-bridge instance took over/);
  const health = await (await fetch(`http://127.0.0.1:${port}/health`)).json();
  assert.equal(health.service, "roblox-claude-bridge");

  await newer.stop();
  await older.stop();
});

test("a bridge keeps retrying while a foreign process holds the port", async () => {
  const http = await import("node:http");
  const foreign = http.createServer((req, res) => res.writeHead(404).end());
  await new Promise((r) => foreign.listen(0, "127.0.0.1", r));
  const port = foreign.address().port;

  const bridge = new StudioBridge({ port });
  assert.equal(await bridge.start(), false);
  assert.equal(bridge.listenError.code, "EADDRINUSE");
  await new Promise((r) => foreign.close(r));
  for (let i = 0; i < 40 && bridge.listenError; i++) await sleep(100);
  assert.equal(bridge.listenError, null, "bridge should grab the port once it is free");
  await bridge.stop();
});

test("the server process exits when its client closes stdin, even during startup", async () => {
  const child = spawn(process.execPath, [path.join(root, "src/index.js")], {
    env: { ...process.env, ROBLOX_BRIDGE_PORT: "0", ROBLOX_BRIDGE_OFFLINE: "1" },
    stdio: ["pipe", "pipe", "pipe"],
  });
  child.stdin.end(); // client goes away immediately
  const code = await Promise.race([
    new Promise((r) => child.on("exit", (c) => r(c))),
    sleep(8000).then(() => "still running"),
  ]);
  if (code === "still running") child.kill();
  assert.equal(code, 0);
});
