-- PvP Combat System (Server)
-- Handles damage, combos, block/parry, and NPCs

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

-- Config
local MAX_HP = 100
local M1_DAMAGE = 12
local M1_BLOCK_DAMAGE = 4
local M1_FINISHER_DMG = 20
local M2_PARRY_WINDOW = 0.35
local M2_PARRY_STUN = 1.8
local M1_COOLDOWN = 0.45
local M1_COMBO_RESET = 1.6
local M1_RANGE = 7
local KNOCKBACK_FORCE = 55
local REGEN_DELAY = 6
local REGEN_RATE = 2

-- RemoteEvents
local eventsFolder = ReplicatedStorage:WaitForChild("CombatEvents")
local remoteM1 = eventsFolder:WaitForChild("M1Hit")
local remoteM2Block = eventsFolder:WaitForChild("M2Block")
local remoteM2Rel = eventsFolder:WaitForChild("M2Release")
local remoteFB = eventsFolder:WaitForChild("CombatFeedback")

-- CombatPlayer class
local CombatPlayer = {}
CombatPlayer.__index = CombatPlayer

function CombatPlayer.new(player)
	local self = setmetatable({}, CombatPlayer)
	self.player = player
	self.hp = MAX_HP
	self.comboCount = 0
	self.lastM1Time = 0
	self.lastDmgTime = 0
	self.isBlocking = false
	self.blockStart = 0
	self.isStunned = false
	self.stunUntil = 0
	self.isDead = false
	self.onCooldown = false
	return self
end

function CombatPlayer:takeDamage(amount, attacker)
	if self.isDead then return 0 end

	local now = tick()
	if self.isBlocking then
		local timeSinceBlock = now - self.blockStart
		if timeSinceBlock <= M2_PARRY_WINDOW then
			-- parry successful
			self:_triggerParryOn(attacker)
			remoteFB:FireClient(self.player, "PARRIED", attacker.player.Name)
			remoteFB:FireClient(attacker.player, "STUNNED", self.player.Name)
			return 0
		else
			amount = M1_BLOCK_DAMAGE
			remoteFB:FireClient(self.player, "BLOCKED", tostring(amount))
		end
	end

	self.hp = math.max(0, self.hp - amount)
	self.lastDmgTime = now

	local char = self.player.Character
	if char then
		local hum = char:FindFirstChildOfClass("Humanoid")
		if hum then hum.Health = self.hp end
	end

	remoteFB:FireClient(self.player, "TOOK_DAMAGE", amount, self.hp)

	if self.hp <= 0 then self:_handleDeath() end
	return amount
end

function CombatPlayer:_triggerParryOn(attackerCP)
	attackerCP.isStunned = true
	attackerCP.stunUntil = tick() + M2_PARRY_STUN
	local char = attackerCP.player.Character
	if char then
		local hum = char:FindFirstChildOfClass("Humanoid")
		if hum then hum.WalkSpeed = 0; hum.JumpPower = 0 end
	end
	task.delay(M2_PARRY_STUN, function() attackerCP:_removeStun() end)
end

function CombatPlayer:_removeStun()
	self.isStunned = false
	local char = self.player.Character
	if char then
		local hum = char:FindFirstChildOfClass("Humanoid")
		if hum then hum.WalkSpeed = 16; hum.JumpPower = 50 end
	end
end

function CombatPlayer:_handleDeath()
	if self.isDead then return end
	self.isDead = true
	local char = self.player.Character
	if char then
		local hum = char:FindFirstChildOfClass("Humanoid")
		if hum then hum:TakeDamage(hum.Health) end
	end
	remoteFB:FireClient(self.player, "DIED")
	task.delay(3, function() self:_reset() end)
end

function CombatPlayer:_reset()
	self.hp = MAX_HP
	self.comboCount = 0
	self.lastM1Time = 0
	self.lastDmgTime = 0
	self.isBlocking = false
	self.blockStart = 0
	self.isStunned = false
	self.stunUntil = 0
	self.isDead = false
	self.onCooldown = false
end

-- Player registry
local registry = {}

local function registerPlayer(player)
	registry[player] = CombatPlayer.new(player)
end
local function unregisterPlayer(player) registry[player] = nil end
local function getCombatPlayer(player) return registry[player] end

-- NPC registry
local npcRegistry = {}

local function registerNPC(model)
	if npcRegistry[model] then return end
	local hum = model:FindFirstChildOfClass("Humanoid")
	if not hum then return end
	npcRegistry[model] = {hp = hum.MaxHealth > 0 and hum.MaxHealth or MAX_HP, isDead = false}
	hum.HealthChanged:Connect(function(newHP)
		local state = npcRegistry[model]
		if state then
			state.hp = newHP
			if newHP <= 0 then state.isDead = true end
		end
	end)
end

for _, obj in ipairs(workspace:GetDescendants()) do
	if obj:IsA("Model") and obj:FindFirstChildOfClass("Humanoid") then
		registerNPC(obj)
	end
end

workspace.DescendantAdded:Connect(function(obj)
	if obj:IsA("Humanoid") then
		local model = obj.Parent
		if model and model:IsA("Model") then registerNPC(model) end
	end
end)

-- Hit detection helper
local overlapParams = OverlapParams.new()
overlapParams.FilterType = Enum.RaycastFilterType.Exclude

local function detectHit(attackerPlayer)
	local char = attackerPlayer.Character
	if not char then return {}, {} end
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if not hrp then return {}, {} end

	local attackCF = hrp.CFrame * CFrame.new(0,0,-(M1_RANGE/2))
	local boxSize = Vector3.new(M1_RANGE,6,M1_RANGE)
	overlapParams.FilterDescendantsInstances = {char}
	local parts = workspace:GetPartBoundsInBox(attackCF, boxSize, overlapParams)

	local seenModels = {}
	local playerTargets = {}
	local npcTargets = {}

	for _, part in ipairs(parts) do
		local model = part:FindFirstAncestorOfClass("Model")
		if model and not seenModels[model] then
			seenModels[model] = true
			local targetPlayer = Players:GetPlayerFromCharacter(model)
			if targetPlayer and targetPlayer ~= attackerPlayer then
				local cp = getCombatPlayer(targetPlayer)
				if cp and not cp.isDead then table.insert(playerTargets, cp) end
			elseif npcRegistry[model] and not npcRegistry[model].isDead then
				table.insert(npcTargets, model)
			end
		end
	end

	return playerTargets, npcTargets
end

-- Knockback helper
local function applyKnockback(attacker, victim, force)
	local aChar = attacker.Character
	local vChar = victim.Character
	if not aChar or not vChar then return end
	local aHRP = aChar:FindFirstChild("HumanoidRootPart")
	local vHRP = vChar:FindFirstChild("HumanoidRootPart")
	if not aHRP or not vHRP then return end
	local dir = (vHRP.Position - aHRP.Position)
	dir = Vector3.new(dir.X,0.4,dir.Z).Unit
	local bv = Instance.new("BodyVelocity")
	bv.Velocity = dir * force
	bv.MaxForce = Vector3.new(1e5,1e5,1e5)
	bv.P = 1e4
	bv.Parent = vHRP
	Debris:AddItem(bv,0.18)
end

-- M1 attack
remoteM1.OnServerEvent:Connect(function(attacker)
	local attackerCP = getCombatPlayer(attacker)
	if not attackerCP then return end
	if attackerCP.isDead or attackerCP.isStunned or attackerCP.isBlocking or attackerCP.onCooldown then return end

	local now = tick()
	if (now - attackerCP.lastM1Time) > M1_COMBO_RESET then attackerCP.comboCount = 0 end
	attackerCP.comboCount = (attackerCP.comboCount % 4) + 1
	attackerCP.lastM1Time = now
	attackerCP.onCooldown = true
	task.delay(M1_COOLDOWN, function() attackerCP.onCooldown = false end)

	local isFinisher = attackerCP.comboCount == 4
	local rawDamage = isFinisher and M1_FINISHER_DMG or M1_DAMAGE
	local playerTargets, npcTargets = detectHit(attacker)

	for _, victimCP in ipairs(playerTargets) do
		local dealt = victimCP:takeDamage(rawDamage, attackerCP)
		if dealt > 0 then
			local kb = isFinisher and KNOCKBACK_FORCE*1.6 or KNOCKBACK_FORCE
			applyKnockback(attacker, victimCP.player, kb)
			remoteFB:FireClient(attacker, "HIT", dealt, victimCP.player.Name, isFinisher)
		end
	end

	for _, npcModel in ipairs(npcTargets) do
		local hum = npcModel:FindFirstChildOfClass("Humanoid")
		if hum then
			hum:TakeDamage(rawDamage)
			local kb = isFinisher and KNOCKBACK_FORCE*1.6 or KNOCKBACK_FORCE
			local aHRP = attacker.Character and attacker.Character:FindFirstChild("HumanoidRootPart")
			local vHRP = npcModel:FindFirstChild("HumanoidRootPart")
			if aHRP and vHRP then
				local dir = Vector3.new(vHRP.Position.X - aHRP.Position.X,0.4,vHRP.Position.Z - aHRP.Position.Z).Unit
				local bv = Instance.new("BodyVelocity")
				bv.Velocity = dir * kb
				bv.MaxForce = Vector3.new(1e5,1e5,1e5)
				bv.P = 1e4
				bv.Parent = vHRP
				Debris:AddItem(bv,0.18)
			end
			remoteFB:FireClient(attacker, "HIT", rawDamage, npcModel.Name, isFinisher)
		end
	end
end)

-- M2 block
remoteM2Block.OnServerEvent:Connect(function(player)
	local cp = getCombatPlayer(player)
	if not cp or cp.isDead or cp.isStunned then return end
	cp.isBlocking = true
	cp.blockStart = tick()
	local char = player.Character
	if char then
		local hum = char:FindFirstChildOfClass("Humanoid")
		if hum then hum.WalkSpeed = 8 end
	end
end)

remoteM2Rel.OnServerEvent:Connect(function(player)
	local cp = getCombatPlayer(player)
	if not cp then return end
	cp.isBlocking = false
	local char = player.Character
	if char then
		local hum = char:FindFirstChildOfClass("Humanoid")
		if hum and not cp.isStunned then hum.WalkSpeed = 16 end
	end
end)

-- HP regen
RunService.Heartbeat:Connect(function()
	local now = tick()
	for player, cp in pairs(registry) do
		if not cp.isDead and cp.hp < MAX_HP and (now - cp.lastDmgTime) >= REGEN_DELAY then
			cp.hp = math.min(MAX_HP, cp.hp + (REGEN_RATE/60))
			local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
			if hum then hum.Health = cp.hp end
		end
	end
end)

-- Player lifecycle
Players.PlayerAdded:Connect(registerPlayer)
Players.PlayerRemoving:Connect(unregisterPlayer)
for _, p in ipairs(Players:GetPlayers()) do registerPlayer(p) end

print("Combat System") 


-- PvP Combat System (Client Input)
-- StarterPlayerScripts
local Players           = game:GetService("Players")
local UserInputService  = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")
local Debris            = game:GetService("Debris")
local player = Players.LocalPlayer


-- Remote Events
local eventsFolder  = ReplicatedStorage:WaitForChild("CombatEvents", 15)
local remoteM1      = eventsFolder:WaitForChild("M1Hit",          15)
local remoteM2Block = eventsFolder:WaitForChild("M2Block",        15)
local remoteM2Rel   = eventsFolder:WaitForChild("M2Release",      15)
local remoteFB      = eventsFolder:WaitForChild("CombatFeedback", 15)

-- State
local isBlocking        = false
local m1Cooldown        = false
local M1_LOCAL_COOLDOWN = 0.4    
local comboIndex        = 0      
local lastSwingTime     = 0     
local COMBO_RESET_TIME  = 1.6   


-- Animations IDs
local ANIM_IDS = {
	punch1 = "rbxassetid://93863819424859", 
	punch2 = "rbxassetid://122001408099699",
	punch3 = "rbxassetid://97904674266679",  
	punch4 = "rbxassetid://87026046828127", 
	punch5 = "rbxassetid://136316029926876",
	block  = "rbxassetid://0",   
}

-- Animation tracks
local animTracks = {}


local function loadAnimations(character)
	local humanoid = character:WaitForChild("Humanoid")
	local animator = humanoid:WaitForChild("Animator")

	animTracks = {}  

	for name, id in pairs(ANIM_IDS) do
		if id ~= "rbxassetid://0" then
			local animObject       = Instance.new("Animation")
			animObject.AnimationId = id
			local track            = animator:LoadAnimation(animObject)
			track.Looped           = (name == "block")   
			track.Priority         = Enum.AnimationPriority.Action
			animTracks[name]       = track
		end
	end
end


local function playPunchAnim(index)
	local track = animTracks["punch" .. index]
	if track then
		if track.IsPlaying then track:Stop(0) end
		track:Play(0.1)
	end
end


local function playBlockAnim()
	local track = animTracks["block"]
	if track and not track.IsPlaying then
		track:Play(0.15)
	end
end

local function stopBlockAnim()
	local track = animTracks["block"]
	if track and track.IsPlaying then
		track:Stop(0.15)
	end
end

-- UI
local screenGui = script.Parent
local statusLabel = screenGui:WaitForChild("statusLabel")
local hpBarBg =  screenGui:WaitForChild("hpBarBg")
local hpBarFill = hpBarBg:WaitForChild("hpBarFill")
local hpText =  hpBarBg:WaitForChild("hpText")


local function updateHPBar(currentHP, maxHP)
	maxHP = maxHP or 100
	local ratio = math.clamp(currentHP / maxHP, 0, 1)
	
	TweenService:Create(hpBarFill,
		TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = UDim2.new(ratio, 0, 1, 0)}
	):Play()
	hpText.Text = math.ceil(currentHP) .. " HP"
end


local statusTween
local function showStatus(text, color)
	color = color 
	statusLabel.Text             = text
	statusLabel.TextColor3       = color
	statusLabel.TextTransparency = 0
	if statusTween then statusTween:Cancel() end
	task.delay(1.2, function()
		statusTween = TweenService:Create(statusLabel,
			TweenInfo.new(0.5, Enum.EasingStyle.Quad),
			{ TextTransparency = 1 }
		)
		statusTween:Play()
	end)
end

local function getEnemyPosition(targetName)
	local targetPlayer = Players:FindFirstChild(targetName)
	if targetPlayer and targetPlayer.Character then
		local hrp = targetPlayer.Character:FindFirstChild("HumanoidRootPart")
		if hrp then return hrp.Position end
	end
	local npcModel = workspace:FindFirstChild(targetName)
	if npcModel then
		local hrp = npcModel:FindFirstChild("HumanoidRootPart")
		if hrp then return hrp.Position end
	end
	return Vector3.new(0, 10, 0)
end

-- Input
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	-- M1 attack
	if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
	if m1Cooldown or isBlocking then return end

	local char = player.Character
	if not char then return end
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then return end

	local now = tick()
	if (now - lastSwingTime) > COMBO_RESET_TIME then
		comboIndex = 0
	end
	comboIndex    = (comboIndex % 5) + 1
	lastSwingTime = now


	playPunchAnim(comboIndex)

	remoteM1:FireServer()

	m1Cooldown = true
	task.delay(M1_LOCAL_COOLDOWN, function()
		m1Cooldown = false
	end)
end)


UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	-- M2 block
	if input.UserInputType ~= Enum.UserInputType.MouseButton2 then return end
	if isBlocking then return end

	local char = player.Character
	if not char then return end
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then return end

	isBlocking = true
	remoteM2Block:FireServer()

	
	playBlockAnim()

	showStatus("BLOCKING", Color3.fromRGB(80, 160, 255))
end)


UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType ~= Enum.UserInputType.MouseButton2 then return end
	if not isBlocking then return end

	isBlocking = false
	remoteM2Rel:FireServer()


	stopBlockAnim()

	statusLabel.Text = ""
end)

-- Feedback
remoteFB.OnClientEvent:Connect(function(eventType, arg1, arg2, arg3)

	if eventType == "HIT" then
		local pos = getEnemyPosition(arg2)
		if arg3 then showStatus("FINISHER!", Color3.fromRGB(255, 100, 30)) end

	elseif eventType == "TOOK_DAMAGE" then
		updateHPBar(arg2, 100)
		

	elseif eventType == "BLOCKED" then
		showStatus("BLOCKED " .. tostring(arg1) .. " DMG")
		local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		if hum then updateHPBar(hum.Health, 100) end

	elseif eventType == "PARRIED" then
		showStatus("PARRY")

	elseif eventType == "STUNNED" then
		showStatus("STUNNED")
		stopBlockAnim()
		isBlocking = false

	elseif eventType == "DIED" then
		updateHPBar(0, 100)
		stopBlockAnim()
		showStatus("YOU DIED")
		task.delay(3.5, function()
			updateHPBar(100, 100)
		end)
	end
end)

player.CharacterAdded:Connect(function(char)
	isBlocking = false
	m1Cooldown = false
	comboIndex = 0
	loadAnimations(char)
	task.delay(0.5, function()
		updateHPBar(100, 100)
		statusLabel.Text = ""
	end)
end)


if player.Character then
	loadAnimations(player.Character)
	updateHPBar(100, 100)
end

-- Done
print("CombatSystem")
