// End-to-end tests: MCP client <-> MCP server <-> HTTP bridge <-> fake Studio plugin.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { StudioBridge } from "../src/bridge.js";
import { Reflection } from "../src/reflection.js";
import { createServer } from "../src/index.js";

process.env.ROBLOX_BRIDGE_OFFLINE = "1";
process.env.ROBLOX_BRIDGE_CACHE = "/nonexistent-roblox-bridge-cache";

let bridge, client, base;

/** Minimal stand-in for the Luau plugin: long-polls and answers commands. */
function startFakePlugin(context, handlers) {
  let running = true;
  const loop = (async () => {
    while (running) {
      const res = await fetch(`${base}/poll`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ context, info: { placeName: "TestPlace" } }),
      });
      const { commands } = await res.json();
      for (const cmd of commands) {
        let result;
        try {
          const handler = handlers[cmd.op];
          if (!handler) throw new Error(`Unknown operation: ${cmd.op}`);
          result = { id: cmd.id, ok: true, data: await handler(cmd.args) };
        } catch (err) {
          result = { id: cmd.id, ok: false, error: err.message };
        }
        await fetch(`${base}/result`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ results: [result] }),
        });
      }
    }
  })();
  return { stop: () => ((running = false), loop) };
}

const text = (r) => r.content.map((c) => c.text).join("\n");

before(async () => {
  const reflection = new Reflection();
  bridge = new StudioBridge({ port: 0, reflection });
  assert.equal(await bridge.start(), true);
  base = `http://127.0.0.1:${bridge.port}`;
  const server = createServer({ bridge, reflection });
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  client = new Client({ name: "test", version: "1.0.0" });
  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
});

after(async () => {
  await client.close();
  await bridge.stop();
});

test("lists all tools", async () => {
  const { tools } = await client.listTools();
  const names = tools.map((t) => t.name);
  for (const n of ["studio_status", "get_tree", "create_instance", "run_luau", "batch", "edit_script", "playtest"]) {
    assert.ok(names.includes(n), `missing tool ${n}`);
  }
});

test("reports a helpful error when Studio is not connected", async () => {
  const r = await client.callTool({ name: "get_tree", arguments: {} });
  assert.equal(r.isError, true);
  assert.match(text(r), /not connected/);
});

test("forwards commands to the plugin and returns results", async () => {
  const seen = [];
  const plugin = startFakePlugin("edit", {
    ping: () => ({ placeName: "TestPlace", context: "edit" }),
    create: (args) => (seen.push(args), { created: `${args.parent}.${args.name}` }),
    set_properties: () => {
      throw new Error('Workspace has no child "Nope"');
    },
  });
  // wait for the first poll to register
  for (let i = 0; i < 50 && !bridge.isConnected("edit"); i++) await new Promise((r) => setTimeout(r, 10));

  const status = await client.callTool({ name: "studio_status", arguments: {} });
  assert.match(text(status), /TestPlace/);

  const created = await client.callTool({
    name: "create_instance",
    arguments: { className: "Part", parent: "Workspace", name: "Floor", properties: { Size: [10, 1, 10] } },
  });
  assert.equal(created.isError, undefined);
  assert.match(text(created), /Workspace\.Floor/);
  assert.deepEqual(seen[0].properties.Size, [10, 1, 10]);
  assert.equal(seen[0].context, undefined, "context must not be forwarded as an argument");

  const failed = await client.callTool({ name: "set_properties", arguments: { path: "Workspace.Nope", properties: {} } });
  assert.equal(failed.isError, true);
  assert.match(text(failed), /no child "Nope"/);

  // commands for a context without a poller fail fast
  const server = await client.callTool({ name: "get_output", arguments: { context: "server" } });
  assert.equal(server.isError, true);
  assert.match(text(server), /context "server" is not connected/);

  await plugin.stop();
});

test("queued commands run in order", async () => {
  const order = [];
  const plugin = startFakePlugin("edit", { move: (a) => (order.push(a.path), "ok") });
  const calls = ["A", "B", "C"].map((p) => bridge.call("move", { path: p, parent: "Workspace" }));
  await Promise.all(calls);
  assert.deepEqual(order, ["A", "B", "C"]);
  await plugin.stop();
});

test("class info works offline with fallback data", async () => {
  const r = await client.callTool({ name: "get_class_info", arguments: { className: "Part" } });
  assert.match(text(r), /Unknown class|Part/);
  const props = await (await fetch(`${base}/reflection?class=Part`)).json();
  assert.ok(props.properties.some((p) => p.name === "Anchored"));
});
