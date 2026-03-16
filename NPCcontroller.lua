--!strict
-- LOCATION: StarterPlayerScripts/ClientNPCController

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")

local ClientNPCController = {}

-- [ MODULES ]
local BaseConfigurations = require(ReplicatedStorage.Modules.BaseConfigurations)
local NPCConfigurations = require(ReplicatedStorage.Modules.NPCConfigurations)
local CameraShaker = require(ReplicatedStorage.Modules.CameraShaker)

-- [ CONFIGURATION ]
local ROTATION_SPEED = 12 
local CHASE_MULTIPLIER = 1.5 
local SHAKE_MAX_DIST = 50   
local SHAKE_MIN_DIST = 5    
local SHAKE_MAX_MAG = 4     
local SHAKE_ROUGHNESS = 8   
local DEFAULT_KNOCKBACK = 100

-- [ AUDIO ]
local HB_MAX_DISTANCE = 60      
local HB_MIN_DISTANCE = 10      
local HB_MAX_VOLUME = 1.5       
local HB_MIN_PITCH = 1.0        
local HB_MAX_PITCH = 1.3        
local HB_CHECK_RATE = 0.1       

-- [ ASSETS ]
local NPCFolder = ReplicatedStorage:WaitForChild("NPCs") 
local GlobalSounds = Workspace:WaitForChild("Sounds")
local Events = ReplicatedStorage:WaitForChild("Events")
local npcEvent = Events:WaitForChild("NPCInteraction")
local StealZone = Workspace:WaitForChild("StealZone") :: BasePart
local BasesFolder = Workspace:WaitForChild("Bases")

-- [ STATE ]
local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera
local npcs = {} 
local camShaker: any = nil
local activeShakeInstance: any = nil 

local heartbeatSound: Sound? = nil
local lastAudioCheck = 0

-- [[ IGNORE LIST ]] 
local cachedBaseIgnoreList = {} 

-- [ TYPES ]
type NPCData = {
	Model: Model,
	Root: BasePart, 
	Animator: Animator,
	AnimationController: AnimationController,
	HomePosition: Vector3,
	CurrentTarget: boolean, 
	Tracks: {[string]: AnimationTrack},
	CurrentAnim: string?,
	NPCHeartbeat: Sound?, 
	AssignedBase: string?,
	AlertGUI: BillboardGui?,
	IsAlerted: boolean,
	Config: any,
	CatchDistance: number
}

-- [ HELPERS ]
local function setupShaker()
	if camShaker then return end
	camShaker = CameraShaker.new(Enum.RenderPriority.Camera.Value + 1, function(shakeCFrame)
		camera.CFrame = camera.CFrame * shakeCFrame
	end)
	camShaker:Start()
end

local function setupPlayerHeartbeat()
	if heartbeatSound then return end
	local template = GlobalSounds:WaitForChild("Heartbeat", 5)
	if template then
		heartbeatSound = template:Clone()
		heartbeatSound.Name = "PlayerHeartbeat"
		heartbeatSound.Looped = true
		heartbeatSound.Volume = 0
		heartbeatSound.Parent = player:WaitForChild("PlayerGui") 
		heartbeatSound:Play()
	end
end

local function setupBaseSign(baseModel: Model, npcName: string)
	local signModel = baseModel:FindFirstChild("Sign")
	if not signModel then return end
	local mainPart = signModel:FindFirstChild("Main")
	if not mainPart then return end
	local gui = mainPart:FindFirstChild("BaseGUI")
	if not gui then return end
	local textLabel = gui:FindFirstChild("Text") :: TextLabel
	if textLabel then textLabel.Text = npcName .. "'s Base" end
end

-- [[ UPDATE IGNORE LIST ]]
local function updateBaseIgnoreList()
	table.clear(cachedBaseIgnoreList)
	if not BasesFolder then return end

	for _, base in ipairs(BasesFolder:GetChildren()) do
		local walls = base:FindFirstChild("Walls")
		if walls then table.insert(cachedBaseIgnoreList, walls) end

		local roof = base:FindFirstChild("Roof")
		if roof then table.insert(cachedBaseIgnoreList, roof) end
	end
end

-- [[ RAYCAST LOGIC ]]
local function snapToGround(model: Model, targetCFrame: CFrame, hipHeight: number): CFrame
	local params = RaycastParams.new()

	local filter = {model, StealZone, player.Character}
	for _, obj in ipairs(cachedBaseIgnoreList) do
		table.insert(filter, obj)
	end

	params.FilterDescendantsInstances = filter
	params.FilterType = Enum.RaycastFilterType.Exclude

	local result = Workspace:Raycast(targetCFrame.Position + Vector3.new(0, 10, 0), Vector3.new(0, -100, 0), params)
	if result then
		local _, size = model:GetBoundingBox()
		local halfHeight = size.Y / 2
		local newY = result.Position.Y + halfHeight + hipHeight
		return CFrame.new(result.Position.X, newY, result.Position.Z) * targetCFrame.Rotation
	else
		return targetCFrame
	end
end

local function getGroundHeight(model: Model, x: number, z: number, currentY: number): number?
	local params = RaycastParams.new()

	local filter = {model, StealZone, player.Character}
	for _, obj in ipairs(cachedBaseIgnoreList) do
		table.insert(filter, obj)
	end

	params.FilterDescendantsInstances = filter
	params.FilterType = Enum.RaycastFilterType.Exclude

	local origin = Vector3.new(x, currentY + 5, z)
	local result = Workspace:Raycast(origin, Vector3.new(0, -20, 0), params)
	if result then return result.Position.Y end
	return nil
end

local function playAnimation(data: NPCData, animName: string)
	if data.CurrentAnim == animName then return end
	if data.CurrentAnim and data.Tracks[data.CurrentAnim] then
		data.Tracks[data.CurrentAnim]:Stop(0.2)
	end
	local track = data.Tracks[animName]
	if track then
		track:Play(0.2)
		if animName == "Walk" then track:AdjustSpeed(1) end
	end
	data.CurrentAnim = animName
end

-- [[ FIXED: CHECK SOURCE BASE ]]
local function hasStolenItem(baseName: string): boolean
	local char = player.Character
	if not char then return false end

	if char:GetAttribute("Carrying") == true then
		-- Check if the source base matches the Guard's base
		local source = char:GetAttribute("CarriedItem_SourceBase")
		if source and source == baseName then
			return true
		end
	end
	return false
end

local function setupLocalNPC(template: Model, spawnCFrame: CFrame, baseName: string)
	local model = template:Clone()
	model.Name = "LocalGuard_" .. baseName
	local folder = Workspace:FindFirstChild("LocalNPCs") or Instance.new("Folder", Workspace)
	folder.Name = "LocalNPCs"
	model.Parent = folder

	local animController = model:FindFirstChild("AnimationController") or model:FindFirstChild("Humanoid")
	local animator = animController and animController:WaitForChild("Animator", 5) :: Animator
	local rootPart = model:FindFirstChild("Mesh") or model.PrimaryPart :: BasePart
	if not rootPart then rootPart = model:FindFirstChildWhichIsA("MeshPart") :: BasePart end

	if not animController or not animator or not rootPart then return end

	-- [[ DISABLE CLIMBING ]]
	if model:IsA("Model") then
		local humanoid = model:FindFirstChild("Humanoid")
		if humanoid then
			humanoid:SetStateEnabled(Enum.HumanoidStateType.Climbing, false)
			humanoid.AutoJumpEnabled = false
		end
	end

	rootPart.Anchored = true
	model.PrimaryPart = rootPart
	CollectionService:AddTag(model, "NPC")

	local configName = template.Name 
	local config = NPCConfigurations.GetConfig(configName)
	if not config then return end

	local groundCF = snapToGround(model, spawnCFrame, config.HipHeight or 0)
	rootPart.CFrame = groundCF

	local _, size = model:GetBoundingBox()
	local calculatedCatchDist = math.max(5, (math.max(size.X, size.Z) / 2) + 3.5)

	local tracks = {}
	for name, id in pairs(config.Animations) do
		local anim = Instance.new("Animation")
		anim.AnimationId = id
		local track = animator:LoadAnimation(anim)
		track.Looped = true
		if name == "Idle" then track.Priority = Enum.AnimationPriority.Idle
		elseif name == "Walk" then track.Priority = Enum.AnimationPriority.Movement end
		tracks[name] = track
	end

	local sound = nil
	local templateSound = GlobalSounds:FindFirstChild("Heartbeat")
	if templateSound then
		sound = templateSound:Clone()
		sound.Parent = rootPart
		sound.Looped = true
		sound.RollOffMaxDistance = 96
		sound.RollOffMinDistance = 8
		sound.Volume = 2
	end

	local alertGui = model:FindFirstChild("AlertGUI", true) :: BillboardGui
	if alertGui then alertGui.Enabled = false end

	local data: NPCData = {
		Model = model, Root = rootPart, Animator = animator, AnimationController = animController,
		HomePosition = rootPart.Position, CurrentTarget = false, Tracks = tracks, CurrentAnim = nil,
		NPCHeartbeat = sound, AssignedBase = baseName, AlertGUI = alertGui, IsAlerted = false, 
		Config = config,
		CatchDistance = calculatedCatchDist 
	}
	table.insert(npcs, data)
end

local function moveNPC(data: NPCData, targetPos: Vector3, dt: number, speed: number)
	local currentPos = data.Root.Position
	local direction = (Vector3.new(targetPos.X, currentPos.Y, targetPos.Z) - currentPos)
	if direction.Magnitude < 0.5 then return end 
	direction = direction.Unit
	local newPos = currentPos + (direction * speed * dt)
	local groundY = getGroundHeight(data.Model, newPos.X, newPos.Z, currentPos.Y)
	if groundY then
		local _, size = data.Model:GetBoundingBox()
		local halfHeight = size.Y / 2
		newPos = Vector3.new(newPos.X, groundY + halfHeight + (data.Config.HipHeight or 0), newPos.Z)
	end
	local currentLook = data.Root.CFrame.LookVector
	local lerpedLook = currentLook:Lerp(direction, dt * ROTATION_SPEED)
	data.Root.CFrame = CFrame.new(newPos, newPos + lerpedLook)
end

-- [ MAIN UPDATE LOOP ]
local function update(dt: number)
	if not player.Character then return end
	local root = player.Character:FindFirstChild("HumanoidRootPart")
	if not root then return end

	local closestDistance = math.huge
	local closestChaseDistance = math.huge
	local isChasing = false

	lastAudioCheck += dt
	local updateAudio = lastAudioCheck >= HB_CHECK_RATE

	for _, data in ipairs(npcs) do
		if not data.Model.Parent then continue end

		local dist = (root.Position - data.Root.Position).Magnitude

		-- [[ CHANGED: Checks specific base attribute ]]
		local isStolen = hasStolenItem(data.AssignedBase)

		if isStolen then
			if dist < closestDistance then closestDistance = dist end
			if dist < 1000 then 
				if dist < closestChaseDistance then closestChaseDistance = dist end
			end
		end

		local shouldChase = false
		if isStolen and dist < 1000 then 
			shouldChase = true
			isChasing = true
		end

		if shouldChase then
			data.CurrentTarget = true
			if data.AlertGUI and not data.IsAlerted then
				data.AlertGUI.Enabled = true
				data.IsAlerted = true
				local s = GlobalSounds:FindFirstChild("Alert")
				if s then local c = s:Clone(); c.Parent = data.Root; c:Play(); Debris:AddItem(c, 2) end
			end

			moveNPC(data, root.Position, dt, data.Config.WalkSpeed * CHASE_MULTIPLIER)
			playAnimation(data, "Walk")
			if data.NPCHeartbeat and not data.NPCHeartbeat.Playing then data.NPCHeartbeat:Play() end

			if dist < data.CatchDistance then 
				data.Root.CFrame = CFrame.new(data.HomePosition) 
				data.CurrentTarget = false

				local forceMag = data.Config.KnockbackForce or DEFAULT_KNOCKBACK
				local dir = (root.Position - data.Root.Position).Unit
				local velocity = (dir * forceMag) + Vector3.new(0, forceMag * 0.5, 0)
				root.AssemblyLinearVelocity = velocity

				npcEvent:FireServer("PlayerCaught", {
					Base = data.AssignedBase,
					Force = 0
				})
			end
		else
			data.CurrentTarget = false
			if data.AlertGUI then data.AlertGUI.Enabled = false end
			data.IsAlerted = false
			if data.NPCHeartbeat then data.NPCHeartbeat:Stop() end

			local distToHome = (Vector3.new(data.HomePosition.X, 0, data.HomePosition.Z) - Vector3.new(data.Root.Position.X, 0, data.Root.Position.Z)).Magnitude
			if distToHome > 1 then 
				moveNPC(data, data.HomePosition, dt, data.Config.WalkSpeed)
				playAnimation(data, "Walk")
			else 
				playAnimation(data, "Idle")
				if distToHome > 0.1 then data.Root.CFrame = data.Root.CFrame:Lerp(CFrame.new(data.HomePosition) * data.Root.CFrame.Rotation, dt * 5) end
			end
		end
	end

	-- [[ SHAKE & AUDIO ]]
	if not camShaker then setupShaker() end
	if isChasing and closestChaseDistance < SHAKE_MAX_DIST then
		local normalizedDist = math.clamp((closestChaseDistance - SHAKE_MIN_DIST) / (SHAKE_MAX_DIST - SHAKE_MIN_DIST), 0, 1)
		local intensity = (1 - normalizedDist) * SHAKE_MAX_MAG
		if not activeShakeInstance then
			activeShakeInstance = camShaker:ShakeSustain(CameraShaker.Presets.Earthquake)
		end
		if activeShakeInstance then
			activeShakeInstance:SetScaleMagnitude(intensity)
			activeShakeInstance:SetScaleRoughness(SHAKE_ROUGHNESS)
		end
	else
		if activeShakeInstance then activeShakeInstance:StartFadeOut(1); activeShakeInstance = nil end
	end

	if updateAudio then
		lastAudioCheck = 0
		if not heartbeatSound then setupPlayerHeartbeat() end
		if heartbeatSound then
			if closestDistance < HB_MAX_DISTANCE then
				local alpha = math.clamp(1 - ((closestDistance - HB_MIN_DISTANCE) / (HB_MAX_DISTANCE - HB_MIN_DISTANCE)), 0, 1)
				TweenService:Create(heartbeatSound, TweenInfo.new(HB_CHECK_RATE, Enum.EasingStyle.Linear), {
					Volume = alpha * HB_MAX_VOLUME, PlaybackSpeed = HB_MIN_PITCH + (alpha * (HB_MAX_PITCH - HB_MIN_PITCH))
				}):Play()
			else
				if heartbeatSound.Volume > 0 then TweenService:Create(heartbeatSound, TweenInfo.new(0.5), {Volume = 0, PlaybackSpeed = HB_MIN_PITCH}):Play() end
			end
		end
	end
end

local function processBase(base: Instance)
	if not base:IsA("Model") then return end
	local config = BaseConfigurations[base.Name]
	local spawnPart = base:WaitForChild("Spawn", 10) :: BasePart
	if config and config.NPCName and spawnPart then
		setupBaseSign(base, config.NPCName)
		local template = NPCFolder:WaitForChild(config.NPCName, 10)
		if template then setupLocalNPC(template, spawnPart.CFrame, base.Name) end
	end
end

local function init()
	setupPlayerHeartbeat()
	setupShaker()

	-- Initialize Ignore List
	updateBaseIgnoreList()
	if BasesFolder then
		BasesFolder.ChildAdded:Connect(function()
			task.wait(0.5)
			updateBaseIgnoreList()
		end)
	end

	if not BasesFolder then return end
	for _, base in ipairs(BasesFolder:GetChildren()) do task.spawn(processBase, base) end

	BasesFolder.ChildAdded:Connect(function(child) task.spawn(processBase, child) end)
end

task.spawn(init)
RunService.Heartbeat:Connect(update)

print("[ClientNPCController] Active (Logic: Specific Base Chase Only)")

return ClientNPCController
