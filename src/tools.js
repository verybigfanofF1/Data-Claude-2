// MCP tool definitions. Most tools forward to the Studio plugin through the bridge;
// get_class_info / search_classes / get_enum are answered locally from the API dump.

import { z } from "zod";

export const INSTRUCTIONS = `
You are connected to a live Roblox Studio session through the Claude Bridge plugin.
Everything you change happens immediately in the open place and is undoable (Ctrl+Z / the undo tool).

WORKFLOW
1. Call studio_status first. Then get_tree to understand the place before changing it.
2. Use get_class_info whenever unsure about a class's properties, methods, events or enum values.
3. Prefer batch for multi-step builds (one undo step, one round-trip).
4. After writing scripts, playtest (action "play" or "run"), then read get_output to check for errors,
   and stop the test (playtest action "stop").

PATHS
Instances are addressed by dotted paths from the DataModel, exactly like Instance:GetFullName():
"Workspace.Map.Door", "ServerScriptService.GameManager", "StarterGui.HUD.Frame.Label".
A leading "game." is optional. If a name contains a dot, pass the path as an array of names instead.

VALUE FORMATS (property values are converted using the property's real type)
- Vector3: [x, y, z]            Vector2: [x, y]
- Color3: "#ff8800" or [r, g, b] (0-1, or 0-255 if any component > 1)
- CFrame: [x, y, z] (position only), {"position":[x,y,z], "rotation":[rx,ry,rz]} (degrees),
          {"position":[...], "lookAt":[...]}, or 12 numbers [x,y,z,r00,r01,r02,r10,r11,r12,r20,r21,r22]
- UDim2: [xScale, xOffset, yScale, yOffset]      UDim: [scale, offset]
- Enum: item name, e.g. "Neon", or "Enum.Material.Neon"
- BrickColor: name, e.g. "Bright red"
- Instance reference (e.g. PrimaryPart, Part0): path string, e.g. "Workspace.Car.Body"
- NumberRange: [min, max]   NumberSequence: [[time, value], ...] or single number
- ColorSequence: [[time, color], ...] or single color   Rect: [minX, minY, maxX, maxY]
- Font (TextLabel.FontFace): {"family":"rbxasset://fonts/families/GothamSSm.json","weight":"Bold","style":"Normal"}
- Special keys in properties: "$attributes": {name: value} sets attributes, "$tags": [..] sets CollectionService tags
  (exact set), "$addTags": [..] adds tags, "$pivot": CFrame moves a Model/part via PivotTo, "$scale": number scales a Model.
- Explicit typing (e.g. for attributes): {"$type": "Vector3", "value": [1,2,3]}, {"$type": "Enum", "enum": "Material", "value": "Neon"}.

ROBLOX CONVENTIONS
- Server logic: Script in ServerScriptService. Client logic: LocalScript in StarterPlayer.StarterPlayerScripts
  or StarterGui / StarterCharacterScripts. Shared code: ModuleScript in ReplicatedStorage.
- Client/server communication: RemoteEvent / RemoteFunction in ReplicatedStorage. Never trust the client.
- Persistent data: DataStoreService (requires "Enable Studio Access to API Services" to test in Studio).
- Write modern Luau: task.wait/task.spawn (not wait/spawn), game:GetService(...), typed Luau where helpful.
- Anchor static map parts. Group builds into Models and set PrimaryPart.
`.trim();

const contextArg = z
  .enum(["edit", "server", "client"])
  .optional()
  .describe('Studio DataModel to target. "edit" (default) = the place being edited; "server"/"client" = running playtest.');
const pathArg = z.union([z.string(), z.array(z.string())]).describe('Instance path, e.g. "Workspace.Map.Door"');
const propsArg = z.record(z.string(), z.any()).describe("Property name -> value (see value formats in server instructions)");

const OPERATION_NAMES = [
  "get_tree", "find", "get_properties", "set_properties", "create", "delete", "clone", "move",
  "read_script", "write_script", "edit_script", "run_luau", "get_selection", "set_selection",
  "insert_asset", "terrain",
];

/**
 * Tool table: name -> {description, schema, op (plugin op) | local (handler), timeoutMs?, context?}
 */
export function buildTools(reflection) {
  return {
    studio_status: {
      description: "Check whether Roblox Studio is connected and get info about the open place (name, ids, mode, connected contexts).",
      schema: {},
      local: async (_args, bridge) => {
        const contexts = bridge.connectedContexts();
        const status = { bridgePort: bridge.port, connectedContexts: contexts, apiReflection: reflection.source };
        if (bridge.listenError) status.bridgeError = bridge.listenError.message;
        const target = "edit" in contexts ? "edit" : Object.keys(contexts)[0];
        if (target) status.place = await bridge.call("ping", {}, { context: target, timeoutMs: 10_000 });
        else
          status.hint =
            "Studio is not connected. In Studio: Plugins tab -> Claude -> Connect, and allow HTTP access to localhost.";
        return status;
      },
    },

    get_tree: {
      description: "Get the instance hierarchy under a path (default: the main services). Returns names, classes, paths and child counts.",
      schema: {
        path: pathArg.optional(),
        depth: z.number().int().min(0).max(10).optional().describe("How many levels deep (default 2)"),
        maxChildren: z.number().int().min(1).max(2000).optional().describe("Max children listed per instance (default 100)"),
        context: contextArg,
      },
      op: "get_tree",
    },

    find_instances: {
      description: "Search descendants by name (case-insensitive substring or Lua pattern), class (IsA), tag or attribute.",
      schema: {
        root: pathArg.optional().describe("Where to search (default: whole game)"),
        name: z.string().optional(),
        className: z.string().optional().describe("Matches with IsA, so 'BasePart' finds Parts, MeshParts, ..."),
        tag: z.string().optional(),
        attribute: z.string().optional().describe("Only instances having this attribute"),
        limit: z.number().int().min(1).max(5000).optional().describe("Default 200"),
        context: contextArg,
      },
      op: "find",
    },

    get_properties: {
      description: "Read all (or selected) properties, attributes and tags of an instance.",
      schema: {
        path: pathArg,
        properties: z.array(z.string()).optional().describe("Only these properties (default: all readable)"),
        context: contextArg,
      },
      op: "get_properties",
    },

    set_properties: {
      description: "Set properties (plus $attributes / $tags) on one or more instances.",
      schema: {
        path: pathArg.optional(),
        paths: z.array(pathArg).optional().describe("Apply the same properties to several instances"),
        properties: propsArg,
        context: contextArg,
      },
      op: "set_properties",
    },

    create_instance: {
      description: "Create a new instance (Part, Model, Script, ScreenGui, RemoteEvent, ...). For scripts pass `source`.",
      schema: {
        className: z.string(),
        parent: pathArg.describe('Parent path, e.g. "Workspace" or "ServerScriptService"'),
        name: z.string().optional(),
        properties: propsArg.optional(),
        source: z.string().optional().describe("Luau source for Script / LocalScript / ModuleScript"),
        context: contextArg,
      },
      op: "create",
    },

    delete_instances: {
      description: "Delete instances (undoable).",
      schema: { paths: z.array(pathArg).min(1), context: contextArg },
      op: "delete",
    },

    clone_instance: {
      description: "Duplicate an instance (with descendants), optionally into a new parent / with a new name / new properties.",
      schema: {
        path: pathArg,
        parent: pathArg.optional().describe("Default: same parent"),
        name: z.string().optional(),
        properties: propsArg.optional(),
        count: z.number().int().min(1).max(500).optional().describe("Number of copies (default 1)"),
        context: contextArg,
      },
      op: "clone",
    },

    move_instance: {
      description: "Re-parent an instance.",
      schema: { path: pathArg, parent: pathArg, context: contextArg },
      op: "move",
    },

    read_script: {
      description: "Read the source of a Script/LocalScript/ModuleScript (with line numbers).",
      schema: {
        path: pathArg,
        startLine: z.number().int().min(1).optional(),
        endLine: z.number().int().min(1).optional(),
        context: contextArg,
      },
      op: "read_script",
    },

    write_script: {
      description: "Replace the entire source of a script. Creates the script if it doesn't exist and `className` is given.",
      schema: {
        path: pathArg,
        source: z.string(),
        className: z.enum(["Script", "LocalScript", "ModuleScript"]).optional().describe("Create the script with this class if missing"),
        context: contextArg,
      },
      op: "write_script",
    },

    edit_script: {
      description: "Edit part of a script: replace an exact snippet `oldText` with `newText`. oldText must match exactly once unless replaceAll.",
      schema: {
        path: pathArg,
        oldText: z.string(),
        newText: z.string(),
        replaceAll: z.boolean().optional(),
        context: contextArg,
      },
      op: "edit_script",
    },

    run_luau: {
      description:
        "Execute arbitrary Luau inside Studio with plugin permissions (full access to game, services, `plugin`). " +
        "print()/warn() output and returned values are sent back. Changes are recorded as one undo step. " +
        "Use for anything the other tools don't cover (procedural building, bulk edits, queries, terrain, lighting...).",
      schema: {
        code: z.string(),
        timeoutSeconds: z.number().min(1).max(600).optional().describe("Default 60"),
        context: contextArg,
      },
      op: "run_luau",
      timeoutFromArgs: true,
    },

    get_selection: {
      description: "Get the instances currently selected in Studio's Explorer.",
      schema: { context: contextArg },
      op: "get_selection",
    },

    set_selection: {
      description: "Select instances in Studio's Explorer (shows the user what you're working on).",
      schema: { paths: z.array(pathArg), context: contextArg },
      op: "set_selection",
    },

    get_output: {
      description: "Read Studio's Output window (prints, warnings, errors from scripts). Use after a playtest to find bugs.",
      schema: {
        sinceSeq: z.number().int().optional().describe("Only messages after this sequence number"),
        limit: z.number().int().min(1).max(1000).optional().describe("Default 100 (most recent)"),
        types: z.array(z.enum(["output", "info", "warning", "error"])).optional(),
        clear: z.boolean().optional().describe("Clear the captured buffer after reading"),
        context: contextArg,
      },
      op: "get_output",
    },

    playtest: {
      description:
        'Control playtesting. "play" = Play with a character (F5), "run" = simulate without a player (F8), "stop" = end the test. ' +
        'While a test runs, target context "server" or "client" in other tools to inspect the live game.',
      schema: { action: z.enum(["play", "run", "stop"]) },
      local: async ({ action }, bridge) => {
        if (action === "stop") {
          const ctxs = bridge.connectedContexts();
          const target = "server" in ctxs ? "server" : "edit";
          return bridge.call("playtest", { action }, { context: target, timeoutMs: 20_000 });
        }
        return bridge.call("playtest", { action }, { context: "edit", timeoutMs: 20_000 });
      },
    },

    insert_asset: {
      description: "Insert a Roblox library asset (model, mesh, decal...) by asset id. Only assets you own or free/public ones work.",
      schema: {
        assetId: z.number().int(),
        parent: pathArg.optional().describe('Default "Workspace"'),
        position: z.array(z.number()).length(3).optional().describe("Pivot the inserted model to this position"),
        context: contextArg,
      },
      op: "insert_asset",
    },

    terrain: {
      description: "Edit Terrain: fill a block/ball/cylinder/wedge with a material, or clear terrain.",
      schema: {
        action: z.enum(["fill_block", "fill_ball", "fill_cylinder", "fill_wedge", "clear"]),
        position: z.array(z.number()).length(3).optional(),
        size: z.array(z.number()).length(3).optional().describe("Block/cylinder/wedge size [x,y,z] (cylinder: [radius*2, height, radius*2])"),
        radius: z.number().optional().describe("Ball radius"),
        rotation: z.array(z.number()).length(3).optional().describe("Degrees"),
        material: z.string().optional().describe('Enum.Material name, e.g. "Grass", "Water", "Rock", "Sand", "Air" (erase)'),
      },
      op: "terrain",
    },

    batch: {
      description:
        "Run several operations in order as ONE undo step and one round-trip. Each operation is {op, args} where op is one of: " +
        OPERATION_NAMES.join(", ") +
        " (args are the same as the matching tool; create = create_instance, find = find_instances, delete = delete_instances, " +
        "clone = clone_instance, move = move_instance). Stops at the first error unless continueOnError.",
      schema: {
        operations: z.array(z.object({ op: z.enum(OPERATION_NAMES), args: z.record(z.string(), z.any()) })).min(1),
        continueOnError: z.boolean().optional(),
        context: contextArg,
      },
      op: "batch",
      timeoutMs: 180_000,
    },

    undo: {
      description: "Undo the last change in Studio (same as Ctrl+Z).",
      schema: { steps: z.number().int().min(1).max(50).optional() },
      op: "undo",
    },

    redo: {
      description: "Redo the last undone change in Studio.",
      schema: { steps: z.number().int().min(1).max(50).optional() },
      op: "redo",
    },

    get_class_info: {
      description: "Look up a Roblox class in the API reference: properties (with types, defaults, enum values), methods, events, superclasses.",
      schema: {
        className: z.string(),
        includeInherited: z.boolean().optional().describe("Include members from superclasses (default true)"),
      },
      local: async ({ className, includeInherited = true }) => reflection.classInfo(className, { includeInherited }),
    },

    search_classes: {
      description: "Find Roblox class names containing a substring (e.g. 'Constraint', 'Gui', 'Light').",
      schema: { query: z.string() },
      local: async ({ query }) => reflection.searchClasses(query),
    },

    get_enum: {
      description: "List the items of a Roblox Enum (e.g. Material, PartType, EasingStyle, KeyCode).",
      schema: { name: z.string() },
      local: async ({ name }) => {
        const items = await reflection.enumItems(name.replace(/^Enum\./, ""));
        return items ? { enum: name, items } : { error: `Unknown enum "${name}"` };
      },
    },
  };
}

/** Register every tool on an McpServer. */
export function registerTools(server, bridge, reflection) {
  const tools = buildTools(reflection);
  for (const [name, def] of Object.entries(tools)) {
    server.registerTool(name, { description: def.description, inputSchema: def.schema }, async (args = {}) => {
      try {
        let result;
        if (def.local) {
          result = await def.local(args, bridge);
        } else {
          const { context = "edit", ...rest } = args;
          let timeoutMs = def.timeoutMs ?? 60_000;
          if (def.timeoutFromArgs && rest.timeoutSeconds) timeoutMs = rest.timeoutSeconds * 1000 + 5_000;
          result = await bridge.call(def.op, rest, { context, timeoutMs });
        }
        return { content: [{ type: "text", text: formatResult(result) }] };
      } catch (err) {
        return { isError: true, content: [{ type: "text", text: `Error: ${err.message}` }] };
      }
    });
  }
  return tools;
}

function formatResult(result) {
  if (result === undefined || result === null) return "OK";
  if (typeof result === "string") return result;
  return JSON.stringify(result, null, 2);
}
