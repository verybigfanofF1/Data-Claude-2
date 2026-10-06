// HTTP bridge between the MCP server (Claude side) and the Roblox Studio plugin.
//
// Studio plugins cannot accept incoming connections, so the plugin long-polls:
//   POST /poll    {context, info}        -> {commands: [{id, op, args}]}  (held open until work arrives)
//   POST /result  {results: [{id, ok, data, error}]}
//   GET  /reflection?class=Part          -> property metadata used by the plugin to (de)serialize values
//   GET  /health                         -> bridge + connection status
//
// Each Studio DataModel the plugin runs in ("edit", "server", "client" during playtests)
// polls with its own context, and commands are routed to the matching queue.

import http from "node:http";
import { randomUUID } from "node:crypto";

const POLL_HOLD_MS = 15_000;
const CONTEXT_STALE_MS = 35_000;
const MAX_BODY_BYTES = 20 * 1024 * 1024;

export class StudioBridge {
  constructor({ port = 44755, host = "127.0.0.1", reflection = null, log = () => {} } = {}) {
    this.port = port;
    this.host = host;
    this.reflection = reflection;
    this.log = log;
    this.queues = new Map(); // context -> [command]
    this.waiters = new Map(); // context -> {res, timer}
    this.pending = new Map(); // id -> {resolve, reject, timer, op}
    this.contexts = new Map(); // context -> {lastSeen, info}
    this.server = null;
    this.listenError = null;
  }

  start() {
    this.server = http.createServer((req, res) => this.#handle(req, res));
    return new Promise((resolve) => {
      this.server.once("error", (err) => {
        this.listenError = err;
        this.log(`bridge: cannot listen on ${this.host}:${this.port}: ${err.message}`);
        resolve(false);
      });
      this.server.listen(this.port, this.host, () => {
        this.port = this.server.address().port;
        this.log(`bridge: listening on http://${this.host}:${this.port}`);
        resolve(true);
      });
    });
  }

  async stop() {
    for (const { res, timer } of this.waiters.values()) {
      clearTimeout(timer);
      this.#json(res, 200, { commands: [] });
    }
    this.waiters.clear();
    for (const [id, p] of this.pending) {
      clearTimeout(p.timer);
      p.reject(new Error("Bridge stopped"));
      this.pending.delete(id);
    }
    if (this.server) await new Promise((r) => this.server.close(() => r()));
  }

  connectedContexts() {
    const now = Date.now();
    const out = {};
    for (const [ctx, { lastSeen, info }] of this.contexts) {
      if (now - lastSeen < CONTEXT_STALE_MS || this.waiters.has(ctx)) out[ctx] = info;
    }
    return out;
  }

  isConnected(context = "edit") {
    return context in this.connectedContexts();
  }

  /** Send a command to the plugin and wait for its result. */
  call(op, args = {}, { context = "edit", timeoutMs = 60_000 } = {}) {
    if (this.listenError) {
      return Promise.reject(
        new Error(
          `Bridge is not running (${this.listenError.message}). ` +
            `Is another instance using port ${this.port}? Set ROBLOX_BRIDGE_PORT to change it.`
        )
      );
    }
    if (!this.isConnected(context)) {
      const ctxs = Object.keys(this.connectedContexts());
      return Promise.reject(
        new Error(
          ctxs.length
            ? `Studio context "${context}" is not connected (connected: ${ctxs.join(", ")}). ` +
                `"server"/"client" exist only during a playtest; "edit" only outside of one.`
            : "Roblox Studio is not connected. Open Studio, enable the Claude Bridge plugin " +
                "(Plugins tab -> Claude -> Connect) and allow HTTP requests to localhost when prompted."
        )
      );
    }
    const id = randomUUID();
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        this.#removeQueued(context, id);
        reject(new Error(`Studio did not answer "${op}" within ${Math.round(timeoutMs / 1000)}s`));
      }, timeoutMs);
      this.pending.set(id, { resolve, reject, timer, op });
      this.#enqueue(context, { id, op, args });
    });
  }

  #enqueue(context, cmd) {
    if (!this.queues.has(context)) this.queues.set(context, []);
    this.queues.get(context).push(cmd);
    this.#flush(context);
  }

  #removeQueued(context, id) {
    const q = this.queues.get(context);
    if (q) this.queues.set(context, q.filter((c) => c.id !== id));
  }

  #flush(context) {
    const waiter = this.waiters.get(context);
    const q = this.queues.get(context);
    if (!waiter || !q || q.length === 0) return;
    this.waiters.delete(context);
    clearTimeout(waiter.timer);
    this.queues.set(context, []);
    this.#json(waiter.res, 200, { commands: q });
  }

  async #handle(req, res) {
    try {
      const url = new URL(req.url, `http://${req.headers.host || "localhost"}`);
      if (req.method === "GET" && url.pathname === "/health") {
        return this.#json(res, 200, { ok: true, contexts: this.connectedContexts() });
      }
      if (req.method === "GET" && url.pathname === "/reflection") {
        const cls = url.searchParams.get("class");
        if (!cls || !this.reflection) return this.#json(res, 404, { error: "no reflection" });
        const props = await this.reflection.propertiesFor(cls);
        return this.#json(res, 200, { className: cls, properties: props });
      }
      if (req.method === "POST" && url.pathname === "/poll") {
        const body = await readJson(req);
        const context = String(body.context || "edit");
        this.contexts.set(context, { lastSeen: Date.now(), info: body.info || {} });
        // A newer poll from the same context replaces the old one.
        const old = this.waiters.get(context);
        if (old) {
          clearTimeout(old.timer);
          this.#json(old.res, 200, { commands: [] });
        }
        const timer = setTimeout(() => {
          if (this.waiters.get(context)?.res === res) {
            this.waiters.delete(context);
            this.contexts.set(context, { lastSeen: Date.now(), info: body.info || {} });
            this.#json(res, 200, { commands: [] });
          }
        }, POLL_HOLD_MS);
        this.waiters.set(context, { res, timer });
        req.on("close", () => {
          if (!res.writableEnded && this.waiters.get(context)?.res === res) {
            clearTimeout(timer);
            this.waiters.delete(context);
          }
        });
        return this.#flush(context);
      }
      if (req.method === "POST" && url.pathname === "/result") {
        const body = await readJson(req);
        for (const r of body.results || []) {
          const p = this.pending.get(r.id);
          if (!p) continue;
          this.pending.delete(r.id);
          clearTimeout(p.timer);
          if (r.ok) p.resolve(r.data);
          else p.reject(new Error(r.error || `"${p.op}" failed in Studio`));
        }
        return this.#json(res, 200, { ok: true });
      }
      this.#json(res, 404, { error: "not found" });
    } catch (err) {
      this.log(`bridge: request error: ${err.message}`);
      if (!res.headersSent) this.#json(res, 400, { error: err.message });
    }
  }

  #json(res, status, obj) {
    if (res.writableEnded) return;
    const body = JSON.stringify(obj);
    res.writeHead(status, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body) });
    res.end(body);
  }
}

function readJson(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on("data", (c) => {
      size += c.length;
      if (size > MAX_BODY_BYTES) {
        reject(new Error("body too large"));
        req.destroy();
      } else chunks.push(c);
    });
    req.on("end", () => {
      const text = Buffer.concat(chunks).toString("utf8");
      if (!text) return resolve({});
      try {
        resolve(JSON.parse(text));
      } catch {
        reject(new Error("invalid JSON"));
      }
    });
    req.on("error", reject);
  });
}
