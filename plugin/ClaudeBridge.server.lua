--[[
	Claude Bridge - Roblox Studio plugin
	Connects Roblox Studio to Claude through the local roblox-claude-bridge MCP server.

	Install: copy this file into your Studio Plugins folder
	(Studio -> Plugins tab -> Plugins Folder), then restart Studio.
	The plugin long-polls http://127.0.0.1:<port> and executes commands sent by Claude.
]]

local VERSION = "1.0.0"
local DEFAULT_PORT = 44755

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local Selection = game:GetService("Selection")
local CollectionService = game:GetService("CollectionService")
local LogService = game:GetService("LogService")

local SETTING_ENABLED = "ClaudeBridgeEnabled"
local SETTING_PORT = "ClaudeBridgePort"

local function getSetting(name, default)
	local ok, value = pcall(function()
		return plugin:GetSetting(name)
	end)
	if ok and value ~= nil then
		return value
	end
	return default
end

local function setSetting(name, value)
	pcall(function()
		plugin:SetSetting(name, value)
	end)
end

local port = tonumber(getSetting(SETTING_PORT, DEFAULT_PORT)) or DEFAULT_PORT
local baseUrl = "http://127.0.0.1:" .. port

local function getContext()
	if RunService:IsEdit() then
		return "edit"
	elseif RunService:IsClient() then
		return "client"
	end
	return "server"
end

------------------------------------------------------------------------
-- UI: toolbar button + status widget (edit DataModel only)
------------------------------------------------------------------------

local connectButton, statusLabel, logLabel
local logLines = {}

local function uiLog(text)
	table.insert(logLines, os.date("%H:%M:%S") .. "  " .. text)
	while #logLines > 14 do
		table.remove(logLines, 1)
	end
	if logLabel then
		logLabel.Text = table.concat(logLines, "\n")
	end
end

local function setStatus(text, color)
	if statusLabel then
		statusLabel.Text = text
		statusLabel.TextColor3 = color or Color3.fromRGB(220, 220, 220)
	end
end

------------------------------------------------------------------------
-- Output capture (for get_output)
------------------------------------------------------------------------

local OUTPUT_LIMIT = 1000
local outputBuffer = {}
local outputSeq = 0
local MESSAGE_TYPES = {
	[Enum.MessageType.MessageOutput] = "output",
	[Enum.MessageType.MessageInfo] = "info",
	[Enum.MessageType.MessageWarning] = "warning",
	[Enum.MessageType.MessageError] = "error",
}

local function pushOutput(message, messageType)
	outputSeq += 1
	table.insert(outputBuffer, {
		seq = outputSeq,
		type = MESSAGE_TYPES[messageType] or "output",
		message = message,
		time = os.clock(),
	})
	if #outputBuffer > OUTPUT_LIMIT then
		table.remove(outputBuffer, 1)
	end
end

pcall(function()
	for _, entry in ipairs(LogService:GetLogHistory()) do
		pushOutput(entry.message, entry.messageType)
	end
end)
LogService.MessageOut:Connect(pushOutput)

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

local function describe(value)
	local t = typeof(value)
	if t == "table" then
		local ok, json = pcall(HttpService.JSONEncode, HttpService, value)
		return ok and json or "table"
	end
	return tostring(value) .. " (" .. t .. ")"
end

local function fail(message, ...)
	error(string.format(message, ...), 0)
end

local function splitPath(path)
	if type(path) == "table" then
		local parts = table.clone(path)
		if parts[1] == "game" then
			table.remove(parts, 1)
		end
		return parts
	end
	if type(path) ~= "string" then
		fail("Path must be a string or an array of names, got %s", describe(path))
	end
	if path == "" or path == "game" then
		return {}
	end
	local parts = string.split(path, ".")
	if parts[1] == "game" then
		table.remove(parts, 1)
	end
	return parts
end

local function resolve(path)
	local parts = splitPath(path)
	local current = game
	for _, name in ipairs(parts) do
		local nextInstance
		if current == game then
			nextInstance = game:FindFirstChild(name)
			if not nextInstance then
				local ok, service = pcall(game.GetService, game, name)
				if ok and typeof(service) == "Instance" then
					nextInstance = service
				end
			end
			if not nextInstance and string.lower(name) == "workspace" then
				nextInstance = workspace
			end
		else
			nextInstance = current:FindFirstChild(name)
		end
		if not nextInstance then
			local children = {}
			for i, child in ipairs(current:GetChildren()) do
				if i > 25 then
					table.insert(children, "...")
					break
				end
				table.insert(children, child.Name)
			end
			fail(
				"Instance not found: %q has no child %q (children: %s)",
				current == game and "game" or current:GetFullName(),
				name,
				#children > 0 and table.concat(children, ", ") or "none"
			)
		end
		current = nextInstance
	end
	return current
end

local function pathOf(instance)
	if instance == game then
		return "game"
	end
	return instance:GetFullName()
end

local function round(n)
	if n ~= n or n == math.huge or n == -math.huge then
		return tostring(n)
	end
	if n == math.floor(n) then
		return n
	end
	return math.floor(n * 10000 + 0.5) / 10000
end

------------------------------------------------------------------------
-- Serialization (Roblox value -> JSON-friendly)
------------------------------------------------------------------------

local serialize

local function serializeTable(value, depth, seen)
	if depth > 12 or seen[value] then
		return "<table>"
	end
	seen[value] = true
	local isArray = #value > 0 or next(value) == nil
	local out = {}
	if isArray then
		for i, v in ipairs(value) do
			out[i] = serialize(v, depth + 1, seen)
		end
	else
		for k, v in pairs(value) do
			out[tostring(k)] = serialize(v, depth + 1, seen)
		end
	end
	seen[value] = nil
	return out
end

serialize = function(value, depth, seen)
	depth = depth or 0
	seen = seen or {}
	local t = typeof(value)
	if t == "nil" or t == "boolean" or t == "string" then
		return value
	elseif t == "number" then
		return round(value)
	elseif t == "table" then
		return serializeTable(value, depth, seen)
	elseif t == "Vector3" or t == "Vector3int16" then
		return { round(value.X), round(value.Y), round(value.Z) }
	elseif t == "Vector2" or t == "Vector2int16" then
		return { round(value.X), round(value.Y) }
	elseif t == "Color3" then
		return "#" .. value:ToHex()
	elseif t == "BrickColor" then
		return value.Name
	elseif t == "CFrame" then
		local rx, ry, rz = value:ToOrientation()
		return {
			position = { round(value.X), round(value.Y), round(value.Z) },
			rotation = { round(math.deg(rx)), round(math.deg(ry)), round(math.deg(rz)) },
		}
	elseif t == "UDim2" then
		return { round(value.X.Scale), value.X.Offset, round(value.Y.Scale), value.Y.Offset }
	elseif t == "UDim" then
		return { round(value.Scale), value.Offset }
	elseif t == "EnumItem" then
		return tostring(value)
	elseif t == "Instance" then
		return { ["$ref"] = pathOf(value), className = value.ClassName }
	elseif t == "NumberRange" then
		return { round(value.Min), round(value.Max) }
	elseif t == "NumberSequence" then
		local out = {}
		for _, kp in ipairs(value.Keypoints) do
			table.insert(out, { round(kp.Time), round(kp.Value), round(kp.Envelope) })
		end
		return out
	elseif t == "ColorSequence" then
		local out = {}
		for _, kp in ipairs(value.Keypoints) do
			table.insert(out, { round(kp.Time), "#" .. kp.Value:ToHex() })
		end
		return out
	elseif t == "Rect" then
		return { round(value.Min.X), round(value.Min.Y), round(value.Max.X), round(value.Max.Y) }
	elseif t == "Font" then
		return { family = value.Family, weight = value.Weight.Name, style = value.Style.Name }
	elseif t == "PhysicalProperties" then
		return {
			density = round(value.Density),
			friction = round(value.Friction),
			elasticity = round(value.Elasticity),
			frictionWeight = round(value.FrictionWeight),
			elasticityWeight = round(value.ElasticityWeight),
		}
	elseif t == "Content" then
		local ok, uri = pcall(function()
			return value.Uri
		end)
		return ok and uri or tostring(value)
	end
	return tostring(value)
end

------------------------------------------------------------------------
-- Deserialization (JSON value -> Roblox value, guided by the property type)
------------------------------------------------------------------------

local function unwrap(value)
	if type(value) == "table" and value.value ~= nil and value["$type"] ~= nil then
		return value.value
	end
	return value
end

local function toVector3(v)
	v = unwrap(v)
	if typeof(v) == "Vector3" then
		return v
	elseif type(v) == "number" then
		return Vector3.new(v, v, v)
	elseif type(v) == "table" then
		return Vector3.new(v[1] or v.x or v.X or 0, v[2] or v.y or v.Y or 0, v[3] or v.z or v.Z or 0)
	end
	fail("Cannot convert %s to Vector3 (use [x, y, z])", describe(v))
end

local function toVector2(v)
	v = unwrap(v)
	if typeof(v) == "Vector2" then
		return v
	elseif type(v) == "number" then
		return Vector2.new(v, v)
	elseif type(v) == "table" then
		return Vector2.new(v[1] or v.x or v.X or 0, v[2] or v.y or v.Y or 0)
	end
	fail("Cannot convert %s to Vector2 (use [x, y])", describe(v))
end

local function toColor3(v)
	v = unwrap(v)
	if typeof(v) == "Color3" then
		return v
	elseif typeof(v) == "BrickColor" then
		return v.Color
	elseif type(v) == "string" then
		local hex = string.gsub(v, "^#", "")
		if string.match(hex, "^%x%x%x%x%x%x$") then
			return Color3.fromHex(hex)
		end
		return BrickColor.new(v).Color
	elseif type(v) == "table" then
		local r = v[1] or v.r or v.R or 0
		local g = v[2] or v.g or v.G or 0
		local b = v[3] or v.b or v.B or 0
		if r > 1 or g > 1 or b > 1 then
			return Color3.fromRGB(r, g, b)
		end
		return Color3.new(r, g, b)
	end
	fail("Cannot convert %s to Color3 (use \"#rrggbb\" or [r, g, b])", describe(v))
end

local function toCFrame(v)
	v = unwrap(v)
	if typeof(v) == "CFrame" then
		return v
	elseif typeof(v) == "Vector3" then
		return CFrame.new(v)
	elseif type(v) == "table" then
		if #v == 3 then
			return CFrame.new(v[1], v[2], v[3])
		elseif #v == 12 then
			return CFrame.new(table.unpack(v))
		end
		local position = v.position and toVector3(v.position) or Vector3.zero
		if v.lookAt then
			return CFrame.lookAt(position, toVector3(v.lookAt))
		end
		if v.rotation then
			local r = toVector3(v.rotation)
			return CFrame.new(position) * CFrame.fromOrientation(math.rad(r.X), math.rad(r.Y), math.rad(r.Z))
		end
		return CFrame.new(position)
	end
	fail("Cannot convert %s to CFrame (use [x,y,z] or {position, rotation})", describe(v))
end

local function toEnum(v, enumType)
	v = unwrap(v)
	if typeof(v) == "EnumItem" then
		return v
	end
	if type(enumType) == "string" then
		local ok, e = pcall(function()
			return Enum[enumType]
		end)
		if not ok or not e then
			fail("Unknown enum %q", enumType)
		end
		enumType = e
	end
	local items = enumType:GetEnumItems()
	if type(v) == "string" then
		local name = string.match(v, "([^%.]+)$") or v
		for _, item in ipairs(items) do
			if item.Name == name then
				return item
			end
		end
		local lower = string.lower(name)
		for _, item in ipairs(items) do
			if string.lower(item.Name) == lower then
				return item
			end
		end
	elseif type(v) == "number" then
		for _, item in ipairs(items) do
			if item.Value == v then
				return item
			end
		end
	end
	local names = {}
	for i, item in ipairs(items) do
		if i > 40 then
			table.insert(names, "...")
			break
		end
		table.insert(names, item.Name)
	end
	fail("%s is not a valid %s. Valid: %s", describe(v), tostring(enumType), table.concat(names, ", "))
end

local function toNumberSequence(v)
	v = unwrap(v)
	if typeof(v) == "NumberSequence" then
		return v
	elseif type(v) == "number" then
		return NumberSequence.new(v)
	elseif type(v) == "table" then
		if type(v[1]) == "number" and #v == 2 then
			return NumberSequence.new(v[1], v[2])
		end
		local keypoints = {}
		for _, kp in ipairs(v) do
			table.insert(keypoints, NumberSequenceKeypoint.new(kp[1], kp[2], kp[3] or 0))
		end
		return NumberSequence.new(keypoints)
	end
	fail("Cannot convert %s to NumberSequence", describe(v))
end

local function isColorLike(v)
	return type(v) == "string" or (type(v) == "table" and type(v[1]) == "number" and #v == 3) or typeof(v) == "Color3"
end

local function toColorSequence(v)
	v = unwrap(v)
	if typeof(v) == "ColorSequence" then
		return v
	elseif isColorLike(v) then
		return ColorSequence.new(toColor3(v))
	elseif type(v) == "table" then
		if #v == 2 and isColorLike(v[1]) and isColorLike(v[2]) then
			return ColorSequence.new(toColor3(v[1]), toColor3(v[2]))
		end
		local keypoints = {}
		for _, kp in ipairs(v) do
			table.insert(keypoints, ColorSequenceKeypoint.new(kp[1], toColor3(kp[2])))
		end
		return ColorSequence.new(keypoints)
	end
	fail("Cannot convert %s to ColorSequence", describe(v))
end

local function toFont(v)
	v = unwrap(v)
	if typeof(v) == "Font" then
		return v
	elseif typeof(v) == "EnumItem" then
		return Font.fromEnum(v)
	elseif type(v) == "string" then
		if string.find(v, "://", 1, true) then
			return Font.new(v)
		end
		return Font.fromName(v)
	elseif type(v) == "table" then
		local family = v.family or v.Family or "rbxasset://fonts/families/SourceSansPro.json"
		if not string.find(family, "://", 1, true) then
			family = "rbxasset://fonts/families/" .. family .. ".json"
		end
		return Font.new(
			family,
			toEnum(v.weight or v.Weight or "Regular", "FontWeight"),
			toEnum(v.style or v.Style or "Normal", "FontStyle")
		)
	end
	fail("Cannot convert %s to Font", describe(v))
end

local DECODERS = {
	bool = function(v)
		return v == true or v == "true" or v == 1
	end,
	string = function(v)
		return tostring(v)
	end,
	ContentId = function(v)
		if type(v) == "number" then
			return "rbxassetid://" .. v
		end
		return tostring(v)
	end,
	Content = function(v)
		if type(v) == "number" then
			v = "rbxassetid://" .. v
		end
		local ok, content = pcall(function()
			return Content.fromUri(v)
		end)
		return ok and content or v
	end,
	float = tonumber,
	double = tonumber,
	int = tonumber,
	int64 = tonumber,
	number = tonumber,
	Vector3 = toVector3,
	Vector2 = toVector2,
	Vector3int16 = function(v)
		local vec = toVector3(v)
		return Vector3int16.new(vec.X, vec.Y, vec.Z)
	end,
	Vector2int16 = function(v)
		local vec = toVector2(v)
		return Vector2int16.new(vec.X, vec.Y)
	end,
	Color3 = toColor3,
	CFrame = toCFrame,
	BrickColor = function(v)
		v = unwrap(v)
		if typeof(v) == "BrickColor" then
			return v
		elseif type(v) == "number" then
			return BrickColor.new(v)
		elseif type(v) == "string" and not string.match(v, "^#") then
			return BrickColor.new(v)
		end
		return BrickColor.new(toColor3(v))
	end,
	UDim2 = function(v)
		v = unwrap(v)
		if typeof(v) == "UDim2" then
			return v
		end
		if type(v) == "table" and #v == 2 and type(v[1]) == "table" then
			return UDim2.new(v[1][1], v[1][2], v[2][1], v[2][2])
		end
		return UDim2.new(v[1] or 0, v[2] or 0, v[3] or 0, v[4] or 0)
	end,
	UDim = function(v)
		v = unwrap(v)
		if type(v) == "number" then
			return UDim.new(v, 0)
		end
		return UDim.new(v[1] or 0, v[2] or 0)
	end,
	NumberRange = function(v)
		v = unwrap(v)
		if type(v) == "number" then
			return NumberRange.new(v)
		end
		return NumberRange.new(v[1], v[2] or v[1])
	end,
	NumberSequence = toNumberSequence,
	ColorSequence = toColorSequence,
	Rect = function(v)
		v = unwrap(v)
		return Rect.new(v[1] or 0, v[2] or 0, v[3] or 0, v[4] or 0)
	end,
	Font = toFont,
	PhysicalProperties = function(v)
		v = unwrap(v)
		if v == nil or v == false then
			return nil
		end
		if type(v) == "string" then
			return PhysicalProperties.new(toEnum(v, "Material"))
		end
		return PhysicalProperties.new(
			v.density or v[1] or 0.7,
			v.friction or v[2] or 0.3,
			v.elasticity or v[3] or 0.5,
			v.frictionWeight or v[4] or 1,
			v.elasticityWeight or v[5] or 1
		)
	end,
}

local function decode(value, typeName, category, current)
	-- Explicit type wrappers: {"$type": "Vector3", "value": [...]}, {"$ref": "Workspace.Part"}
	if type(value) == "table" then
		if value["$ref"] ~= nil then
			return resolve(value["$ref"])
		end
		if value["$type"] ~= nil then
			local explicit = value["$type"]
			if explicit == "Enum" then
				return toEnum(value.value or value.name, value.enum)
			elseif explicit == "Instance" then
				return resolve(value.path or value.value)
			end
			typeName, category = explicit, nil
		end
	end
	if typeName == nil and current ~= nil then
		local currentType = typeof(current)
		if currentType == "EnumItem" then
			return toEnum(value, current.EnumType)
		elseif currentType == "Instance" then
			category = "Class"
		else
			typeName = currentType
		end
	end
	if category == "Enum" then
		return toEnum(value, typeName)
	elseif category == "Class" then
		if value == nil or value == false or value == "" then
			return nil
		end
		if typeof(value) == "Instance" then
			return value
		end
		return resolve(value)
	end
	local decoder = typeName and DECODERS[typeName]
	if decoder then
		return decoder(value)
	end
	return unwrap(value)
end

------------------------------------------------------------------------
-- Reflection (property lists + types, served by the bridge from the API dump)
------------------------------------------------------------------------

local reflectionCache = {}

local function getReflection(className)
	local cached = reflectionCache[className]
	if cached then
		return cached
	end
	local info = { list = {}, byName = {} }
	local ok, response = pcall(function()
		return HttpService:GetAsync(baseUrl .. "/reflection?class=" .. HttpService:UrlEncode(className), true)
	end)
	if ok then
		local decodedOk, data = pcall(HttpService.JSONDecode, HttpService, response)
		if decodedOk and type(data) == "table" and data.properties then
			for _, prop in ipairs(data.properties) do
				table.insert(info.list, prop)
				info.byName[prop.name] = prop
			end
			reflectionCache[className] = info
		end
	end
	return info
end

------------------------------------------------------------------------
-- Property get/set
------------------------------------------------------------------------

local function setAttributes(instance, attributes)
	for name, value in pairs(attributes) do
		if value == nil or (type(value) == "table" and value["$nil"]) then
			instance:SetAttribute(name, nil)
		else
			local current = instance:GetAttribute(name)
			local converted = decode(value, nil, nil, current)
			instance:SetAttribute(name, converted)
		end
	end
end

local function setTags(instance, tags)
	local wanted = {}
	for _, tag in ipairs(tags) do
		wanted[tag] = true
	end
	for _, tag in ipairs(CollectionService:GetTags(instance)) do
		if not wanted[tag] then
			CollectionService:RemoveTag(instance, tag)
		end
	end
	for tag in pairs(wanted) do
		CollectionService:AddTag(instance, tag)
	end
end

local function setProperty(instance, name, value)
	if name == "$attributes" then
		return setAttributes(instance, value)
	elseif name == "$tags" then
		return setTags(instance, value)
	elseif name == "$addTags" then
		for _, tag in ipairs(value) do
			CollectionService:AddTag(instance, tag)
		end
		return
	elseif name == "$pivot" then
		return instance:PivotTo(toCFrame(value))
	elseif name == "$scale" then
		return instance:ScaleTo(tonumber(value))
	end
	local meta = getReflection(instance.ClassName).byName[name]
	local readOk, current = pcall(function()
		return instance[name]
	end)
	if not readOk and not meta then
		fail("%s has no property %q", instance.ClassName, name)
	end
	local typeName, category = meta and meta.type, meta and meta.category
	if not meta and readOk and current == nil and type(value) == "string" then
		-- Without reflection data, a nil-valued property (PrimaryPart, Part0, Adornee...) is an Instance reference.
		category = "Class"
	end
	local converted = decode(value, typeName, category, readOk and current or nil)
	local ok, err = pcall(function()
		instance[name] = converted
	end)
	if not ok then
		fail("Cannot set %s.%s = %s: %s", pathOf(instance), name, describe(value), tostring(err))
	end
end

local LATE_PROPERTIES = { PrimaryPart = 2, Parent = 3, ["$pivot"] = 1, ["$scale"] = 1 }

local function applyProperties(instance, properties)
	local names = {}
	for name in pairs(properties) do
		table.insert(names, name)
	end
	table.sort(names, function(a, b)
		local pa, pb = LATE_PROPERTIES[a] or 0, LATE_PROPERTIES[b] or 0
		if pa ~= pb then
			return pa < pb
		end
		return a < b
	end)
	for _, name in ipairs(names) do
		setProperty(instance, name, properties[name])
	end
end

local SKIP_READ = { Source = true }

-- Used when the bridge cannot provide reflection data; unreadable ones are skipped.
local COMMON_PROPERTIES = {
	"Name", "ClassName", "Parent", "Archivable", "Anchored", "CanCollide", "CanTouch", "CanQuery", "CastShadow",
	"Massless", "Position", "Orientation", "Size", "CFrame", "Color", "BrickColor", "Material", "Transparency",
	"Reflectance", "Shape", "PrimaryPart", "WorldPivot", "Disabled", "Enabled", "RunContext", "Value", "Text",
	"TextColor3", "TextSize", "TextScaled", "Font", "FontFace", "BackgroundColor3", "BackgroundTransparency",
	"AnchorPoint", "Visible", "ZIndex", "Image", "Brightness", "Range", "MaxHealth", "Health", "WalkSpeed",
	"JumpPower", "SoundId", "Volume", "Looped", "Playing", "Texture", "MeshId", "TextureID", "ClockTime",
	"Ambient", "OutdoorAmbient", "FogEnd", "FogColor", "Gravity",
}

local function readProperties(instance, only)
	local result = { path = pathOf(instance), className = instance.ClassName, properties = {} }
	local names = {}
	if only and #only > 0 then
		names = only
	else
		for _, prop in ipairs(getReflection(instance.ClassName).list) do
			if not SKIP_READ[prop.name] then
				table.insert(names, prop.name)
			end
		end
		if #names == 0 then
			names = COMMON_PROPERTIES
		end
	end
	for _, name in ipairs(names) do
		local ok, value = pcall(function()
			return instance[name]
		end)
		if ok then
			result.properties[name] = serialize(value)
		end
	end
	local attributes = {}
	for name, value in pairs(instance:GetAttributes()) do
		attributes[name] = serialize(value)
	end
	if next(attributes) then
		result.attributes = attributes
	end
	local tags = CollectionService:GetTags(instance)
	if #tags > 0 then
		result.tags = tags
	end
	result.childCount = #instance:GetChildren()
	if instance:IsA("PVInstance") and not instance:IsA("BasePart") then
		pcall(function()
			result.pivot = serialize(instance:GetPivot())
		end)
		if instance:IsA("Model") then
			pcall(function()
				result.boundingBoxSize = serialize(instance:GetExtentsSize())
			end)
		end
	end
	if instance:IsA("LuaSourceContainer") then
		local ok, source = pcall(function()
			return instance.Source
		end)
		if ok then
			local _, lineCount = string.gsub(source, "\n", "")
			result.sourceLines = lineCount + 1
			result.note = "Use read_script to see the source."
		end
	end
	return result
end

------------------------------------------------------------------------
-- Script source helpers
------------------------------------------------------------------------

local ScriptEditorService = game:GetService("ScriptEditorService")

local function getSource(script)
	local ok, source = pcall(function()
		return ScriptEditorService:GetEditorSource(script)
	end)
	if ok and type(source) == "string" then
		return source
	end
	return script.Source
end

local function setSource(script, source)
	local ok = pcall(function()
		ScriptEditorService:UpdateSourceAsync(script, function()
			return source
		end)
	end)
	if not ok then
		script.Source = source
	end
end

local function assertScript(instance)
	if not instance:IsA("LuaSourceContainer") then
		fail("%s is a %s, not a script", pathOf(instance), instance.ClassName)
	end
end

------------------------------------------------------------------------
-- Undo history
------------------------------------------------------------------------

local recordingDepth = 0

local function withHistory(name, fn, ...)
	if recordingDepth > 0 then
		return fn(...)
	end
	local okBegin, recordingId = pcall(function()
		return ChangeHistoryService:TryBeginRecording(name)
	end)
	if not okBegin then
		recordingId = nil
	end
	recordingDepth += 1
	local results = table.pack(pcall(fn, ...))
	recordingDepth -= 1
	if recordingId then
		pcall(function()
			ChangeHistoryService:FinishRecording(
				recordingId,
				results[1] and Enum.FinishRecordingOperation.Commit or Enum.FinishRecordingOperation.Cancel
			)
		end)
	end
	if not results[1] then
		local message = tostring(results[2])
		if recordingId then
			message ..= " (changes from this step were rolled back)"
		end
		error(message, 0)
	end
	return table.unpack(results, 2, results.n)
end

------------------------------------------------------------------------
-- Command handlers
------------------------------------------------------------------------

local DEFAULT_ROOTS = {
	"Workspace", "Players", "Lighting", "MaterialService", "ReplicatedFirst", "ReplicatedStorage",
	"ServerScriptService", "ServerStorage", "StarterGui", "StarterPack", "StarterPlayer", "Teams",
	"SoundService", "TextChatService",
}

local function defaultRoots()
	local roots = {}
	for _, name in ipairs(DEFAULT_ROOTS) do
		local service = game:FindFirstChild(name) or game:FindService(name)
		if service then
			table.insert(roots, service)
		end
	end
	return roots
end

local function instanceLabel(instance)
	local label = instance.Name .. " (" .. instance.ClassName
	if instance:IsA("BaseScript") then
		local ok, disabled = pcall(function()
			return instance.Disabled
		end)
		if ok and disabled then
			label ..= ", disabled"
		end
	elseif instance:IsA("ValueBase") then
		local ok, value = pcall(function()
			return instance.Value
		end)
		if ok then
			label ..= " = " .. tostring(serialize(value))
		end
	end
	return label .. ")"
end

local handlers = {}

handlers.ping = function()
	local camera = workspace.CurrentCamera
	local selected = {}
	for i, instance in ipairs(Selection:Get()) do
		if i > 20 then
			break
		end
		table.insert(selected, pathOf(instance))
	end
	return {
		placeName = game.Name,
		placeId = game.PlaceId,
		gameId = game.GameId,
		context = getContext(),
		running = RunService:IsRunning(),
		pluginVersion = VERSION,
		selection = selected,
		camera = camera and {
			position = serialize(camera.CFrame.Position),
			lookVector = serialize(camera.CFrame.LookVector),
		} or nil,
	}
end

handlers.get_tree = function(args)
	local depth = args.depth or 2
	local maxChildren = args.maxChildren or 100
	local maxLines = 4000
	local lines = {}
	local truncated = false

	local function walk(instance, level)
		if #lines >= maxLines then
			truncated = true
			return
		end
		local children = instance:GetChildren()
		local label = string.rep("  ", level) .. instanceLabel(instance)
		if #children > 0 and level >= depth then
			label ..= " [" .. #children .. " children]"
		end
		table.insert(lines, label)
		if level < depth then
			for i, child in ipairs(children) do
				if i > maxChildren then
					table.insert(lines, string.rep("  ", level + 1) .. "... " .. (#children - maxChildren) .. " more")
					break
				end
				walk(child, level + 1)
			end
		end
	end

	local roots
	if args.path ~= nil and args.path ~= "" and args.path ~= "game" then
		local root = resolve(args.path)
		roots = { root }
		table.insert(lines, "# " .. pathOf(root) .. "  (child path = parent path .. \".\" .. name)")
	else
		roots = defaultRoots()
		table.insert(lines, "# game  (path of an instance = names joined with \".\", e.g. Workspace.Model.Part)")
	end
	for _, root in ipairs(roots) do
		walk(root, 0)
	end
	if truncated then
		table.insert(lines, "... output truncated, use a deeper path or smaller depth")
	end
	return table.concat(lines, "\n")
end

handlers.find = function(args)
	local limit = args.limit or 200
	local roots = args.root and { resolve(args.root) } or defaultRoots()
	local query = args.name and string.lower(args.name)
	local results = {}
	local total = 0

	local function matches(instance)
		if args.className and not instance:IsA(args.className) then
			return false
		end
		if query then
			local name = string.lower(instance.Name)
			if not string.find(name, query, 1, true) then
				local ok, found = pcall(string.match, instance.Name, args.name)
				if not (ok and found) then
					return false
				end
			end
		end
		if args.tag and not CollectionService:HasTag(instance, args.tag) then
			return false
		end
		if args.attribute and instance:GetAttribute(args.attribute) == nil then
			return false
		end
		return true
	end

	for _, root in ipairs(roots) do
		local ok, descendants = pcall(root.GetDescendants, root)
		if ok then
			for _, instance in ipairs(descendants) do
				if matches(instance) then
					total += 1
					if #results < limit then
						table.insert(results, pathOf(instance) .. " (" .. instance.ClassName .. ")")
					end
				end
			end
		end
	end
	local header = string.format("%d match(es)%s", total, total > limit and (", showing first " .. limit) or "")
	if total == 0 then
		return header
	end
	return header .. "\n" .. table.concat(results, "\n")
end

handlers.get_properties = function(args)
	return readProperties(resolve(args.path), args.properties)
end

handlers.set_properties = function(args)
	local targets = {}
	if args.path then
		table.insert(targets, resolve(args.path))
	end
	for _, path in ipairs(args.paths or {}) do
		table.insert(targets, resolve(path))
	end
	if #targets == 0 then
		fail("Provide path or paths")
	end
	local updated = {}
	for _, instance in ipairs(targets) do
		applyProperties(instance, args.properties or {})
		table.insert(updated, pathOf(instance))
	end
	return { updated = updated }
end

handlers.create = function(args)
	local parent = resolve(args.parent or "Workspace")
	local ok, instance = pcall(Instance.new, args.className)
	if not ok then
		fail("Cannot create %q: %s", tostring(args.className), tostring(instance))
	end
	if args.name then
		instance.Name = args.name
	end
	if args.source ~= nil then
		assertScript(instance)
		instance.Source = args.source
	end
	local properties = table.clone(args.properties or {})
	local parentOverride = properties.Parent
	properties.Parent = nil
	local okProps, err = pcall(applyProperties, instance, properties)
	if not okProps then
		instance:Destroy()
		error(err, 0)
	end
	instance.Parent = parentOverride and resolve(parentOverride) or parent
	return { created = pathOf(instance), className = instance.ClassName }
end

handlers.delete = function(args)
	local deleted = {}
	for _, path in ipairs(args.paths or { args.path }) do
		local instance = resolve(path)
		if instance.Parent == game then
			fail("Refusing to delete service %s", pathOf(instance))
		end
		local fullPath = pathOf(instance)
		instance.Parent = nil -- keeps it undoable (Destroy would lock it)
		table.insert(deleted, fullPath)
	end
	return { deleted = deleted }
end

handlers.clone = function(args)
	local source = resolve(args.path)
	local parent = args.parent and resolve(args.parent) or source.Parent
	local count = args.count or 1
	local created = {}
	local wasArchivable = source.Archivable
	source.Archivable = true
	for i = 1, count do
		local copy = source:Clone()
		if not copy then
			source.Archivable = wasArchivable
			fail("%s cannot be cloned", pathOf(source))
		end
		if args.name then
			copy.Name = count > 1 and (args.name .. i) or args.name
		end
		if args.properties then
			applyProperties(copy, args.properties)
		end
		copy.Parent = parent
		table.insert(created, pathOf(copy))
	end
	source.Archivable = wasArchivable
	return { created = created }
end

handlers.move = function(args)
	local instance = resolve(args.path)
	local parent = resolve(args.parent)
	instance.Parent = parent
	return { moved = pathOf(instance) }
end

handlers.read_script = function(args)
	local script = resolve(args.path)
	assertScript(script)
	local source = getSource(script)
	local lines = string.split(source, "\n")
	local first = math.max(1, args.startLine or 1)
	local last = math.min(#lines, args.endLine or #lines)
	local out = { string.format("-- %s (%s), %d lines", pathOf(script), script.ClassName, #lines) }
	local width = #tostring(last)
	for i = first, last do
		table.insert(out, string.format("%" .. width .. "d| %s", i, lines[i]))
	end
	return table.concat(out, "\n")
end

handlers.write_script = function(args)
	local ok, script = pcall(resolve, args.path)
	if not ok then
		if not args.className then
			error(script, 0)
		end
		local parts = splitPath(args.path)
		local name = table.remove(parts)
		script = Instance.new(args.className)
		script.Name = name
		script.Source = args.source
		script.Parent = resolve(parts)
		return { created = pathOf(script), lines = #string.split(args.source, "\n") }
	end
	assertScript(script)
	setSource(script, args.source)
	return { updated = pathOf(script), lines = #string.split(args.source, "\n") }
end

local function countPlain(haystack, needle)
	local count, start = 0, 1
	while true do
		local s, e = string.find(haystack, needle, start, true)
		if not s then
			return count
		end
		count += 1
		start = e + 1
	end
end

local function replacePlain(haystack, needle, replacement, all)
	local out, start = {}, 1
	while true do
		local s, e = string.find(haystack, needle, start, true)
		if not s then
			break
		end
		table.insert(out, string.sub(haystack, start, s - 1))
		table.insert(out, replacement)
		start = e + 1
		if not all then
			break
		end
	end
	table.insert(out, string.sub(haystack, start))
	return table.concat(out)
end

handlers.edit_script = function(args)
	local script = resolve(args.path)
	assertScript(script)
	if args.oldText == nil or args.oldText == "" then
		fail("oldText must not be empty")
	end
	local source = getSource(script)
	local count = countPlain(source, args.oldText)
	if count == 0 then
		fail("oldText was not found in %s. Use read_script to get the exact current text.", pathOf(script))
	elseif count > 1 and not args.replaceAll then
		fail("oldText appears %d times in %s; include more context or set replaceAll", count, pathOf(script))
	end
	setSource(script, replacePlain(source, args.oldText, args.newText or "", args.replaceAll))
	return { updated = pathOf(script), replacements = args.replaceAll and count or 1 }
end

handlers.run_luau = function(args)
	local fn, compileError = loadstring(args.code, "=ClaudeCode")
	if not fn then
		fail("Compile error: %s", tostring(compileError))
	end
	local logs = {}
	local function capture(kind, original)
		return function(...)
			local parts = {}
			for i = 1, select("#", ...) do
				parts[i] = tostring((select(i, ...)))
			end
			local line = table.concat(parts, " ")
			table.insert(logs, kind == "print" and line or (kind .. ": " .. line))
			original(...)
		end
	end
	local env = setmetatable({
		print = capture("print", print),
		warn = capture("warn", warn),
		plugin = plugin,
	}, { __index = getfenv(1) })
	setfenv(fn, env)
	local results = table.pack(xpcall(fn, function(err)
		return debug.traceback(tostring(err), 2)
	end))
	if not results[1] then
		local message = tostring(results[2])
		if #logs > 0 then
			message ..= "\n--- output before the error ---\n" .. table.concat(logs, "\n")
		end
		error(message, 0)
	end
	local returned = {}
	for i = 2, results.n do
		returned[i - 1] = serialize(results[i])
	end
	return {
		output = logs,
		returned = results.n > 1 and (results.n == 2 and returned[1] or returned) or nil,
	}
end

handlers.get_selection = function()
	local out = {}
	for _, instance in ipairs(Selection:Get()) do
		table.insert(out, pathOf(instance) .. " (" .. instance.ClassName .. ")")
	end
	return out
end

handlers.set_selection = function(args)
	local instances = {}
	for _, path in ipairs(args.paths or {}) do
		table.insert(instances, resolve(path))
	end
	Selection:Set(instances)
	return { selected = #instances }
end

handlers.get_output = function(args)
	local wanted
	if args.types then
		wanted = {}
		for _, t in ipairs(args.types) do
			wanted[t] = true
		end
	end
	local matched = {}
	for _, entry in ipairs(outputBuffer) do
		if (not args.sinceSeq or entry.seq > args.sinceSeq) and (not wanted or wanted[entry.type]) then
			table.insert(matched, entry)
		end
	end
	local limit = args.limit or 100
	local first = math.max(1, #matched - limit + 1)
	local lines = {}
	for i = first, #matched do
		local entry = matched[i]
		table.insert(lines, string.format("[%d] %s: %s", entry.seq, entry.type, entry.message))
	end
	if args.clear then
		table.clear(outputBuffer)
	end
	local header = string.format("context=%s lastSeq=%d (%d message(s))", getContext(), outputSeq, #lines)
	return header .. (#lines > 0 and ("\n" .. table.concat(lines, "\n")) or "")
end

handlers.playtest = function(args)
	local StudioTestService = game:GetService("StudioTestService")
	if args.action == "play" or args.action == "run" then
		if RunService:IsRunning() then
			fail("A test is already running; stop it first")
		end
		local method = args.action == "play" and "ExecutePlayModeAsync" or "ExecuteRunModeAsync"
		local started = false
		task.spawn(function()
			local ok, err = pcall(function()
				started = true
				StudioTestService[method](StudioTestService, {})
			end)
			if not ok then
				if args.action == "run" then
					pcall(function()
						RunService:Run()
					end)
				else
					warn("[Claude] Could not start playtest: " .. tostring(err))
				end
			end
		end)
		task.wait(0.5)
		return {
			started = started,
			action = args.action,
			hint = 'Wait a few seconds, then use context "server" / "client" and get_output. Stop with playtest {action:"stop"}.',
		}
	elseif args.action == "stop" then
		if not RunService:IsRunning() then
			return { stopped = false, message = "No test is running" }
		end
		task.delay(0.2, function()
			local ok = pcall(function()
				StudioTestService:EndTest(nil)
			end)
			if not ok then
				pcall(function()
					RunService:Stop()
				end)
			end
		end)
		return { stopping = true }
	end
	fail("Unknown playtest action %q", tostring(args.action))
end

handlers.insert_asset = function(args)
	local parent = resolve(args.parent or "Workspace")
	local ok, objects = pcall(function()
		return game:GetObjects("rbxassetid://" .. tostring(args.assetId))
	end)
	if not ok or not objects or #objects == 0 then
		local okInsert, model = pcall(function()
			return game:GetService("InsertService"):LoadAsset(args.assetId)
		end)
		if not okInsert then
			fail("Could not load asset %s: %s", tostring(args.assetId), tostring(objects or model))
		end
		objects = model:GetChildren()
	end
	local inserted = {}
	for _, object in ipairs(objects) do
		object.Parent = parent
		if args.position and object:IsA("PVInstance") then
			object:PivotTo(CFrame.new(toVector3(args.position)))
		end
		table.insert(inserted, pathOf(object) .. " (" .. object.ClassName .. ")")
	end
	return { inserted = inserted }
end

handlers.terrain = function(args)
	local terrain = workspace.Terrain
	local material = args.material and toEnum(args.material, "Material") or Enum.Material.Grass
	local position = toVector3(args.position or { 0, 0, 0 })
	local cframe = CFrame.new(position)
	if args.rotation then
		cframe = toCFrame({ position = args.position or { 0, 0, 0 }, rotation = args.rotation })
	end
	local size = args.size and toVector3(args.size) or Vector3.new(16, 16, 16)
	if args.action == "fill_block" then
		terrain:FillBlock(cframe, size, material)
	elseif args.action == "fill_ball" then
		terrain:FillBall(position, args.radius or 8, material)
	elseif args.action == "fill_cylinder" then
		terrain:FillCylinder(cframe, size.Y, args.radius or size.X / 2, material)
	elseif args.action == "fill_wedge" then
		terrain:FillWedge(cframe, size, material)
	elseif args.action == "clear" then
		terrain:Clear()
	else
		fail("Unknown terrain action %q", tostring(args.action))
	end
	return { done = args.action, material = tostring(material) }
end

handlers.batch = function(args)
	local results = {}
	for i, operation in ipairs(args.operations or {}) do
		local handler = handlers[operation.op]
		if not handler or operation.op == "batch" then
			fail("Operation %d: unknown op %q", i, tostring(operation.op))
		end
		local ok, result = pcall(handler, operation.args or {})
		if ok then
			results[i] = { op = operation.op, ok = true, result = result }
		else
			if not args.continueOnError then
				fail("Operation %d (%s) failed: %s", i, operation.op, tostring(result))
			end
			results[i] = { op = operation.op, ok = false, error = tostring(result) }
		end
	end
	return results
end

handlers.undo = function(args)
	for _ = 1, args.steps or 1 do
		ChangeHistoryService:Undo()
	end
	return { undone = args.steps or 1 }
end

handlers.redo = function(args)
	for _ = 1, args.steps or 1 do
		ChangeHistoryService:Redo()
	end
	return { redone = args.steps or 1 }
end

local MUTATING = {
	set_properties = true, create = true, delete = true, clone = true, move = true, write_script = true,
	edit_script = true, run_luau = true, insert_asset = true, terrain = true, batch = true,
}

local function execute(command)
	local handler = handlers[command.op]
	if not handler then
		return { id = command.id, ok = false, error = "Unknown operation: " .. tostring(command.op) }
	end
	local args = command.args or {}
	local ok, result
	if MUTATING[command.op] then
		ok, result = pcall(withHistory, "Claude: " .. command.op, handler, args)
	else
		ok, result = pcall(handler, args)
	end
	if not ok then
		return { id = command.id, ok = false, error = tostring(result) }
	end
	return { id = command.id, ok = true, data = serialize(result) }
end

------------------------------------------------------------------------
-- Connection loop
------------------------------------------------------------------------

local enabled = false
local generation = 0

local function post(path, body)
	return HttpService:RequestAsync({
		Url = baseUrl .. path,
		Method = "POST",
		Headers = { ["Content-Type"] = "application/json" },
		Body = HttpService:JSONEncode(body),
	})
end

local function sendResult(result)
	local okEncode, _ = pcall(HttpService.JSONEncode, HttpService, result)
	if not okEncode then
		result = { id = result.id, ok = result.ok, error = result.error, data = describe(result.data) }
	end
	for attempt = 1, 3 do
		local ok, response = pcall(post, "/result", { results = { result } })
		if ok and response.Success then
			return
		end
		task.wait(0.5 * attempt)
	end
end

local function pollLoop(myGeneration)
	local backoff = 1
	local wasConnected = false
	while enabled and generation == myGeneration do
		local ok, response = pcall(post, "/poll", {
			context = getContext(),
			info = { placeName = game.Name, placeId = game.PlaceId, pluginVersion = VERSION },
		})
		if generation ~= myGeneration then
			break
		end
		if ok and response.Success then
			backoff = 1
			if not wasConnected then
				wasConnected = true
				setStatus("Connected to Claude (port " .. port .. ")", Color3.fromRGB(90, 220, 120))
				uiLog("connected")
				print("[Claude] Connected to Claude bridge on port " .. port .. " (" .. getContext() .. ")")
			end
			local decodedOk, body = pcall(HttpService.JSONDecode, HttpService, response.Body)
			if decodedOk and type(body) == "table" then
				for _, command in ipairs(body.commands or {}) do
					uiLog(command.op)
					local result = execute(command)
					if not result.ok then
						uiLog("  error: " .. string.sub(tostring(result.error), 1, 120))
					end
					sendResult(result)
				end
			end
		else
			if wasConnected then
				wasConnected = false
				uiLog("disconnected")
			end
			local reason = ok and ("HTTP " .. tostring(response.StatusCode)) or tostring(response)
			if string.find(reason, "Http requests are not enabled", 1, true) then
				setStatus("Enable HTTP: Game Settings -> Security -> Allow HTTP Requests", Color3.fromRGB(255, 170, 60))
			else
				setStatus("Waiting for Claude bridge on port " .. port .. "...", Color3.fromRGB(255, 200, 80))
			end
			task.wait(backoff)
			backoff = math.min(backoff * 2, 8)
		end
	end
end

local function setEnabled(value)
	enabled = value
	generation += 1
	setSetting(SETTING_ENABLED, value)
	if connectButton then
		connectButton:SetActive(value)
	end
	if value then
		setStatus("Connecting to port " .. port .. "...", Color3.fromRGB(255, 200, 80))
		task.spawn(pollLoop, generation)
	else
		setStatus("Disconnected", Color3.fromRGB(180, 180, 180))
		uiLog("disabled")
	end
end

------------------------------------------------------------------------
-- Boot
------------------------------------------------------------------------

if getContext() == "edit" then
	local toolbar = plugin:CreateToolbar("Claude")
	connectButton = toolbar:CreateButton(
		"ClaudeConnect",
		"Connect / disconnect Roblox Studio and Claude",
		"rbxasset://textures/StudioSharedUI/statusSuccess.png",
		"Connect"
	)
	connectButton.ClickableWhenViewportHidden = true
	local panelButton = toolbar:CreateButton(
		"ClaudePanel",
		"Show the Claude Bridge status panel",
		"rbxasset://textures/StudioSharedUI/info.png",
		"Status"
	)
	panelButton.ClickableWhenViewportHidden = true

	local okWidget, widget = pcall(function()
		return plugin:CreateDockWidgetPluginGui(
			"ClaudeBridgeStatus",
			DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Float, false, false, 340, 260, 260, 160)
		)
	end)
	if okWidget and widget then
		widget.Title = "Claude Bridge"
		local frame = Instance.new("Frame")
		frame.Size = UDim2.fromScale(1, 1)
		frame.BackgroundColor3 = Color3.fromRGB(37, 37, 37)
		frame.BorderSizePixel = 0
		frame.Parent = widget
		statusLabel = Instance.new("TextLabel")
		statusLabel.Size = UDim2.new(1, -16, 0, 28)
		statusLabel.Position = UDim2.fromOffset(8, 6)
		statusLabel.BackgroundTransparency = 1
		statusLabel.Font = Enum.Font.SourceSansBold
		statusLabel.TextSize = 16
		statusLabel.TextXAlignment = Enum.TextXAlignment.Left
		statusLabel.TextWrapped = true
		statusLabel.Parent = frame
		logLabel = Instance.new("TextLabel")
		logLabel.Size = UDim2.new(1, -16, 1, -44)
		logLabel.Position = UDim2.fromOffset(8, 38)
		logLabel.BackgroundTransparency = 1
		logLabel.Font = Enum.Font.Code
		logLabel.TextSize = 13
		logLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
		logLabel.TextXAlignment = Enum.TextXAlignment.Left
		logLabel.TextYAlignment = Enum.TextYAlignment.Top
		logLabel.Text = ""
		logLabel.Parent = frame
		panelButton.Click:Connect(function()
			widget.Enabled = not widget.Enabled
		end)
	end

	connectButton.Click:Connect(function()
		setEnabled(not enabled)
	end)
	setEnabled(getSetting(SETTING_ENABLED, true) == true)
else
	-- Playtest DataModels (server / client): follow the edit session's setting.
	if getSetting(SETTING_ENABLED, true) == true then
		setEnabled(true)
	end
end

plugin.Unloading:Connect(function()
	enabled = false
	generation += 1
end)
