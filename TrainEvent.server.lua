--[[
	TrainEvent.server.lua

	Server-side hazard controller for the Subway map on Map3.

	Round flow:
	1. Bind to the live Subway model when it appears in Workspace.
	2. During a Map3 round, schedule one train pass at a random time.
	3. Trigger horn + warning-light flicker before the train arrives.
	4. Move the train across the track zone.
	5. Bubble and arc-fling any player standing on the tracks.
	6. Restore player state and reset the train when the event ends.

	Expected map hierarchy:
	  Subway
	    SUBWAY
	      TRAIN
	      ForScript
	        Main
	        Left
	        Right
	      JumpPads
	        JUMP
	          Light
	      Lights
	        Ceiling_Light
	          BeamBase
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

-- These values are assumed to be created by the wider round-management system.
-- This script only consumes them; it does not own their lifecycle.
local RoundActive = ReplicatedStorage:WaitForChild("RoundActive")
local CurrentMapName = ReplicatedStorage:WaitForChild("CurrentMapName")
local RoundSecondsLeft = ReplicatedStorage:WaitForChild("RoundSecondsLeft")

-- Tunable behavior values are grouped together so the hazard can be adjusted
-- without digging through logic-heavy functions.
local CONFIG = {
	-- Earliest second in the round when the train is allowed to spawn.
	TrainEarliest = 15,
	-- How much time should remain in the round after the train event finishes.
	TrainBufferEnd = 20,
	-- How long the train physically travels through the station.
	TrainDuration = 2.5,
	-- How long a hit player spends in the scripted fling motion.
	FlingTime = 1.0,
	-- Height of the arc used when throwing players to safety.
	FlingArcHeight = 5,
	-- Extra time the player stays bubbled after landing.
	BubbleAfter = 5.0,
	-- Warning lead time between horn/lights and actual train movement.
	WarningTime = 3.0,
	-- How quickly the warning lights alternate between normal and red.
	FlickerRate = 0.15,
}

-- Visual palette used by the warning system.
-- Keeping these in one table makes the presentation intentionally consistent.
local COLORS = {
	Normal = Color3.fromRGB(152, 194, 219),
	Warning = Color3.fromRGB(255, 0, 0),
	BeamNormal = Color3.fromRGB(255, 255, 255),
	SpotNormal = Color3.fromRGB(255, 229, 1),
	LightBaseNormal = Color3.fromRGB(241, 231, 199),
}

-- Utility: create a folder if it does not already exist.
-- This lets the script safely self-bootstrap its remote container.
local function getOrCreateFolder(parent, name)
	local folder = parent:FindFirstChild(name)
	if folder then
		return folder
	end

	folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

-- Utility: create or reuse the RemoteEvent that the clients listen to for
-- train-related effects such as camera shake or impact feedback.
local function getOrCreateRemoteEvent(parent, name)
	local remote = parent:FindFirstChild(name)
	if remote and remote:IsA("RemoteEvent") then
		return remote
	end

	remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = parent
	return remote
end

local Remotes = getOrCreateFolder(ReplicatedStorage, "Remotes")
local TrainRemote = getOrCreateRemoteEvent(Remotes, "TrainEvent")

-- Sound lookup is deliberately tolerant: it prefers an SFX folder but will
-- fall back to a full ReplicatedStorage search so the showcase script is less
-- fragile to asset organization differences.
local function findSound(name)
	local sfxFolder = ReplicatedStorage:FindFirstChild("SFX")
	if sfxFolder then
		local sound = sfxFolder:FindFirstChild(name)
		if sound and sound:IsA("Sound") then
			return sound
		end
	end

	for _, descendant in ipairs(ReplicatedStorage:GetDescendants()) do
		if descendant:IsA("Sound") and descendant.Name == name then
			return descendant
		end
	end

	return nil
end

local POP_SOUND = findSound("Pop")
local HORN_SOUND = findSound("TrainHorn")
local TRAIN_SOUND = findSound("TrainSound")

-- mapState stores references tied to the currently loaded Subway model.
-- This data becomes invalid when the map is removed and gets rebuilt on load.
local mapState = {
	-- Model that is physically moved during the hazard.
	trainModel = nil,
	-- Main trigger volume representing the dangerous track area.
	mainZone = nil,
	-- Safe landing areas on each side of the tracks.
	leftPlatform = nil,
	rightPlatform = nil,
	-- Precomputed start/end transforms for the train animation path.
	startPivot = nil,
	endPivot = nil,
	-- Collections of lights affected by the warning pass.
	jumpLights = {},
	ceilingLights = {},
	-- Set of ceiling-light indices chosen to flicker this round/map bind.
	flickerSet = {},
}

-- runtime stores transient execution state for the currently active hazard.
local runtime = {
	-- Invalidation token used to cancel delayed work from prior rounds.
	roundToken = 0,
	-- Heartbeat connection for warning-light flicker.
	flickerConnection = nil,
	-- Live looping sound attached to the moving train.
	trainSoundInstance = nil,
	-- Tracks which players were put into train-controlled state.
	affectedPlayers = {},
}

-- Each new round or cleanup increments the token so any previously scheduled
-- callbacks become no-ops when they wake up.
local function nextRoundToken()
	runtime.roundToken += 1
	return runtime.roundToken
end

-- Convenience accessor used throughout the script because nearly every action
-- ultimately drives the character through the HumanoidRootPart.
local function getCharacterRoot(player)
	local character = player and player.Character
	return character and character:FindFirstChild("HumanoidRootPart") or nil
end

-- Separate helper for Humanoid access keeps the higher-level code readable.
local function getHumanoid(player)
	local character = player and player.Character
	return character and character:FindFirstChildOfClass("Humanoid") or nil
end

-- Reset physics state after the scripted sequence so the player returns to
-- normal Roblox character simulation.
local function resetRootMotion(root)
	if not root then
		return
	end

	root.Anchored = false
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
end

-- Explicitly re-enable the locomotion states this script expects the player to
-- have once the train interaction is over.
local function restoreHumanoidControl(humanoid)
	if not humanoid then
		return
	end

	humanoid:SetStateEnabled(Enum.HumanoidStateType.Running, true)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall, true)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, true)
	humanoid.AutoRotate = true

	if humanoid.JumpPower < 1 then
		humanoid.JumpPower = 50
	end
end

-- Generic helper for spatial one-shot audio. The sound is cloned onto a
-- temporary Attachment because Roblox sounds need a 3D parent to play in-world.
local function playOneShotAt(soundTemplate, worldPosition, lifetime)
	if not soundTemplate then
		return
	end

	local attachment = Instance.new("Attachment")
	attachment.WorldPosition = worldPosition
	attachment.Parent = Workspace.Terrain

	local sound = soundTemplate:Clone()
	sound.Parent = attachment
	sound:Play()

	-- Destroy on Ended for normal cleanup, plus a fallback timed destroy in case
	-- the sound asset never fires Ended for any reason.
	sound.Ended:Connect(function()
		if attachment then
			attachment:Destroy()
		end
	end)

	task.delay(lifetime, function()
		if attachment and attachment.Parent then
			attachment:Destroy()
		end
	end)
end

-- Return all ceiling fixtures to their baseline art state.
-- This is called both on normal completion and on early cancellation.
local function restoreCeilingLights()
	for _, lightInfo in ipairs(mapState.ceilingLights) do
		if lightInfo.beam then
			lightInfo.beam.Color = ColorSequence.new(COLORS.BeamNormal)
		end
		if lightInfo.spot then
			lightInfo.spot.Color = COLORS.SpotNormal
		end
		if lightInfo.lightBase then
			lightInfo.lightBase.Color = COLORS.LightBaseNormal
		end
	end
end

-- Stop warning visuals and force all affected lights back to their non-alert
-- presentation.
local function stopWarningFlicker()
	if runtime.flickerConnection then
		runtime.flickerConnection:Disconnect()
		runtime.flickerConnection = nil
	end

	for _, light in ipairs(mapState.jumpLights) do
		light.Color = COLORS.Normal
	end

	restoreCeilingLights()
end

-- Flicker is driven from Heartbeat so the pattern stays in sync with real time
-- and instantly stops when the round token changes.
local function startWarningFlicker(roundToken)
	stopWarningFlicker()

	runtime.flickerConnection = RunService.Heartbeat:Connect(function()
		-- If another round started or cleanup ran, this effect belongs to stale work.
		if runtime.roundToken ~= roundToken then
			stopWarningFlicker()
			return
		end

		-- os.clock-based toggling avoids storing extra state and gives a steady blink.
		local isWarningFrame = math.floor(os.clock() / CONFIG.FlickerRate) % 2 == 0
		local jumpColor = isWarningFrame and COLORS.Warning or COLORS.Normal

		-- All jump pad lights flicker together so the track warning reads clearly.
		for _, light in ipairs(mapState.jumpLights) do
			light.Color = jumpColor
		end

		-- Ceiling lights only flicker for a chosen subset, which makes the station
		-- feel less uniform and visually more alarming.
		for index, lightInfo in ipairs(mapState.ceilingLights) do
			if mapState.flickerSet[index] then
				if lightInfo.beam then
					lightInfo.beam.Color = isWarningFrame
						and ColorSequence.new(COLORS.Warning)
						or ColorSequence.new(COLORS.BeamNormal)
				end
				if lightInfo.spot then
					lightInfo.spot.Color = isWarningFrame and COLORS.Warning or COLORS.SpotNormal
				end
				if lightInfo.lightBase then
					lightInfo.lightBase.Color = isWarningFrame and COLORS.Warning or COLORS.LightBaseNormal
				end
			end
		end
	end)
end

-- Start the looping train movement sound. A clone is used so the original
-- sound asset in storage remains untouched.
local function startTrainLoopSound()
	if not TRAIN_SOUND or not mapState.trainModel then
		return
	end

	local soundParent = mapState.trainModel.PrimaryPart or mapState.trainModel:FindFirstChildWhichIsA("BasePart")
	if not soundParent then
		return
	end

	runtime.trainSoundInstance = TRAIN_SOUND:Clone()
	runtime.trainSoundInstance.Looped = true
	runtime.trainSoundInstance.Parent = soundParent
	runtime.trainSoundInstance:Play()
end

-- Tear down the temporary loop sound once the train stops or the event aborts.
local function stopTrainLoopSound()
	if not runtime.trainSoundInstance then
		return
	end

	runtime.trainSoundInstance:Stop()
	runtime.trainSoundInstance:Destroy()
	runtime.trainSoundInstance = nil
end

-- Cheap inside-volume test against the main hazard part.
-- The Y check gets a small grace margin so players near the top face still count.
local function isInsidePart(part, worldPosition)
	local localPosition = part.CFrame:PointToObjectSpace(worldPosition)
	local halfSize = part.Size / 2

	return math.abs(localPosition.X) <= halfSize.X
		and math.abs(localPosition.Y) <= halfSize.Y + 3
		and math.abs(localPosition.Z) <= halfSize.Z
end

-- Pick the closer safe platform so the recovery feels spatially consistent.
local function getNearestPlatform(worldPosition)
	if not mapState.leftPlatform or not mapState.rightPlatform then
		return mapState.leftPlatform or mapState.rightPlatform
	end

	local leftDistance = (mapState.leftPlatform.Position - worldPosition).Magnitude
	local rightDistance = (mapState.rightPlatform.Position - worldPosition).Magnitude

	if leftDistance <= rightDistance then
		return mapState.leftPlatform
	end

	return mapState.rightPlatform
end

-- Centralized cleanup for any player currently controlled by this script.
-- Keeping this in one place reduces the risk of forgetting one piece of state.
local function releasePlayerFromTrain(player)
	runtime.affectedPlayers[player] = nil
	player:SetAttribute("TrainFlung", nil)
	player:SetAttribute("TrainBubbled", nil)

	if player:GetAttribute("Bubbled") == true then
		player:SetAttribute("Bubbled", false)
	end

	local root = getCharacterRoot(player)
	local humanoid = getHumanoid(player)

	resetRootMotion(root)

	-- Network ownership is handed back to the owning client once the server-side
	-- forced movement is complete.
	if root then
		pcall(function()
			root:SetNetworkOwner(player)
		end)
	end

	restoreHumanoidControl(humanoid)
end

-- Main hit response for a player touched by the train.
-- The sequence is: mark state, anchor root, animate along an arc, wait, pop,
-- then restore movement control.
local function flingPlayerToSafety(player, roundToken)
	local root = getCharacterRoot(player)
	if not root then
		return
	end

	local destination = getNearestPlatform(root.Position)
	if not destination then
		return
	end

	-- Preserve whether the player was already bubbled by another system so this
	-- script can avoid trampling unrelated game state.
	local wasAlreadyBubbled = player:GetAttribute("Bubbled") == true
	local startPosition = root.Position
	local endPosition = destination.Position
	local _, startYaw, _ = root.CFrame:ToEulerAnglesYXZ()

	-- These attributes act as both state markers for other scripts and guards for
	-- this script's delayed cleanup work.
	runtime.affectedPlayers[player] = true
	player:SetAttribute("TrainFlung", true)
	player:SetAttribute("TrainBubbled", true)

	-- BubbleToken acts as a generation counter. If some other script updates the
	-- bubble state later, the delayed unbubble in this function will not clobber it.
	local bubbleToken = (player:GetAttribute("BubbleToken") or 0) + 1
	player:SetAttribute("BubbleToken", bubbleToken)

	if not wasAlreadyBubbled then
		player:SetAttribute("Bubbled", true)
	end

	-- The player is anchored so the server has full control over the arc motion.
	root.Anchored = true
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero

	-- The remote gives the client a hook for local camera or UI feedback.
	player:SetAttribute("ServerTeleportAt", os.clock())
	TrainRemote:FireClient(player, "crash")

	local startTime = os.clock()
	local connection
	connection = RunService.Heartbeat:Connect(function()
		local currentRoot = getCharacterRoot(player)
		-- Abort if the round changed, the player left, or the character changed.
		if runtime.roundToken ~= roundToken or not player.Parent or not currentRoot then
			connection:Disconnect()
			if player.Parent and player:GetAttribute("TrainFlung") == true then
				player:SetAttribute("TrainFlung", nil)
			end
			return
		end

		-- Another system may clear TrainFlung early, so respect that and stop.
		if player:GetAttribute("TrainFlung") ~= true then
			connection:Disconnect()
			return
		end

		-- Smoothstep gives a cleaner start/end than linear interpolation.
		local elapsed = os.clock() - startTime
		local alpha = math.clamp(elapsed / CONFIG.FlingTime, 0, 1)
		local smoothAlpha = alpha * alpha * (3 - 2 * alpha)

		-- Horizontal interpolation plus a simple parabola produces a readable arc.
		local travelPosition = startPosition:Lerp(endPosition, smoothAlpha)
		local arcOffset = 4 * CONFIG.FlingArcHeight * alpha * (1 - alpha)
		travelPosition += Vector3.new(0, arcOffset, 0)

		-- Preserve original yaw so the player does not spin while being moved.
		currentRoot.CFrame = CFrame.new(travelPosition) * CFrame.Angles(0, startYaw, 0)

		if alpha < 1 then
			return
		end

		connection:Disconnect()
		player:SetAttribute("TrainFlung", nil)

		-- Once the motion finishes, keep the player bubbled for a short recovery
		-- window before fully restoring normal play.
		task.delay(CONFIG.BubbleAfter, function()
			if not player.Parent then
				return
			end

			if player:GetAttribute("Bubbled") ~= true then
				return
			end

			-- Only unbubble if the same train-owned bubble instance is still active.
			if player:GetAttribute("BubbleToken") ~= bubbleToken then
				return
			end

			player:SetAttribute("Bubbled", false)
			player:SetAttribute("TrainBubbled", nil)
			runtime.affectedPlayers[player] = nil

			-- Pop sound is intentionally played at the player's final world position.
			local popRoot = getCharacterRoot(player)
			if popRoot then
				playOneShotAt(POP_SOUND, popRoot.Position, 4)
			end

			-- defer avoids doing the full restore work directly inside the delayed
			-- callback stack, which keeps this path a little cleaner.
			task.defer(function()
				if player.Parent then
					releasePlayerFromTrain(player)
				end
			end)
		end)
	end)
end

-- Shared stop path used by both normal completion and cancellation.
local function stopTrainEffects()
	stopWarningFlicker()
	stopTrainLoopSound()
	TrainRemote:FireAllClients("shake_stop")
end

-- Physically move the train through the station and detect crossings against
-- players standing in the main track zone.
local function runTrain(roundToken)
	if not mapState.trainModel or not mapState.mainZone or not mapState.startPivot or not mapState.endPivot then
		return
	end

	if runtime.roundToken ~= roundToken then
		return
	end

	-- Track which players were already processed during this train pass so a
	-- single player cannot be hit multiple times in one movement.
	local alreadyHit = {}
	local startTime = os.clock()
	local previousTrainZ = mapState.startPivot.Position.Z

	-- Start audiovisual feedback before the first movement step.
	startTrainLoopSound()
	TrainRemote:FireAllClients("shake_start", mapState.trainModel)

	local connection
	connection = RunService.Heartbeat:Connect(function()
		if runtime.roundToken ~= roundToken then
			connection:Disconnect()
			stopTrainEffects()
			return
		end

		-- The train path is a linear interpolation between precomputed pivots.
		local alpha = math.clamp((os.clock() - startTime) / CONFIG.TrainDuration, 0, 1)
		mapState.trainModel:PivotTo(mapState.startPivot:Lerp(mapState.endPivot, alpha))

		-- The hit test assumes the train moves along the negative Z axis.
		-- A player is counted as hit when their Z lies between the last frame's Z
		-- and the current frame's Z while they are inside the main danger volume.
		local trainZ = mapState.trainModel:GetPivot().Position.Z

		for _, player in ipairs(Players:GetPlayers()) do
			if alreadyHit[player] then
				continue
			end

			-- Only active round players are valid hazard targets.
			if player:GetAttribute("State") ~= "Round" then
				continue
			end

			local root = getCharacterRoot(player)
			if not root then
				continue
			end

			if not isInsidePart(mapState.mainZone, root.Position) then
				continue
			end

			local playerZ = root.Position.Z
			if playerZ <= previousTrainZ and playerZ >= trainZ then
				alreadyHit[player] = true
				-- Spawn keeps the heartbeat loop responsive even if the fling setup work
				-- becomes more expensive later.
				task.spawn(flingPlayerToSafety, player, roundToken)
			end
		end

		previousTrainZ = trainZ

		if alpha < 1 then
			return
		end

		-- When the train finishes its pass, snap it back to the start so the map is
		-- ready for the next round without needing another setup pass.
		connection:Disconnect()
		mapState.trainModel:PivotTo(mapState.startPivot)
		stopTrainEffects()
	end)
end

-- Pick a valid random train time inside the round and stage the warning window.
local function scheduleTrain(roundToken)
	-- Small delay gives the round controller time to finish writing timing data.
	task.wait(0.5)

	if runtime.roundToken ~= roundToken or not RoundActive.Value then
		return
	end

	local roundDuration = RoundSecondsLeft.Value
	if roundDuration <= 0 then
		roundDuration = 60
	end

	-- This caps the latest possible train start so the event does not happen too
	-- close to the end of the round.
	local latestStart = math.max(CONFIG.TrainEarliest, roundDuration - CONFIG.TrainBufferEnd)
	local delaySeconds = math.random(CONFIG.TrainEarliest, latestStart)
	print("[TrainEvent] Scheduled in", delaySeconds, "s")

	-- The warning starts shortly before the train itself begins moving.
	task.delay(math.max(0, delaySeconds - CONFIG.WarningTime), function()
		if runtime.roundToken ~= roundToken or not RoundActive.Value then
			return
		end

		-- Horn plays from the center of the danger zone to sell the incoming train.
		if mapState.mainZone then
			playOneShotAt(HORN_SOUND, mapState.mainZone.Position, 10)
		end

		startWarningFlicker(roundToken)

		-- After the warning window expires, actually move the train.
		task.delay(CONFIG.WarningTime, function()
			if runtime.roundToken ~= roundToken or not RoundActive.Value then
				return
			end

			runTrain(roundToken)
		end)
	end)
end

-- Entry point when RoundActive flips true.
-- The script only runs on Map3 and only if the Subway map has already been bound.
local function startRound()
	if CurrentMapName.Value ~= "Map3" then
		return
	end

	if not mapState.trainModel then
		return
	end

	-- Capture the token for this specific round and schedule the event async.
	local roundToken = nextRoundToken()
	task.spawn(scheduleTrain, roundToken)
end

-- Entry point when RoundActive flips false.
-- This aggressively restores any player or effect state the train could own.
local function endRound()
	nextRoundToken()
	stopTrainEffects()

	for _, player in ipairs(Players:GetPlayers()) do
		if not runtime.affectedPlayers[player] and not player:GetAttribute("TrainFlung") then
			continue
		end

		releasePlayerFromTrain(player)
	end

	-- Reset the train's physical placement so the station is left in a known state.
	if mapState.trainModel and mapState.startPivot then
		mapState.trainModel:PivotTo(mapState.startPivot)
	end
end

-- Randomly choose half the ceiling fixtures to flicker.
-- This is rebuilt on each map bind so the warning pattern is not identical.
local function rebuildFlickerSet()
	mapState.flickerSet = {}

	local indices = {}
	for index = 1, #mapState.ceilingLights do
		indices[index] = index
	end

	-- Fisher-Yates shuffle to produce an unbiased random subset.
	for index = #indices, 2, -1 do
		local swapIndex = math.random(1, index)
		indices[index], indices[swapIndex] = indices[swapIndex], indices[index]
	end

	for selectionIndex = 1, math.floor(#indices / 2) do
		mapState.flickerSet[indices[selectionIndex]] = true
	end
end

-- Discover all jump-pad lights that should switch to warning colors.
local function collectJumpLights(subway)
	mapState.jumpLights = {}

	local jumpPads = subway:FindFirstChild("JumpPads")
	if not jumpPads then
		return
	end

	for _, jumpPad in ipairs(jumpPads:GetChildren()) do
		if jumpPad.Name ~= "JUMP" then
			continue
		end

		local light = jumpPad:FindFirstChild("Light")
		if light and light:IsA("BasePart") then
			table.insert(mapState.jumpLights, light)
		end
	end
end

-- Discover each ceiling light's components so the warning effect can adjust
-- beam, spotlight, and base color where available.
local function collectCeilingLights(subway)
	mapState.ceilingLights = {}

	local lightsFolder = subway:FindFirstChild("Lights")
	if not lightsFolder then
		mapState.flickerSet = {}
		return
	end

	for _, ceilingLight in ipairs(lightsFolder:GetChildren()) do
		if ceilingLight.Name ~= "Ceiling_Light" then
			continue
		end

		local beamBase = ceilingLight:FindFirstChild("BeamBase")
		local lightBase = ceilingLight:FindFirstChild("lightbase")
		if not beamBase then
			continue
		end

		-- Some fixtures may be partially built; only keep ones with at least one
		-- visual component that can actually be modified.
		local beam = beamBase:FindFirstChildOfClass("Beam")
		local spot = beamBase:FindFirstChildOfClass("SpotLight")
		if beam or spot or lightBase then
			table.insert(mapState.ceilingLights, {
				beam = beam,
				spot = spot,
				lightBase = lightBase,
			})
		end
	end

	rebuildFlickerSet()
end

-- Compute the travel path from hardcoded track coordinates while preserving the
-- model's current orientation.
local function buildTrackPivots(train)
	local currentPivot = train:GetPivot()
	local currentPosition = currentPivot.Position
	local rotationOnly = currentPivot - currentPosition

	mapState.startPivot = CFrame.new(-96, currentPosition.Y, 41.433) * rotationOnly
	mapState.endPivot = CFrame.new(-96, currentPosition.Y, -336.16) * rotationOnly
end

-- Clear every cached map reference when the Subway model leaves Workspace.
-- This prevents stale instances from being used if the map is reloaded later.
local function clearMapState()
	stopTrainEffects()
	nextRoundToken()

	mapState.trainModel = nil
	mapState.mainZone = nil
	mapState.leftPlatform = nil
	mapState.rightPlatform = nil
	mapState.startPivot = nil
	mapState.endPivot = nil
	mapState.jumpLights = {}
	mapState.ceilingLights = {}
	mapState.flickerSet = {}
end

-- Bind the script to a specific live Subway model by resolving the parts and
-- folders the hazard depends on.
local function setupFromModel(subwayModel)
	local subway = subwayModel:FindFirstChild("SUBWAY")
	if not subway then
		return
	end

	-- The train must be a Model because the script animates it via PivotTo.
	local train = subway:FindFirstChild("TRAIN")
	if not train or not train:IsA("Model") then
		return
	end

	local forScript = subway:FindFirstChild("ForScript")
	if not forScript then
		return
	end

	-- Main is the only hard requirement for hazard logic. Left/Right are optional,
	-- but if they exist the player is flung toward the nearest safe side.
	local mainZone = forScript:FindFirstChild("Main")
	if not mainZone or not mainZone:IsA("BasePart") then
		return
	end

	local leftPlatform = forScript:FindFirstChild("Left")
	local rightPlatform = forScript:FindFirstChild("Right")

	-- Cache resolved references so runtime logic does not repeatedly search the tree.
	mapState.trainModel = train
	mapState.mainZone = mainZone
	mapState.leftPlatform = leftPlatform
	mapState.rightPlatform = rightPlatform

	collectJumpLights(subway)
	collectCeilingLights(subway)
	buildTrackPivots(train)

	-- Immediately place the train at its start location so the map is visually in
	-- the expected idle state.
	train:PivotTo(mapState.startPivot)
	print("[TrainEvent] Registered:", train:GetFullName())

	-- If the map appears in the middle of an active Map3 round, bootstrap the
	-- train event for that round instead of waiting for the next one.
	if RoundActive.Value and CurrentMapName.Value == "Map3" then
		startRound()
	end
end

-- RoundActive is the top-level switch that drives the whole hazard lifecycle.
RoundActive.Changed:Connect(function(isActive)
	if isActive then
		startRound()
	else
		endRound()
	end
end)

-- The Subway model may be inserted dynamically after this script starts, so the
-- script listens for it instead of assuming it already exists.
Workspace.ChildAdded:Connect(function(child)
	task.wait(0.2)
	if child:IsA("Model") and child.Name == "Subway" then
		setupFromModel(child)
	end
end)

-- Remove all cached references when the bound Subway model disappears.
Workspace.ChildRemoved:Connect(function(child)
	if child:IsA("Model") and child.Name == "Subway" then
		clearMapState()
	end
end)

-- Minimal cleanup for player tables when someone leaves the server.
Players.PlayerRemoving:Connect(function(player)
	runtime.affectedPlayers[player] = nil
end)

-- Handle the common case where the Subway map is already in Workspace before
-- this server script begins executing.
for _, child in ipairs(Workspace:GetChildren()) do
	if child:IsA("Model") and child.Name == "Subway" then
		setupFromModel(child)
	end
end

print("[TrainEvent] Loaded")