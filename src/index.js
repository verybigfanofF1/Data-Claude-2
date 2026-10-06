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
  await bridge.start();
  reflection.load(); // warm up in the background

  const server = createServer({ bridge, reflection });
  await server.connect(new StdioServerTransport());
  log(`MCP server ready (v${VERSION})`);

  const shutdown = async () => {
    await bridge.stop().catch(() => {});
    process.exit(0);
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
  process.stdin.on("close", shutdown);
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
