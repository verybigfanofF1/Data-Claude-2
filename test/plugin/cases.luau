--!nocheck
-- Appended to the plugin source by the runner, so plugin locals (execute, handlers, ...) are in scope.

local passed, failed = 0, 0
local nextId = 0

local function run(op, args)
	nextId += 1
	return execute({ id = tostring(nextId), op = op, args = args or {} })
end

local function check(name, fn)
	local ok, err = pcall(fn)
	if ok then
		passed += 1
		print("ok   - " .. name)
	else
		failed += 1
		print("FAIL - " .. name .. ": " .. tostring(err))
	end
end

local function expectOk(result)
	if not result.ok then
		error("expected ok, got error: " .. tostring(result.error), 2)
	end
	return result.data
end

local function expectError(result, pattern)
	if result.ok then
		error("expected an error", 2)
	end
	if pattern and not string.find(result.error, pattern) then
		error("error " .. string.format("%q", result.error) .. " does not match " .. pattern, 2)
	end
end

local function eq(a, b, msg)
	if a ~= b then
		error((msg or "values differ") .. ": " .. tostring(a) .. " ~= " .. tostring(b), 2)
	end
end

check("ping returns place info", function()
	local data = expectOk(run("ping"))
	eq(data.placeName, "MockPlace")
	eq(data.context, "edit")
	eq(data.camera.position[2], 10)
end)

check("create Part with typed properties", function()
	local data = expectOk(run("create", {
		className = "Part",
		parent = "Workspace",
		name = "Floor",
		properties = { Size = { 10, 1, 20 }, Color = "#ff8800", Material = "Neon", Anchored = true },
	}))
	eq(data.created, "Workspace.Floor")
	local floor = workspace:FindFirstChild("Floor")
	eq(floor.Size.X, 10)
	eq(floor.Size.Z, 20)
	eq(floor.Color:ToHex(), "ff8800")
	eq(floor.Material, Enum.Material.Neon)
	eq(floor.Anchored, true)
end)

check("mutations are recorded as one undo step", function()
	local last = __mock.recordings[#__mock.recordings]
	eq(last.name, "Claude: create")
	eq(last.op, Enum.FinishRecordingOperation.Commit)
end)

check("Color3 accepts 0-255 and 0-1 arrays, enum full names, CFrame tables", function()
	expectOk(run("set_properties", {
		path = "game.Workspace.Floor",
		properties = { Color = { 255, 0, 0 }, Material = "Enum.Material.Grass", CFrame = { position = { 1, 2, 3 }, rotation = { 0, 90, 0 } } },
	}))
	local floor = workspace.Floor
	eq(floor.Color:ToHex(), "ff0000")
	eq(floor.Material, Enum.Material.Grass)
	eq(floor.CFrame.Y, 2)
	expectOk(run("set_properties", { path = { "Workspace", "Floor" }, properties = { Color = { 0, 0.5, 1 } } }))
	eq(floor.Color:ToHex(), "0080ff")
end)

check("invalid enum value gives a helpful error and cancels the recording", function()
	expectError(run("set_properties", { path = "Workspace.Floor", properties = { Material = "Lava" } }), "not a valid Material")
	eq(__mock.recordings[#__mock.recordings].op, Enum.FinishRecordingOperation.Cancel)
end)

check("unknown property and unknown path errors", function()
	expectError(run("set_properties", { path = "Workspace.Floor", properties = { Bogus = 1 } }), "no property \"Bogus\"")
	expectError(run("get_properties", { path = "Workspace.Nope" }), "has no child \"Nope\"")
end)

check("attributes and tags", function()
	expectOk(run("set_properties", {
		path = "Workspace.Floor",
		properties = { ["$attributes"] = { Damage = 10, Spawn = { ["$type"] = "Vector3", value = { 1, 2, 3 } } }, ["$tags"] = { "Lava", "Hazard" } },
	}))
	local floor = workspace.Floor
	eq(floor:GetAttribute("Damage"), 10)
	eq(floor:GetAttribute("Spawn").Y, 2)
	local data = expectOk(run("get_properties", { path = "Workspace.Floor" }))
	eq(data.attributes.Damage, 10)
	eq(#data.tags, 2)
	eq(data.properties.Color, "#0080ff")
	eq(data.properties.Size[1], 10)
end)

check("find by class, name and tag", function()
	expectOk(run("create", { className = "Model", parent = "Workspace", name = "Map" }))
	expectOk(run("create", { className = "Part", parent = "Workspace.Map", name = "LavaTile" }))
	local byClass = expectOk(run("find", { className = "BasePart" }))
	assert(string.find(byClass, "Workspace.Floor (Part)", 1, true), byClass)
	assert(string.find(byClass, "Workspace.Map.LavaTile (Part)", 1, true), byClass)
	local byName = expectOk(run("find", { name = "lava" }))
	assert(string.find(byName, "^1 match"), byName)
	local byTag = expectOk(run("find", { tag = "Hazard" }))
	assert(string.find(byTag, "Workspace.Floor", 1, true), byTag)
end)

check("get_tree renders the hierarchy", function()
	local tree = expectOk(run("get_tree", { depth = 2 }))
	assert(string.find(tree, "Workspace (Workspace)", 1, true), tree)
	assert(string.find(tree, "    LavaTile (Part)", 1, true), tree)
	local sub = expectOk(run("get_tree", { path = "Workspace.Map", depth = 0 }))
	assert(string.find(sub, "Map (Model) [1 children]", 1, true), sub)
end)

check("model PrimaryPart reference and $pivot", function()
	expectOk(run("set_properties", { path = "Workspace.Map", properties = { PrimaryPart = "Workspace.Map.LavaTile", ["$pivot"] = { 0, 50, 0 } } }))
	eq(workspace.Map.PrimaryPart, workspace.Map.LavaTile)
	eq(workspace.Map._pivot.Y, 50)
end)

check("clone with count and move", function()
	local data = expectOk(run("clone", { path = "Workspace.Map.LavaTile", name = "Tile", count = 3, properties = { Position = { 5, 0, 0 } } }))
	eq(#data.created, 3)
	eq(data.created[3], "Workspace.Map.Tile3")
	eq(workspace.Map.Tile2.Position.X, 5)
	expectOk(run("move", { path = "Workspace.Map.Tile3", parent = "ReplicatedStorage" }))
	assert(game.ReplicatedStorage:FindFirstChild("Tile3"))
end)

check("delete instances, refuse services", function()
	expectOk(run("delete", { paths = { "ReplicatedStorage.Tile3" } }))
	eq(game.ReplicatedStorage:FindFirstChild("Tile3"), nil)
	expectError(run("delete", { paths = { "Workspace" } }), "Refusing")
end)

check("scripts: create, read, edit, write", function()
	expectOk(run("create", {
		className = "Script",
		parent = "ServerScriptService",
		name = "Main",
		source = "local x = 1\nprint(x)\nprint(x)\n",
	}))
	local text = expectOk(run("read_script", { path = "ServerScriptService.Main" }))
	assert(string.find(text, "1| local x = 1", 1, true), text)
	expectError(run("edit_script", { path = "ServerScriptService.Main", oldText = "print(x)", newText = "warn(x)" }), "appears 2 times")
	local edited = expectOk(run("edit_script", { path = "ServerScriptService.Main", oldText = "print(x)", newText = "warn(x)", replaceAll = true }))
	eq(edited.replacements, 2)
	eq(game.ServerScriptService.Main.Source, "local x = 1\nwarn(x)\nwarn(x)\n")
	-- special characters must be treated literally, not as Lua patterns
	expectOk(run("edit_script", { path = "ServerScriptService.Main", oldText = "local x = 1", newText = "local x = (50%) .. [x]" }))
	assert(string.find(game.ServerScriptService.Main.Source, "(50%) .. [x]", 1, true))
	expectOk(run("write_script", { path = "ReplicatedStorage.Util", className = "ModuleScript", source = "return {}" }))
	eq(game.ReplicatedStorage.Util.ClassName, "ModuleScript")
	expectError(run("read_script", { path = "Workspace.Floor" }), "not a script")
end)

check("run_luau returns values and captures print", function()
	local data = expectOk(run("run_luau", { code = "print('hello', 42)\nreturn workspace.Floor.Size, #workspace:GetChildren()" }))
	eq(data.output[1], "hello 42")
	eq(data.returned[1][1], 10)
	assert(type(data.returned[2]) == "number")
	expectError(run("run_luau", { code = "error('boom')" }), "boom")
	expectError(run("run_luau", { code = "this is not lua" }), "Compile error")
end)

check("batch runs ops in order and stops on error", function()
	local data = expectOk(run("batch", {
		operations = {
			{ op = "create", args = { className = "Folder", parent = "Workspace", name = "Batch" } },
			{ op = "create", args = { className = "Part", parent = "Workspace.Batch", name = "P" } },
		},
	}))
	eq(#data, 2)
	assert(workspace.Batch.P)
	local before = #__mock.recordings
	expectError(run("batch", { operations = { { op = "move", args = { path = "Workspace.Nope", parent = "Workspace" } } } }), "Operation 1")
	eq(#__mock.recordings, before + 1, "nested ops must not open their own recordings")
	local partial = expectOk(run("batch", {
		continueOnError = true,
		operations = { { op = "move", args = { path = "Workspace.Nope", parent = "Workspace" } }, { op = "get_selection", args = {} } },
	}))
	eq(partial[1].ok, false)
	eq(partial[2].ok, true)
end)

check("selection", function()
	expectOk(run("set_selection", { paths = { "Workspace.Floor" } }))
	local sel = expectOk(run("get_selection"))
	eq(sel[1], "Workspace.Floor (Part)")
end)

check("output capture", function()
	__mock.messageOut:Fire("Script error!", Enum.MessageType.MessageError)
	local out = expectOk(run("get_output", { types = { "error" } }))
	assert(string.find(out, "error: Script error!", 1, true), out)
end)

check("terrain fill", function()
	expectOk(run("terrain", { action = "fill_block", position = { 0, -5, 0 }, size = { 100, 10, 100 }, material = "Grass" }))
	local call = __mock.terrainCalls[#__mock.terrainCalls]
	eq(call[1], "FillBlock")
	eq(call[3].X, 100)
	eq(call[4], Enum.Material.Grass)
end)

check("unknown op", function()
	expectError(run("nope"), "Unknown operation")
end)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
	error("plugin tests failed", 0)
end
