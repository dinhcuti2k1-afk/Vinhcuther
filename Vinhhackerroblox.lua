--[[
	AdminTools (1 file duy nhất)
	Bay | Xuyên tường | Tàng hình | Định vị người chơi/bot | Giảm lag | Dịch chuyển theo tên

	CÁCH DÙNG: dán CÙNG nội dung file này vào 2 nơi
	  1) Script       -> ServerScriptService            (phần server tự chạy)
	  2) LocalScript  -> StarterPlayer/StarterPlayerScripts (phần client tự chạy)
	Code tự nhận biết đang chạy ở đâu bằng RunService:IsServer().
	(Roblox bắt buộc code server và client chạy ở 2 đối tượng riêng, nên cần dán 2 lần.)

	Phím tắt: F = Bay | N = Xuyên tường | V = Tàng hình | L = Định vị | P = Giảm lag
	          RightShift = ẩn/hiện bảng | Space = bay lên | Ctrl/Shift = bay xuống
]]

local RunService = game:GetService("RunService")

----------------------------------------------------------------------
-- PHẦN SERVER
----------------------------------------------------------------------
if RunService:IsServer() then
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CONFIG = {
	-- Thêm UserId của những người được dùng công cụ, ví dụ: {123456789, 987654321}
	AdminUserIds = {},
	-- Khi test trong Studio, ai cũng dùng được. Server thật (đã publish) không bị ảnh hưởng.
	AllowEveryoneInStudio = true,
	TeleportCooldown = 1, -- giây
	TeleportOffset = CFrame.new(0, 0, 5), -- đứng phía sau mục tiêu 5 studs
}

local remote = Instance.new("RemoteEvent")
remote.Name = "AdminToolsRemote"
remote.Parent = ReplicatedStorage

local admins = {} -- [Player] = true
local invisible = {} -- [Player] = true khi đang tàng hình
local invisibleConns = {} -- [Player] = RBXScriptConnection
local lastTeleport = {} -- [Player] = os.clock()

----------------------------------------------------------------------
-- Quyền admin
----------------------------------------------------------------------
local function isAdmin(player)
	if CONFIG.AllowEveryoneInStudio and RunService:IsStudio() then
		return true
	end
	if table.find(CONFIG.AdminUserIds, player.UserId) then
		return true
	end
	if game.CreatorType == Enum.CreatorType.User then
		return player.UserId == game.CreatorId
	elseif game.CreatorType == Enum.CreatorType.Group then
		local ok, rank = pcall(player.GetRankInGroup, player, game.CreatorId)
		return ok and rank == 255
	end
	return false
end

local function notify(player, text)
	remote:FireClient(player, "Notify", text)
end

----------------------------------------------------------------------
-- Tàng hình
----------------------------------------------------------------------
local function applyToInstance(inst, on)
	if inst:IsA("Humanoid") then
		inst.DisplayDistanceType = on and Enum.HumanoidDisplayDistanceType.None
			or Enum.HumanoidDisplayDistanceType.Viewer
	elseif (inst:IsA("BasePart") and inst.Name ~= "HumanoidRootPart") or inst:IsA("Decal") then
		if on then
			if inst:GetAttribute("OrigTransparency") == nil then
				inst:SetAttribute("OrigTransparency", inst.Transparency)
			end
			inst.Transparency = 1
		else
			local original = inst:GetAttribute("OrigTransparency")
			if original ~= nil then
				inst.Transparency = original
				inst:SetAttribute("OrigTransparency", nil)
			end
		end
	end
end

local function applyToCharacter(player, character)
	local old = invisibleConns[player]
	if old then
		old:Disconnect()
		invisibleConns[player] = nil
	end
	if not character then
		return
	end

	local on = invisible[player] == true
	for _, descendant in ipairs(character:GetDescendants()) do
		applyToInstance(descendant, on)
	end
	if on then
		-- Phụ kiện/Tool thêm vào sau cũng bị ẩn.
		invisibleConns[player] = character.DescendantAdded:Connect(function(descendant)
			applyToInstance(descendant, true)
		end)
	end
end

local function setInvisible(player, on)
	invisible[player] = on or nil
	applyToCharacter(player, player.Character)
	remote:FireClient(player, "State", "Invisible", on)
	notify(player, on and "Đã tàng hình." or "Đã hiện hình.")
end

----------------------------------------------------------------------
-- Dịch chuyển tới người chơi / bot theo tên
----------------------------------------------------------------------
local function trim(s)
	return (s:gsub("^%s*(.-)%s*$", "%1"))
end

-- Ưu tiên khớp đúng tên, sau đó khớp phần đầu tên. Tìm người chơi trước, bot sau.
local function findTarget(requester, query)
	local q = string.lower(trim(query))
	if q == "" then
		return nil
	end

	local partialPlayer
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= requester then
			local name, display = p.Name:lower(), p.DisplayName:lower()
			if name == q or display == q then
				return p.Character, p.DisplayName
			end
			if not partialPlayer and (name:sub(1, #q) == q or display:sub(1, #q) == q) then
				partialPlayer = p
			end
		end
	end
	if partialPlayer then
		return partialPlayer.Character, partialPlayer.DisplayName
	end

	local partialBot
	for _, inst in ipairs(workspace:GetDescendants()) do
		if inst:IsA("Humanoid") then
			local model = inst.Parent
			if model and model:IsA("Model") and not Players:GetPlayerFromCharacter(model) then
				local name = model.Name:lower()
				if name == q then
					return model, model.Name .. " (bot)"
				end
				if not partialBot and name:sub(1, #q) == q then
					partialBot = model
				end
			end
		end
	end
	if partialBot then
		return partialBot, partialBot.Name .. " (bot)"
	end
	return nil
end

local function teleportToTarget(player, query)
	local now = os.clock()
	if now - (lastTeleport[player] or 0) < CONFIG.TeleportCooldown then
		return
	end
	lastTeleport[player] = now

	local character = player.Character
	local myRoot = character and character:FindFirstChild("HumanoidRootPart")
	if not myRoot then
		notify(player, "Nhân vật của bạn chưa sẵn sàng.")
		return
	end

	local targetModel, targetName = findTarget(player, query)
	if not targetModel then
		notify(player, "Không tìm thấy: " .. trim(query))
		return
	end
	local targetRoot = targetModel:FindFirstChild("HumanoidRootPart") or targetModel.PrimaryPart
	if not targetRoot then
		notify(player, targetName .. " chưa có nhân vật trong map.")
		return
	end

	local position = (targetRoot.CFrame * CONFIG.TeleportOffset).Position
	local lookAt = Vector3.new(targetRoot.Position.X, position.Y, targetRoot.Position.Z)
	character:PivotTo(CFrame.lookAt(position, lookAt))
	myRoot.AssemblyLinearVelocity = Vector3.zero
	notify(player, "Đã dịch chuyển tới " .. targetName)
end

----------------------------------------------------------------------
-- Remote + vòng đời người chơi
----------------------------------------------------------------------
remote.OnServerEvent:Connect(function(player, action, argument)
	if not admins[player] then
		return
	end
	if action == "Invisible" then
		if typeof(argument) == "boolean" then
			setInvisible(player, argument)
		end
	elseif action == "Teleport" then
		if typeof(argument) == "string" and #argument > 0 and #argument <= 50 then
			teleportToTarget(player, argument)
		end
	end
end)

local function onPlayerAdded(player)
	local allowed = isAdmin(player)
	admins[player] = allowed or nil
	player:SetAttribute("IsAdmin", allowed)

	player.CharacterAdded:Connect(function(character)
		if invisible[player] then
			task.defer(applyToCharacter, player, character)
		end
	end)
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerAdded, player)
end

Players.PlayerRemoving:Connect(function(player)
	admins[player] = nil
	invisible[player] = nil
	lastTeleport[player] = nil
	local conn = invisibleConns[player]
	if conn then
		conn:Disconnect()
		invisibleConns[player] = nil
	end
end)

	return
end

----------------------------------------------------------------------
-- PHẦN CLIENT
----------------------------------------------------------------------
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")

local player = Players.LocalPlayer
local remote = ReplicatedStorage:WaitForChild("AdminToolsRemote")

----------------------------------------------------------------------
-- Cổng admin: chờ server báo trạng thái
----------------------------------------------------------------------
local function waitAdminStatus()
	local deadline = os.clock() + 20
	while os.clock() < deadline do
		local value = player:GetAttribute("IsAdmin")
		if value ~= nil then
			return value == true
		end
		task.wait(0.2)
	end
	return false
end

if not waitAdminStatus() then
	return
end

----------------------------------------------------------------------
-- Trạng thái chung + thông báo
----------------------------------------------------------------------
local state = { Fly = false, Noclip = false, Invisible = false, Locator = false, AntiLag = false }
local statusLabel
local setState -- khai báo trước, gán sau khi dựng giao diện

local function notify(text)
	if not statusLabel then
		return
	end
	statusLabel.Text = text
	local token = os.clock()
	statusLabel:SetAttribute("Token", token)
	task.delay(4, function()
		if statusLabel and statusLabel:GetAttribute("Token") == token then
			statusLabel.Text = ""
		end
	end)
end

local function getCharacterParts()
	local character = player.Character
	if not character then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if root and humanoid then
		return character, root, humanoid
	end
	return nil
end

----------------------------------------------------------------------
-- BAY
----------------------------------------------------------------------
local flySpeed = 60
local flyHeld = { Up = false, Down = false }
local flyConn
local flyObjects
local controlsModule

local function getControls()
	if controlsModule then
		return controlsModule
	end
	local scripts = player:FindFirstChild("PlayerScripts")
	local module = scripts and scripts:FindFirstChild("PlayerModule")
	if module then
		local ok, result = pcall(function()
			return require(module):GetControls()
		end)
		if ok then
			controlsModule = result
		end
	end
	return controlsModule
end

local function stopFly()
	if flyConn then
		flyConn:Disconnect()
		flyConn = nil
	end
	if flyObjects then
		for _, obj in ipairs(flyObjects) do
			obj:Destroy()
		end
		flyObjects = nil
	end
	local _, _, humanoid = getCharacterParts()
	if humanoid then
		humanoid.PlatformStand = false
		humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
	end
	flyHeld.Up = false
	flyHeld.Down = false
end

local function setFly(on)
	if not on then
		stopFly()
		return false
	end
	if flyObjects then
		return true
	end

	local _, root, humanoid = getCharacterParts()
	if not root then
		notify("Chưa có nhân vật để bay.")
		return false
	end

	local attachment = Instance.new("Attachment")
	attachment.Name = "AdminFlyAttachment"
	attachment.Parent = root

	local linear = Instance.new("LinearVelocity")
	linear.Attachment0 = attachment
	linear.RelativeTo = Enum.ActuatorRelativeTo.World
	linear.MaxForce = math.huge
	linear.VectorVelocity = Vector3.zero
	linear.Parent = root

	local align = Instance.new("AlignOrientation")
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = attachment
	align.RigidityEnabled = false
	align.MaxTorque = math.huge
	align.Responsiveness = 30
	align.CFrame = root.CFrame.Rotation
	align.Parent = root

	flyObjects = { attachment, linear, align }
	humanoid.PlatformStand = true
	humanoid.Died:Once(function()
		if state.Fly then
			setState("Fly", setFly(false))
		end
	end)

	flyConn = RunService.RenderStepped:Connect(function()
		local camera = workspace.CurrentCamera
		local direction = Vector3.zero
		local controls = getControls()
		if controls then
			direction = camera.CFrame:VectorToWorldSpace(controls:GetMoveVector())
		end

		local vertical = 0
		local typing = UserInputService:GetFocusedTextBox() ~= nil
		if flyHeld.Up or (not typing and UserInputService:IsKeyDown(Enum.KeyCode.Space)) then
			vertical += 1
		end
		if
			flyHeld.Down
			or (
				not typing
				and (
					UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)
					or UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
				)
			)
		then
			vertical -= 1
		end

		local velocity = direction + Vector3.new(0, vertical, 0)
		if velocity.Magnitude > 0.01 then
			velocity = velocity.Unit * flySpeed
		end
		linear.VectorVelocity = velocity

		local look = camera.CFrame.LookVector
		local flat = Vector3.new(look.X, 0, look.Z)
		if flat.Magnitude > 0.01 then
			align.CFrame = CFrame.lookAt(Vector3.zero, flat)
		end
	end)
	return true
end

----------------------------------------------------------------------
-- XUYÊN TƯỜNG (Noclip)
-- Lưu ý: tắt va chạm toàn bộ nhân vật nên sẽ rơi xuyên sàn nếu không bật Bay.
----------------------------------------------------------------------
local noclipConn
local noclipOriginal = setmetatable({}, { __mode = "k" })

local function setNoclip(on)
	if noclipConn then
		noclipConn:Disconnect()
		noclipConn = nil
	end
	if on then
		noclipConn = RunService.Stepped:Connect(function()
			local character = player.Character
			if not character then
				return
			end
			for _, part in ipairs(character:GetDescendants()) do
				if part:IsA("BasePart") and part.CanCollide then
					noclipOriginal[part] = true
					part.CanCollide = false
				end
			end
		end)
		if not state.Fly then
			notify("Xuyên tường bật. Hãy bật Bay để không rơi xuyên sàn.")
		end
		return true
	end

	for part in pairs(noclipOriginal) do
		if part.Parent then
			part.CanCollide = true
		end
	end
	table.clear(noclipOriginal)
	return false
end

----------------------------------------------------------------------
-- ĐỊNH VỊ người chơi + bot (Highlight xuyên tường + nhãn tên/khoảng cách)
-- Lưu ý: Roblox chỉ vẽ tối đa khoảng 31 Highlight cùng lúc; nhãn tên vẫn hiện đủ.
----------------------------------------------------------------------
local PLAYER_COLOR = Color3.fromRGB(80, 200, 255)
local BOT_COLOR = Color3.fromRGB(255, 170, 60)

local espEnabled = false
local espGeneration = 0
local espTargets = {} -- [Model] = true (đang tạo) | { highlight, gui, label, root }
local espAddedConn

local function destroyEspData(data)
	if type(data) ~= "table" then
		return
	end
	data.highlight:Destroy()
	data.gui:Destroy()
end

local function addEspTarget(model)
	if espTargets[model] or model == player.Character then
		return
	end
	espTargets[model] = true
	local generation = espGeneration

	task.spawn(function()
		local root = model:WaitForChild("HumanoidRootPart", 5) or model.PrimaryPart
		if
			generation ~= espGeneration
			or espTargets[model] ~= true
			or not root
			or not model:IsDescendantOf(workspace)
		then
			if generation == espGeneration then
				espTargets[model] = nil
			end
			return
		end

		local highlight = Instance.new("Highlight")
		highlight.Name = "AdminESP"
		highlight.Adornee = model
		highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		highlight.FillTransparency = 0.75
		highlight.Parent = model -- chỉ tồn tại ở client của bạn

		local gui = Instance.new("BillboardGui")
		gui.Name = "AdminESPLabel"
		gui.Adornee = root
		gui.AlwaysOnTop = true
		gui.Size = UDim2.fromOffset(140, 36)
		gui.StudsOffset = Vector3.new(0, 3.5, 0)
		gui.MaxDistance = 3000
		gui.Parent = root

		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(1, 1)
		label.Font = Enum.Font.GothamBold
		label.TextSize = 13
		label.TextStrokeTransparency = 0.4
		label.TextColor3 = Color3.new(1, 1, 1)
		label.Parent = gui

		espTargets[model] = { highlight = highlight, gui = gui, label = label, root = root }
	end)
end

local function considerHumanoid(inst)
	if inst:IsA("Humanoid") then
		local model = inst.Parent
		if model and model:IsA("Model") then
			addEspTarget(model)
		end
	end
end

local function setLocator(on)
	if on == espEnabled then
		return on
	end
	espEnabled = on
	espGeneration += 1

	if not on then
		if espAddedConn then
			espAddedConn:Disconnect()
			espAddedConn = nil
		end
		for _, data in pairs(espTargets) do
			destroyEspData(data)
		end
		table.clear(espTargets)
		return false
	end

	for _, inst in ipairs(workspace:GetDescendants()) do
		considerHumanoid(inst)
	end
	espAddedConn = workspace.DescendantAdded:Connect(considerHumanoid)

	local generation = espGeneration
	task.spawn(function()
		while espEnabled and generation == espGeneration do
			local myRoot = select(2, getCharacterParts())
			for model, data in pairs(espTargets) do
				if type(data) == "table" then
					if not model:IsDescendantOf(workspace) or not data.root:IsDescendantOf(workspace) then
						destroyEspData(data)
						espTargets[model] = nil
					else
						local owner = Players:GetPlayerFromCharacter(model)
						local color = owner and PLAYER_COLOR or BOT_COLOR
						data.highlight.FillColor = color
						data.highlight.OutlineColor = color
						data.label.TextColor3 = color
						local distance = myRoot and (myRoot.Position - data.root.Position).Magnitude or 0
						data.label.Text = string.format(
							"%s [%s]\n%d studs",
							owner and owner.DisplayName or model.Name,
							owner and "Player" or "Bot",
							distance
						)
					end
				end
			end
			task.wait(0.2)
		end
	end)
	return true
end

----------------------------------------------------------------------
-- GIẢM LAG (chế độ hiệu năng, hoàn tác được)
----------------------------------------------------------------------
local perfOn = false
local perfSaved = setmetatable({}, { __mode = "k" }) -- [Instance] = { prop = giá trị gốc }
local perfGlobals
local perfAddedConns = {}

local EFFECT_CLASSES = {
	ParticleEmitter = true, Trail = true, Beam = true, Smoke = true, Fire = true, Sparkles = true,
	BloomEffect = true, BlurEffect = true, DepthOfFieldEffect = true, SunRaysEffect = true,
}

local function trySet(object, property, value)
	pcall(function()
		object[property] = value
	end)
end

local function applyPerf(inst)
	if perfSaved[inst] then
		return
	end
	if EFFECT_CLASSES[inst.ClassName] then
		perfSaved[inst] = { Enabled = inst.Enabled }
		inst.Enabled = false
	elseif inst:IsA("Terrain") then
		return
	elseif inst:IsA("MeshPart") then
		perfSaved[inst] = {
			CastShadow = inst.CastShadow,
			Reflectance = inst.Reflectance,
			RenderFidelity = inst.RenderFidelity,
		}
		inst.CastShadow = false
		inst.Reflectance = 0
		inst.RenderFidelity = Enum.RenderFidelity.Performance
	elseif inst:IsA("BasePart") then
		perfSaved[inst] = { CastShadow = inst.CastShadow, Reflectance = inst.Reflectance }
		inst.CastShadow = false
		inst.Reflectance = 0
	end
end

local function setAntiLag(on)
	if on == perfOn then
		return on
	end
	perfOn = on

	if on then
		local terrain = workspace.Terrain
		perfGlobals = {
			shadows = Lighting.GlobalShadows,
			decoration = terrain.Decoration,
			waveSize = terrain.WaterWaveSize,
			reflectance = terrain.WaterReflectance,
		}
		pcall(function()
			perfGlobals.quality = settings().Rendering.QualityLevel
		end)

		trySet(Lighting, "GlobalShadows", false)
		trySet(terrain, "Decoration", false)
		trySet(terrain, "WaterWaveSize", 0)
		trySet(terrain, "WaterReflectance", 0)
		trySet(settings().Rendering, "QualityLevel", Enum.QualityLevel.Level01)

		for _, root in ipairs({ workspace, Lighting }) do
			table.insert(
				perfAddedConns,
				root.DescendantAdded:Connect(function(inst)
					if perfOn then
						applyPerf(inst)
					end
				end)
			)
			-- Xử lý theo đợt để không giật khung hình khi map lớn.
			task.spawn(function()
				local count = 0
				for _, inst in ipairs(root:GetDescendants()) do
					if not perfOn then
						break
					end
					applyPerf(inst)
					count += 1
					if count % 400 == 0 then
						task.wait()
					end
				end
			end)
		end
		return true
	end

	for _, conn in ipairs(perfAddedConns) do
		conn:Disconnect()
	end
	table.clear(perfAddedConns)

	for inst, props in pairs(perfSaved) do
		if inst.Parent then
			for property, value in pairs(props) do
				trySet(inst, property, value)
			end
		end
	end
	table.clear(perfSaved)

	if perfGlobals then
		local terrain = workspace.Terrain
		trySet(Lighting, "GlobalShadows", perfGlobals.shadows)
		trySet(terrain, "Decoration", perfGlobals.decoration)
		trySet(terrain, "WaterWaveSize", perfGlobals.waveSize)
		trySet(terrain, "WaterReflectance", perfGlobals.reflectance)
		if perfGlobals.quality then
			trySet(settings().Rendering, "QualityLevel", perfGlobals.quality)
		end
		perfGlobals = nil
	end
	return false
end

----------------------------------------------------------------------
-- Danh sách tính năng
----------------------------------------------------------------------
local features = {
	Fly = { label = "Bay", key = Enum.KeyCode.F, apply = setFly },
	Noclip = { label = "Xuyên tường", key = Enum.KeyCode.N, apply = setNoclip },
	Invisible = {
		label = "Tàng hình",
		key = Enum.KeyCode.V,
		apply = function(on)
			remote:FireServer("Invisible", on)
			return nil -- server sẽ gửi lại "State" để cập nhật nút
		end,
	},
	Locator = { label = "Định vị", key = Enum.KeyCode.L, apply = setLocator },
	AntiLag = { label = "Giảm lag", key = Enum.KeyCode.P, apply = setAntiLag },
}
local featureOrder = { "Fly", "Noclip", "Invisible", "Locator", "AntiLag" }

----------------------------------------------------------------------
-- Giao diện
----------------------------------------------------------------------
local COLOR_ON = Color3.fromRGB(46, 160, 90)
local COLOR_OFF = Color3.fromRGB(52, 56, 68)
local COLOR_TEXT = Color3.fromRGB(235, 238, 245)

local function create(className, props, parent)
	local inst = Instance.new(className)
	for key, value in pairs(props) do
		inst[key] = value
	end
	inst.Parent = parent
	return inst
end

local screenGui = create("ScreenGui", {
	Name = "AdminTools",
	ResetOnSpawn = false,
	DisplayOrder = 100,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
}, player:WaitForChild("PlayerGui"))

local panel = create("Frame", {
	Name = "Panel",
	Size = UDim2.fromOffset(250, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	Position = UDim2.new(0, 12, 0.25, 0),
	BackgroundColor3 = Color3.fromRGB(28, 30, 38),
	BorderSizePixel = 0,
}, screenGui)
create("UICorner", { CornerRadius = UDim.new(0, 8) }, panel)
create("UIPadding", {
	PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8),
	PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8),
}, panel)
create("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, panel)

local function makeButton(text, order, parent, size, position)
	local button = create("TextButton", {
		Text = text,
		LayoutOrder = order,
		Size = size or UDim2.new(1, 0, 0, 30),
		Position = position or UDim2.new(),
		BackgroundColor3 = COLOR_OFF,
		TextColor3 = COLOR_TEXT,
		Font = Enum.Font.GothamMedium,
		TextSize = 14,
		BorderSizePixel = 0,
	}, parent or panel)
	create("UICorner", { CornerRadius = UDim.new(0, 6) }, button)
	return button
end

local function makeRow(order)
	return create("Frame", {
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, 30),
		BackgroundTransparency = 1,
	}, panel)
end

-- Thanh tiêu đề (kéo để di chuyển bảng)
local title = create("TextLabel", {
	LayoutOrder = 0,
	Size = UDim2.new(1, 0, 0, 24),
	BackgroundTransparency = 1,
	Text = "Admin Tools  (kéo để di chuyển)",
	TextColor3 = COLOR_TEXT,
	Font = Enum.Font.GothamBold,
	TextSize = 14,
	Active = true,
}, panel)

local fpsLabel = create("TextLabel", {
	LayoutOrder = 1,
	Size = UDim2.new(1, 0, 0, 16),
	BackgroundTransparency = 1,
	Text = "FPS: --",
	TextColor3 = Color3.fromRGB(150, 220, 170),
	Font = Enum.Font.Gotham,
	TextSize = 12,
}, panel)

local dragging, dragStart, startPos = false, nil, nil
title.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		dragging = true
		dragStart = input.Position
		startPos = panel.Position
		input.Changed:Connect(function()
			if input.UserInputState == Enum.UserInputState.End then
				dragging = false
			end
		end)
	end
end)
UserInputService.InputChanged:Connect(function(input)
	if
		dragging
		and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch)
	then
		local delta = input.Position - dragStart
		panel.Position = UDim2.new(
			startPos.X.Scale, startPos.X.Offset + delta.X,
			startPos.Y.Scale, startPos.Y.Offset + delta.Y
		)
	end
end)

-- Nút bật/tắt tính năng
local buttons = {}
for index, name in ipairs(featureOrder) do
	buttons[name] = makeButton("", 10 + index)
end

-- Chỉnh tốc độ bay
local speedRow = makeRow(20)
local speedMinus = makeButton("-", 0, speedRow, UDim2.new(0.2, -3, 1, 0), UDim2.new(0, 0, 0, 0))
local speedLabel = create("TextLabel", {
	Size = UDim2.new(0.6, 0, 1, 0),
	Position = UDim2.new(0.2, 0, 0, 0),
	BackgroundTransparency = 1,
	TextColor3 = COLOR_TEXT,
	Font = Enum.Font.Gotham,
	TextSize = 13,
}, speedRow)
local speedPlus = makeButton("+", 0, speedRow, UDim2.new(0.2, -3, 1, 0), UDim2.new(0.8, 3, 0, 0))
local function refreshSpeed()
	speedLabel.Text = "Tốc độ bay: " .. flySpeed
end
refreshSpeed()
speedMinus.MouseButton1Click:Connect(function()
	flySpeed = math.max(10, flySpeed - 10)
	refreshSpeed()
end)
speedPlus.MouseButton1Click:Connect(function()
	flySpeed = math.min(250, flySpeed + 10)
	refreshSpeed()
end)

-- Nút Lên/Xuống cho mobile (chỉ hiện khi đang bay)
local flyRow = makeRow(21)
flyRow.Visible = false
local upButton = makeButton("▲ Lên", 0, flyRow, UDim2.new(0.5, -3, 1, 0), UDim2.new(0, 0, 0, 0))
local downButton = makeButton("▼ Xuống", 0, flyRow, UDim2.new(0.5, -3, 1, 0), UDim2.new(0.5, 3, 0, 0))
local function holdButton(button, key)
	button.MouseButton1Down:Connect(function()
		flyHeld[key] = true
	end)
	button.MouseButton1Up:Connect(function()
		flyHeld[key] = false
	end)
	button.MouseLeave:Connect(function()
		flyHeld[key] = false
	end)
end
holdButton(upButton, "Up")
holdButton(downButton, "Down")

-- Dịch chuyển theo tên
local nameBox = create("TextBox", {
	LayoutOrder = 30,
	Size = UDim2.new(1, 0, 0, 30),
	BackgroundColor3 = Color3.fromRGB(40, 43, 54),
	TextColor3 = COLOR_TEXT,
	PlaceholderText = "Tên người chơi / bot...",
	PlaceholderColor3 = Color3.fromRGB(130, 135, 150),
	Text = "",
	ClearTextOnFocus = false,
	Font = Enum.Font.Gotham,
	TextSize = 14,
	BorderSizePixel = 0,
}, panel)
create("UICorner", { CornerRadius = UDim.new(0, 6) }, nameBox)

local teleportButton = makeButton("Dịch chuyển tới", 31)

local function requestTeleport()
	local text = nameBox.Text
	if text:match("^%s*$") then
		notify("Hãy nhập tên người chơi trước.")
		return
	end
	remote:FireServer("Teleport", text)
end
teleportButton.MouseButton1Click:Connect(requestTeleport)
nameBox.FocusLost:Connect(function(enterPressed)
	if enterPressed then
		requestTeleport()
	end
end)

statusLabel = create("TextLabel", {
	LayoutOrder = 40,
	Size = UDim2.new(1, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundTransparency = 1,
	Text = "",
	TextWrapped = true,
	TextColor3 = Color3.fromRGB(255, 214, 120),
	Font = Enum.Font.Gotham,
	TextSize = 12,
}, panel)

create("TextLabel", {
	LayoutOrder = 41,
	Size = UDim2.new(1, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundTransparency = 1,
	Text = "Phím: F/N/V/L/P • RightShift ẩn/hiện • Space lên • Ctrl/Shift xuống",
	TextWrapped = true,
	TextColor3 = Color3.fromRGB(130, 135, 150),
	Font = Enum.Font.Gotham,
	TextSize = 11,
}, panel)

----------------------------------------------------------------------
-- Gắn logic bật/tắt
----------------------------------------------------------------------
setState = function(name, value)
	state[name] = value
	local button = buttons[name]
	local feature = features[name]
	if button and feature then
		button.Text = string.format("%s [%s]: %s", feature.label, feature.key.Name, value and "BẬT" or "TẮT")
		button.BackgroundColor3 = value and COLOR_ON or COLOR_OFF
	end
	if name == "Fly" then
		flyRow.Visible = value
	end
end

local function toggleFeature(name)
	local result = features[name].apply(not state[name])
	if result ~= nil then
		setState(name, result)
	end
end

for _, name in ipairs(featureOrder) do
	setState(name, false)
	buttons[name].MouseButton1Click:Connect(function()
		toggleFeature(name)
	end)
end

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then
		return
	end
	if input.KeyCode == Enum.KeyCode.RightShift then
		panel.Visible = not panel.Visible
		return
	end
	for _, name in ipairs(featureOrder) do
		if input.KeyCode == features[name].key then
			toggleFeature(name)
			return
		end
	end
end)

remote.OnClientEvent:Connect(function(kind, a, b)
	if kind == "Notify" then
		notify(a)
	elseif kind == "State" then
		setState(a, b)
	end
end)

-- Hồi sinh: dừng bay (đối tượng bay gắn với nhân vật cũ).
player.CharacterAdded:Connect(function()
	if state.Fly then
		setState("Fly", setFly(false))
	end
end)

-- Đếm FPS
local frames, lastTick = 0, os.clock()
RunService.RenderStepped:Connect(function()
	frames += 1
	local now = os.clock()
	if now - lastTick >= 0.5 then
		fpsLabel.Text = "FPS: " .. math.floor(frames / (now - lastTick) + 0.5)
		frames = 0
		lastTick = now
	end
end)
