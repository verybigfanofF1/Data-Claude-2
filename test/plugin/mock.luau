--!nocheck
-- Minimal mock of the Roblox Studio API, enough to load the Claude Bridge plugin
-- in the standalone Luau runtime and exercise its command handlers.
-- Returns an environment table; the runner loads the plugin source into it.

local env = setmetatable({}, { __index = _G })

local function typeOf(v)
	local mt = type(v) == "table" and getmetatable(v)
	if mt and rawget(mt, "__type") then
		return mt.__type
	end
	return type(v)
end
env.typeof = typeOf

local function signal()
	local handlers = {}
	return {
		Connect = function(_, fn)
			table.insert(handlers, fn)
			return { Disconnect = function() end }
		end,
		Fire = function(_, ...)
			for _, fn in ipairs(handlers) do
				fn(...)
			end
		end,
	}
end

-- Vector3 ---------------------------------------------------------------
local Vector3 = {}
local V3mt = { __type = "Vector3" }
V3mt.__index = V3mt
function Vector3.new(x, y, z)
	return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, V3mt)
end
V3mt.__add = function(a, b)
	return Vector3.new(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
end
V3mt.__eq = function(a, b)
	return a.X == b.X and a.Y == b.Y and a.Z == b.Z
end
Vector3.zero = Vector3.new(0, 0, 0)
env.Vector3 = Vector3

local Vector2 = {}
local V2mt = { __type = "Vector2" }
function Vector2.new(x, y)
	return setmetatable({ X = x or 0, Y = y or 0 }, V2mt)
end
env.Vector2 = Vector2

-- CFrame (translation + stored orientation, enough for round-trips) ------
local CFrame = {}
local CFmt = { __type = "CFrame" }
CFmt.__index = function(self, k)
	if k == "Position" then
		return Vector3.new(self.X, self.Y, self.Z)
	elseif k == "LookVector" then
		return Vector3.new(0, 0, -1)
	elseif k == "ToOrientation" then
		return function(s)
			return s._rx, s._ry, s._rz
		end
	end
	return nil
end
local function cf(x, y, z, rx, ry, rz)
	return setmetatable({ X = x, Y = y, Z = z, _rx = rx or 0, _ry = ry or 0, _rz = rz or 0 }, CFmt)
end
function CFrame.new(x, y, z)
	if typeOf(x) == "Vector3" then
		return cf(x.X, x.Y, x.Z)
	end
	return cf(x or 0, y or 0, z or 0)
end
function CFrame.fromOrientation(rx, ry, rz)
	return cf(0, 0, 0, rx, ry, rz)
end
function CFrame.lookAt(pos)
	return cf(pos.X, pos.Y, pos.Z)
end
CFmt.__mul = function(a, b)
	return cf(a.X + b.X, a.Y + b.Y, a.Z + b.Z, a._rx + b._rx, a._ry + b._ry, a._rz + b._rz)
end
env.CFrame = CFrame

-- Color3 -----------------------------------------------------------------
local Color3 = {}
local C3mt = { __type = "Color3" }
C3mt.__index = {
	ToHex = function(self)
		return string.format(
			"%02x%02x%02x",
			math.floor(self.R * 255 + 0.5),
			math.floor(self.G * 255 + 0.5),
			math.floor(self.B * 255 + 0.5)
		)
	end,
}
function Color3.new(r, g, b)
	return setmetatable({ R = r, G = g, B = b }, C3mt)
end
function Color3.fromRGB(r, g, b)
	return Color3.new(r / 255, g / 255, b / 255)
end
function Color3.fromHex(hex)
	return Color3.fromRGB(
		tonumber(string.sub(hex, 1, 2), 16),
		tonumber(string.sub(hex, 3, 4), 16),
		tonumber(string.sub(hex, 5, 6), 16)
	)
end
env.Color3 = Color3

local BrickColor = {}
local BCmt = { __type = "BrickColor" }
function BrickColor.new(v)
	return setmetatable({ Name = tostring(v), Color = Color3.new(0.5, 0.5, 0.5) }, BCmt)
end
env.BrickColor = BrickColor

local UDim2 = {}
local U2mt = { __type = "UDim2" }
function UDim2.new(a, b, c, d)
	return setmetatable({ X = { Scale = a, Offset = b }, Y = { Scale = c, Offset = d } }, U2mt)
end
function UDim2.fromScale(a, b)
	return UDim2.new(a, 0, b, 0)
end
function UDim2.fromOffset(a, b)
	return UDim2.new(0, a, 0, b)
end
env.UDim2 = UDim2

-- Enum -------------------------------------------------------------------
local EnumItemMt = { __type = "EnumItem" }
EnumItemMt.__tostring = function(self)
	return "Enum." .. self._enumName .. "." .. self.Name
end
EnumItemMt.__index = function(self, k)
	if k == "EnumType" then
		return env.Enum[self._enumName]
	end
	return nil
end
local EnumTypeMt = { __type = "Enum" }
EnumTypeMt.__tostring = function(self)
	return self._name
end
EnumTypeMt.__index = function(self, k)
	if k == "GetEnumItems" then
		return function(s)
			return s._items
		end
	end
	local item = setmetatable({ Name = k, Value = #self._items, _enumName = self._name }, EnumItemMt)
	table.insert(self._items, item)
	rawset(self, k, item)
	return item
end
local KNOWN_ENUMS = {
	Material = { "Plastic", "SmoothPlastic", "Neon", "Wood", "Grass", "Water", "Rock", "Sand" },
	PartType = { "Ball", "Block", "Cylinder" },
}
env.Enum = setmetatable({}, {
	__index = function(self, name)
		local enumType = setmetatable({ _name = name, _items = {} }, EnumTypeMt)
		rawset(self, name, enumType)
		for _, itemName in ipairs(KNOWN_ENUMS[name] or {}) do
			local _ = enumType[itemName]
		end
		return enumType
	end,
})

-- Instances --------------------------------------------------------------
local SUPER = {
	Part = "BasePart", SpawnLocation = "Part", MeshPart = "BasePart", BasePart = "PVInstance",
	Model = "PVInstance", Workspace = "Model", PVInstance = "Instance",
	Script = "BaseScript", LocalScript = "Script", BaseScript = "LuaSourceContainer",
	ModuleScript = "LuaSourceContainer", LuaSourceContainer = "Instance",
	StringValue = "ValueBase", IntValue = "ValueBase", ValueBase = "Instance",
}
local DEFAULTS = {
	BasePart = function()
		return {
			Anchored = false,
			Size = Vector3.new(4, 1, 2),
			Position = Vector3.new(0, 0, 0),
			CFrame = CFrame.new(0, 0, 0),
			Color = Color3.new(0.6, 0.6, 0.6),
			Material = env.Enum.Material.Plastic,
			Transparency = 0,
		}
	end,
	Model = function()
		return { PrimaryPart = false }
	end,
	LuaSourceContainer = function()
		return { Source = "" }
	end,
	BaseScript = function()
		return { Disabled = false }
	end,
	ValueBase = function()
		return { Value = "" }
	end,
}
local NOT_CREATABLE = { BasePart = true, Instance = true, PVInstance = true, LuaSourceContainer = true }

local InstanceMt = { __type = "Instance" }
local methods = {}

local function isA(className, target)
	local c = className
	while c do
		if c == target then
			return true
		end
		c = SUPER[c]
	end
	return target == "Instance"
end

local function newInstance(className)
	local props = { Name = className, ClassName = className, Archivable = true }
	local c = className
	while c do
		if DEFAULTS[c] then
			for k, v in pairs(DEFAULTS[c]()) do
				if props[k] == nil then
					props[k] = v
				end
			end
		end
		c = SUPER[c]
	end
	return setmetatable({ _props = props, _children = {}, _attributes = {}, _parent = nil }, InstanceMt)
end

InstanceMt.__index = function(self, k)
	if k == "Parent" or k == "_parent" or k == "_pivot" then
		return rawget(self, k == "Parent" and "_parent" or k)
	end
	if methods[k] then
		return methods[k]
	end
	local v = self._props[k]
	if v == nil then
		local child = methods.FindFirstChild(self, k)
		if child then
			return child
		end
		error(tostring(k) .. " is not a valid member of " .. self._props.ClassName, 2)
	end
	if v == false and k == "PrimaryPart" then
		return nil
	end
	return v
end
InstanceMt.__newindex = function(self, k, v)
	if k == "Parent" then
		local oldParent = rawget(self, "_parent")
		if oldParent then
			local siblings = oldParent._children
			for i, child in ipairs(siblings) do
				if child == self then
					table.remove(siblings, i)
					break
				end
			end
		end
		rawset(self, "_parent", v)
		if v then
			table.insert(v._children, self)
		end
		return
	end
	if self._props[k] == nil then
		error(tostring(k) .. " is not a valid member of " .. self._props.ClassName, 2)
	end
	if k ~= "Name" and k ~= "Source" and k ~= "Value" and typeOf(v) ~= typeOf(self._props[k]) and self._props[k] ~= false then
		error("Unable to assign property " .. k .. ". " .. typeOf(self._props[k]) .. " expected, got " .. typeOf(v), 2)
	end
	self._props[k] = v
end
InstanceMt.__tostring = function(self)
	return self._props.Name
end

function methods.IsA(self, className)
	return isA(self._props.ClassName, className)
end
function methods.GetChildren(self)
	return table.clone(self._children)
end
function methods.GetDescendants(self)
	local out = {}
	local function walk(i)
		for _, c in ipairs(i._children) do
			table.insert(out, c)
			walk(c)
		end
	end
	walk(self)
	return out
end
function methods.FindFirstChild(self, name)
	for _, c in ipairs(self._children) do
		if c._props.Name == name then
			return c
		end
	end
	return nil
end
function methods.GetFullName(self)
	local parts = {}
	local i = self
	while i and i._props.ClassName ~= "DataModel" do
		table.insert(parts, 1, i._props.Name)
		i = i._parent
	end
	return table.concat(parts, ".")
end
function methods.Clone(self)
	if not self._props.Archivable then
		return nil
	end
	local copy = newInstance(self._props.ClassName)
	for k, v in pairs(self._props) do
		copy._props[k] = v
	end
	for k, v in pairs(self._attributes) do
		copy._attributes[k] = v
	end
	for _, c in ipairs(self._children) do
		local cc = methods.Clone(c)
		if cc then
			cc.Parent = copy
		end
	end
	return copy
end
function methods.Destroy(self)
	self.Parent = nil
end
function methods.GetAttributes(self)
	return table.clone(self._attributes)
end
function methods.GetAttribute(self, name)
	return self._attributes[name]
end
function methods.SetAttribute(self, name, value)
	if type(value) == "table" and typeOf(value) == "table" then
		error("SetAttribute: tables are not supported", 2)
	end
	self._attributes[name] = value
end
function methods.GetPivot(self)
	return CFrame.new(0, 0, 0)
end
function methods.PivotTo(self, cframe)
	rawset(self, "_pivot", cframe)
end
function methods.GetExtentsSize(self)
	return Vector3.new(1, 1, 1)
end

env.Instance = {
	new = function(className)
		if NOT_CREATABLE[className] or (not SUPER[className] and className ~= "Folder" and className ~= "RemoteEvent") then
			error("Unable to create an Instance of type \"" .. tostring(className) .. "\"", 2)
		end
		return newInstance(className)
	end,
}

-- DataModel + services ---------------------------------------------------
local game = newInstance("DataModel")
game._props.Name = "MockPlace"
game._props.PlaceId = 123
game._props.GameId = 456
local function addService(className, name)
	local s = newInstance(className)
	s._props.Name = name or className
	s.Parent = game
	return s
end
local workspaceService = addService("Workspace")
local terrain = newInstance("Terrain")
terrain._props.Name = "Terrain"
terrain.Parent = workspaceService
local terrainCalls = {}
methods.FillBlock = function(_, cframe, size, material)
	table.insert(terrainCalls, { "FillBlock", cframe, size, material })
end
methods.Clear = function()
	table.insert(terrainCalls, { "Clear" })
end
for _, name in ipairs({ "ServerScriptService", "ReplicatedStorage", "Lighting", "StarterGui", "StarterPlayer" }) do
	addService(name)
end
local camera = newInstance("Camera")
camera._props.Name = "Camera"
camera._props.CFrame = CFrame.new(0, 10, 20)
workspaceService._props.CurrentCamera = camera
workspaceService._props.Terrain = terrain

local tags = {}
local recordings = {}
local selection = {}
local messageOut = signal()
local httpRequests = {}

local services = {
	HttpService = {
		JSONEncode = function(_, v)
			return "<json>"
		end,
		JSONDecode = function(_, s)
			error("mock JSONDecode")
		end,
		UrlEncode = function(_, s)
			return s
		end,
		GetAsync = function(_, url)
			table.insert(httpRequests, url)
			error("mock: HTTP disabled")
		end,
		RequestAsync = function(_, req)
			table.insert(httpRequests, req.Url)
			error("mock: HTTP disabled")
		end,
	},
	RunService = {
		IsEdit = function()
			return true
		end,
		IsClient = function()
			return false
		end,
		IsRunning = function()
			return false
		end,
	},
	ChangeHistoryService = {
		TryBeginRecording = function(_, name)
			table.insert(recordings, { name = name })
			return #recordings
		end,
		FinishRecording = function(_, id, op)
			recordings[id].op = op
		end,
		Undo = function() end,
		Redo = function() end,
	},
	Selection = {
		Get = function()
			return selection
		end,
		Set = function(_, list)
			selection = list
		end,
	},
	CollectionService = {
		GetTags = function(_, inst)
			local out = {}
			for tag in pairs(tags[inst] or {}) do
				table.insert(out, tag)
			end
			table.sort(out)
			return out
		end,
		AddTag = function(_, inst, tag)
			tags[inst] = tags[inst] or {}
			tags[inst][tag] = true
		end,
		RemoveTag = function(_, inst, tag)
			if tags[inst] then
				tags[inst][tag] = nil
			end
		end,
		HasTag = function(_, inst, tag)
			return tags[inst] ~= nil and tags[inst][tag] == true
		end,
	},
	LogService = {
		GetLogHistory = function()
			return {}
		end,
		MessageOut = messageOut,
	},
	ScriptEditorService = {
		GetEditorSource = function()
			error("not open")
		end,
		UpdateSourceAsync = function()
			error("not open")
		end,
	},
}

methods.GetService = function(self, name)
	if services[name] then
		return services[name]
	end
	local child = methods.FindFirstChild(self, name)
	if child then
		return child
	end
	error("'" .. name .. "' is not a valid Service name", 2)
end
methods.FindService = function(self, name)
	return methods.FindFirstChild(self, name)
end

env.game = game
env.workspace = workspaceService

env.task = {
	spawn = function(fn, ...)
		local co = coroutine.create(fn)
		coroutine.resume(co, ...)
		return co
	end,
	wait = function()
		return 0
	end,
	delay = function() end,
}

local settings = { ClaudeBridgeEnabled = false }
env.plugin = {
	GetSetting = function(_, k)
		return settings[k]
	end,
	SetSetting = function(_, k, v)
		settings[k] = v
	end,
	CreateToolbar = function()
		return {
			CreateButton = function()
				return { Click = signal(), SetActive = function() end }
			end,
		}
	end,
	CreateDockWidgetPluginGui = function()
		error("no widgets in mock")
	end,
	Unloading = signal(),
}

-- Test helpers exposed to the test suffix
env.__mock = {
	recordings = recordings,
	terrainCalls = terrainCalls,
	httpRequests = httpRequests,
	messageOut = messageOut,
	tags = tags,
	selection = function()
		return selection
	end,
}

return env
