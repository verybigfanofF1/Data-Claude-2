// Roblox API reflection, built from the community-maintained API dump.
// Gives Claude (get_class_info) and the Studio plugin (property lists + value types)
// an accurate picture of every class, property, method, event and enum.

import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";

const DUMP_URL =
  process.env.ROBLOX_API_DUMP_URL ||
  "https://raw.githubusercontent.com/MaximumADHD/Roblox-Client-Tracker/roblox/Mini-API-Dump.json";
const CACHE_DIR = process.env.ROBLOX_BRIDGE_CACHE || path.join(os.homedir(), ".cache", "roblox-claude-bridge");
const CACHE_FILE = path.join(CACHE_DIR, "api-dump.json");
const CACHE_MAX_AGE_MS = 7 * 24 * 3600 * 1000;
const PLUGIN_READABLE = new Set(["None", "PluginSecurity"]);
const HIDDEN_TAGS = ["Hidden", "NotScriptable", "Deprecated", "WriteOnly"];

// Used when the API dump cannot be downloaded: enough to work with common classes.
const FALLBACK_PROPERTIES = [
  ["Name", "string"], ["ClassName", "string"], ["Parent", "Instance", "Class"], ["Archivable", "bool"],
  ["Anchored", "bool"], ["CanCollide", "bool"], ["CanTouch", "bool"], ["CanQuery", "bool"], ["CastShadow", "bool"],
  ["Position", "Vector3"], ["Orientation", "Vector3"], ["Size", "Vector3"], ["CFrame", "CFrame"],
  ["Color", "Color3"], ["BrickColor", "BrickColor"], ["Material", "Material", "Enum"],
  ["Transparency", "float"], ["Reflectance", "float"], ["Shape", "PartType", "Enum"], ["Massless", "bool"],
  ["PrimaryPart", "BasePart", "Class"], ["WorldPivot", "CFrame"],
  ["Disabled", "bool"], ["Enabled", "bool"], ["RunContext", "RunContext", "Enum"],
  ["Value", "string"], ["Text", "string"], ["TextColor3", "Color3"], ["TextSize", "float"], ["TextScaled", "bool"],
  ["Font", "Font", "Enum"], ["BackgroundColor3", "Color3"], ["BackgroundTransparency", "float"],
  ["Size", "UDim2"], ["Position", "UDim2"], ["AnchorPoint", "Vector2"], ["Visible", "bool"], ["ZIndex", "int"],
  ["Image", "Content"], ["Brightness", "float"], ["Range", "float"], ["MaxHealth", "float"], ["Health", "float"],
  ["WalkSpeed", "float"], ["JumpPower", "float"], ["SoundId", "Content"], ["Volume", "float"], ["Looped", "bool"],
  ["Playing", "bool"], ["Texture", "Content"], ["MeshId", "Content"], ["TextureID", "Content"],
  ["ClockTime", "float"], ["Ambient", "Color3"], ["OutdoorAmbient", "Color3"], ["FogEnd", "float"],
  ["FogColor", "Color3"], ["Gravity", "float"],
].map(([name, type, category = "DataType"]) => ({ name, type, category: categoryFor(type, category) }));

function categoryFor(type, category) {
  if (["string", "bool", "float", "double", "int", "int64"].includes(type)) return "Primitive";
  return category;
}

export class Reflection {
  constructor({ log = () => {} } = {}) {
    this.log = log;
    this.classes = null; // name -> class
    this.enums = null; // name -> [item names]
    this.loading = null;
    this.source = "loading";
  }

  /** Lazily load the dump (cache -> network -> fallback). Never throws. */
  load() {
    if (!this.loading) this.loading = this.#load();
    return this.loading;
  }

  async #load() {
    let dump = null;
    try {
      const stat = await fs.stat(CACHE_FILE);
      if (Date.now() - stat.mtimeMs < CACHE_MAX_AGE_MS) {
        dump = JSON.parse(await fs.readFile(CACHE_FILE, "utf8"));
        this.source = "cache";
      }
    } catch {}
    if (!dump && process.env.ROBLOX_BRIDGE_OFFLINE !== "1") {
      try {
        const res = await fetch(DUMP_URL, { signal: AbortSignal.timeout(20_000) });
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const text = await res.text();
        dump = JSON.parse(text);
        this.source = "network";
        await fs.mkdir(CACHE_DIR, { recursive: true }).catch(() => {});
        await fs.writeFile(CACHE_FILE, text).catch(() => {});
      } catch (err) {
        this.log(`reflection: could not download API dump (${err.message}); using built-in fallback`);
      }
    }
    if (!dump) {
      // A stale cache is better than nothing.
      try {
        dump = JSON.parse(await fs.readFile(CACHE_FILE, "utf8"));
        this.source = "stale-cache";
      } catch {}
    }
    this.classes = new Map();
    this.enums = new Map();
    if (dump) {
      for (const c of dump.Classes) this.classes.set(c.Name, c);
      for (const e of dump.Enums || []) this.enums.set(e.Name, e.Items.map((i) => i.Name));
    } else {
      this.source = "fallback";
    }
  }

  #chain(className) {
    const chain = [];
    let c = this.classes.get(className);
    while (c) {
      chain.push(c);
      c = c.Superclass && c.Superclass !== "<<<ROOT>>>" ? this.classes.get(c.Superclass) : null;
    }
    return chain;
  }

  /** Properties a plugin can read, including inherited ones: [{name, type, category, readOnly}] */
  async propertiesFor(className) {
    await this.load();
    const chain = this.#chain(className);
    if (chain.length === 0) return FALLBACK_PROPERTIES;
    const seen = new Set();
    const out = [];
    for (const c of chain) {
      for (const m of c.Members) {
        if (m.MemberType !== "Property" || seen.has(m.Name)) continue;
        const tags = m.Tags || [];
        if (tags.some((t) => HIDDEN_TAGS.includes(t))) continue;
        if (!PLUGIN_READABLE.has(m.Security?.Read ?? "None")) continue;
        seen.add(m.Name);
        out.push({
          name: m.Name,
          type: m.ValueType?.Name,
          category: m.ValueType?.Category,
          readOnly: tags.includes("ReadOnly") || !PLUGIN_READABLE.has(m.Security?.Write ?? "None"),
        });
      }
    }
    return out;
  }

  /** Human/LLM friendly description of a class. */
  async classInfo(className, { includeInherited = true } = {}) {
    await this.load();
    const chain = this.#chain(className);
    if (chain.length === 0) {
      const lower = className.toLowerCase();
      const suggestions = [...this.classes.keys()].filter((n) => n.toLowerCase().includes(lower)).slice(0, 15);
      return { error: `Unknown class "${className}"`, suggestions, source: this.source };
    }
    const cls = chain[0];
    const members = (includeInherited ? chain : [cls]).flatMap((c) =>
      c.Members.filter((m) => !(m.Tags || []).some((t) => ["Hidden", "NotScriptable", "Deprecated"].includes(t)))
        .filter((m) => PLUGIN_READABLE.has(typeof m.Security === "string" ? m.Security : m.Security?.Read ?? "None"))
        .map((m) => ({ ...m, from: c.Name }))
    );
    const fmtParams = (ps = []) => ps.map((p) => `${p.Name}: ${p.Type?.Name}`).join(", ");
    const tags = cls.Tags || [];
    return {
      className: cls.Name,
      superclasses: chain.slice(1).map((c) => c.Name),
      creatable: !tags.includes("NotCreatable"),
      service: tags.includes("Service"),
      properties: members
        .filter((m) => m.MemberType === "Property")
        .map((m) => {
          const type = m.ValueType?.Name;
          const p = { name: m.Name, type, from: m.from };
          if ((m.Tags || []).includes("ReadOnly")) p.readOnly = true;
          if (m.ValueType?.Category === "Enum") p.enumItems = this.enums.get(type);
          if (m.Default && !m.Default.startsWith("__api_dump")) p.default = m.Default;
          return p;
        }),
      methods: members
        .filter((m) => m.MemberType === "Function")
        .map((m) => `${m.Name}(${fmtParams(m.Parameters)}) -> ${!m.ReturnType?.Name || m.ReturnType.Name === "null" ? "void" : m.ReturnType.Name}${m.from !== cls.Name ? `  [${m.from}]` : ""}`),
      events: members
        .filter((m) => m.MemberType === "Event")
        .map((m) => `${m.Name}(${fmtParams(m.Parameters)})${m.from !== cls.Name ? `  [${m.from}]` : ""}`),
      callbacks: members.filter((m) => m.MemberType === "Callback").map((m) => `${m.Name}(${fmtParams(m.Parameters)})`),
      source: this.source,
    };
  }

  async enumItems(enumName) {
    await this.load();
    return this.enums.get(enumName) || null;
  }

  async searchClasses(query, limit = 40) {
    await this.load();
    const q = query.toLowerCase();
    return [...this.classes.values()]
      .filter((c) => c.Name.toLowerCase().includes(q))
      .slice(0, limit)
      .map((c) => ({ name: c.Name, superclass: c.Superclass, creatable: !(c.Tags || []).includes("NotCreatable") }));
  }
}
