--[[
	DevHub Plugin v5.1
	A GitHub-style project workspace for Roblox scripters.
	Open-source project (MIT). Not affiliated with GitHub or Roblox.

	What's new in v5.1
	  * Code editor shows scripts of any length (Roblox text boxes stop drawing after ~16,000
	    characters, so the code is now shown in stacked sections with continuous line numbers)
	  * Backups and "This place" storage are split into several parts, so large libraries save
	  * Clear error messages when a backup is missing or incomplete

	What's new in v5.0
	  * Rebuilt UI: every button is a real, always-visible button (no more clicking empty space)
	  * One modal dialog system (rename, new project, confirm, choices) that always sits on top
	  * Responsive toolbars that wrap instead of clipping when the dock is narrow
	  * History view with line-by-line Diff, Restore and Delete for snapshots
	  * Pull from / Push to scripts in Studio (Script, LocalScript AND ModuleScript)
	  * Import several selected scripts as projects in one click
	  * Duplicate / Rename / Sort / Search projects
	  * Settings: storage location, prompt-on-close toggle, copy between storages, backup export/import
	  * Fully backwards compatible with v4.x saved data
]]

local plugin = plugin

-- ============ Services ============
local Selection = game:GetService("Selection")
local TweenService = game:GetService("TweenService")
local ScriptEditorService = game:GetService("ScriptEditorService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local TextService = game:GetService("TextService")
local ServerStorage = game:GetService("ServerStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")

-- Plugins also load inside play-test sessions; only run in the edit session.
if RunService:IsRunning() then return end

local VERSION = "5.1"
local LOG = "[DevHub v" .. VERSION .. "] "

-- ============ Theme ============
local Theme = {
	bg           = Color3.fromRGB(15, 18, 27),
	surface      = Color3.fromRGB(23, 28, 40),
	surfaceAlt   = Color3.fromRGB(31, 38, 53),
	surfaceHover = Color3.fromRGB(42, 51, 70),
	codeBg       = Color3.fromRGB(18, 22, 32),
	gutter       = Color3.fromRGB(26, 31, 44),
	accent       = Color3.fromRGB(92, 126, 247),
	accentHover  = Color3.fromRGB(116, 145, 255),
	text         = Color3.fromRGB(240, 243, 250),
	textDim      = Color3.fromRGB(158, 170, 190),
	border       = Color3.fromRGB(48, 59, 79),
	danger       = Color3.fromRGB(220, 62, 62),
	dangerHover  = Color3.fromRGB(240, 96, 96),
	success      = Color3.fromRGB(52, 190, 120),
	warning      = Color3.fromRGB(245, 180, 70),
	diffAddBg    = Color3.fromRGB(24, 62, 42),
	diffAddText  = Color3.fromRGB(150, 232, 176),
	diffDelBg    = Color3.fromRGB(78, 32, 38),
	diffDelText  = Color3.fromRGB(255, 160, 160),
}

local HEADER_H = 46
local STATUS_H = 24
local TOP_BAR = 3

-- ============ Constants ============
-- (Roblox scripts may have at most 200 top-level locals, so related names are grouped into tables.)
local K = {
	STORAGE = "DevHub_Projects",
	BACKUP = "DevHub_Projects_Backup",
	RECOVERY = "DevHub_RecoveryDraft",
	MODE = "DevHub_Mode",
	PROMPT = "DevHub_PromptOnClose",
	SORT = "DevHub_Sort",
	PLACE = "DevHubData",
	EXPORT = "DevHubBackup",
}
local SCHEMA_VERSION = 2

-- ============ Small utilities ============
local function trim(s)
	return string.match(s or "", "^%s*(.-)%s*$") or ""
end

local function countLines(text)
	local _, n = string.gsub(text, "\n", "")
	return n + 1
end

-- >>> PURE HELPERS (no Roblox objects used; unit-tested outside Studio)
local Pure = {}

-- Cuts a string into pieces of at most maxBytes without ever splitting a
-- multi-byte UTF-8 character. table.concat(pieces) always equals the input.
function Pure.splitString(s, maxBytes)
	local pieces = {}
	local pos, len = 1, #s
	while pos <= len do
		local stop = math.min(pos + maxBytes - 1, len)
		if stop < len then
			-- step back while the next byte is a UTF-8 continuation byte (10xxxxxx)
			while stop > pos do
				local nextByte = string.byte(s, stop + 1)
				if nextByte and nextByte >= 0x80 and nextByte <= 0xBF then
					stop = stop - 1
				else
					break
				end
			end
		end
		pieces[#pieces + 1] = string.sub(s, pos, stop)
		pos = stop + 1
	end
	return pieces
end

-- Cuts code into chunks on line boundaries. table.concat(chunks, "\n") always
-- equals the input text. Each chunk stays under maxLines lines / maxChars
-- characters (a single very long line gets a chunk of its own).
function Pure.chunkText(text, maxLines, maxChars)
	local lines = string.split(text, "\n")
	local chunks = {}
	local buffer, bufferChars = {}, 0
	for _, line in ipairs(lines) do
		local cost = #line + 1
		if #buffer > 0 and (#buffer >= maxLines or bufferChars + cost > maxChars) then
			chunks[#chunks + 1] = table.concat(buffer, "\n")
			buffer, bufferChars = {}, 0
		end
		buffer[#buffer + 1] = line
		bufferChars = bufferChars + cost
	end
	chunks[#chunks + 1] = table.concat(buffer, "\n")
	return chunks
end

function Pure.lineNumberText(first, count)
	local parts = table.create(count)
	for i = 1, count do parts[i] = tostring(first + i - 1) end
	return table.concat(parts, "\n")
end

-- <<< PURE HELPERS

local function timeAgo(t)
	if not t or t <= 0 then return "unknown date" end
	local d = os.time() - t
	if d < 60 then return "just now" end
	if d < 3600 then return math.floor(d / 60) .. "m ago" end
	if d < 86400 then return math.floor(d / 3600) .. "h ago" end
	if d < 86400 * 30 then return math.floor(d / 86400) .. "d ago" end
	return os.date("%Y-%m-%d", t)
end

local function getSetting(key, default)
	local ok, v = pcall(function() return plugin:GetSetting(key) end)
	if ok and v ~= nil then return v end
	return default
end

local function setSetting(key, value)
	local ok, err = pcall(function() plugin:SetSetting(key, value) end)
	if not ok then warn(LOG .. "Could not save setting " .. key .. ": " .. tostring(err)) end
	return ok, err
end

local function getMode()
	local m = getSetting(K.MODE, "plugin")
	if m == "plugin" or m == "place" then return m end
	return "plugin"
end

local function modeLabel(mode)
	return mode == "plugin" and "Plugin settings" or "This place"
end

-- ============ Storage ============
local function backupKeyFor(mode)
	return mode == "place" and (K.BACKUP .. "_Place") or K.BACKUP
end

-- A single StringValue refuses very long strings ("Unable to assign property
-- Value. Provided string length ..."). Big data is therefore stored as a Folder
-- of numbered StringValues (Part_0001, Part_0002, ...) and joined when read.
-- Data saved by older versions as ONE StringValue is still read correctly.
local Parts = { BYTES = 100000 }

function Parts.read(container, name)
	local node = container:FindFirstChild(name)
	if not node then return nil, "missing" end
	if node:IsA("StringValue") then return node.Value end -- older single-value format
	if not node:IsA("Folder") then return nil, "'" .. name .. "' is not a folder or text value" end

	local parts = {}
	for _, child in ipairs(node:GetChildren()) do
		if child:IsA("StringValue") then
			local index = tonumber(string.match(child.Name, "^Part_(%d+)$"))
			if index then parts[#parts + 1] = { index = index, value = child.Value } end
		end
	end
	table.sort(parts, function(a, b) return a.index < b.index end)

	local expectedParts = node:GetAttribute("Parts")
	if type(expectedParts) == "number" and #parts ~= expectedParts then
		return nil, string.format("incomplete: found %d of %d parts", #parts, expectedParts)
	end
	local pieces = table.create(#parts)
	for i, part in ipairs(parts) do
		if part.index ~= i then return nil, "incomplete: part " .. i .. " is missing" end
		pieces[i] = part.value
	end
	local joined = table.concat(pieces)
	local expectedLength = node:GetAttribute("Length")
	if type(expectedLength) == "number" and #joined ~= expectedLength then
		return nil, string.format("incomplete: expected %d bytes, found %d", expectedLength, #joined)
	end
	return joined
end

-- Builds the new copy first and removes the old one only afterwards, so a
-- failed write never destroys existing data.
function Parts.write(container, name, data)
	local pieces = Pure.splitString(data, Parts.BYTES)
	if #pieces == 0 then pieces[1] = "" end
	local folder = Instance.new("Folder")
	folder.Name = name
	for i, piece in ipairs(pieces) do
		local sv = Instance.new("StringValue")
		sv.Name = string.format("Part_%04d", i)
		sv.Value = piece
		sv.Parent = folder
	end
	folder:SetAttribute("Parts", #pieces)
	folder:SetAttribute("Length", #data)
	folder:SetAttribute("Saved", os.time())
	local old = container:FindFirstChild(name)
	if old then old:Destroy() end
	folder.Parent = container
	return #pieces
end

local function readRaw(mode)
	if mode == "place" then
		return pcall(function()
			local value, problem = Parts.read(ServerStorage, K.PLACE)
			if value ~= nil then return value end
			if problem ~= "missing" then error(problem, 0) end
			-- v4.x stored place data as an attribute on game; still readable.
			return game:GetAttribute(K.STORAGE)
		end)
	end
	return pcall(function() return plugin:GetSetting(K.STORAGE) end)
end

local function writeRaw(mode, encoded)
	if mode == "place" then
		return pcall(function() Parts.write(ServerStorage, K.PLACE, encoded) end)
	end
	return pcall(function() plugin:SetSetting(K.STORAGE, encoded) end)
end

local function decodeStoredData(raw)
	if type(raw) == "table" then
		return raw -- v4.0 plugin settings may contain a Lua table
	elseif type(raw) == "string" and raw ~= "" then
		local ok, decoded = pcall(function() return HttpService:JSONDecode(raw) end)
		if ok and type(decoded) == "table" then
			if type(decoded.projects) == "table" then return decoded.projects end
			return decoded
		end
		return nil, "Stored project data is not valid JSON"
	end
	return {}
end

local function normalizeProjects(data)
	local normalized = {}
	for name, value in pairs(data) do
		if type(name) == "string" and name ~= "" then
			if type(value) == "string" then
				-- v4.0 legacy format: project name -> code string
				normalized[name] = { code = value, snapshots = {}, created = 0, modified = 0, schemaVersion = SCHEMA_VERSION }
			elseif type(value) == "table" then
				local safeSnapshots = {}
				if type(value.snapshots) == "table" then
					for _, snap in ipairs(value.snapshots) do
						if type(snap) == "table" and type(snap.code) == "string" then
							table.insert(safeSnapshots, {
								time = tonumber(snap.time) or os.time(),
								description = type(snap.description) == "string" and snap.description or "Snapshot",
								code = snap.code,
							})
						end
					end
				end
				local lastSnapTime = #safeSnapshots > 0 and safeSnapshots[#safeSnapshots].time or 0
				local created = tonumber(value.created) or 0
				normalized[name] = {
					code = type(value.code) == "string" and value.code or "",
					snapshots = safeSnapshots,
					created = created,
					modified = tonumber(value.modified) or math.max(created, lastSnapTime),
					schemaVersion = SCHEMA_VERSION,
				}
			end
		end
	end
	return normalized
end

local function loadData(mode)
	mode = mode or getMode()
	local ok, raw = readRaw(mode)
	local decoded, decodeErr
	if ok then
		decoded, decodeErr = decodeStoredData(raw)
	else
		decodeErr = "Load failed: " .. tostring(raw)
	end
	if not decoded then
		warn(LOG .. tostring(decodeErr) .. ". Trying the last backup.")
		local backupOk, backupRaw = pcall(function() return plugin:GetSetting(backupKeyFor(mode)) end)
		if backupOk then
			local backup = decodeStoredData(backupRaw)
			if backup then return normalizeProjects(backup) end
		end
		return {}
	end
	return normalizeProjects(decoded)
end

local function saveData(data, mode)
	mode = mode or getMode()
	local okEncode, encoded = pcall(function()
		return HttpService:JSONEncode({ schemaVersion = SCHEMA_VERSION, projects = data })
	end)
	if not okEncode then
		warn(LOG .. "Encoding failed: " .. tostring(encoded))
		return false, "Could not encode project data"
	end
	-- Keep a last-known-good backup before replacing the main data.
	local readOk, previous = readRaw(mode)
	if readOk and previous ~= nil then
		local previousEncoded
		if type(previous) == "string" then
			previousEncoded = previous
		else
			local encodeOk, value = pcall(function() return HttpService:JSONEncode(previous) end)
			if encodeOk then previousEncoded = value end
		end
		if previousEncoded and previousEncoded ~= "" then
			pcall(function() plugin:SetSetting(backupKeyFor(mode), previousEncoded) end)
		end
	end

	local writeOk, writeErr = writeRaw(mode, encoded)
	if writeOk then
		local verifyOk, verify = readRaw(mode)
		if not (verifyOk and verify == encoded) then
			writeOk = false
			writeErr = "verification failed"
		end
	end
	if not writeOk then
		warn(LOG .. "Save failed: " .. tostring(writeErr))
		return false, "Save failed: " .. tostring(writeErr)
	end
	return true
end

-- ============ UI helpers ============
local function new(class, props, parent)
	local obj = Instance.new(class)
	for k, v in pairs(props) do
		if v ~= nil then obj[k] = v end
	end
	obj.Parent = parent
	return obj
end

local function corner(obj, radius)
	return new("UICorner", { CornerRadius = UDim.new(0, radius or 6) }, obj)
end

local function stroke(obj, color, thickness)
	return new("UIStroke", {
		Color = color or Theme.border,
		Thickness = thickness or 1,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, obj)
end

local function pad(obj, l, r, t, b)
	return new("UIPadding", {
		PaddingLeft = UDim.new(0, l or 0),
		PaddingRight = UDim.new(0, r or l or 0),
		PaddingTop = UDim.new(0, t or 0),
		PaddingBottom = UDim.new(0, b or t or 0),
	}, obj)
end

local function label(parent, text, props)
	local p = {
		Text = text,
		BackgroundTransparency = 1,
		TextColor3 = Theme.text,
		Font = Enum.Font.Gotham,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
		BorderSizePixel = 0,
	}
	if props then for k, v in pairs(props) do p[k] = v end end
	return new("TextLabel", p, parent)
end

local BUTTON_STYLES = {
	primary   = { bg = Theme.accent,     hover = Theme.accentHover },
	secondary = { bg = Theme.surfaceAlt, hover = Theme.surfaceHover },
	danger    = { bg = Theme.danger,     hover = Theme.dangerHover },
	ghost     = { bg = Theme.surface,    hover = Theme.surfaceHover },
}

local function makeButton(parent, text, style, props)
	local s = BUTTON_STYLES[style or "secondary"]
	local btn = new("TextButton", {
		Text = text,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.new(0, 0, 0, 30),
		BackgroundColor3 = s.bg,
		TextColor3 = Theme.text,
		Font = Enum.Font.GothamMedium,
		TextSize = 13,
		AutoButtonColor = false,
		BorderSizePixel = 0,
	}, parent)
	pad(btn, 12, 12, 0, 0)
	corner(btn, 6)
	if props then for k, v in pairs(props) do btn[k] = v end end
	btn.MouseEnter:Connect(function()
		TweenService:Create(btn, TweenInfo.new(0.1), { BackgroundColor3 = s.hover }):Play()
	end)
	btn.MouseLeave:Connect(function()
		TweenService:Create(btn, TweenInfo.new(0.1), { BackgroundColor3 = s.bg }):Play()
	end)
	return btn
end

local function setButtonEnabled(btn, enabled)
	btn.Interactable = enabled
	btn.TextTransparency = enabled and 0 or 0.6
end

-- Every button the plugin keeps a reference to lives in `Btn` (see the local-variable limit note above).
local Btn = {}
local _, edTitle, historyTitle, diffTitle

-- ============ Toolbar + widget ============
local toolbar = plugin:CreateToolbar("DevHub")
local openButton = toolbar:CreateButton("DevHub", "Open DevHub", "")
openButton.ClickableWhenViewportHidden = true

local widgetInfo = DockWidgetPluginGuiInfo.new(
	Enum.InitialDockState.Right,
	true,
	false,
	520,
	720,
	340,
	380
)
local widget = plugin:CreateDockWidgetPluginGui("DevHubWidget", widgetInfo)
widget.Title = "DevHub | Roblox Project Workspace"
widget.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

-- ============ Root + chrome ============
-- With ZIndexBehavior.Sibling, ZIndex only matters between siblings.
-- Everything that must overlap (views, dialog, toast) is therefore a DIRECT
-- child of root, created in stacking order: later = on top.
local root = new("Frame", {
	Size = UDim2.new(1, 0, 1, 0),
	BackgroundColor3 = Theme.bg,
	BorderSizePixel = 0,
}, widget)

new("Frame", {
	Name = "AccentBar",
	Size = UDim2.new(1, 0, 0, TOP_BAR),
	BackgroundColor3 = Theme.accent,
	BorderSizePixel = 0,
}, root)

-- ---- Home header ----
local header = new("Frame", {
	Name = "Header",
	Size = UDim2.new(1, 0, 0, HEADER_H),
	Position = UDim2.new(0, 0, 0, TOP_BAR),
	BackgroundColor3 = Theme.surface,
	BorderSizePixel = 0,
}, root)

local headerTitle = label(header, "DevHub", {
	Position = UDim2.new(0, 14, 0, 0),
	Size = UDim2.new(0, 90, 1, 0),
	Font = Enum.Font.GothamBold,
	TextSize = 18,
})

local headerButtons = new("Frame", {
	AnchorPoint = Vector2.new(1, 0.5),
	Position = UDim2.new(1, -10, 0.5, 0),
	Size = UDim2.new(0, 0, 0, 30),
	AutomaticSize = Enum.AutomaticSize.X,
	BackgroundTransparency = 1,
}, header)
new("UIListLayout", {
	FillDirection = Enum.FillDirection.Horizontal,
	Padding = UDim.new(0, 6),
	SortOrder = Enum.SortOrder.LayoutOrder,
	VerticalAlignment = Enum.VerticalAlignment.Center,
}, headerButtons)

Btn.new = makeButton(headerButtons, "+ New", "primary", { LayoutOrder = 1 })
Btn.import = makeButton(headerButtons, "Import", "secondary", { LayoutOrder = 2 })
Btn.settings = makeButton(headerButtons, "Settings", "secondary", { LayoutOrder = 3 })

new("Frame", {
	Size = UDim2.new(1, 0, 0, 1),
	Position = UDim2.new(0, 0, 1, -1),
	BackgroundColor3 = Theme.border,
	BorderSizePixel = 0,
}, header)

-- ---- Home view ----
local homeView = new("Frame", {
	Name = "HomeView",
	Size = UDim2.new(1, 0, 1, -(TOP_BAR + HEADER_H + STATUS_H)),
	Position = UDim2.new(0, 0, 0, TOP_BAR + HEADER_H),
	BackgroundTransparency = 1,
}, root)

local searchRow = new("Frame", {
	Size = UDim2.new(1, -20, 0, 34),
	Position = UDim2.new(0, 10, 0, 10),
	BackgroundTransparency = 1,
}, homeView)

local projectSearch = new("TextBox", {
	Name = "ProjectSearch",
	PlaceholderText = "Search projects...",
	PlaceholderColor3 = Theme.textDim,
	Text = "",
	ClearTextOnFocus = false,
	Size = UDim2.new(1, -118, 1, 0),
	BackgroundColor3 = Theme.surface,
	TextColor3 = Theme.text,
	Font = Enum.Font.Gotham,
	TextSize = 13,
	TextXAlignment = Enum.TextXAlignment.Left,
	BorderSizePixel = 0,
}, searchRow)
corner(projectSearch, 7)
stroke(projectSearch)
pad(projectSearch, 12, 8, 0, 0)

Btn.sort = makeButton(searchRow, "Sort: Recent", "secondary", {
	AutomaticSize = Enum.AutomaticSize.None,
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, 0, 0, 0),
	Size = UDim2.new(0, 110, 1, 0),
})

local projectList = new("ScrollingFrame", {
	Name = "ProjectList",
	Size = UDim2.new(1, -20, 1, -62),
	Position = UDim2.new(0, 10, 0, 52),
	BackgroundColor3 = Theme.surface,
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	CanvasSize = UDim2.new(),
	ScrollBarThickness = 6,
	ScrollBarImageColor3 = Theme.accent,
	ScrollingDirection = Enum.ScrollingDirection.Y,
	BorderSizePixel = 0,
}, homeView)
corner(projectList, 8)
stroke(projectList)
new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 6) }, projectList)
pad(projectList, 8, 14, 8, 8)

-- ---- Sub header helper (editor, settings, history, diff) ----
local function makeSubHeader(parent, title, backText)
	local h = new("Frame", {
		Size = UDim2.new(1, 0, 0, HEADER_H),
		BackgroundColor3 = Theme.surface,
		BorderSizePixel = 0,
	}, parent)
	local back = makeButton(h, backText or "< Back", "secondary", {
		AutomaticSize = Enum.AutomaticSize.None,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 10, 0.5, 0),
		Size = UDim2.new(0, 76, 0, 30),
	})
	local titleLabel = label(h, title, {
		Position = UDim2.new(0, 96, 0, 0),
		Size = UDim2.new(1, -106, 1, 0),
		Font = Enum.Font.GothamBold,
		TextSize = 15,
		TextTruncate = Enum.TextTruncate.AtEnd,
	})
	new("Frame", {
		Size = UDim2.new(1, 0, 0, 1),
		Position = UDim2.new(0, 0, 1, -1),
		BackgroundColor3 = Theme.border,
		BorderSizePixel = 0,
	}, h)
	return h, back, titleLabel
end

-- ---- Settings view ----
local settingsView = new("Frame", {
	Name = "SettingsView",
	Size = UDim2.new(1, 0, 1, -(TOP_BAR + STATUS_H)),
	Position = UDim2.new(0, 0, 0, TOP_BAR),
	BackgroundColor3 = Theme.bg,
	BorderSizePixel = 0,
	Visible = false,
}, root)
_, Btn.settingsBack = makeSubHeader(settingsView, "Settings")

local settingsScroll = new("ScrollingFrame", {
	Size = UDim2.new(1, -20, 1, -(HEADER_H + 10)),
	Position = UDim2.new(0, 10, 0, HEADER_H + 10),
	BackgroundTransparency = 1,
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	CanvasSize = UDim2.new(),
	ScrollBarThickness = 6,
	ScrollBarImageColor3 = Theme.accent,
	BorderSizePixel = 0,
}, settingsView)
new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 8) }, settingsScroll)
pad(settingsScroll, 0, 10, 0, 12)

local settingsOrder = 0
local function settingsSection(title)
	settingsOrder = settingsOrder + 1
	label(settingsScroll, string.upper(title), {
		Size = UDim2.new(1, 0, 0, 22),
		TextColor3 = Theme.textDim,
		Font = Enum.Font.GothamBold,
		TextSize = 11,
		LayoutOrder = settingsOrder,
	})
end

local function settingsRow(title, description, buttonText, style)
	settingsOrder = settingsOrder + 1
	local row = new("Frame", {
		Size = UDim2.new(1, 0, 0, 92),
		BackgroundColor3 = Theme.surface,
		BorderSizePixel = 0,
		LayoutOrder = settingsOrder,
	}, settingsScroll)
	corner(row, 8)
	stroke(row)
	label(row, title, {
		Position = UDim2.new(0, 14, 0, 10),
		Size = UDim2.new(1, -176, 0, 18),
		Font = Enum.Font.GothamMedium,
		TextSize = 14,
	})
	label(row, description, {
		Position = UDim2.new(0, 14, 0, 30),
		Size = UDim2.new(1, -176, 0, 56),
		TextColor3 = Theme.textDim,
		TextSize = 12,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
	})
	local btn = makeButton(row, buttonText, style or "secondary", {
		AutomaticSize = Enum.AutomaticSize.None,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -14, 0.5, 0),
		Size = UDim2.new(0, 140, 0, 32),
	})
	return btn
end

settingsSection("Storage")
Btn.storage = settingsRow(
	"Storage location",
	"Plugin settings: private to you, shared across every place on this computer. This place: saved inside the place file (ServerStorage > DevHubData) so teammates can see it.",
	"Plugin settings"
)
Btn.copy = settingsRow(
	"Copy to other storage",
	"Copies every project to the other storage location. Projects whose names already exist there are skipped, never overwritten.",
	"Copy projects"
)
settingsSection("Behavior")
Btn.prompt = settingsRow(
	"Offer to save scripts on close",
	"When you close a script tab in Studio, DevHub asks if you want to keep a copy as a project.",
	"Off"
)
settingsSection("Backup")
Btn.export = settingsRow(
	"Export backup to this place",
	"Writes all projects into ServerStorage > DevHubBackup so they travel with the place file. Large libraries are split into several parts automatically.",
	"Export backup"
)
Btn.importBackup = settingsRow(
	"Import backup from this place",
	"Reads ServerStorage > DevHubBackup and adds its projects. Name clashes are imported as 'Name (2)', so nothing is lost.",
	"Import backup"
)
settingsSection("About")
settingsOrder = settingsOrder + 1
label(settingsScroll, "DevHub v" .. VERSION .. "  |  An open-source, GitHub-style project workspace for Roblox developers. Not affiliated with or endorsed by GitHub or Roblox.", {
	Size = UDim2.new(1, 0, 0, 52),
	TextColor3 = Theme.textDim,
	TextSize = 12,
	TextWrapped = true,
	TextYAlignment = Enum.TextYAlignment.Top,
	LayoutOrder = settingsOrder,
})

-- ---- Editor view ----
local editorView = new("Frame", {
	Name = "EditorView",
	Size = UDim2.new(1, 0, 1, -(TOP_BAR + STATUS_H)),
	Position = UDim2.new(0, 0, 0, TOP_BAR),
	BackgroundColor3 = Theme.bg,
	BorderSizePixel = 0,
	Visible = false,
}, root)

_, Btn.back, edTitle = makeSubHeader(editorView, "Editing")

local actionsBar = new("Frame", {
	Name = "ActionsBar",
	Size = UDim2.new(1, 0, 0, 46),
	Position = UDim2.new(0, 0, 0, HEADER_H),
	BackgroundColor3 = Theme.surfaceAlt,
	BorderSizePixel = 0,
}, editorView)
local actionsLayout = new("UIListLayout", {
	FillDirection = Enum.FillDirection.Horizontal,
	Wraps = true,
	Padding = UDim.new(0, 6),
	SortOrder = Enum.SortOrder.LayoutOrder,
	VerticalAlignment = Enum.VerticalAlignment.Top,
}, actionsBar)
pad(actionsBar, 10, 10, 8, 8)

Btn.save = makeButton(actionsBar, "Save", "primary", { LayoutOrder = 1 })
Btn.undo = makeButton(actionsBar, "Undo", "secondary", { LayoutOrder = 2 })
Btn.redo = makeButton(actionsBar, "Redo", "secondary", { LayoutOrder = 3 })
Btn.snap = makeButton(actionsBar, "Snapshot", "secondary", { LayoutOrder = 4 })
Btn.history = makeButton(actionsBar, "History", "secondary", { LayoutOrder = 5 })
Btn.pull = makeButton(actionsBar, "Pull", "secondary", { LayoutOrder = 6 })
Btn.push = makeButton(actionsBar, "Push", "secondary", { LayoutOrder = 7 })
Btn.rename = makeButton(actionsBar, "Rename", "secondary", { LayoutOrder = 8 })
Btn.delete = makeButton(actionsBar, "Delete", "danger", { LayoutOrder = 9 })

local body = new("Frame", {
	Name = "EditorBody",
	Size = UDim2.new(1, 0, 1, -(HEADER_H + 46)),
	Position = UDim2.new(0, 0, 0, HEADER_H + 46),
	BackgroundColor3 = Theme.codeBg,
	BorderSizePixel = 0,
}, editorView)

local GUTTER_W = 52
local CODE_FONT = Enum.Font.Code
local CODE_SIZE = 14

local gutter = new("Frame", {
	Size = UDim2.new(0, GUTTER_W, 1, 0),
	BackgroundColor3 = Theme.gutter,
	BorderSizePixel = 0,
	ClipsDescendants = true,
}, body)
-- Holds one line-number label per code chunk and slides with the scroll position.
local gutterInner = new("Frame", {
	Size = UDim2.new(1, 0, 0, 0),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
}, gutter)

local codeScroll = new("ScrollingFrame", {
	Size = UDim2.new(1, -GUTTER_W, 1, 0),
	Position = UDim2.new(0, GUTTER_W, 0, 0),
	BackgroundTransparency = 1,
	ScrollBarThickness = 8,
	ScrollBarImageColor3 = Theme.accent,
	ScrollingDirection = Enum.ScrollingDirection.XY,
	AutomaticCanvasSize = Enum.AutomaticSize.None,
	CanvasSize = UDim2.new(),
	BorderSizePixel = 0,
}, body)

-- Roblox text boxes only draw about 16,000 characters, so the code is shown as a
-- stack of smaller text boxes ("chunks"). This invisible button sits behind them:
-- clicking the empty area below the code puts the cursor at the end.
local clickPad = new("TextButton", {
	Text = "",
	AutoButtonColor = false,
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	Size = UDim2.new(1, 0, 1, 0),
	ZIndex = 1,
}, codeScroll)

-- ---- History panel ----
local historyPanel = new("Frame", {
	Name = "HistoryPanel",
	Size = UDim2.new(1, 0, 1, 0),
	BackgroundColor3 = Theme.bg,
	BorderSizePixel = 0,
	Visible = false,
}, editorView)
_, Btn.historyClose, historyTitle = makeSubHeader(historyPanel, "History", "Close")
local historyScroll = new("ScrollingFrame", {
	Size = UDim2.new(1, -20, 1, -(HEADER_H + 20)),
	Position = UDim2.new(0, 10, 0, HEADER_H + 10),
	BackgroundColor3 = Theme.surface,
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	CanvasSize = UDim2.new(),
	ScrollBarThickness = 6,
	ScrollBarImageColor3 = Theme.accent,
	BorderSizePixel = 0,
}, historyPanel)
corner(historyScroll, 8)
stroke(historyScroll)
new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 6) }, historyScroll)
pad(historyScroll, 8, 14, 8, 8)

-- ---- Diff panel ----
local diffPanel = new("Frame", {
	Name = "DiffPanel",
	Size = UDim2.new(1, 0, 1, 0),
	BackgroundColor3 = Theme.bg,
	BorderSizePixel = 0,
	Visible = false,
}, editorView)
_, Btn.diffClose, diffTitle = makeSubHeader(diffPanel, "Diff", "Close")
local diffSummary = label(diffPanel, "", {
	Position = UDim2.new(0, 14, 0, HEADER_H + 6),
	Size = UDim2.new(1, -28, 0, 22),
	TextColor3 = Theme.textDim,
	TextSize = 12,
})
local diffScroll = new("ScrollingFrame", {
	Size = UDim2.new(1, -20, 1, -(HEADER_H + 40)),
	Position = UDim2.new(0, 10, 0, HEADER_H + 32),
	BackgroundColor3 = Theme.codeBg,
	AutomaticCanvasSize = Enum.AutomaticSize.None,
	CanvasSize = UDim2.new(),
	ScrollBarThickness = 8,
	ScrollBarImageColor3 = Theme.accent,
	ScrollingDirection = Enum.ScrollingDirection.XY,
	BorderSizePixel = 0,
}, diffPanel)
corner(diffScroll, 8)
stroke(diffScroll)

-- ---- Status bar ----
local statusBar = new("Frame", {
	Name = "StatusBar",
	Size = UDim2.new(1, 0, 0, STATUS_H),
	Position = UDim2.new(0, 0, 1, -STATUS_H),
	BackgroundColor3 = Theme.surface,
	BorderSizePixel = 0,
}, root)
new("Frame", {
	Size = UDim2.new(1, 0, 0, 1),
	BackgroundColor3 = Theme.border,
	BorderSizePixel = 0,
}, statusBar)
local statusLeft = label(statusBar, "", {
	Position = UDim2.new(0, 12, 0, 0),
	Size = UDim2.new(1, -90, 1, 0),
	TextColor3 = Theme.textDim,
	TextSize = 12,
	TextTruncate = Enum.TextTruncate.AtEnd,
})
label(statusBar, "v" .. VERSION, {
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, -12, 0, 0),
	Size = UDim2.new(0, 60, 1, 0),
	TextColor3 = Theme.textDim,
	TextSize = 12,
	TextXAlignment = Enum.TextXAlignment.Right,
})

-- ---- Modal dialog (always above every view) ----
local overlay = new("Frame", {
	Name = "DialogOverlay",
	Size = UDim2.new(1, 0, 1, 0),
	BackgroundColor3 = Color3.new(0, 0, 0),
	BackgroundTransparency = 0.45,
	BorderSizePixel = 0,
	Active = true,
	Visible = false,
}, root)
local dialogPanel = new("Frame", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.new(0.5, 0, 0.5, 0),
	Size = UDim2.new(0.9, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundColor3 = Theme.surface,
	BorderSizePixel = 0,
}, overlay)
corner(dialogPanel, 10)
stroke(dialogPanel, Theme.accent)
new("UISizeConstraint", { MaxSize = Vector2.new(400, math.huge) }, dialogPanel)
new("UIListLayout", { Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder }, dialogPanel)
pad(dialogPanel, 16, 16, 16, 16)

local dlgTitle = label(dialogPanel, "", {
	Size = UDim2.new(1, 0, 0, 22),
	Font = Enum.Font.GothamBold,
	TextSize = 16,
	LayoutOrder = 1,
})
local dlgMessage = label(dialogPanel, "", {
	Size = UDim2.new(1, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	TextColor3 = Theme.textDim,
	TextWrapped = true,
	TextYAlignment = Enum.TextYAlignment.Top,
	LayoutOrder = 2,
})
local dlgInput = new("TextBox", {
	PlaceholderColor3 = Theme.textDim,
	Text = "",
	ClearTextOnFocus = false,
	Size = UDim2.new(1, 0, 0, 34),
	BackgroundColor3 = Theme.bg,
	TextColor3 = Theme.text,
	Font = Enum.Font.Gotham,
	TextSize = 14,
	TextXAlignment = Enum.TextXAlignment.Left,
	BorderSizePixel = 0,
	LayoutOrder = 3,
	Visible = false,
}, dialogPanel)
corner(dlgInput, 6)
stroke(dlgInput)
pad(dlgInput, 10, 10, 0, 0)
local dlgButtons = new("Frame", {
	Size = UDim2.new(1, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundTransparency = 1,
	LayoutOrder = 4,
}, dialogPanel)
local dlgButtonLayout = new("UIListLayout", {
	Padding = UDim.new(0, 8),
	SortOrder = Enum.SortOrder.LayoutOrder,
}, dlgButtons)

-- ---- Toast ----
local toast = new("Frame", {
	Name = "Toast",
	AnchorPoint = Vector2.new(0.5, 1),
	Position = UDim2.new(0.5, 0, 1, -(STATUS_H + 10)),
	Size = UDim2.new(1, -24, 0, 38),
	BackgroundColor3 = Theme.surfaceAlt,
	BorderSizePixel = 0,
	Visible = false,
	ZIndex = 100,
}, root)
corner(toast, 8)
stroke(toast)
new("UISizeConstraint", { MaxSize = Vector2.new(460, 38) }, toast)
local toastBar = new("Frame", {
	Size = UDim2.new(0, 4, 1, -12),
	Position = UDim2.new(0, 6, 0, 6),
	BackgroundColor3 = Theme.accent,
	BorderSizePixel = 0,
	ZIndex = 101,
}, toast)
corner(toastBar, 2)
local toastLabel = label(toast, "", {
	Position = UDim2.new(0, 20, 0, 0),
	Size = UDim2.new(1, -30, 1, 0),
	TextSize = 13,
	TextTruncate = Enum.TextTruncate.AtEnd,
	ZIndex = 101,
})

-- ============ App state ============
local projects = loadData(getMode())
local currentProject = nil
local currentView = "home"
local sortMode = getSetting(K.SORT, "recent")
local undoStack, redoStack = {}, {}
local isApplyingEditorState = false
local lastEditorText = ""
local savedEditorText = ""
local lastEditTime = 0
local isDirty = false
local recoveryWriteToken = 0

-- forward declarations
local refreshProjectList, openProject, leaveEditor, refreshSettings, refreshEditorChrome

-- ============ Toast + status ============
local toastToken = 0
local function notify(text, kind, duration)
	toastToken = toastToken + 1
	local myToken = toastToken
	local color = Theme.accent
	if kind == "success" then color = Theme.success
	elseif kind == "error" then color = Theme.danger
	elseif kind == "warn" then color = Theme.warning end
	toastBar.BackgroundColor3 = color
	toastLabel.Text = text
	toast.Visible = true
	task.delay(duration or (kind == "error" and 4.5 or 2.6), function()
		if myToken == toastToken then toast.Visible = false end
	end)
end

local function setStatus(text)
	statusLeft.Text = text or ""
end

-- ============ Dialog system ============
local dialogToken = 0
local dialogPrimary = nil

local function showDialog(opts)
	dialogToken = dialogToken + 1
	local myToken = dialogToken
	dlgTitle.Text = opts.title or ""
	dlgMessage.Text = opts.message or ""
	dlgMessage.Visible = opts.message ~= nil and opts.message ~= ""
	if opts.input then
		dlgInput.Visible = true
		dlgInput.PlaceholderText = opts.input.placeholder or ""
		dlgInput.Text = opts.input.default or ""
	else
		dlgInput.Visible = false
		dlgInput.Text = ""
	end

	for _, child in ipairs(dlgButtons:GetChildren()) do
		if child:IsA("TextButton") then child:Destroy() end
	end

	local defs = opts.buttons
	local horizontal = #defs <= 2
	dlgButtonLayout.FillDirection = horizontal and Enum.FillDirection.Horizontal or Enum.FillDirection.Vertical
	dialogPrimary = nil

	for i, def in ipairs(defs) do
		local size
		if #defs == 2 then size = UDim2.new(0.5, -4, 0, 34) else size = UDim2.new(1, 0, 0, 34) end
		local b = makeButton(dlgButtons, def.text, def.style or "secondary", {
			AutomaticSize = Enum.AutomaticSize.None,
			Size = size,
			LayoutOrder = i,
			TextTruncate = Enum.TextTruncate.AtEnd,
		})
		local function run()
			if myToken ~= dialogToken then return end
			local keepOpen = false
			if def.onClick then
				keepOpen = (def.onClick(dlgInput.Text) == false)
			end
			if not keepOpen and myToken == dialogToken then
				overlay.Visible = false
			end
		end
		b.MouseButton1Click:Connect(run)
		if not dialogPrimary and (def.style == "primary" or def.style == "danger") then
			dialogPrimary = run
		end
	end

	overlay.Visible = true
	if opts.input then
		task.defer(function()
			if myToken == dialogToken then dlgInput:CaptureFocus() end
		end)
	end
end

dlgInput.FocusLost:Connect(function(enterPressed)
	if enterPressed and overlay.Visible and dialogPrimary then
		dialogPrimary()
	end
end)

local function confirmDialog(title, message, confirmText, onYes, danger)
	showDialog({
		title = title,
		message = message,
		buttons = {
			{ text = "Cancel" },
			{ text = confirmText or "Confirm", style = danger and "danger" or "primary", onClick = function() onYes() end },
		},
	})
end

-- ============ View switching ============
local function showView(name)
	currentView = name
	header.Visible = name == "home"
	homeView.Visible = name == "home"
	settingsView.Visible = name == "settings"
	editorView.Visible = name == "editor"
	if name ~= "editor" then
		historyPanel.Visible = false
		diffPanel.Visible = false
	end
end

-- ============ Data helpers ============
local function persist()
	local ok, err = saveData(projects, getMode())
	if not ok then notify(err or "Save failed", "error") end
	return ok
end

local function newProjectRecord(code)
	local now = os.time()
	return { code = code or "", snapshots = {}, created = now, modified = now, schemaVersion = SCHEMA_VERSION }
end

local function uniqueName(base)
	if not projects[base] then return base end
	local i = 2
	while projects[base .. " (" .. i .. ")"] do i = i + 1 end
	return base .. " (" .. i .. ")"
end

local function validateName(name, ignore)
	if name == "" then return false, "Enter a project name" end
	if #name > 80 then return false, "Name is too long (80 characters max)" end
	if projects[name] and name ~= ignore then return false, "A project named '" .. name .. "' already exists" end
	return true
end

local function snapshotCount(p)
	return p.snapshots and #p.snapshots or 0
end

-- ============ Studio script helpers ============
local function getSelectedScripts()
	local out = {}
	for _, obj in ipairs(Selection:Get()) do
		if obj:IsA("LuaSourceContainer") then table.insert(out, obj) end
	end
	return out
end

local function getSource(scr)
	local okDoc, text = pcall(function()
		local doc = ScriptEditorService:FindScriptDocument(scr)
		if doc then return doc:GetText() end
		return nil
	end)
	if okDoc and type(text) == "string" then return text end
	return scr.Source
end

local function writeSource(scr, text)
	pcall(function() ChangeHistoryService:SetWaypoint("DevHub: before push") end)
	local ok = pcall(function()
		ScriptEditorService:UpdateSourceAsync(scr, function() return text end)
	end)
	if not ok then
		local ok2, err = pcall(function() scr.Source = text end)
		if not ok2 then return false, tostring(err) end
	end
	pcall(function() ChangeHistoryService:SetWaypoint("DevHub: push") end)
	return true
end

-- ============ Editor core ============
local TEXT_BIG = Vector2.new(100000, 100000)

-- ---- Chunked code editor ----
-- The code lives in `Editor.chunks`: a list of { text, lines, width, box, nums }.
-- The full text is always table.concat(chunk texts, "\n"). Each chunk is its own
-- TextBox (small enough to draw completely) with its own line-number label.
local Editor = {
	CHUNK_LINES = 150,  -- target size when (re)building chunks
	CHUNK_CHARS = 8000,
	HARD_LINES = 400,   -- a chunk that grows past this is split again
	HARD_CHARS = 12000,
	TOP_PAD = 6,
	LINE_H = CODE_SIZE + 2,
	caretLine = 1,
	caretCol = 1,
	chunks = {},
	focused = nil,   -- the chunk whose box has keyboard focus
	cached = nil,    -- cached full text (nil = needs rebuilding)
	suppress = false, -- true while we change boxes ourselves (ignore their events)
	totalLines = 1,
	onChange = nil,      -- set later: user typed something
	onCaretMoved = nil,  -- set later: cursor moved
	onShortcut = nil,    -- set later: Ctrl+S / Z / Y
}

Editor.LINE_H = (function()
	local ok, size = pcall(function()
		return TextService:GetTextSize(string.rep("A\n", 9) .. "A", CODE_SIZE, CODE_FONT, TEXT_BIG)
	end)
	if ok and size.Y > 0 then return size.Y / 10 end
	return CODE_SIZE + 2
end)()

function Editor.measureWidth(text)
	local ok, size = pcall(function()
		return TextService:GetTextSize(text, CODE_SIZE, CODE_FONT, TEXT_BIG)
	end)
	return ok and size.X or 0
end

function Editor.indexOfChunk(chunk)
	for i, c in ipairs(Editor.chunks) do
		if c == chunk then return i end
	end
	return nil
end

function Editor.focusChunk(chunk, cursor)
	task.defer(function()
		if not chunk.box.Parent then return end
		chunk.box:CaptureFocus()
		chunk.box.CursorPosition = math.max(1, math.min(cursor, #chunk.text + 1))
		chunk.box.SelectionStart = -1
	end)
end

function Editor.isFocused()
	return Editor.focused ~= nil and Editor.focused.box:IsFocused()
end

function Editor.getText()
	if Editor.cached then return Editor.cached end
	local parts = table.create(#Editor.chunks)
	for i, c in ipairs(Editor.chunks) do parts[i] = c.text end
	Editor.cached = table.concat(parts, "\n")
	return Editor.cached
end

function Editor.relayout()
	local win = codeScroll.AbsoluteWindowSize
	local maxWidth = 0
	for _, c in ipairs(Editor.chunks) do
		if c.width > maxWidth then maxWidth = c.width end
	end
	local canvasW = math.max(maxWidth + 48, win.X)
	local y, line = Editor.TOP_PAD, 1
	for _, c in ipairs(Editor.chunks) do
		local h = c.lines * Editor.LINE_H
		c.box.Position = UDim2.fromOffset(0, y)
		c.box.Size = UDim2.fromOffset(canvasW, h)
		c.nums.Position = UDim2.fromOffset(0, y)
		c.nums.Size = UDim2.new(1, 0, 0, h)
		if c.numFirst ~= line or c.numCount ~= c.lines then
			c.numFirst, c.numCount = line, c.lines
			c.nums.Text = Pure.lineNumberText(line, c.lines)
		end
		c.startLine = line
		c.top = y
		line = line + c.lines
		y = y + h
	end
	Editor.totalLines = line - 1
	local canvasH = math.max(y + 40, win.Y)
	codeScroll.CanvasSize = UDim2.fromOffset(canvasW, canvasH)
	clickPad.Size = UDim2.fromOffset(canvasW, canvasH)
end

-- Where the cursor is: global line number, column, and position inside its chunk.
function Editor.caretInfo()
	local c = Editor.focused
	if not c or not c.box:IsFocused() then return nil end
	local cur = c.box.CursorPosition
	if not cur or cur < 1 then return nil end
	local before = string.sub(c.text, 1, cur - 1)
	local _, newlines = string.gsub(before, "\n", "")
	local lastNl = string.match(before, ".*()\n")
	return {
		chunk = c,
		line = c.startLine + newlines,
		localLine = newlines,
		col = lastNl and (#before - lastNl + 1) or (#before + 1),
		lineText = string.match(before, "[^\n]*$") or "",
	}
end

function Editor.removeChunk(chunk)
	local idx = Editor.indexOfChunk(chunk)
	if idx then table.remove(Editor.chunks, idx) end
	if Editor.focused == chunk then Editor.focused = nil end
	chunk.box:Destroy()
	chunk.nums:Destroy()
end

-- A chunk grew too big (typing or a big paste): break it into smaller chunks
-- and keep the cursor where it was.
function Editor.resplit(chunk)
	local pieces = Pure.chunkText(chunk.text, Editor.CHUNK_LINES, Editor.CHUNK_CHARS)
	if #pieces <= 1 then return end
	local idx = Editor.indexOfChunk(chunk)
	if not idx then return end
	local cursor = chunk.box.CursorPosition
	local hadFocus = Editor.focused == chunk and cursor and cursor > 0
	local newChunks = {}
	for i, piece in ipairs(pieces) do
		newChunks[i] = Editor.createChunk(piece)
		table.insert(Editor.chunks, idx + i, newChunks[i])
	end
	Editor.removeChunk(chunk)
	if hadFocus then
		local offset = 0
		for i, piece in ipairs(pieces) do
			if cursor <= offset + #piece + 1 or i == #pieces then
				Editor.focusChunk(newChunks[i], cursor - offset)
				break
			end
			offset = offset + #piece + 1
		end
	end
end

function Editor.onChunkEdited(chunk)
	local text = chunk.box.Text
	chunk.text = text
	chunk.lines = countLines(text)
	chunk.width = Editor.measureWidth(text)
	Editor.cached = nil
	if #text > Editor.HARD_CHARS or chunk.lines > Editor.HARD_LINES then
		Editor.resplit(chunk)
	end
	Editor.relayout()
	if Editor.onChange then Editor.onChange() end
end

-- Joins two neighbouring chunks (Backspace / Delete across a chunk border).
function Editor.mergeNeighbours(firstIdx, cursorInMerged)
	local a, b = Editor.chunks[firstIdx], Editor.chunks[firstIdx + 1]
	if not a or not b then return end
	local merged = a.text .. b.text
	if #merged > Editor.HARD_CHARS then return end -- too big to join; leave the border alone
	Editor.suppress = true
	a.box.Text = merged
	Editor.suppress = false
	a.text = merged
	a.lines = countLines(merged)
	a.width = Editor.measureWidth(merged)
	Editor.removeChunk(b)
	Editor.cached = nil
	Editor.relayout()
	Editor.focusChunk(a, cursorInMerged)
	if Editor.onChange then Editor.onChange() end
end

function Editor.isKeyDown(...)
	for _, key in ipairs({ ... }) do
		if UserInputService:IsKeyDown(key) then return true end
	end
	return false
end

-- Lets the arrow keys and Backspace/Delete work across chunk borders, so the
-- editor feels like one continuous text box.
function Editor.onKey(chunk, input)
	if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
	if Editor.onShortcut then Editor.onShortcut(input) end
	if Editor.isKeyDown(Enum.KeyCode.LeftShift, Enum.KeyCode.RightShift, Enum.KeyCode.LeftControl,
		Enum.KeyCode.RightControl, Enum.KeyCode.LeftAlt, Enum.KeyCode.RightAlt,
		Enum.KeyCode.LeftMeta, Enum.KeyCode.RightMeta) then
		return
	end
	local box = chunk.box
	local idx = Editor.indexOfChunk(chunk)
	if not idx then return end
	local text, cursor = box.Text, box.CursorPosition
	if not cursor or cursor < 1 then return end
	if box.SelectionStart ~= -1 and box.SelectionStart ~= cursor then return end
	local key = input.KeyCode
	local prev, nextChunk = Editor.chunks[idx - 1], Editor.chunks[idx + 1]
	local before = string.sub(text, 1, cursor - 1)
	local lastNl = string.match(before, ".*()\n") or 0
	local column = #before - lastNl -- characters before the cursor on its line

	if key == Enum.KeyCode.Down then
		if nextChunk and not string.find(text, "\n", cursor, true) then
			local firstLine = string.match(nextChunk.text, "^[^\n]*")
			Editor.focusChunk(nextChunk, math.min(column, #firstLine) + 1)
		end
	elseif key == Enum.KeyCode.Up then
		if prev and not string.find(before, "\n", 1, true) then
			local prevNl = string.match(prev.text, ".*()\n") or 0
			local lastLen = #prev.text - prevNl
			Editor.focusChunk(prev, prevNl + math.min(column, lastLen) + 1)
		end
	elseif key == Enum.KeyCode.Left then
		if prev and cursor == 1 then Editor.focusChunk(prev, #prev.text + 1) end
	elseif key == Enum.KeyCode.Right then
		if nextChunk and cursor == #text + 1 then Editor.focusChunk(nextChunk, 1) end
	elseif key == Enum.KeyCode.Backspace then
		if prev and cursor == 1 then Editor.mergeNeighbours(idx - 1, #prev.text + 1) end
	elseif key == Enum.KeyCode.Delete then
		if nextChunk and cursor == #text + 1 then Editor.mergeNeighbours(idx, #text + 1) end
	end
end

Editor.createChunk = function(text)
	local chunk = {
		text = text,
		lines = countLines(text),
		width = Editor.measureWidth(text),
		startLine = 1,
		top = 0,
	}
	local box = new("TextBox", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		TextColor3 = Theme.text,
		Font = CODE_FONT,
		TextSize = CODE_SIZE,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		MultiLine = true,
		ClearTextOnFocus = false,
		TextWrapped = false,
		RichText = false,
		Text = text,
		Size = UDim2.fromOffset(100, chunk.lines * Editor.LINE_H),
		ZIndex = 2,
	}, codeScroll)
	pad(box, 8, 8, 0, 0)
	local nums = new("TextLabel", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		TextColor3 = Theme.textDim,
		Font = CODE_FONT,
		TextSize = CODE_SIZE,
		TextXAlignment = Enum.TextXAlignment.Right,
		TextYAlignment = Enum.TextYAlignment.Top,
		Text = "",
		Size = UDim2.new(1, 0, 0, chunk.lines * Editor.LINE_H),
	}, gutterInner)
	pad(nums, 4, 10, 0, 0)
	chunk.box, chunk.nums = box, nums

	box:GetPropertyChangedSignal("Text"):Connect(function()
		if Editor.suppress then return end
		Editor.onChunkEdited(chunk)
	end)
	box:GetPropertyChangedSignal("CursorPosition"):Connect(function()
		if Editor.suppress then return end
		if Editor.onCaretMoved then Editor.onCaretMoved(chunk) end
	end)
	box.Focused:Connect(function() Editor.focused = chunk end)
	box.FocusLost:Connect(function()
		if Editor.focused == chunk then Editor.focused = nil end
	end)
	box.InputBegan:Connect(function(input) Editor.onKey(chunk, input) end)
	return chunk
end

-- Replaces the whole editor text (opening a project, undo, restore, pull ...).
function Editor.setText(text)
	text = text or ""
	-- remember the cursor so keyboard undo/redo does not drop focus
	local refocusIdx, refocusCursor
	if Editor.focused and Editor.focused.box:IsFocused() then
		refocusIdx = Editor.indexOfChunk(Editor.focused)
		refocusCursor = Editor.focused.box.CursorPosition
	end
	Editor.suppress = true
	for i = #Editor.chunks, 1, -1 do Editor.removeChunk(Editor.chunks[i]) end
	Editor.focused = nil
	for _, piece in ipairs(Pure.chunkText(text, Editor.CHUNK_LINES, Editor.CHUNK_CHARS)) do
		table.insert(Editor.chunks, Editor.createChunk(piece))
	end
	Editor.cached = nil
	Editor.relayout()
	Editor.suppress = false
	if refocusIdx then
		local target = Editor.chunks[math.min(refocusIdx, #Editor.chunks)]
		Editor.focusChunk(target, refocusCursor and refocusCursor > 0 and refocusCursor or 1)
	end
end

clickPad.MouseButton1Click:Connect(function()
	local last = Editor.chunks[#Editor.chunks]
	if last then Editor.focusChunk(last, #last.text + 1) end
end)

local function updateCanvas()
	Editor.relayout()
end

local function updateStatus()
	if currentView ~= "editor" then return end
	local info = Editor.caretInfo()
	if info then Editor.caretLine, Editor.caretCol = info.line, info.col end
	setStatus(string.format("Ln %d, Col %d   |   %d lines   |   %s",
		Editor.caretLine, Editor.caretCol, Editor.totalLines, isDirty and "Unsaved changes" or "All changes saved"))
end

refreshEditorChrome = function()
	if currentProject then
		edTitle.Text = currentProject .. (isDirty and "   (unsaved)" or "")
		edTitle.TextColor3 = isDirty and Theme.warning or Theme.text
	end
	Btn.save.Text = isDirty and "Save *" or "Save"
	setButtonEnabled(Btn.undo, #undoStack > 0)
	setButtonEnabled(Btn.redo, #redoStack > 0)
	updateStatus()
end

local function followCaret()
	local info = Editor.caretInfo()
	if not info then return end
	local lh = Editor.LINE_H
	local cx = Editor.measureWidth(info.lineText)
	local y = info.chunk.top + info.localLine * lh
	local x = 8 + cx
	local win = codeScroll.AbsoluteWindowSize
	local pos = codeScroll.CanvasPosition
	local nx, ny = pos.X, pos.Y
	if y < ny then
		ny = y
	elseif y + lh + 6 > ny + win.Y then
		ny = y + lh + 6 - win.Y
	end
	if x < nx + 20 then
		nx = x - 40
	elseif x + 20 > nx + win.X then
		nx = x + 20 - win.X
	end
	nx = math.max(nx, 0)
	ny = math.max(ny, 0)
	if nx ~= pos.X or ny ~= pos.Y then
		codeScroll.CanvasPosition = Vector2.new(nx, ny)
	end
end

local function setEditorText(text, markSaved)
	isApplyingEditorState = true
	Editor.setText(text or "")
	local current = Editor.getText()
	lastEditorText = current
	if markSaved then savedEditorText = current end
	isDirty = current ~= savedEditorText
	isApplyingEditorState = false
	updateCanvas()
	refreshEditorChrome()
end

local function pushUndo(text)
	table.insert(undoStack, text)
	if #undoStack > 200 then table.remove(undoStack, 1) end
end

-- Recovery drafts (crash / accidental close protection)
local function scheduleRecoveryDraft()
	if not currentProject or not isDirty then return end
	recoveryWriteToken = recoveryWriteToken + 1
	local token = recoveryWriteToken
	local projectName = currentProject
	local draftCode = Editor.getText()
	task.delay(1.25, function()
		if token ~= recoveryWriteToken or currentProject ~= projectName or not isDirty then return end
		local ok, encoded = pcall(function()
			return HttpService:JSONEncode({ project = projectName, code = draftCode, savedAt = os.time() })
		end)
		if ok then setSetting(K.RECOVERY, encoded) end
	end)
end

local function clearRecoveryDraft()
	recoveryWriteToken = recoveryWriteToken + 1
	pcall(function() plugin:SetSetting(K.RECOVERY, nil) end)
end

local function applyEdit(newText, markSaved)
	-- programmatic edit that the user can undo
	pushUndo(Editor.getText())
	redoStack = {}
	lastEditTime = 0
	setEditorText(newText, markSaved or false)
	scheduleRecoveryDraft()
end

local function undo()
	if #undoStack == 0 then return end
	table.insert(redoStack, Editor.getText())
	local state = table.remove(undoStack)
	lastEditTime = 0
	setEditorText(state, false)
	scheduleRecoveryDraft()
end

local function redo()
	if #redoStack == 0 then return end
	pushUndo(Editor.getText())
	local state = table.remove(redoStack)
	lastEditTime = 0
	setEditorText(state, false)
	scheduleRecoveryDraft()
end

local function saveCurrent()
	if not currentProject or not projects[currentProject] then return false end
	local p = projects[currentProject]
	local oldCode, oldModified = p.code, p.modified
	local currentText = Editor.getText()
	p.code = currentText
	p.modified = os.time()
	if not persist() then
		p.code, p.modified = oldCode, oldModified
		return false
	end
	savedEditorText = currentText
	isDirty = false
	clearRecoveryDraft()
	refreshEditorChrome()
	notify("Saved '" .. currentProject .. "'", "success")
	return true
end

-- Runs `proceed` right away, or after asking what to do with unsaved edits.
local function guardDirty(proceed)
	if currentProject and isDirty then
		showDialog({
			title = "Unsaved changes",
			message = "'" .. currentProject .. "' has edits that are not saved yet.",
			buttons = {
				{ text = "Save and continue", style = "primary", onClick = function()
					if saveCurrent() then proceed() else return false end
				end },
				{ text = "Discard changes", style = "danger", onClick = function()
					isDirty = false
					clearRecoveryDraft()
					proceed()
				end },
				{ text = "Cancel" },
			},
		})
	else
		proceed()
	end
end

openProject = function(name)
	local p = projects[name]
	if not p then return end
	currentProject = name
	undoStack, redoStack = {}, {}
	lastEditTime = 0
	setEditorText(p.code or "", true)
	codeScroll.CanvasPosition = Vector2.new(0, 0)
	showView("editor")
	refreshEditorChrome()
end

leaveEditor = function()
	currentProject = nil
	isDirty = false
	undoStack, redoStack = {}, {}
	clearRecoveryDraft()
	showView("home")
	refreshProjectList()
end

-- ============ Responsive editor layout ============
local function layoutEditor()
	local barH = actionsLayout.AbsoluteContentSize.Y + 16
	actionsBar.Size = UDim2.new(1, 0, 0, barH)
	local top = HEADER_H + barH
	body.Position = UDim2.new(0, 0, 0, top)
	body.Size = UDim2.new(1, 0, 1, -top)
end
actionsLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(layoutEditor)
task.defer(layoutEditor)

local function adaptToWidgetSize()
	headerTitle.Visible = widget.AbsoluteSize.X >= 360
	updateCanvas()
end
widget:GetPropertyChangedSignal("AbsoluteSize"):Connect(adaptToWidgetSize)
task.defer(adaptToWidgetSize)

-- ============ Text box + scroll events ============
Editor.onChange = function()
	if isApplyingEditorState then return end
	local newText = Editor.getText()
	if newText ~= lastEditorText then
		local now = tick()
		-- Group fast typing into one undo step
		if now - lastEditTime > 0.6 or #undoStack == 0 then pushUndo(lastEditorText) end
		lastEditTime = now
		redoStack = {}
		lastEditorText = newText
	end
	isDirty = newText ~= savedEditorText
	refreshEditorChrome()
	scheduleRecoveryDraft()
end

codeScroll:GetPropertyChangedSignal("AbsoluteWindowSize"):Connect(updateCanvas)
codeScroll:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
	gutterInner.Position = UDim2.fromOffset(0, -codeScroll.CanvasPosition.Y)
end)
Editor.onCaretMoved = function(chunk)
	updateStatus()
	if Editor.focused == chunk then followCaret() end
end

-- Keyboard shortcuts (only while the code editor is focused)
local lastShortcutTime = 0
local function handleShortcut(input)
	if not Editor.isFocused() then return end
	if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
	local ctrl = UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)
		or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
		or UserInputService:IsKeyDown(Enum.KeyCode.LeftMeta)
		or UserInputService:IsKeyDown(Enum.KeyCode.RightMeta)
	if not ctrl then return end
	local key = input.KeyCode
	if key ~= Enum.KeyCode.S and key ~= Enum.KeyCode.Z and key ~= Enum.KeyCode.Y then return end
	-- both connections below can fire for the same key press
	local now = tick()
	if now - lastShortcutTime < 0.08 then return end
	lastShortcutTime = now
	if key == Enum.KeyCode.S then
		saveCurrent()
	elseif key == Enum.KeyCode.Z then
		if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift) then
			redo()
		else
			undo()
		end
	elseif key == Enum.KeyCode.Y then
		redo()
	end
end
Editor.onShortcut = handleShortcut
UserInputService.InputBegan:Connect(handleShortcut)

-- Show the (empty) editor so there is always one box to click into.
Editor.setText("")

-- ============ Diff engine ============
local function computeDiff(a, b)
	local n, m = #a, #b
	local start = 1
	while start <= n and start <= m and a[start] == b[start] do start = start + 1 end
	local ea, eb = n, m
	while ea >= start and eb >= start and a[ea] == b[eb] do
		ea = ea - 1
		eb = eb - 1
	end

	local ops = {}
	for i = 1, start - 1 do ops[#ops + 1] = { " ", a[i] } end

	local an, bn = ea - start + 1, eb - start + 1
	if an > 0 and bn > 0 and an * bn > 1500000 then
		-- Too large for a precise diff: show it as one removed + one added block
		for i = start, ea do ops[#ops + 1] = { "-", a[i] } end
		for j = start, eb do ops[#ops + 1] = { "+", b[j] } end
	elseif an > 0 or bn > 0 then
		local L = {}
		for i = 1, an + 1 do L[i] = table.create(bn + 1, 0) end
		for i = an, 1, -1 do
			local ai = a[start + i - 1]
			local Li, Li1 = L[i], L[i + 1]
			for j = bn, 1, -1 do
				if ai == b[start + j - 1] then
					Li[j] = Li1[j + 1] + 1
				else
					local down, right = Li1[j], Li[j + 1]
					Li[j] = down >= right and down or right
				end
			end
		end
		local i, j = 1, 1
		while i <= an and j <= bn do
			if a[start + i - 1] == b[start + j - 1] then
				ops[#ops + 1] = { " ", a[start + i - 1] }
				i = i + 1
				j = j + 1
			elseif L[i + 1][j] >= L[i][j + 1] then
				ops[#ops + 1] = { "-", a[start + i - 1] }
				i = i + 1
			else
				ops[#ops + 1] = { "+", b[start + j - 1] }
				j = j + 1
			end
		end
		while i <= an do
			ops[#ops + 1] = { "-", a[start + i - 1] }
			i = i + 1
		end
		while j <= bn do
			ops[#ops + 1] = { "+", b[start + j - 1] }
			j = j + 1
		end
	end

	for k = ea + 1, n do ops[#ops + 1] = { " ", a[k] } end
	return ops
end

local DIFF_ROW_H = 17
local DIFF_MAX_ROWS = 800

local function renderDiff(oldText, newText)
	for _, child in ipairs(diffScroll:GetChildren()) do
		if child:IsA("GuiObject") then child:Destroy() end
	end

	local ops = computeDiff(string.split(oldText, "\n"), string.split(newText, "\n"))
	local added, removed = 0, 0
	for _, op in ipairs(ops) do
		if op[1] == "+" then added = added + 1 elseif op[1] == "-" then removed = removed + 1 end
	end
	diffSummary.Text = string.format("+%d added   -%d removed   (- = in snapshot, + = in editor)", added, removed)

	if added == 0 and removed == 0 then
		local msg = label(diffScroll, "No differences. The snapshot matches the editor.", {
			Size = UDim2.new(1, 0, 0, 40),
			TextColor3 = Theme.textDim,
			TextXAlignment = Enum.TextXAlignment.Center,
		})
		diffScroll.CanvasSize = UDim2.new()
		return msg
	end

	-- Keep changed lines with 3 lines of context; collapse everything else
	local keep = {}
	for idx, op in ipairs(ops) do
		if op[1] ~= " " then
			for k = math.max(1, idx - 3), math.min(#ops, idx + 3) do keep[k] = true end
		end
	end

	local rows = {}
	local skipped = 0
	for idx, op in ipairs(ops) do
		if keep[idx] then
			if skipped > 0 then
				rows[#rows + 1] = { kind = "note", text = "... " .. skipped .. " unchanged lines ..." }
				skipped = 0
			end
			rows[#rows + 1] = { kind = op[1], text = op[2] }
		else
			skipped = skipped + 1
		end
	end
	if skipped > 0 then rows[#rows + 1] = { kind = "note", text = "... " .. skipped .. " unchanged lines ..." } end

	local truncated = false
	if #rows > DIFF_MAX_ROWS then
		truncated = true
		for k = #rows, DIFF_MAX_ROWS + 1, -1 do rows[k] = nil end
	end

	local charW = TextService:GetTextSize("M", 12, CODE_FONT, TEXT_BIG).X
	local maxLen = 0
	for _, r in ipairs(rows) do
		r.text = string.gsub(r.text, "\t", "    ")
		if #r.text > maxLen then maxLen = #r.text end
	end
	local width = math.max(maxLen * charW + 40, diffScroll.AbsoluteWindowSize.X)

	for idx, r in ipairs(rows) do
		local bg, fg, prefix = nil, Theme.textDim, "  "
		if r.kind == "+" then bg, fg, prefix = Theme.diffAddBg, Theme.diffAddText, "+ "
		elseif r.kind == "-" then bg, fg, prefix = Theme.diffDelBg, Theme.diffDelText, "- "
		elseif r.kind == "note" then fg, prefix = Theme.accentHover, "" end
		new("TextLabel", {
			Position = UDim2.fromOffset(0, (idx - 1) * DIFF_ROW_H),
			Size = UDim2.fromOffset(width, DIFF_ROW_H),
			BackgroundColor3 = bg or Theme.codeBg,
			BackgroundTransparency = bg and 0 or 1,
			BorderSizePixel = 0,
			Text = prefix .. r.text,
			TextColor3 = fg,
			Font = CODE_FONT,
			TextSize = 12,
			TextXAlignment = Enum.TextXAlignment.Left,
		}, diffScroll)
	end

	local totalH = #rows * DIFF_ROW_H
	if truncated then
		diffSummary.Text = diffSummary.Text .. "   (showing first " .. DIFF_MAX_ROWS .. " rows)"
	end
	diffScroll.CanvasSize = UDim2.fromOffset(width, totalH + 8)
	diffScroll.CanvasPosition = Vector2.new(0, 0)
end

-- ============ History (snapshots) ============
local function refreshHistory()
	for _, child in ipairs(historyScroll:GetChildren()) do
		if child:IsA("GuiObject") then child:Destroy() end
	end
	local p = currentProject and projects[currentProject]
	if not p then return end
	local snaps = p.snapshots
	historyTitle.Text = "History: " .. currentProject .. " (" .. #snaps .. ")"

	if #snaps == 0 then
		label(historyScroll, "No snapshots yet.\nUse the Snapshot button to save a restore point,\nlike a commit.", {
			Size = UDim2.new(1, 0, 0, 80),
			TextColor3 = Theme.textDim,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Center,
		})
		return
	end

	for i = #snaps, 1, -1 do
		local snap = snaps[i]
		local row = new("Frame", {
			Size = UDim2.new(1, 0, 0, 82),
			BackgroundColor3 = Theme.surfaceAlt,
			BorderSizePixel = 0,
			LayoutOrder = #snaps - i,
		}, historyScroll)
		corner(row, 8)
		stroke(row)

		label(row, snap.description, {
			Position = UDim2.new(0, 12, 0, 8),
			Size = UDim2.new(1, -24, 0, 20),
			Font = Enum.Font.GothamMedium,
			TextSize = 14,
			TextTruncate = Enum.TextTruncate.AtEnd,
		})
		label(row, os.date("%Y-%m-%d %H:%M", snap.time) .. "  |  " .. timeAgo(snap.time) .. "  |  " .. countLines(snap.code) .. " lines", {
			Position = UDim2.new(0, 12, 0, 28),
			Size = UDim2.new(1, -24, 0, 16),
			TextColor3 = Theme.textDim,
			TextSize = 12,
			TextTruncate = Enum.TextTruncate.AtEnd,
		})

		local btns = new("Frame", {
			Position = UDim2.new(0, 12, 0, 48),
			Size = UDim2.new(1, -24, 0, 28),
			BackgroundTransparency = 1,
		}, row)
		new("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			Padding = UDim.new(0, 6),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}, btns)

		local diffB = makeButton(btns, "Diff", "secondary", { Size = UDim2.new(0, 0, 0, 28), LayoutOrder = 1 })
		local restoreB = makeButton(btns, "Restore", "primary", { Size = UDim2.new(0, 0, 0, 28), LayoutOrder = 2 })
		local delB = makeButton(btns, "Delete", "danger", { Size = UDim2.new(0, 0, 0, 28), LayoutOrder = 3 })

		diffB.MouseButton1Click:Connect(function()
			diffTitle.Text = "Diff: " .. snap.description
			diffPanel.Visible = true
			renderDiff(snap.code, Editor.getText())
		end)

		restoreB.MouseButton1Click:Connect(function()
			confirmDialog("Restore snapshot?",
				"The editor text will be replaced with '" .. snap.description .. "'. You can undo this, and nothing is saved until you press Save.",
				"Restore", function()
					applyEdit(snap.code, false)
					historyPanel.Visible = false
					notify("Snapshot restored. Press Save to keep it.", "success")
				end)
		end)

		delB.MouseButton1Click:Connect(function()
			confirmDialog("Delete snapshot?", "'" .. snap.description .. "' will be permanently removed.", "Delete", function()
				local removed = table.remove(snaps, i)
				if not persist() then
					table.insert(snaps, i, removed)
					return
				end
				refreshHistory()
				notify("Snapshot deleted")
			end, true)
		end)
	end
end

-- ============ Project actions ============
local function createProjectFlow()
	showDialog({
		title = "New project",
		message = "Give your project a name. You can rename it later.",
		input = { placeholder = "Project name", default = uniqueName("Untitled") },
		buttons = {
			{ text = "Cancel" },
			{ text = "Create", style = "primary", onClick = function(value)
				local name = trim(value)
				local ok, err = validateName(name)
				if not ok then notify(err, "warn"); return false end
				projects[name] = newProjectRecord("-- " .. name .. "\n")
				if not persist() then projects[name] = nil; return false end
				refreshProjectList()
				openProject(name)
				notify("Created '" .. name .. "'", "success")
			end },
		},
	})
end

local function importSelectedScripts()
	local scripts = getSelectedScripts()
	if #scripts == 0 then
		notify("Select one or more scripts in the Explorer first", "warn")
		return
	end
	local before = {}
	local added = {}
	for _, scr in ipairs(scripts) do
		local name = uniqueName(scr.Name)
		before[name] = true
		projects[name] = newProjectRecord(getSource(scr))
		table.insert(added, name)
	end
	if not persist() then
		for _, name in ipairs(added) do projects[name] = nil end
		return
	end
	refreshProjectList()
	notify("Imported " .. #added .. (#added == 1 and " script" or " scripts"), "success")
end

local function duplicateProject(name)
	local src = projects[name]
	if not src then return end
	local copyName = uniqueName(name .. " copy")
	local snaps = {}
	for _, s in ipairs(src.snapshots) do
		table.insert(snaps, { time = s.time, description = s.description, code = s.code })
	end
	local rec = newProjectRecord(src.code)
	rec.snapshots = snaps
	projects[copyName] = rec
	if not persist() then projects[copyName] = nil; return end
	refreshProjectList()
	notify("Duplicated as '" .. copyName .. "'", "success")
end

local function deleteProjectFlow(name)
	confirmDialog("Delete project?",
		"'" .. name .. "' and all of its snapshots will be permanently deleted. This cannot be undone.",
		"Delete", function()
			local old = projects[name]
			projects[name] = nil
			if not persist() then projects[name] = old; return end
			if currentProject == name then
				currentProject = nil
				isDirty = false
				clearRecoveryDraft()
				showView("home")
			end
			refreshProjectList()
			notify("Deleted '" .. name .. "'")
		end, true)
end

local function renameProjectFlow()
	if not currentProject then return end
	local oldName = currentProject
	showDialog({
		title = "Rename project",
		input = { placeholder = "Project name", default = oldName },
		buttons = {
			{ text = "Cancel" },
			{ text = "Rename", style = "primary", onClick = function(value)
				local name = trim(value)
				if name == oldName then return end
				local ok, err = validateName(name, oldName)
				if not ok then notify(err, "warn"); return false end
				local record = projects[oldName]
				projects[name] = record
				projects[oldName] = nil
				if not persist() then
					projects[oldName] = record
					projects[name] = nil
					return false
				end
				currentProject = name
				refreshEditorChrome()
				notify("Renamed to '" .. name .. "'", "success")
			end },
		},
	})
end

local function snapshotFlow()
	if not currentProject then return end
	local p = projects[currentProject]
	local last = p.snapshots[#p.snapshots]
	if last and last.code == Editor.getText() then
		notify("Nothing changed since the last snapshot", "warn")
		return
	end
	showDialog({
		title = "Create snapshot",
		message = "A snapshot is a restore point of the editor text, like a commit. Describe what changed.",
		input = { placeholder = "e.g. Added damage calculation", default = "" },
		buttons = {
			{ text = "Cancel" },
			{ text = "Save snapshot", style = "primary", onClick = function(value)
				local desc = trim(value)
				if desc == "" then desc = "Snapshot " .. (#p.snapshots + 1) end
				table.insert(p.snapshots, { time = os.time(), description = desc, code = Editor.getText() })
				if not persist() then
					table.remove(p.snapshots, #p.snapshots)
					return false
				end
				notify("Snapshot saved", "success")
			end },
		},
	})
end

local function pullFlow()
	if not currentProject then return end
	local scripts = getSelectedScripts()
	if #scripts == 0 then
		notify("Select a script in the Explorer to pull from", "warn")
		return
	end
	if #scripts > 1 then
		notify("Select just one script to pull from", "warn")
		return
	end
	local text = getSource(scripts[1])
	if text == Editor.getText() then
		notify("The editor already matches '" .. scripts[1].Name .. "'")
		return
	end
	applyEdit(text, false)
	notify("Pulled '" .. scripts[1].Name .. "'. Use Undo to revert.", "success")
end

local function createScriptFrom(className, code, name)
	local selected = Selection:Get()[1]
	local parent = selected or ServerScriptService
	local ok, scr = pcall(function()
		local s = Instance.new(className)
		s.Name = name
		s.Parent = parent
		return s
	end)
	if not ok then
		notify("Could not create the script here: " .. tostring(scr), "error")
		return
	end
	local wrote, err = writeSource(scr, code)
	if not wrote then notify("Created script but could not write source: " .. tostring(err), "error"); return end
	pcall(function() Selection:Set({ scr }) end)
	pcall(function() plugin:OpenScript(scr) end)
	notify("Created " .. className .. " '" .. name .. "' in " .. parent.Name, "success")
end

local function pushFlow()
	if not currentProject then return end
	local scripts = getSelectedScripts()
	local text = Editor.getText()
	local projectName = currentProject
	local buttons = {}
	local message
	if #scripts > 0 then
		local target = #scripts == 1 and ("'" .. scripts[1].Name .. "'") or (#scripts .. " selected scripts")
		message = "Send the editor text (including unsaved edits) to " .. target .. ", or create a new script."
		table.insert(buttons, { text = "Replace " .. target, style = "danger", onClick = function()
			local failed = 0
			for _, scr in ipairs(scripts) do
				if not writeSource(scr, text) then failed = failed + 1 end
			end
			if failed > 0 then notify(failed .. " script(s) could not be updated", "error")
			else notify("Replaced source of " .. target, "success") end
		end })
		table.insert(buttons, { text = "Append to " .. target, onClick = function()
			local failed = 0
			for _, scr in ipairs(scripts) do
				local current = getSource(scr)
				local combined = current == "" and text or (current .. "\n\n-- DevHub: " .. projectName .. "\n" .. text)
				if not writeSource(scr, combined) then failed = failed + 1 end
			end
			if failed > 0 then notify(failed .. " script(s) could not be updated", "error")
			else notify("Appended to " .. target, "success") end
		end })
	else
		message = "No script is selected, so DevHub can create a new one. It goes into the selected object, or ServerScriptService if nothing is selected."
	end
	table.insert(buttons, { text = "Create new ModuleScript", onClick = function() createScriptFrom("ModuleScript", text, projectName) end })
	table.insert(buttons, { text = "Create new Script", onClick = function() createScriptFrom("Script", text, projectName) end })
	table.insert(buttons, { text = "Create new LocalScript", onClick = function() createScriptFrom("LocalScript", text, projectName) end })
	table.insert(buttons, { text = "Cancel" })
	showDialog({ title = "Push to Studio", message = message, buttons = buttons })
end

-- ============ Project list ============
local SORT_LABELS = { recent = "Recent", name = "Name", snapshots = "Snapshots" }
local SORT_NEXT = { recent = "name", name = "snapshots", snapshots = "recent" }

refreshProjectList = function()
	for _, child in ipairs(projectList:GetChildren()) do
		if child:IsA("GuiObject") then child:Destroy() end
	end
	Btn.sort.Text = "Sort: " .. (SORT_LABELS[sortMode] or "Recent")

	local query = string.lower(trim(projectSearch.Text))
	local total = 0
	local names = {}
	for name in pairs(projects) do
		total = total + 1
		if query == "" or string.find(string.lower(name), query, 1, true) then
			table.insert(names, name)
		end
	end

	table.sort(names, function(a, b)
		local pa, pb = projects[a], projects[b]
		if sortMode == "name" then
			return string.lower(a) < string.lower(b)
		elseif sortMode == "snapshots" then
			local ca, cb = snapshotCount(pa), snapshotCount(pb)
			if ca ~= cb then return ca > cb end
		else
			if pa.modified ~= pb.modified then return pa.modified > pb.modified end
		end
		return string.lower(a) < string.lower(b)
	end)

	if currentView == "home" then
		if query == "" then
			setStatus(total .. (total == 1 and " project" or " projects") .. "   |   Storage: " .. modeLabel(getMode()))
		else
			setStatus(#names .. " of " .. total .. " projects match")
		end
	end

	if #names == 0 then
		local empty = new("Frame", {
			Size = UDim2.new(1, 0, 0, 150),
			BackgroundTransparency = 1,
			LayoutOrder = 1,
		}, projectList)
		label(empty, query ~= "" and "No matching projects.\nTry a different search." or "Your workspace is empty.\nCreate a project, or import scripts you already have in Studio.", {
			Size = UDim2.new(1, 0, 0, 60),
			Position = UDim2.new(0, 0, 0, 14),
			TextColor3 = Theme.textDim,
			TextSize = 14,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Center,
		})
		if query == "" then
			local create = makeButton(empty, "+ Create your first project", "primary", {
				AnchorPoint = Vector2.new(0.5, 0),
				Position = UDim2.new(0.5, 0, 0, 84),
			})
			create.MouseButton1Click:Connect(createProjectFlow)
		end
		projectList.CanvasPosition = Vector2.new(0, 0)
		return
	end

	for i, name in ipairs(names) do
		local p = projects[name]
		local card = new("Frame", {
			Name = "ProjectCard",
			Size = UDim2.new(1, 0, 0, 62),
			BackgroundColor3 = Theme.surfaceAlt,
			BorderSizePixel = 0,
			LayoutOrder = i,
		}, projectList)
		corner(card, 8)
		stroke(card)

		-- The big click target is created FIRST so the action buttons sit on top of it.
		local openBtn = new("TextButton", {
			Name = "Open",
			Text = "",
			Size = UDim2.new(1, 0, 1, 0),
			BackgroundTransparency = 1,
			AutoButtonColor = false,
		}, card)

		label(card, name, {
			Position = UDim2.new(0, 14, 0, 10),
			Size = UDim2.new(1, -170, 0, 20),
			Font = Enum.Font.GothamMedium,
			TextSize = 14,
			TextTruncate = Enum.TextTruncate.AtEnd,
		})
		local snaps = snapshotCount(p)
		label(card, countLines(p.code) .. " lines  |  " .. snaps .. (snaps == 1 and " snapshot" or " snapshots") .. "  |  " .. timeAgo(p.modified), {
			Position = UDim2.new(0, 14, 0, 33),
			Size = UDim2.new(1, -170, 0, 18),
			TextColor3 = Theme.textDim,
			TextSize = 12,
			TextTruncate = Enum.TextTruncate.AtEnd,
		})

		local actions = new("Frame", {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -10, 0.5, 0),
			Size = UDim2.new(0, 0, 0, 28),
			AutomaticSize = Enum.AutomaticSize.X,
			BackgroundTransparency = 1,
		}, card)
		new("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			Padding = UDim.new(0, 6),
			SortOrder = Enum.SortOrder.LayoutOrder,
			VerticalAlignment = Enum.VerticalAlignment.Center,
		}, actions)
		local copyB = makeButton(actions, "Copy", "ghost", { Size = UDim2.new(0, 0, 0, 28), LayoutOrder = 1 })
		local delB = makeButton(actions, "Delete", "danger", { Size = UDim2.new(0, 0, 0, 28), LayoutOrder = 2 })

		openBtn.MouseEnter:Connect(function()
			TweenService:Create(card, TweenInfo.new(0.1), { BackgroundColor3 = Theme.surfaceHover }):Play()
		end)
		openBtn.MouseLeave:Connect(function()
			TweenService:Create(card, TweenInfo.new(0.1), { BackgroundColor3 = Theme.surfaceAlt }):Play()
		end)
		openBtn.MouseButton1Click:Connect(function() openProject(name) end)
		copyB.MouseButton1Click:Connect(function() duplicateProject(name) end)
		delB.MouseButton1Click:Connect(function() deleteProjectFlow(name) end)
	end
end

-- ============ Settings ============
refreshSettings = function()
	Btn.storage.Text = modeLabel(getMode())
	Btn.copy.Text = "Copy to " .. (getMode() == "plugin" and "place" or "plugin")
	Btn.prompt.Text = getSetting(K.PROMPT, false) and "On" or "Off"
end

local function mergeInto(target, source)
	local copied, skipped = 0, 0
	for name, record in pairs(source) do
		if target[name] then
			skipped = skipped + 1
		else
			target[name] = record
			copied = copied + 1
		end
	end
	return copied, skipped
end

-- ============ Button wiring ============
Btn.new.MouseButton1Click:Connect(createProjectFlow)
Btn.import.MouseButton1Click:Connect(importSelectedScripts)
Btn.settings.MouseButton1Click:Connect(function()
	refreshSettings()
	showView("settings")
	setStatus("Settings")
end)
Btn.settingsBack.MouseButton1Click:Connect(function()
	showView("home")
	refreshProjectList()
end)

Btn.sort.MouseButton1Click:Connect(function()
	sortMode = SORT_NEXT[sortMode] or "recent"
	setSetting(K.SORT, sortMode)
	refreshProjectList()
end)
projectSearch:GetPropertyChangedSignal("Text"):Connect(function()
	refreshProjectList()
end)

Btn.storage.MouseButton1Click:Connect(function()
	local newMode = getMode() == "plugin" and "place" or "plugin"
	if not setSetting(K.MODE, newMode) then
		notify("Could not change storage location", "error")
		return
	end
	projects = loadData(newMode)
	refreshSettings()
	refreshProjectList()
	notify("Now using: " .. modeLabel(newMode), "success")
end)

Btn.copy.MouseButton1Click:Connect(function()
	local current = getMode()
	local other = current == "plugin" and "place" or "plugin"
	confirmDialog("Copy projects?",
		"Copy all projects from '" .. modeLabel(current) .. "' to '" .. modeLabel(other) .. "'? Existing names there are kept as they are.",
		"Copy", function()
			local target = loadData(other)
			local copied, skipped = mergeInto(target, projects)
			local ok, err = saveData(target, other)
			if not ok then notify(err or "Copy failed", "error"); return end
			notify("Copied " .. copied .. ", skipped " .. skipped .. " (name already existed)", "success")
		end)
end)

Btn.prompt.MouseButton1Click:Connect(function()
	setSetting(K.PROMPT, not getSetting(K.PROMPT, false))
	refreshSettings()
end)

Btn.export.MouseButton1Click:Connect(function()
	local ok, result = pcall(function()
		local encoded = HttpService:JSONEncode({ schemaVersion = SCHEMA_VERSION, projects = projects })
		local partCount = Parts.write(ServerStorage, K.EXPORT, encoded)
		-- Read it straight back so a damaged backup is never reported as saved.
		local readBack, problem = Parts.read(ServerStorage, K.EXPORT)
		if readBack ~= encoded then
			error("verification failed (" .. tostring(problem or "stored data differs") .. ")", 0)
		end
		return { parts = partCount, kb = math.ceil(#encoded / 1024) }
	end)
	if ok then
		notify(string.format("Backup saved: %d KB in %d part%s (ServerStorage > %s)",
			result.kb, result.parts, result.parts == 1 and "" or "s", K.EXPORT), "success", 4)
	else
		notify("Backup failed: " .. tostring(result), "error", 6)
	end
end)

Btn.importBackup.MouseButton1Click:Connect(function()
	if not ServerStorage:FindFirstChild(K.EXPORT) then
		notify("No backup found. Press 'Export backup' first.", "warn", 4)
		return
	end
	local raw, problem = Parts.read(ServerStorage, K.EXPORT)
	if not raw then
		notify("Backup problem: " .. tostring(problem), "error", 6)
		return
	end
	if raw == "" then notify("The backup is empty", "warn"); return end
	local decoded = decodeStoredData(raw)
	if not decoded then
		notify("Backup is damaged (not valid data). Export a fresh one.", "error", 6)
		return
	end
	local incoming = normalizeProjects(decoded)
	local added = {}
	for name, record in pairs(incoming) do
		local finalName = uniqueName(name)
		projects[finalName] = record
		table.insert(added, finalName)
	end
	if not persist() then
		for _, n in ipairs(added) do projects[n] = nil end
		return
	end
	refreshProjectList()
	notify("Imported " .. #added .. " projects from backup", "success")
end)

-- Editor buttons
Btn.save.MouseButton1Click:Connect(function() saveCurrent() end)
Btn.undo.MouseButton1Click:Connect(undo)
Btn.redo.MouseButton1Click:Connect(redo)
Btn.snap.MouseButton1Click:Connect(snapshotFlow)
Btn.history.MouseButton1Click:Connect(function()
	if not currentProject then return end
	refreshHistory()
	historyPanel.Visible = true
end)
Btn.pull.MouseButton1Click:Connect(pullFlow)
Btn.push.MouseButton1Click:Connect(pushFlow)
Btn.rename.MouseButton1Click:Connect(renameProjectFlow)
Btn.delete.MouseButton1Click:Connect(function()
	if currentProject then deleteProjectFlow(currentProject) end
end)
Btn.back.MouseButton1Click:Connect(function()
	guardDirty(leaveEditor)
end)
Btn.historyClose.MouseButton1Click:Connect(function()
	historyPanel.Visible = false
	diffPanel.Visible = false
end)
Btn.diffClose.MouseButton1Click:Connect(function()
	diffPanel.Visible = false
end)

-- ============ Script editor hook (optional "save on close" prompt) ============
local prompted = setmetatable({}, { __mode = "k" })

local function promptSaveScript(scriptName, text)
	if overlay.Visible then return end
	showDialog({
		title = "Save to DevHub?",
		message = "Keep a copy of this script as a DevHub project.",
		input = { placeholder = "Project name", default = scriptName },
		buttons = {
			{ text = "Not now" },
			{ text = "Save as project", style = "primary", onClick = function(value)
				local name = trim(value)
				if name == "" then notify("Enter a project name", "warn"); return false end
				if #name > 80 then notify("Name is too long", "warn"); return false end
				local function commit()
					local previous = projects[name]
					local record = newProjectRecord(text)
					if previous then
						record.snapshots = previous.snapshots
						record.created = previous.created
					end
					projects[name] = record
					if not persist() then projects[name] = previous; return end
					refreshProjectList()
					notify(previous and ("Updated '" .. name .. "'") or ("Saved as '" .. name .. "'"), "success")
				end
				if projects[name] then
					confirmDialog("Overwrite project?", "'" .. name .. "' already exists. Its code will be replaced; snapshots are kept.", "Overwrite", commit, true)
				else
					commit()
				end
			end },
		},
	})
end

local function hookScriptDocument(doc)
	local ok, scr = pcall(function() return doc:GetScript() end)
	if not ok or not scr or not scr:IsA("LuaSourceContainer") then return end
	pcall(function()
		doc.Closed:Connect(function()
			if not getSetting(K.PROMPT, false) then return end
			local okText, text = pcall(function() return doc:GetText() end)
			if not okText or type(text) ~= "string" then
				local okSrc, src = pcall(function() return scr.Source end)
				text = okSrc and src or ""
			end
			if text == "" or prompted[scr] == text then return end
			local existing = projects[scr.Name]
			if existing and existing.code == text then return end
			prompted[scr] = text
			promptSaveScript(scr.Name, text)
		end)
	end)
end

pcall(function()
	for _, doc in ipairs(ScriptEditorService:GetScriptDocuments()) do
		hookScriptDocument(doc)
	end
	ScriptEditorService.TextDocumentDidOpen:Connect(hookScriptDocument)
end)

-- ============ Initialize ============
openButton.Click:Connect(function()
	widget.Enabled = not widget.Enabled
end)
widget:GetPropertyChangedSignal("Enabled"):Connect(function()
	openButton:SetActive(widget.Enabled)
end)
openButton:SetActive(widget.Enabled)

showView("home")
refreshSettings()
refreshProjectList()

-- Offer recovery of an unsaved draft from a previous session
local recoveryOk, recoveryRaw = pcall(function() return plugin:GetSetting(K.RECOVERY) end)
if recoveryOk and type(recoveryRaw) == "string" and recoveryRaw ~= "" then
	local decodeOk, recovery = pcall(function() return HttpService:JSONDecode(recoveryRaw) end)
	if decodeOk and type(recovery) == "table" and type(recovery.project) == "string" and type(recovery.code) == "string" then
		showDialog({
			title = "Recover unsaved draft?",
			message = "DevHub found unsaved edits to '" .. recovery.project .. "' from " .. timeAgo(tonumber(recovery.savedAt)) .. ".",
			buttons = {
				{ text = "Discard", style = "danger", onClick = function() clearRecoveryDraft() end },
				{ text = "Recover", style = "primary", onClick = function()
					if not projects[recovery.project] then
						projects[recovery.project] = newProjectRecord("")
					end
					openProject(recovery.project)
					applyEdit(recovery.code, false)
					notify("Draft recovered. Press Save to keep it.", "success")
				end },
			},
		})
	end
end

print(LOG .. "Loaded.")
