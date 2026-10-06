#!/usr/bin/env node
// Roblox Claude Bridge - MCP server entry point.
// Claude talks MCP over stdio; the Roblox Studio plugin talks HTTP to the bridge on localhost.
// NOTE: stdout belongs to the MCP protocol, so all logging goes to stderr.

import { realpathSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { StudioBridge } from "./bridge.js";
import { Reflection } from "./reflection.js";
import { INSTRUCTIONS, registerTools } from "./tools.js";

export const VERSION = "1.0.0";

export function createServer({ bridge, reflection }) {
  const server = new McpServer({ name: "roblox-studio", version: VERSION }, { instructions: INSTRUCTIONS });
  registerTools(server, bridge, reflection);
  return server;
}

async function main() {
  const log = (msg) => process.stderr.write(`[roblox-claude-bridge] ${msg}\n`);
  const port = Number(process.env.ROBLOX_BRIDGE_PORT || 44755);
  const reflection = new Reflection({ log });
  const bridge = new StudioBridge({ port, reflection, log });

  // Exit as soon as the client goes away - even mid-startup. Otherwise an orphaned
  // instance keeps the bridge port and the next one cannot talk to Studio.
  let stopping = false;
  const shutdown = async (reason) => {
    if (stopping) return;
    stopping = true;
    log(`shutting down (${reason})`);
    await bridge.stop().catch(() => {});
    process.exit(0);
  };
  process.on("SIGINT", () => shutdown("SIGINT"));
  process.on("SIGTERM", () => shutdown("SIGTERM"));
  process.on("SIGHUP", () => shutdown("SIGHUP"));
  process.stdin.on("end", () => shutdown("stdin closed"));
  process.stdin.on("close", () => shutdown("stdin closed"));
  const parentPid = process.ppid;
  setInterval(() => {
    // The parent died without closing our stdin: we were re-parented.
    if (process.ppid !== parentPid) shutdown("parent process exited");
  }, 2000).unref();

  // Connect MCP first (it starts reading stdin, so the handlers above fire), then the bridge.
  const server = createServer({ bridge, reflection });
  const transport = new StdioServerTransport();
  transport.onclose = () => shutdown("transport closed");
  await server.connect(transport);
  await bridge.start();
  reflection.load(); // warm up in the background
  log(`MCP server ready (v${VERSION})`);
}

function isMainModule() {
  try {
    return import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href;
  } catch {
    return false;
  }
}

if (isMainModule()) {
  main().catch((err) => {
    process.stderr.write(`[roblox-claude-bridge] fatal: ${err.stack || err}\n`);
    process.exit(1);
  });
}
