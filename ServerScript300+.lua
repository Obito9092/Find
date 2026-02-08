-- advanced egg collection system with rebirth multiplier and persistent save functionality
-- this script manages egg spawning, collection, placement mechanics, and brainrot item rewards
-- author: [your name here]
-- version: 1.0

print("[eggsystem] initializing rebirth multiplier and save system")

-- roblox service initialization for core game functionality
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

-- external module dependencies for game data and systems
local BrainrotData = require(ReplicatedStorage:WaitForChild("BrainrotData"))
local BrainrotPack = ReplicatedStorage:WaitForChild("Brainrot pack1")
local EggData = require(script.Parent:WaitForChild("EggData"))
local EggSpawnSystem = require(script.Parent:WaitForChild("EggSpawnSystem"))
local MoneyManager = require(ServerScriptService:WaitForChild("MoneyManager"))
local DataStoreModule = require(ServerScriptService:WaitForChild("DataStoreModule"))

-- global configuration constants
local PICKAXE_DAMAGE = 10000 -- damage dealt per pickaxe hit to eggs
local DAMAGE_COOLDOWN = 0.2 -- minimum time between damage instances in seconds
local BRAINROT_HEIGHT_OFFSET = 3 -- vertical offset for placing brainrot items above ground

-- data storage tables for tracking game state
local eggs = {} -- stores all active egg instances with their health and metadata
local playerEggs = {} -- tracks which egg each player is currently carrying
local swapParts = {} -- references to all egg placement spawn points in plots
local playerAnimations = {} -- stores original joint positions for arm animations
local eggDamageCooldowns = {} -- prevents spam damage by tracking last hit time
local placedBrainrots = {} -- maintains list of all placed brainrot items in world
local PlayerData = {} -- cached player data from datastore for quick access

-- retrieves the number of rebirths a player has completed
-- parameters: userId (number) - the player's unique identifier
-- returns: number of rebirths or 0 if none found
local function getPlayerRebirths(userId)
	-- check cached player data first for performance
	if PlayerData[userId] then
		return PlayerData[userId].Rebirths or 0
	end
	
	-- search through all plots to find player's rebirth count
	for i = 1, 5 do
		local fullPlot = workspace:FindFirstChild("FullPlot" .. i, true)
		if fullPlot then
			local plotSpawn = fullPlot:FindFirstChild("PlotSpawn", true)
			if plotSpawn and plotSpawn:GetAttribute("OwnerId") == userId then
				return plotSpawn:GetAttribute("Rebirths") or 0
			end
		end
	end
	
	return 0
end

-- calculates money multiplier based on rebirth count
-- parameters: rebirths (number) - total number of player rebirths
-- returns: multiplier value (1 + rebirths)
local function getMoneyMultiplier(rebirths)
	return 1 + rebirths
end

-- initializes the health bar display for an egg
-- parameters: egg (instance) - the egg model or part
--            maxHealth (number) - maximum health value
--            eggName (string) - display name for the egg
local function setupHealthBar(egg, maxHealth, eggName)
	local billboardGui = nil
	
	-- locate billboard gui differently for models vs single parts
	if egg:IsA("Model") then
		billboardGui = egg:FindFirstChild("BillboardGui", true)
	else
		billboardGui = egg:FindFirstChild("BillboardGui")
	end
	
	if not billboardGui then return end
	
	local healthBar = billboardGui:FindFirstChild("Health_Bar", true)
	if not healthBar then return end
	
	-- configure health text display
	local healthFrame = healthBar:FindFirstChild("Health")
	if healthFrame then
		local textHealth = healthFrame:FindFirstChild("TextHealth")
		if textHealth then
			textHealth.Text = tostring(maxHealth)
			textHealth.TextColor3 = Color3.new(1, 1, 1)
		end
	end
	
	-- set egg name label
	local nameLabel = healthBar:FindFirstChild("Name")
	if nameLabel then
		nameLabel.Text = eggName
		nameLabel.TextColor3 = Color3.new(1, 1, 1)
	end
	
	-- configure initial health bar appearance
	healthBar.Size = UDim2.new(1, 0, 0, 20)
	healthBar.BackgroundColor3 = Color3.fromRGB(0, 255, 100)
	
	billboardGui.Enabled = true
	billboardGui.AlwaysOnTop = true
end

-- updates health bar visual to reflect current health
-- parameters: egg (instance) - the egg being updated
--            currentHealth (number) - current health value
--            maxHealth (number) - maximum health value
local function updateHealthBar(egg, currentHealth, maxHealth)
	local billboardGui = nil
	
	if egg:IsA("Model") then
		billboardGui = egg:FindFirstChild("BillboardGui", true)
	else
		billboardGui = egg:FindFirstChild("BillboardGui")
	end
	
	if not billboardGui then return end
	
	local healthBar = billboardGui:FindFirstChild("Health_Bar", true)
	if not healthBar then return end
	
	local healthFrame = healthBar:FindFirstChild("Health")
	if not healthFrame then return end
	
	-- update health text
	local textHealth = healthFrame:FindFirstChild("TextHealth")
	if textHealth then
		textHealth.Text = math.floor(currentHealth)
	end
	
	-- calculate health percentage and update bar size
	local percent = math.clamp(currentHealth / maxHealth, 0, 1)
	healthBar.Size = UDim2.new(percent, 0, 0, 20)
	
	-- color code health bar based on remaining health
	if percent > 0.5 then
		healthBar.BackgroundColor3 = Color3.fromRGB(0, 255, 100) -- green for healthy
	elseif percent > 0.25 then
		healthBar.BackgroundColor3 = Color3.fromRGB(255, 200, 0) -- yellow for damaged
	else
		healthBar.BackgroundColor3 = Color3.fromRGB(255, 50, 50) -- red for critical
	end
end

-- animates player arms upward to carry position
-- parameters: player (player instance) - the player to animate
-- returns: boolean indicating success
local function animateArmsUp(player)
	if not player.Character then return end
	
	-- try r15 rig first (newer character type)
	local rightUpperArm = player.Character:FindFirstChild("RightUpperArm")
	local leftUpperArm = player.Character:FindFirstChild("LeftUpperArm")
	
	if rightUpperArm and leftUpperArm then
		local rightShoulder = rightUpperArm:FindFirstChild("RightShoulder")
		local leftShoulder = leftUpperArm:FindFirstChild("LeftShoulder")
		
		if rightShoulder and leftShoulder then
			-- store original positions for later restoration
			local originalRightC0 = rightShoulder.C0
			local originalLeftC0 = leftShoulder.C0
			
			-- calculate new arm positions using cframe rotation
			local carryRightC0 = originalRightC0 * CFrame.Angles(math.rad(-180), math.rad(0), math.rad(-20))
			local carryLeftC0 = originalLeftC0 * CFrame.Angles(math.rad(-180), math.rad(0), math.rad(20))
			
			-- smooth animation using tweenservice
			TweenService:Create(rightShoulder, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {C0 = carryRightC0}):Play()
			TweenService:Create(leftShoulder, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {C0 = carryLeftC0}):Play()
			
			-- cache animation data for reversal
			playerAnimations[player.UserId] = {
				RightShoulder = rightShoulder,
				LeftShoulder = leftShoulder,
				OriginalRightC0 = originalRightC0,
				OriginalLeftC0 = originalLeftC0
			}
			
			return true
		end
	end
	
	-- fallback to r6 rig (older character type)
	local torso = player.Character:FindFirstChild("Torso")
	if torso then
		local rightShoulder = torso:FindFirstChild("Right Shoulder")
		local leftShoulder = torso:FindFirstChild("Left Shoulder")
		
		if rightShoulder and leftShoulder then
			local originalRightC0 = rightShoulder.C0
			local originalLeftC0 = leftShoulder.C0
			
			local carryRightC0 = originalRightC0 * CFrame.Angles(math.rad(-180), math.rad(0), math.rad(-20))
			local carryLeftC0 = originalLeftC0 * CFrame.Angles(math.rad(-180), math.rad(0), math.rad(20))
			
			TweenService:Create(rightShoulder, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {C0 = carryRightC0}):Play()
			TweenService:Create(leftShoulder, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {C0 = carryLeftC0}):Play()
			
			playerAnimations[player.UserId] = {
				RightShoulder = rightShoulder,
				LeftShoulder = leftShoulder,
				OriginalRightC0 = originalRightC0,
				OriginalLeftC0 = originalLeftC0
			}
			
			return true
		end
	end
	
	return false
end

-- reverses arm animation back to normal position
-- parameters: player (player instance) - the player to reset
local function animateArmsDown(player)
	if not playerAnimations[player.UserId] then return end
	
	local animData = playerAnimations[player.UserId]
	
	if animData.RightShoulder and animData.LeftShoulder then
		-- tween back to original positions
		TweenService:Create(animData.RightShoulder, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {C0 = animData.OriginalRightC0}):Play()
		TweenService:Create(animData.LeftShoulder, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {C0 = animData.OriginalLeftC0}):Play()
	end
	
	-- clear cached animation data
	playerAnimations[player.UserId] = nil
end

-- updates all proximity prompts for egg placement based on player state
-- parameters: userId (number) - player identifier
--            hasEgg (boolean) - whether player is carrying an egg
local function updateProximityPrompts(userId, hasEgg)
	for spawnKey, swapData in pairs(swapParts) do
		if swapData.UserId == userId then
			local prompt = swapData.SpawnPart:FindFirstChild("EggPlacePrompt")
			if prompt then
				-- disable if spawn already has egg, otherwise match carry state
				if swapData.HasEgg then
					prompt.Enabled = false
				else
					prompt.Enabled = hasEgg
				end
			end
		end
	end
end

-- updates brainrot placement prompts based on tool inventory
-- parameters: userId (number) - player identifier
local function updatePlacePrompts(userId)
	local player = Players:GetPlayerByUserId(userId)
	if not player or not player.Character then return end
	
	local hasBrainrotTool = false
	
	-- check equipped tool first
	local equippedTool = player.Character:FindFirstChildOfClass("Tool")
	if equippedTool then
		local rarityValue = equippedTool:FindFirstChild("Rarity")
		if rarityValue then
			hasBrainrotTool = true
		end
	end
	
	-- check backpack inventory if nothing equipped
	local backpack = player:FindFirstChild("Backpack")
	if backpack and not hasBrainrotTool then
		for _, item in pairs(backpack:GetChildren()) do
			if item:IsA("Tool") then
				local rarityValue = item:FindFirstChild("Rarity")
				if rarityValue then
					hasBrainrotTool = true
					break
				end
			end
		end
	end
	
	-- update all place prompts in player's plot
	for i = 1, 5 do
		local fullPlot = workspace:FindFirstChild("FullPlot" .. i, true)
		if fullPlot then
			local plotSpawn = fullPlot:FindFirstChild("PlotSpawn", true)
			if plotSpawn and plotSpawn:GetAttribute("OwnerId") == userId then
				for j = 1, 24 do
					local placePart = fullPlot:FindFirstChild("place" .. j, true)
					if placePart then
						local prompt = placePart:FindFirstChild("BrainrotPlacePrompt")
						if prompt then
							local hasPlacedBrainrot = placePart:FindFirstChild("PlacedBrainrot") ~= nil
							-- enable only if has tool and spot is empty
							prompt.Enabled = hasBrainrotTool and not hasPlacedBrainrot
						end
					end
				end
				break
			end
		end
	end
end

-- attaches an egg to player's character for carrying
-- parameters: player (player instance) - the player receiving egg
--            eggModel (instance) - the egg model to give
--            eggName (string) - name of the egg
--            eggData (table) - egg configuration data
local function giveEggToPlayer(player, eggModel, eggName, eggData)
	if not player.Character then return end
	
	-- prevent carrying multiple eggs
	if playerEggs[player.UserId] then
		return
	end
	
	-- attempt arm animation
	local success = animateArmsUp(player)
	if not success then
		return
	end
	
	-- create carried egg copy
	local clonedEgg = eggModel:Clone()
	clonedEgg.Name = "CarriedEgg"
	
	if clonedEgg:IsA("Model") then
		-- configure all parts in model
		for _, obj in pairs(clonedEgg:GetDescendants()) do
			if obj:IsA("BasePart") then
				obj.CanCollide = false
				obj.Anchored = false
				obj.Massless = true
			end
			if obj:IsA("ProximityPrompt") then
				obj:Destroy()
			end
			if obj:IsA("Weld") or obj:IsA("WeldConstraint") or obj:IsA("Motor6D") then
				obj:Destroy()
			end
		end
		
		-- ensure model has primary part set
		if not clonedEgg.PrimaryPart then
			for _, part in pairs(clonedEgg:GetDescendants()) do
				if part:IsA("BasePart") and part.Name == "Part" then
					clonedEgg.PrimaryPart = part
					break
				end
			end
			
			-- if still no primary part, find largest part by volume
			if not clonedEgg.PrimaryPart then
				local largestPart = nil
				local largestVolume = 0
				for _, part in pairs(clonedEgg:GetDescendants()) do
					if part:IsA("BasePart") then
						local volume = part.Size.X * part.Size.Y * part.Size.Z
						if volume > largestVolume then
							largestVolume = volume
							largestPart = part
						end
					end
				end
				if largestPart then
					clonedEgg.PrimaryPart = largestPart
				end
			end
		end
	else
		-- single part egg configuration
		clonedEgg.CanCollide = false
		clonedEgg.Anchored = false
		clonedEgg.Massless = true
		local prompt = clonedEgg:FindFirstChild("EggPickupPrompt")
		if prompt then
			prompt:Destroy()
		end
	end
	
	-- attach egg to player's head using welds
	local head = player.Character:FindFirstChild("Head")
	if head then
		if clonedEgg:IsA("Model") and clonedEgg.PrimaryPart then
			local eggPart = clonedEgg.PrimaryPart
			
			-- primary weld to head
			local weld = Instance.new("Weld")
			weld.Part0 = head
			weld.Part1 = eggPart
			weld.C0 = CFrame.new(0, 3, 0)
			weld.C1 = CFrame.new(0, 0, 0)
			weld.Parent = eggPart
			
			-- weld other parts to primary part maintaining relative positions
			for _, part in pairs(clonedEgg:GetDescendants()) do
				if part:IsA("BasePart") and part ~= eggPart then
					local offset = eggPart.CFrame:ToObjectSpace(part.CFrame)
					local partWeld = Instance.new("Weld")
					partWeld.Part0 = eggPart
					partWeld.Part1 = part
					partWeld.C0 = CFrame.new(0, 0, 0)
					partWeld.C1 = offset:Inverse()
					partWeld.Parent = part
				end
			end
		elseif not clonedEgg:IsA("Model") then
			-- simple weld for single part
			local weld = Instance.new("Weld")
			weld.Part0 = head
			weld.Part1 = clonedEgg
			weld.C0 = CFrame.new(0, 3, 0)
			weld.Parent = clonedEgg
		end
	end
	
	clonedEgg.Parent = player.Character
	
	-- track carried egg data
	playerEggs[player.UserId] = {
		Egg = clonedEgg,
		EggName = eggName,
		EggData = eggData
	}
	
	-- remove original egg from world
	EggSpawnSystem:RemoveEgg(eggModel)
	eggModel:Destroy()
	
	updateProximityPrompts(player.UserId, true)
end

-- creates a tool representation of brainrot item
-- parameters: itemName (string) - name of the item
--            rarityName (string) - rarity tier
--            rarityColor (color3) - visual color
--            brainrotModel (instance) - 3d model reference
-- returns: tool instance
local function createBrainrotTool(itemName, rarityName, rarityColor, brainrotModel)
	local tool = Instance.new("Tool")
	tool.Name = itemName
	tool.RequiresHandle = true
	tool.CanBeDropped = false
	tool.Grip = CFrame.new(0, 0, 0)
	
	-- invisible handle part
	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(1, 1, 1)
	handle.Transparency = 1
	handle.CanCollide = false
	handle.Parent = tool
	
	-- attach visual model to handle
	if brainrotModel then
		local visualClone = brainrotModel:Clone()
		visualClone.Name = "Visual"
		
		if visualClone:IsA("Model") then
			for _, part in pairs(visualClone:GetDescendants()) do
				if part:IsA("BasePart") then
					part.CanCollide = false
					part.Massless = true
					part.Anchored = false
					
					local weld = Instance.new("Weld")
					weld.Part0 = handle
					weld.Part1 = part
					weld.C0 = CFrame.new(0, 0, 0)
					weld.C1 = CFrame.new(0, 0, 0)
					weld.Parent = part
				end
			end
		else
			visualClone.CanCollide = false
			visualClone.Massless = true
			visualClone.Anchored = false
			
			local weld = Instance.new("Weld")
			weld.Part0 = handle
			weld.Part1 = visualClone
			weld.C0 = CFrame.new(0, 0, 0)
			weld.C1 = CFrame.new(0, 0, 0)
			weld.Parent = visualClone
		end
		
		visualClone.Parent = tool
	end
	
	-- store metadata in tool
	local rarityValue = Instance.new("StringValue")
	rarityValue.Name = "Rarity"
	rarityValue.Value = rarityName
	rarityValue.Parent = tool
	
	local colorValue = Instance.new("Color3Value")
	colorValue.Name = "RarityColor"
	colorValue.Value = rarityColor
	colorValue.Parent = tool
	
	return tool
end

-- handles egg destruction and reward spawning
-- parameters: egg (instance) - the egg being broken
--            player (player instance) - who broke it
--            eggData (table) - egg configuration
local function breakEggInSwap(egg, player, eggData)
	if not eggs[egg] then return end
	
	local spawnKey = eggs[egg].spawnKey
	local maxHealth = eggs[egg].maxHealth
	local eggModel = eggs[egg].model
	
	-- remove from tracking
	for part, data in pairs(eggs) do
		if data == eggs[egg] then
			eggs[part] = nil
		end
	end
	
	eggDamageCooldowns[egg] = nil
	
	local position
	local eggPart
	
	-- get egg position for spawning effects
	if eggModel then
		eggPart = eggModel.PrimaryPart or eggModel:FindFirstChildWhichIsA("BasePart")
		if not eggPart then return end
		position = eggPart.Position
	elseif egg:IsA("Model") then
		eggPart = egg.PrimaryPart or egg:FindFirstChildWhichIsA("BasePart")
		if not eggPart then return end
		position = eggPart.Position
	else
		eggPart = egg
		position = egg.Position
	end
	
	-- create breaking effect with fragments
	for i = 1, 12 do
		local fragment = Instance.new("Part")
		fragment.Size = Vector3.new(1, 1, 1)
		fragment.Position = position
		fragment.BrickColor = BrickColor.new("Bright yellow")
		fragment.Material = Enum.Material.SmoothPlastic
		fragment.CanCollide = true
		fragment.Parent = workspace
		
		-- randomize fragment physics
		local randomDirection = Vector3.new(
			math.random(-10, 10),
			math.random(5, 15),
			math.random(-10, 10)
		)
		fragment.Velocity = randomDirection
		fragment.RotVelocity = Vector3.new(
			math.random(-20, 20),
			math.random(-20, 20),
			math.random(-20, 20)
		)
		
		-- fade out and cleanup
		TweenService:Create(fragment, TweenInfo.new(1), {Transparency = 1}):Play()
		Debris:AddItem(fragment, 1)
	end
	
	-- destroy egg
	if eggModel then
		eggModel:Destroy()
	elseif egg:IsA("Model") then
		egg:Destroy()
	else
		egg:Destroy()
	end
	
	-- reset spawn point
	if spawnKey and swapParts[spawnKey] then
		swapParts[spawnKey].HasEgg = false
		local prompt = swapParts[spawnKey].SpawnPart:FindFirstChild("EggPlacePrompt")
		if prompt then
			local playerObj = Players:GetPlayerByUserId(swapParts[spawnKey].UserId)
			if playerObj and playerEggs[playerObj.UserId] then
				prompt.Enabled = true
			else
				prompt.Enabled = false
			end
		end
	end
	
	task.wait(0.3)
	
	-- determine reward based on egg rank
	local rankMultiplier = EggData.RankMultipliers[eggData.Rank] or 1
	local itemName, rarityName, rarityColor = BrainrotData:GetRandomItemWithMultiplier(rankMultiplier)
	
	local safePosition = position + Vector3.new(0, 8, 0)
	
	-- create reward display container
	local displayPart = Instance.new("Part")
	displayPart.Name = "RewardDisplay"
	displayPart.Size = Vector3.new(6, 6, 6)
	displayPart.Position = safePosition
	displayPart.Anchored = true
	displayPart.CanCollide = false
	displayPart.Transparency = 1
	displayPart.Parent = workspace
	
	-- add lighting effect
	local light = Instance.new("PointLight")
	light.Brightness = 3
	light.Range = 30
	light.Color = rarityColor
	light.Parent = displayPart
	
	-- particle emitter for visual effect
	local particles = Instance.new("ParticleEmitter")
	particles.Color = ColorSequence.new(rarityColor)
	particles.Size = NumberSequence.new(1, 3)
	particles.Lifetime = NumberRange.new(1, 2)
	particles.Rate = 100
	particles.Speed = NumberRange.new(10, 20)
	particles.SpreadAngle = Vector2.new(180, 180)
	particles.Parent = displayPart
	
	-- billboard gui for text display
	local rarityGui = Instance.new("BillboardGui")
	rarityGui.Size = UDim2.new(0, 400, 0, 100)
	rarityGui.StudsOffset = Vector3.new(0, 5, 0)
	rarityGui.AlwaysOnTop = true
	rarityGui.Adornee = displayPart
	rarityGui.Parent = displayPart
	
	-- rarity text label
	local rarityText = Instance.new("TextLabel")
	rarityText.Size = UDim2.new(1, 0, 0.4, 0)
	rarityText.BackgroundTransparency = 1
	rarityText.Text = rarityName
	rarityText.TextColor3 = rarityColor
	rarityText.TextScaled = true
	rarityText.Font = Enum.Font.GothamBold
	rarityText.TextStrokeTransparency = 0
	rarityText.TextStrokeColor3 = Color3.new(0, 0, 0)
	rarityText.Parent = rarityGui
	
	-- item name label
	local itemText = Instance.new("TextLabel")
	itemText.Size = UDim2.new(1, 0, 0.4, 0)
	itemText.Position = UDim2.new(0, 0, 0.5, 0)
	itemText.BackgroundTransparency = 1
	itemText.Text = itemName
	itemText.TextColor3 = Color3.new(1, 1, 1)
	itemText.TextScaled = true
	itemText.Font = Enum.Font.GothamBold
	itemText.TextStrokeTransparency = 0
	itemText.TextStrokeColor3 = Color3.new(0, 0, 0)
	itemText.Parent = rarityGui
	
	-- spawn actual item model
	local brainrotItem = BrainrotPack:FindFirstChild(itemName)
	if brainrotItem then
		local clonedItem = brainrotItem:Clone()
		
		if clonedItem:IsA("Model") then
			local primaryPart = clonedItem.PrimaryPart or clonedItem:FindFirstChildWhichIsA("BasePart")
			if primaryPart then
				clonedItem:SetPrimaryPartCFrame(CFrame.new(safePosition))
			end
		elseif clonedItem:IsA("BasePart") then
			clonedItem.Position = safePosition
			clonedItem.Anchored = true
			clonedItem.CanCollide = false
		end
		
		clonedItem.Parent = displayPart
		
		-- add pickup interaction
		local proximityPrompt = Instance.new("ProximityPrompt")
		proximityPrompt.ActionText = "Pick Up"
		proximityPrompt.ObjectText = itemName
		proximityPrompt.MaxActivationDistance = 10
		proximityPrompt.HoldDuration = 0.5
		proximityPrompt.KeyboardKeyCode = Enum.KeyCode.E
		proximityPrompt.RequiresLineOfSight = false
		
		if clonedItem:IsA("Model") then
			proximityPrompt.Parent = clonedItem.PrimaryPart or clonedItem:FindFirstChildWhichIsA("BasePart")
		else
			proximityPrompt.Parent = clonedItem
		end
		
		local itemPickedUp = false
		
		proximityPrompt.Triggered:Connect(function(playerWhoTriggered)
			if itemPickedUp then return end
			itemPickedUp = true
			
			local backpack = playerWhoTriggered:FindFirstChild("Backpack")
			if backpack then
				local tool = createBrainrotTool(itemName, rarityName, rarityColor, brainrotItem)
				tool.Parent = backpack
				
				updatePlacePrompts(playerWhoTriggered.UserId)
			end
			
			particles.Enabled = false
			
			-- animate pickup
			TweenService:Create(displayPart, TweenInfo.new(0.5), {
				Position = displayPart.Position + Vector3.new(0, 5, 0)
			}):Play()
			
			TweenService:Create(light, TweenInfo.new(0.5), {Brightness = 0}):Play()
			
			task.wait(0.5)
			displayPart:Destroy()
		end)
		
		-- spinning animation for item
		local spinConnection
		spinConnection = RunService.Heartbeat:Connect(function()
			if clonedItem and clonedItem.Parent and not itemPickedUp then
				if clonedItem:IsA("Model") and clonedItem.PrimaryPart then
					clonedItem:SetPrimaryPartCFrame(clonedItem:GetPrimaryPartCFrame() * CFrame.Angles(0, math.rad(2), 0))
				elseif clonedItem:IsA("BasePart") then
					clonedItem.CFrame = clonedItem.CFrame * CFrame.Angles(0, math.rad(2), 0)
				end
			else
				spinConnection:Disconnect()
			end
		end)
	end
	
	-- floating animation
	local floatTween = TweenService:Create(displayPart, TweenInfo.new(3, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), {
		Position = safePosition + Vector3.new(0, 2, 0)
	})
	floatTween:Play()
	
	-- auto cleanup after 30 seconds
	task.spawn(function()
		task.wait(30)
		if displayPart and displayPart.Parent then
			particles.Enabled = false
			TweenService:Create(displayPart, TweenInfo.new(1), {Position = safePosition + Vector3.new(0, -15, 0)}):Play()
			TweenService:Create(light, TweenInfo.new(1), {Brightness = 0}):Play()
			task.wait(1)
			displayPart:Destroy()
		end
	end)
end

-- applies damage to an egg with cooldown protection
-- parameters: egg (instance) - target egg
--            damage (number) - damage amount
--            player (player instance) - who dealt damage
--            eggData (table) - egg configuration
--            maxHealth (number) - egg's max health
local function damageEggInSwap(egg, damage, player, eggData, maxHealth)
	if not egg then return end
	if not eggs[egg] then return end
	if not eggs[egg].health then return end
	
	local eggId = tostring(egg:GetFullName())
	local currentTime = tick()
	
	-- check cooldown to prevent spam damage
	if eggDamageCooldowns[eggId] and currentTime - eggDamageCooldowns[eggId] < DAMAGE_COOLDOWN then
		return
	end
	
	eggDamageCooldowns[eggId] = currentTime
	
	-- apply damage
	eggs[egg].health = eggs[egg].health - damage
	
	if not eggs[egg] or not eggs[egg].health then return end
	
	-- update visual health bar
	local eggToUpdate = eggs[egg].model or egg
	updateHealthBar(eggToUpdate, eggs[egg].health, maxHealth)
	
	local eggPart = egg
	if egg:IsA("Model") then
		eggPart = egg.PrimaryPart or egg:FindFirstChildWhichIsA("BasePart")
	end
	
	-- check if egg should break
	if eggs[egg] and eggs[egg].health and eggs[egg].health <= 0 then
		breakEggInSwap(egg, player, eggData)
	end
end

-- configures a newly spawned egg in the world
-- parameters: egg (instance) - the egg to setup
local function setupEggInWorld(egg)
	local eggInfo = EggSpawnSystem:GetEggInfo(egg)
	if not eggInfo then return end
	
	-- add info display billboard
	local infoEggTemplate = ReplicatedStorage:FindFirstChild("InfoEgg")
	if infoEggTemplate then
		local eggPart = nil
		if egg:IsA("Model") then
			eggPart = egg.PrimaryPart or egg:FindFirstChildWhichIsA("BasePart")
		else
			eggPart = egg
		end
		
		if eggPart and not eggPart:FindFirstChild("InfoEgg") then
			local infoEggClone = infoEggTemplate:Clone()
			infoEggClone.Adornee = eggPart
			infoEggClone.Parent = eggPart
			
			local infoFrame = infoEggClone:FindFirstChild("Frame")
			if infoFrame then
				local rankeggLabel = infoFrame:FindFirstChild("Rankegg")
				if rankeggLabel then
					rankeggLabel.Text = eggInfo.EggData.Name
					rankeggLabel.TextColor3 = EggData.RankColors[eggInfo.EggData.Rank] or Color3.new(1, 1, 1)
				end
				
				local rankLabel = infoFrame:FindFirstChild("Rank")
				if rankLabel then
					rankLabel.Text = eggInfo.EggData.Rank
					rankLabel.TextColor3 = EggData.RankColors[eggInfo.EggData.Rank] or Color3.new(1, 1, 1)
				end
			end
		end
	end
	
	-- setup countdown timer for stage2 eggs
	if eggInfo.StageType == "stage2" then
		task.spawn(function()
			while egg and egg.Parent do
				local elapsed = tick() - eggInfo.SpawnTime
				local remaining = 60 - elapsed
				if remaining > 0 then
					local eggPart = nil
					if egg:IsA("Model") then
						eggPart = egg.PrimaryPart or egg:FindFirstChildWhichIsA("BasePart")
					else
						eggPart = egg
					end
					
					if eggPart then
						local infoEgg = eggPart:FindFirstChild("InfoEgg")
						if infoEgg then
							local timeLabel = infoEgg:FindFirstChild("TimeLabel", true)
							if timeLabel then
								timeLabel.Text = string.format("Time: %d s", math.floor(remaining))
							end
						end
					end
				else
					break
				end
				task.wait(1)
			end
		end)
	end
	
	-- add pickup prompt
	local proximityPrompt = Instance.new("ProximityPrompt")
	proximityPrompt.Name = "EggPickupPrompt"
	proximityPrompt.ActionText = "Pick Up"
	proximityPrompt.ObjectText = eggInfo.EggData.Name
	proximityPrompt.MaxActivationDistance = 10
	proximityPrompt.HoldDuration = 0.5
	proximityPrompt.KeyboardKeyCode = Enum.KeyCode.E
	proximityPrompt.RequiresLineOfSight = false
	
	if egg:IsA("Model") then
		proximityPrompt.Parent = egg.PrimaryPart or egg:FindFirstChildWhichIsA("BasePart")
	else
		proximityPrompt.Parent = egg
	end
	
	proximityPrompt.Triggered:Connect(function(player)
		if playerEggs[player.UserId] then return end
		giveEggToPlayer(player, egg, eggInfo.EggName, eggInfo.EggData)
	end)
end

-- returns money value per second based on rarity
-- parameters: rarityName (string) - rarity tier name
-- returns: number representing money per second
local function getBrainrotMoneyValue(rarityName)
	local moneyValues = {
		Common = 10,
		Rare = 25,
		Epic = 50,
		Legendary = 100,
		Mythic = 250,
		Exotic = 500,
		Godly = 1000
	}
	return moneyValues[rarityName] or 10
end

-- plays visual feedback when collecting money from brainrot
-- parameters: placedItem (instance) - the brainrot item
local function playCollectionAnimation(placedItem)
	local targetPart = nil
	if placedItem:IsA("Model") then
		targetPart = placedItem.PrimaryPart or placedItem:FindFirstChildWhichIsA("BasePart")
	else
		targetPart = placedItem
	end
	
	if not targetPart then return end
	
	if placedItem:IsA("Model") then
		-- scale bounce animation for models
		local originalSize = targetPart.Size
		local scaleTween = TweenService:Create(targetPart, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Size = originalSize * 1.2
		})
		scaleTween:Play()
		scaleTween.Completed:Wait()
		
		TweenService:Create(targetPart, TweenInfo.new(0.2, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out), {
			Size = originalSize
		}):Play()
	else
		-- jump animation for single parts
		local originalSize = targetPart.Size
		local originalCFrame = targetPart.CFrame
		
		local jumpTween = TweenService:Create(targetPart, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			CFrame = originalCFrame * CFrame.new(0, 2, 0)
		})
		jumpTween:Play()
		jumpTween.Completed:Wait()
		
		TweenService:Create(targetPart, TweenInfo.new(0.15, Enum.EasingStyle.Bounce, Enum.EasingDirection.In), {
			CFrame = originalCFrame
		}):Play()
	end
end

-- saves brainrot placement to datastore
-- parameters: userId (number) - owner id
--            placeNumber (number) - plot position index
--            itemName (string) - item identifier
--            rarityName (string) - rarity tier
--            rarityColor (color3) - visual color
local function savePlacedBrainrot(userId, placeNumber, itemName, rarityName, rarityColor)
	if not PlayerData[userId] then
		PlayerData[userId] = DataStoreModule.LoadPlayerData(userId)
	end
	
	if not PlayerData[userId].PlacedBrainrots then
		PlayerData[userId].PlacedBrainrots = {}
	end
	
	-- store color components separately for datastore compatibility
	PlayerData[userId].PlacedBrainrots[tostring(placeNumber)] = {
		ItemName = itemName,
		Rarity = rarityName,
		ColorR = rarityColor.R,
		ColorG = rarityColor.G,
		ColorB = rarityColor.B
	}
	
	DataStoreModule.SavePlayerData(userId, PlayerData[userId])
	print("[save] saved brainrot at place", placeNumber, "for userid:", userId)
end

-- removes brainrot from saved data
-- parameters: userId (number) - owner id
--            placeNumber (number) - plot position index
local function removePlacedBrainrot(userId, placeNumber)
	if not PlayerData[userId] then return end
	if not PlayerData[userId].PlacedBrainrots then return end
	
	PlayerData[userId].PlacedBrainrots[tostring(placeNumber)] = nil
	DataStoreModule.SavePlayerData(userId, PlayerData[userId])
	print("[save] removed brainrot at place", placeNumber, "for userid:", userId)
end

-- sets up touch collection for brainrot items
-- parameters: placedItem (instance) - the placed brainrot
--            userId (number) - owner id
local function setupTouchCollect(placedItem, userId)
	local touchCooldowns = {}
	local placePart = placedItem.Parent
	
	local rebirths = getPlayerRebirths(userId)
	local multiplier = getMoneyMultiplier(rebirths)
	
	-- helper function to setup touch events on parts
	local function setupPartTouch(part)
		if not part:IsA("BasePart") then return end
		
		part.Touched:Connect(function(hit)
			if not hit or not hit.Parent then return end
			
			local character = hit.Parent
			local player = Players:GetPlayerFromCharacter(character)
			
			if not player then return end
			if player.UserId ~= userId then return end
			
			local currentTime = tick()
			if touchCooldowns[player.UserId] and currentTime - touchCooldowns[player.UserId] < 1 then
				return
			end
			
			local accumulated = placedItem:FindFirstChild("AccumulatedMoney")
			if not accumulated or not accumulated:IsA("NumberValue") then
				return
			end
			
			if accumulated.Value > 0 then
				touchCooldowns[player.UserId] = currentTime
				
				-- apply rebirth multiplier to collected amount
				local amountToCollect = math.floor(accumulated.Value * multiplier)
				accumulated.Value = 0
				
				MoneyManager:AddMoney(player, amountToCollect)
				
				playCollectionAnimation(placedItem)
				
				print("[collect]", player.Name, "got", amountToCollect, "(x"..multiplier.." multiplier)")
			end
		end)
	end
	
	-- setup touch on place part itself
	if placePart and placePart:IsA("BasePart") then
		placePart.Touched:Connect(function(hit)
			if not hit or not hit.Parent then return end
			
			local character = hit.Parent
			local player = Players:GetPlayerFromCharacter(character)
			
			if not player then return end
			if player.UserId ~= userId then return end
			
			local currentTime = tick()
			if touchCooldowns[player.UserId] and currentTime - touchCooldowns[player.UserId] < 1 then
				return
			end
			
			local accumulated = placedItem:FindFirstChild("AccumulatedMoney")
			if not accumulated or not accumulated:IsA("NumberValue") then
				return
			end
			
			if accumulated.Value > 0 then
				touchCooldowns[player.UserId] = currentTime
				
				local amountToCollect = math.floor(accumulated.Value * multiplier)
				accumulated.Value = 0
				
				MoneyManager:AddMoney(player, amountToCollect)
				
				playCollectionAnimation(placedItem)
				
				print("[collect]", player.Name, "got", amountToCollect, "(x"..multiplier.." multiplier)")
			end
		end)
	end
	
	-- setup touch on all model parts
	if placedItem:IsA("Model") then
		for _, part in pairs(placedItem:GetDescendants()) do
			setupPartTouch(part)
		end
	else
		setupPartTouch(placedItem)
	end
end

-- loads a saved brainrot item into the world
-- parameters: placePart (instance) - where to place
--            placeNumber (number) - position index
--            brainrotData (table) - saved item data
--            userId (number) - owner id
--            rebirths (number) - player rebirth count
local function loadPlacedBrainrot(placePart, placeNumber, brainrotData, userId, rebirths)
	local brainrotTemplate = BrainrotPack:FindFirstChild(brainrotData.ItemName)
	if not brainrotTemplate then 
		warn("[load] brainrot template not found:", brainrotData.ItemName)
		return 
	end
	
	local placedItem = brainrotTemplate:Clone()
	placedItem.Name = "PlacedBrainrot"
	
	-- reconstruct color from saved components
	local rarityColor = Color3.new(brainrotData.ColorR, brainrotData.ColorG, brainrotData.ColorB)
	
	-- configure placement physics
	if placedItem:IsA("Model") then
		for _, part in pairs(placedItem:GetDescendants()) do
			if part:IsA("BasePart") then
				part.CanCollide = false
				part.Anchored = true
			end
		end
		
		local targetY = placePart.Position.Y + placePart.Size.Y/2 + BRAINROT_HEIGHT_OFFSET
		placedItem:SetPrimaryPartCFrame(CFrame.new(placePart.Position.X, targetY, placePart.Position.Z) * CFrame.Angles(0, math.rad(180), 0))
	else
		placedItem.CanCollide = false
		placedItem.Anchored = true
		
		local targetY = placePart.Position.Y + placePart.Size.Y/2 + BRAINROT_HEIGHT_OFFSET
		placedItem.CFrame = CFrame.new(placePart.Position.X, targetY, placePart.Position.Z) * CFrame.Angles(0, math.rad(180), 0)
	end
	
	placedItem.Parent = placePart
	
	-- setup money generation values
	local moneyPerSecValue = getBrainrotMoneyValue(brainrotData.Rarity)
	local moneyValue = Instance.new("NumberValue")
	moneyValue.Name = "MoneyPerSecond"
	moneyValue.Value = moneyPerSecValue
	moneyValue.Parent = placedItem
	
	local accumulatedMoney = Instance.new("NumberValue")
	accumulatedMoney.Name = "AccumulatedMoney"
	accumulatedMoney.Value = 0
	accumulatedMoney.Parent = placedItem
	
	local itemNameValue = Instance.new("StringValue")
	itemNameValue.Name = "ItemName"
	itemNameValue.Value = brainrotData.ItemName
	itemNameValue.Parent = placedItem
	
	local ownerValue = Instance.new("IntValue")
	ownerValue.Name = "OwnerId"
	ownerValue.Value = userId
	ownerValue.Parent = placedItem
	
	-- add info billboard
	local infoBrainrotTemplate = ReplicatedStorage:FindFirstChild("infobrainrot")
	if infoBrainrotTemplate then
		local itemPart = nil
		if placedItem:IsA("Model") then
			itemPart = placedItem.PrimaryPart or placedItem:FindFirstChildWhichIsA("BasePart")
		else
			itemPart = placedItem
		end
		
		if itemPart and not itemPart:FindFirstChild("infobrainrot") then
			local infoBrainrotClone = infoBrainrotTemplate:Clone()
			infoBrainrotClone.Adornee = itemPart
			infoBrainrotClone.Parent = itemPart
			
			local infoFrame = infoBrainrotClone:FindFirstChild("Frame")
			if infoFrame then
				local nameLabel = infoFrame:FindFirstChild("Name")
				if nameLabel then
					nameLabel.Text = brainrotData.ItemName
					nameLabel.TextColor3 = rarityColor
				end
				
				local rankLabel = infoFrame:FindFirstChild("Rank")
				if rankLabel then
					rankLabel.Text = brainrotData.Rarity
					rankLabel.TextColor3 = rarityColor
				end
				
				local multiplier = getMoneyMultiplier(rebirths)
				local finalMoney = moneyPerSecValue * multiplier
				
				local moneyPerSecLabel = infoFrame:FindFirstChild("Moneypersec")
				if moneyPerSecLabel then
					moneyPerSecLabel.Text = "$/s: " .. tostring(finalMoney) .. " (x" .. multiplier .. ")"
				end
			end
		end
	end
	
	setupTouchCollect(placedItem, userId)
	
	placedBrainrots[placedItem] = {
		Item = placedItem,
		UserId = userId,
		MoneyPerSec = moneyPerSecValue
	}
	
	print("[load] loaded brainrot:", brainrotData.ItemName, "at place", placeNumber)
end

-- configures swap part with egg placement spawns
-- parameters: swapPart (instance) - the swap container
--            userId (number) - plot owner id
local function setupSwapPart(swapPart, userId)
	for spawnNum = 1, 3 do
		local spawnName = "Spawn" .. spawnNum
		local spawnPart = swapPart:FindFirstChild(spawnName, true)
		
		if spawnPart then
			local spawnKey = swapPart:GetFullName() .. "_" .. spawnName
			
			-- register spawn point
			swapParts[spawnKey] = {
				SwapPart = swapPart,
				SpawnPart = spawnPart,
				UserId = userId,
				HasEgg = false,
				SpawnNumber = spawnNum
			}
			
			-- create placement prompt
			local placePrompt = Instance.new("ProximityPrompt")
			placePrompt.Name = "EggPlacePrompt"
			placePrompt.ActionText = "Place Egg"
			placePrompt.ObjectText = "Spawn " .. spawnNum
			placePrompt.MaxActivationDistance = 8
			placePrompt.HoldDuration = 0.5
			placePrompt.KeyboardKeyCode = Enum.KeyCode.E
			placePrompt.RequiresLineOfSight = false
			placePrompt.Enabled = false
			placePrompt.Parent = spawnPart
			
			placePrompt.Triggered:Connect(function(player)
				if player.UserId ~= userId then return end
				if swapParts[spawnKey].HasEgg then return end
				if not playerEggs[player.UserId] then return end
				
				local eggData = playerEggs[player.UserId]
				local carriedEgg = eggData.Egg
				local eggName = eggData.EggName
				local eggInfo = eggData.EggData
				
				if carriedEgg then
					local placedEgg = carriedEgg:Clone()
					placedEgg.Name = "PlacedEgg"
					
					if placedEgg:IsA("Model") then
						-- configure model parts
						for _, obj in pairs(placedEgg:GetDescendants()) do
							if obj:IsA("BasePart") then
								obj.CanCollide = false
								obj.Anchored = false
								obj.Massless = false
							end
							if obj:IsA("ProximityPrompt") then
								obj:Destroy()
							end
							if obj:IsA("Weld") or obj:IsA("Motor6D") then
								obj:Destroy()
							end
						end
						
						-- ensure primary part exists
						if not placedEgg.PrimaryPart then
							for _, part in pairs(placedEgg:GetDescendants()) do
								if part:IsA("BasePart") and part.Name == "Part" then
									placedEgg.PrimaryPart = part
									break
								end
							end
							
							if not placedEgg.PrimaryPart then
								local largestPart = nil
								local largestVolume = 0
								for _, part in pairs(placedEgg:GetDescendants()) do
									if part:IsA("BasePart") then
										local volume = part.Size.X * part.Size.Y * part.Size.Z
										if volume > largestVolume then
											largestVolume = volume
											largestPart = part
										end
									end
								end
								if largestPart then
									placedEgg.PrimaryPart = largestPart
								end
							end
						end
						
						if placedEgg.PrimaryPart then
							placedEgg.PrimaryPart.Anchored = true
							placedEgg.PrimaryPart.CanCollide = false
							placedEgg.PrimaryPart.Name = "PlacedEgg"
							
							-- weld all parts together
							for _, part in pairs(placedEgg:GetDescendants()) do
								if part:IsA("BasePart") and part ~= placedEgg.PrimaryPart then
									local offset = placedEgg.PrimaryPart.CFrame:ToObjectSpace(part.CFrame)
									local partWeld = Instance.new("Weld")
									partWeld.Part0 = placedEgg.PrimaryPart
									partWeld.Part1 = part
									partWeld.C0 = CFrame.new(0, 0, 0)
									partWeld.C1 = offset:Inverse()
									partWeld.Parent = part
								end
							end
						end
						
						placedEgg.Parent = spawnPart
						
						-- position egg above spawn
						local eggSize = 0
						if placedEgg.PrimaryPart then
							eggSize = placedEgg.PrimaryPart.Size.Y
						end
						placedEgg:SetPrimaryPartCFrame(spawnPart.CFrame * CFrame.new(0, spawnPart.Size.Y/2 + eggSize/2 + 2, 0))
					else
						-- single part placement
						placedEgg.CanCollide = false
						placedEgg.Anchored = true
						local oldPrompt = placedEgg:FindFirstChild("EggPickupPrompt")
						if oldPrompt then
							oldPrompt:Destroy()
						end
						placedEgg.Parent = spawnPart
						placedEgg.Position = spawnPart.Position + Vector3.new(0, spawnPart.Size.Y/2 + placedEgg.Size.Y/2 + 2, 0)
					end
					
					local targetPart = placedEgg
					local registrationKey = nil
					
					if placedEgg:IsA("Model") then
						targetPart = placedEgg.PrimaryPart or placedEgg:FindFirstChildWhichIsA("BasePart")
						registrationKey = targetPart
					else
						registrationKey = placedEgg
					end
					
					if targetPart then
						-- setup health tracking
						local maxHealth = eggInfo.Health
						local health = Instance.new("NumberValue")
						health.Name = "Health"
						health.Value = maxHealth
						health.Parent = targetPart
						
						local eggDataEntry = {
							health = maxHealth,
							maxHealth = maxHealth,
							owner = player,
							spawnKey = spawnKey,
							eggName = eggName,
							eggData = eggInfo,
							model = placedEgg:IsA("Model") and placedEgg or nil
						}
						
						eggs[registrationKey] = eggDataEntry
						
						-- register all parts for models
						if placedEgg:IsA("Model") then
							for _, part in pairs(placedEgg:GetDescendants()) do
								if part:IsA("BasePart") and part ~= registrationKey then
									eggs[part] = eggDataEntry
								end
							end
						end
						
						setupHealthBar(placedEgg, maxHealth, eggInfo.Name)
					end
					
					animateArmsDown(player)
					
					carriedEgg:Destroy()
					playerEggs[player.UserId] = nil
					
					swapParts[spawnKey].HasEgg = true
					placePrompt.Enabled = false
					
					updateProximityPrompts(player.UserId, false)
					
					-- teleport player back slightly
					if player.Character and player.Character:FindFirstChild("HumanoidRootPart") then
						local hrp = player.Character.HumanoidRootPart
						local teleportPosition = spawnPart.Position + Vector3.new(0, 3, -8)
						hrp.CFrame = CFrame.new(teleportPosition)
					end
				end
			end)
		end
	end
end

-- sets up brainrot placement location
-- parameters: placePart (instance) - placement location
--            userId (number) - plot owner id
local function setupPlacePart(placePart, userId)
	local placeNumber = tonumber(placePart.Name:match("%d+"))
	
	local placePrompt = Instance.new("ProximityPrompt")
	placePrompt.Name = "BrainrotPlacePrompt"
	placePrompt.ActionText = "Place Brainrot"
	placePrompt.ObjectText = "Place"
	placePrompt.MaxActivationDistance = 8
	placePrompt.HoldDuration = 0.5
	placePrompt.KeyboardKeyCode = Enum.KeyCode.E
	placePrompt.RequiresLineOfSight = false
	placePrompt.Enabled = false
	placePrompt.Parent = placePart
	
	placePrompt.Triggered:Connect(function(player)
		if player.UserId ~= userId then return end
		if placePart:FindFirstChild("PlacedBrainrot") then return end
		
		local character = player.Character
		if not character then return end
		
		local tool = character:FindFirstChildOfClass("Tool")
		if not tool then return end
		
		local rarityValue = tool:FindFirstChild("Rarity")
		if not rarityValue or not rarityValue:IsA("StringValue") then return end
		
		local colorValue = tool:FindFirstChild("RarityColor")
		if not colorValue or not colorValue:IsA("Color3Value") then return end
		
		local itemName = tool.Name
		local rarityName = rarityValue.Value
		local rarityColor = colorValue.Value
		
		local brainrotTemplate = BrainrotPack:FindFirstChild(itemName)
		if not brainrotTemplate then return end
		
		local placedItem = brainrotTemplate:Clone()
		placedItem.Name = "PlacedBrainrot"
		
		-- configure placement
		if placedItem:IsA("Model") then
			for _, part in pairs(placedItem:GetDescendants()) do
				if part:IsA("BasePart") then
					part.CanCollide = false
					part.Anchored = true
				end
			end
			
			local targetY = placePart.Position.Y + placePart.Size.Y/2 + BRAINROT_HEIGHT_OFFSET
			placedItem:SetPrimaryPartCFrame(CFrame.new(placePart.Position.X, targetY, placePart.Position.Z) * CFrame.Angles(0, math.rad(180), 0))
		else
			placedItem.CanCollide = false
			placedItem.Anchored = true
			
			local targetY = placePart.Position.Y + placePart.Size.Y/2 + BRAINROT_HEIGHT_OFFSET
			placedItem.CFrame = CFrame.new(placePart.Position.X, targetY, placePart.Position.Z) * CFrame.Angles(0, math.rad(180), 0)
		end
		
		placedItem.Parent = placePart
		
		-- setup money generation
		local moneyPerSecValue = getBrainrotMoneyValue(rarityName)
		local moneyValue = Instance.new("NumberValue")
		moneyValue.Name = "MoneyPerSecond"
		moneyValue.Value = moneyPerSecValue
		moneyValue.Parent = placedItem
		
		local accumulatedMoney = Instance.new("NumberValue")
		accumulatedMoney.Name = "AccumulatedMoney"
		accumulatedMoney.Value = 0
		accumulatedMoney.Parent = placedItem
		
		local itemNameValue = Instance.new("StringValue")
		itemNameValue.Name = "ItemName"
		itemNameValue.Value = itemName
		itemNameValue.Parent = placedItem
		
		local ownerValue = Instance.new("IntValue")
		ownerValue.Name = "OwnerId"
		ownerValue.Value = userId
		ownerValue.Parent = placedItem
		
		local rebirths = getPlayerRebirths(userId)
		local multiplier = getMoneyMultiplier(rebirths)
		local finalMoney = moneyPerSecValue * multiplier
		
		-- add info display
		local infoBrainrotTemplate = ReplicatedStorage:FindFirstChild("infobrainrot")
		if infoBrainrotTemplate then
			local itemPart = nil
			if placedItem:IsA("Model") then
				itemPart = placedItem.PrimaryPart or placedItem:FindFirstChildWhichIsA("BasePart")
			else
				itemPart = placedItem
			end
			
			if itemPart and not itemPart:FindFirstChild("infobrainrot") then
				local infoBrainrotClone = infoBrainrotTemplate:Clone()
				infoBrainrotClone.Adornee = itemPart
				infoBrainrotClone.Parent = itemPart
				
				local infoFrame = infoBrainrotClone:FindFirstChild("Frame")
				if infoFrame then
					local nameLabel = infoFrame:FindFirstChild("Name")
					if nameLabel then
						nameLabel.Text = itemName
						nameLabel.TextColor3 = rarityColor
					end
					
					local rankLabel = infoFrame:FindFirstChild("Rank")
					if rankLabel then
						rankLabel.Text = rarityName
						rankLabel.TextColor3 = rarityColor
					end
					
					local moneyPerSecLabel = infoFrame:FindFirstChild("Moneypersec")
					if moneyPerSecLabel then
						moneyPerSecLabel.Text = "$/s: " .. tostring(finalMoney) .. " (x" .. multiplier .. ")"
					end
				end
			end
		end
		
		setupTouchCollect(placedItem, userId)
		
		placedBrainrots[placedItem] = {
			Item = placedItem,
			UserId = userId,
			MoneyPerSec = moneyPerSecValue
		}
		
		tool:Destroy()
		
		updatePlacePrompts(userId)
		
		savePlacedBrainrot(userId, placeNumber, itemName, rarityName, rarityColor)
		
		print("[place] brainrot:", itemName, "at place", placeNumber, "(x"..multiplier.." = "..finalMoney.."/s)")
	end)
end

-- searches for egg data by checking part reference
-- parameters: part (instance) - the part to search for
-- returns: egg part and egg data table or nil
local function findEggDataByPart(part)
	if not part then
		return nil, nil
	end
	
	if eggs[part] then
		return part, eggs[part]
	end
	
	return nil, nil
end

-- handles pickaxe collision with eggs
workspace.DescendantAdded:Connect(function(descendant)
	if descendant:IsA("BasePart") and descendant.Parent and descendant.Parent:IsA("Tool") then
		descendant.Touched:Connect(function(hit)
			if not hit or not hit.Parent then return end
			
			local eggPart, eggData = findEggDataByPart(hit)
			
			if eggPart and eggData then
				local tool = descendant.Parent
				local character = tool.Parent
				local player = Players:GetPlayerFromCharacter(character)
				
				-- only owner can damage their eggs
				if player and eggData.owner and player.UserId == eggData.owner.UserId then
					if eggData.eggData and eggData.maxHealth then
						damageEggInSwap(eggPart, PICKAXE_DAMAGE, player, eggData.eggData, eggData.maxHealth)
					end
				end
			end
		end)
	end
end)

-- auto setup for newly spawned eggs
workspace.DescendantAdded:Connect(function(descendant)
	if descendant.Name == "SpawnedEgg" then
		task.wait(0.1)
		setupEggInWorld(descendant)
	end
end)

-- initializes all systems for a player's plot
-- parameters: fullPlot (instance) - the plot model
--            userId (number) - plot owner id
local function initializePlot(fullPlot, userId)
	local swapPart = fullPlot:FindFirstChild("Swip", true)
	if not swapPart then
		swapPart = fullPlot:FindFirstChild("Swap", true)
	end
	
	if swapPart then
		setupSwapPart(swapPart, userId)
	end
	
	-- setup all 24 brainrot placement spots
	for i = 1, 24 do
		local placePart = fullPlot:FindFirstChild("place" .. i, true)
		if placePart then
			setupPlacePart(placePart, userId)
		end
	end
end

-- event system for plot initialization
local InitPlotEvent = ReplicatedStorage:FindFirstChild("InitPlotEvent")
if not InitPlotEvent then
	InitPlotEvent = Instance.new("BindableEvent")
	InitPlotEvent.Name = "InitPlotEvent"
	InitPlotEvent.Parent = ReplicatedStorage
end

InitPlotEvent.Event:Connect(function(fullPlotName, userId)
	local fullPlot = workspace:FindFirstChild(fullPlotName, true)
	if fullPlot then
		task.wait(0.5)
		initializePlot(fullPlot, userId)
	end
end)

-- event system for loading saved brainrots
local LoadBrainrotsEvent = ReplicatedStorage:FindFirstChild("LoadBrainrotsEvent")
if not LoadBrainrotsEvent then
	LoadBrainrotsEvent = Instance.new("BindableEvent")
	LoadBrainrotsEvent.Name = "LoadBrainrotsEvent"
	LoadBrainrotsEvent.Parent = ReplicatedStorage
end

LoadBrainrotsEvent.Event:Connect(function(fullPlotName, userId, placedBrainrotsData, rebirths)
	local fullPlot = workspace:FindFirstChild(fullPlotName, true)
	if not fullPlot then return end
	
	if not placedBrainrotsData or type(placedBrainrotsData) ~= "table" then return end
	
	-- load each saved brainrot
	for placeNumberStr, brainrotData in pairs(placedBrainrotsData) do
		local placeNumber = tonumber(placeNumberStr)
		if placeNumber then
			local placePart = fullPlot:FindFirstChild("place" .. placeNumber, true)
			if placePart and not placePart:FindFirstChild("PlacedBrainrot") then
				loadPlacedBrainrot(placePart, placeNumber, brainrotData, userId, rebirths)
			end
		end
	end
	
	print("[load] loaded all brainrots for", fullPlotName)
end)

-- player join handler
Players.PlayerAdded:Connect(function(player)
	PlayerData[player.UserId] = DataStoreModule.LoadPlayerData(player.UserId)
	
	player.CharacterAdded:Connect(function(character)
		-- monitor tool additions to character
		character.ChildAdded:Connect(function(child)
			if child:IsA("Tool") then
				local rarityValue = child:FindFirstChild("Rarity")
				if rarityValue then
					updatePlacePrompts(player.UserId)
				end
			end
		end)
		
		-- monitor tool removals from character
		character.ChildRemoved:Connect(function(child)
			if child:IsA("Tool") then
				local rarityValue = child:FindFirstChild("Rarity")
				if rarityValue then
					task.wait(0.1)
					updatePlacePrompts(player.UserId)
				end
			end
		end)
	end)
	
	-- monitor backpack changes
	local backpack = player:FindFirstChild("Backpack")
	if backpack then
		backpack.ChildAdded:Connect(function(child)
			if child:IsA("Tool") then
				local rarityValue = child:FindFirstChild("Rarity")
				if rarityValue then
					updatePlacePrompts(player.UserId)
				end
			end
		end)
		
		backpack.ChildRemoved:Connect(function(child)
			if child:IsA("Tool") then
				local rarityValue = child:FindFirstChild("Rarity")
				if rarityValue then
					task.wait(0.1)
					updatePlacePrompts(player.UserId)
				end
			end
		end)
	end
end)

-- player leave cleanup
Players.PlayerRemoving:Connect(function(player)
	playerEggs[player.UserId] = nil
	playerAnimations[player.UserId] = nil
	
	-- cleanup swap parts
	for swapName, swapData in pairs(swapParts) do
		if swapData.UserId == player.UserId then
			swapParts[swapName] = nil
		end
	end
	
	-- cleanup brainrots
	for item, data in pairs(placedBrainrots) do
		if data.UserId == player.UserId then
			placedBrainrots[item] = nil
		end
	end
	
	PlayerData[player.UserId] = nil
end)

-- main game loop for continuous systems
local lastMoneyUpdate = tick()
RunService.Heartbeat:Connect(function()
	-- cleanup invalid egg references
	for egg, data in pairs(eggs) do
		if not egg or not egg.Parent then
			eggs[egg] = nil
		end
	end
	
	local currentTime = tick()
	
	-- cleanup old damage cooldowns
	for eggId, lastDamageTime in pairs(eggDamageCooldowns) do
		if currentTime - lastDamageTime > DAMAGE_COOLDOWN * 2 then
			eggDamageCooldowns[eggId] = nil
		end
	end
	
	-- accumulate money from brainrots every second
	local deltaTime = currentTime - lastMoneyUpdate
	if deltaTime >= 1 then
		lastMoneyUpdate = currentTime
		
		for item, data in pairs(placedBrainrots) do
			if item and item.Parent then
				local accumulated = item:FindFirstChild("AccumulatedMoney")
				local moneyPerSec = item:FindFirstChild("MoneyPerSecond")
				
				if accumulated and moneyPerSec then
					accumulated.Value = accumulated.Value + (moneyPerSec.Value * deltaTime)
				end
			else
				placedBrainrots[item] = nil
			end
		end
	end
end)

print("[eggsystem] loaded - rebirth multiplier and save system complete")
