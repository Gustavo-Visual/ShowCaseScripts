--[[
    TrainEvent.server.lua — Map3 (Subway) train hazard
    Once per round, a train rushes through at a random time. Players on the
    tracks get bubbled and arc-flung to the nearest platform.

    Expected hierarchy:
      SUBWAY > TRAIN (Model)
      SUBWAY > ForScript > Main / Left / Right (BaseParts)
      SUBWAY > JumpPads > JUMP (x6) > Light (BasePart)
      SUBWAY > Lights > Ceiling_Light > BeamBase
]]

local Players     = game:GetService("Players")
local Workspace   = game:GetService("Workspace")
local RunService  = game:GetService("RunService")
local RS          = game:GetService("ReplicatedStorage")

-- Round state
local RoundActive      = RS:WaitForChild("RoundActive")
local CurrentMapName   = RS:WaitForChild("CurrentMapName")
local RoundSecondsLeft = RS:WaitForChild("RoundSecondsLeft")

-- Remotes
local Remotes = RS:FindFirstChild("Remotes") or Instance.new("Folder")
Remotes.Name = "Remotes"; Remotes.Parent = RS

local TrainRemote = Remotes:FindFirstChild("TrainEvent") or Instance.new("RemoteEvent")
TrainRemote.Name = "TrainEvent"; TrainRemote.Parent = Remotes

-- SFX
local SFXFolder     = RS:FindFirstChild("SFX")
local POP_SFX       = SFXFolder and SFXFolder:FindFirstChild("Pop") or nil
local HORN_SFX      = SFXFolder and SFXFolder:FindFirstChild("TrainHorn") or nil
local TRAIN_SND_SFX = SFXFolder and SFXFolder:FindFirstChild("TrainSound") or nil

if not POP_SFX then
	for _, v in ipairs(RS:GetDescendants()) do
		if v:IsA("Sound") and v.Name == "Pop" then POP_SFX = v; break end
	end
end

local function playPopAt(pos)
	if not POP_SFX then return end
	local a = Instance.new("Attachment")
	a.WorldPosition = pos
	a.Parent = Workspace.Terrain
	local s = POP_SFX:Clone()
	s.Parent = a
	s:Play()
	s.Ended:Connect(function() if a then a:Destroy() end end)
	task.delay(4, function() if a and a.Parent then a:Destroy() end end)
end

-- Config
local TRAIN_EARLIEST   = 15
local TRAIN_BUFFER_END = 20
local TRAIN_DURATION   = 2.5
local FLING_TIME       = 1.0
local FLING_ARC_HEIGHT = 5
local BUBBLE_AFTER     = 5.0
local WARNING_TIME     = 3.0
local FLICKER_RATE     = 0.15

-- Light colors
local NORMAL_COLOR  = Color3.fromRGB(152, 194, 219)
local WARNING_COLOR = Color3.fromRGB(255, 0, 0)

local BEAM_NORMAL      = Color3.fromRGB(255, 255, 255)
local SPOT_NORMAL      = Color3.fromRGB(255, 229, 1)
local LIGHTBASE_NORMAL = Color3.fromRGB(241, 231, 199)

-- References (populated by setupFromModel)
local trainModel    = nil
local mainZone      = nil
local leftPart      = nil
local rightPart     = nil
local startPivot    = nil
local endPivot      = nil
local jumpLights    = {}
local ceilingLights = {}
local flickerSet    = {}

-- State
local trainAffected  = {}
local roundToken     = 0
local moving         = false
local flickerConn    = nil
local trainSoundInst = nil

-- Helpers

local function hrpOf(plr)
	local c = plr and plr.Character
	return c and c:FindFirstChild("HumanoidRootPart") or nil
end

local function isInsidePart(part, pos)
	local localPos = part.CFrame:PointToObjectSpace(pos)
	local half = part.Size / 2
	return math.abs(localPos.X) <= half.X
		and math.abs(localPos.Y) <= half.Y + 3
		and math.abs(localPos.Z) <= half.Z
end

local function getTargetPart(playerPos)
	if not leftPart or not rightPart then return leftPart or rightPart end
	local dLeft  = (leftPart.Position  - playerPos).Magnitude
	local dRight = (rightPart.Position - playerPos).Magnitude
	return (dLeft <= dRight) and leftPart or rightPart
end

-- Light flicker

local function restoreCeilingLights()
	for _, cl in ipairs(ceilingLights) do
		if cl.beam then cl.beam.Color = ColorSequence.new(BEAM_NORMAL) end
		if cl.spot then cl.spot.Color = SPOT_NORMAL end
		if cl.lightbase then cl.lightbase.Color = LIGHTBASE_NORMAL end
	end
end

local function startFlicker(myToken)
	if flickerConn then flickerConn:Disconnect() end
	flickerConn = RunService.Heartbeat:Connect(function()
		if roundToken ~= myToken then
			flickerConn:Disconnect()
			flickerConn = nil
			for _, light in ipairs(jumpLights) do light.Color = NORMAL_COLOR end
			restoreCeilingLights()
			return
		end
		local on = math.floor(os.clock() / FLICKER_RATE) % 2 == 0

		local color = on and WARNING_COLOR or NORMAL_COLOR
		for _, light in ipairs(jumpLights) do light.Color = color end

		for i, cl in ipairs(ceilingLights) do
			if flickerSet[i] then
				if cl.beam then cl.beam.Color = on and ColorSequence.new(WARNING_COLOR) or ColorSequence.new(BEAM_NORMAL) end
				if cl.spot then cl.spot.Color = on and WARNING_COLOR or SPOT_NORMAL end
				if cl.lightbase then cl.lightbase.Color = on and WARNING_COLOR or LIGHTBASE_NORMAL end
			end
		end
	end)
end

local function stopFlicker()
	if flickerConn then flickerConn:Disconnect(); flickerConn = nil end
	for _, light in ipairs(jumpLights) do light.Color = NORMAL_COLOR end
	restoreCeilingLights()
end

local function playHorn()
	if not HORN_SFX or not mainZone then return end
	local a = Instance.new("Attachment")
	a.WorldPosition = mainZone.Position
	a.Parent = Workspace.Terrain
	local s = HORN_SFX:Clone()
	s.Parent = a
	s:Play()
	s.Ended:Connect(function() if a then a:Destroy() end end)
	task.delay(10, function() if a and a.Parent then a:Destroy() end end)
end

-- Train sound

local function startTrainSound()
	if not TRAIN_SND_SFX or not trainModel then return end
	local part = trainModel.PrimaryPart or trainModel:FindFirstChildWhichIsA("BasePart")
	if not part then return end
	trainSoundInst = TRAIN_SND_SFX:Clone()
	trainSoundInst.Looped = true
	trainSoundInst.Parent = part
	trainSoundInst:Play()
end

local function stopTrainSound()
	if trainSoundInst then
		trainSoundInst:Stop()
		trainSoundInst:Destroy()
		trainSoundInst = nil
	end
end

-- Fling

local function flingPlayer(plr, myToken)
	local hrp = hrpOf(plr)
	if not hrp then return end

	local wasBubbled = plr:GetAttribute("Bubbled") == true
	local target = getTargetPart(hrp.Position)
	if not target then return end

	local startPos = hrp.Position
	local endPos   = target.Position

	trainAffected[plr] = true

	-- TrainFlung must be set before Bubbled to prevent BubbleFreeze anchoring early
	plr:SetAttribute("TrainFlung", true)
	plr:SetAttribute("TrainBubbled", true)

	local bToken = (plr:GetAttribute("BubbleToken") or 0) + 1
	plr:SetAttribute("BubbleToken", bToken)
	if not wasBubbled then plr:SetAttribute("Bubbled", true) end

	hrp.Anchored = true
	hrp.AssemblyLinearVelocity = Vector3.zero
	hrp.AssemblyAngularVelocity = Vector3.zero

	plr:SetAttribute("ServerTeleportAt", os.clock())
	TrainRemote:FireClient(plr, "crash")

	local _, startYaw, _ = hrp.CFrame:ToEulerAnglesYXZ()
	local flingStart = os.clock()
	local flingConn
	flingConn = RunService.Heartbeat:Connect(function()
		local h = hrpOf(plr)

		if roundToken ~= myToken or not plr.Parent or not h
			or plr:GetAttribute("TrainFlung") ~= true then
			flingConn:Disconnect()
			if plr.Parent and plr:GetAttribute("TrainFlung") == true then
				plr:SetAttribute("TrainFlung", nil)
			end
			return
		end

		local elapsed = os.clock() - flingStart
		local alpha   = math.clamp(elapsed / FLING_TIME, 0, 1)
		local smooth  = alpha * alpha * (3 - 2 * alpha)

		local pos = startPos:Lerp(endPos, smooth)
		local arc = 4 * FLING_ARC_HEIGHT * alpha * (1 - alpha)
		pos = pos + Vector3.new(0, arc, 0)

		h.CFrame = CFrame.new(pos) * CFrame.Angles(0, startYaw, 0)

		if alpha >= 1 then
			flingConn:Disconnect()
			plr:SetAttribute("TrainFlung", nil)

			task.delay(BUBBLE_AFTER, function()
				if not plr.Parent then return end
				if plr:GetAttribute("Bubbled") == true
					and plr:GetAttribute("BubbleToken") == bToken then
					plr:SetAttribute("Bubbled", false)
					plr:SetAttribute("TrainBubbled", nil)
					trainAffected[plr] = nil

					local popH = hrpOf(plr)
					if popH then playPopAt(popH.Position) end

					task.defer(function()
						if not plr.Parent then return end
						local rh  = hrpOf(plr)
						local rc  = plr.Character
						local rhum = rc and rc:FindFirstChildOfClass("Humanoid")
						if rh then
							rh.Anchored = false
							rh.AssemblyLinearVelocity = Vector3.zero
							rh.AssemblyAngularVelocity = Vector3.zero
							pcall(function() rh:SetNetworkOwner(plr) end)
						end
						if rhum then
							rhum:SetStateEnabled(Enum.HumanoidStateType.Running, true)
							rhum:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
							rhum:SetStateEnabled(Enum.HumanoidStateType.Freefall, true)
							rhum:SetStateEnabled(Enum.HumanoidStateType.GettingUp, true)
							rhum.AutoRotate = true
							if rhum.JumpPower < 1 then rhum.JumpPower = 50 end
						end
					end)
				end
			end)
		end
	end)
end

-- Train movement

local function runTrain(myToken)
	if not trainModel or not mainZone or not startPivot or not endPivot then return end
	if roundToken ~= myToken then return end

	moving = true
	local alreadyHit = {}
	local startTime  = os.clock()
	local prevTrainZ = startPivot.Position.Z

	startTrainSound()
	TrainRemote:FireAllClients("shake_start", trainModel)

	local conn
	conn = RunService.Heartbeat:Connect(function()
		if roundToken ~= myToken then
			conn:Disconnect()
			moving = false
			stopTrainSound()
			stopFlicker()
			TrainRemote:FireAllClients("shake_stop")
			return
		end

		local elapsed = os.clock() - startTime
		local alpha   = math.clamp(elapsed / TRAIN_DURATION, 0, 1)

		trainModel:PivotTo(startPivot:Lerp(endPivot, alpha))

		local trainZ = trainModel:GetPivot().Position.Z

		for _, plr in ipairs(Players:GetPlayers()) do
			if alreadyHit[plr] then continue end
			if plr:GetAttribute("State") ~= "Round" then continue end

			local hrp = hrpOf(plr)
			if not hrp then continue end
			if not isInsidePart(mainZone, hrp.Position) then continue end

			local playerZ = hrp.Position.Z
			if playerZ <= prevTrainZ and playerZ >= trainZ then
				alreadyHit[plr] = true
				task.spawn(flingPlayer, plr, myToken)
			end
		end

		prevTrainZ = trainZ

		if alpha >= 1 then
			conn:Disconnect()
			moving = false
			trainModel:PivotTo(startPivot)
			stopTrainSound()
			stopFlicker()
			TrainRemote:FireAllClients("shake_stop")
		end
	end)
end

-- Round lifecycle

local function onRoundStart()
	if CurrentMapName.Value ~= "Map3" then return end
	if not trainModel then return end

	roundToken += 1
	local myToken = roundToken

	task.wait(0.5) -- let RoundController finish setting RoundSecondsLeft
	if roundToken ~= myToken then return end
	if not RoundActive.Value then return end

	local roundDuration = RoundSecondsLeft.Value
	if roundDuration <= 0 then roundDuration = 60 end
	local trainMax = math.max(TRAIN_EARLIEST, roundDuration - TRAIN_BUFFER_END)
	local delay = math.random(TRAIN_EARLIEST, trainMax)
	print("[TrainEvent] Scheduled in", delay, "s")

	task.delay(math.max(0, delay - WARNING_TIME), function()
		if roundToken ~= myToken then return end
		if not RoundActive.Value then return end

		playHorn()
		startFlicker(myToken)

		task.delay(WARNING_TIME, function()
			if roundToken ~= myToken then return end
			if not RoundActive.Value then return end
			runTrain(myToken)
		end)
	end)
end

local function onRoundEnd()
	roundToken += 1
	stopFlicker()
	stopTrainSound()
	TrainRemote:FireAllClients("shake_stop")

	for _, plr in ipairs(Players:GetPlayers()) do
		if not trainAffected[plr] and not plr:GetAttribute("TrainFlung") then continue end
		trainAffected[plr] = nil

		plr:SetAttribute("TrainFlung", nil)
		plr:SetAttribute("TrainBubbled", nil)
		if plr:GetAttribute("Bubbled") == true then
			plr:SetAttribute("Bubbled", false)
		end

		local h   = hrpOf(plr)
		local c   = plr.Character
		local hum = c and c:FindFirstChildOfClass("Humanoid")
		if h then
			h.Anchored = false
			h.AssemblyLinearVelocity = Vector3.zero
			h.AssemblyAngularVelocity = Vector3.zero
		end
		if hum then
			hum:SetStateEnabled(Enum.HumanoidStateType.Running, true)
			hum:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
			hum:SetStateEnabled(Enum.HumanoidStateType.Freefall, true)
			hum:SetStateEnabled(Enum.HumanoidStateType.GettingUp, true)
			hum.AutoRotate = true
		end
	end

	if trainModel and startPivot then trainModel:PivotTo(startPivot) end
	moving = false
end

RoundActive.Changed:Connect(function(val)
	if val == true then onRoundStart() else onRoundEnd() end
end)

-- Map setup

local function setupFromModel(subwayModel)
	local subway = subwayModel:FindFirstChild("SUBWAY")
	if not subway then return end

	local train = subway:FindFirstChild("TRAIN")
	if not train or not train:IsA("Model") then return end

	local forScript = subway:FindFirstChild("ForScript")
	if not forScript then return end

	local main  = forScript:FindFirstChild("Main")
	local left  = forScript:FindFirstChild("Left")
	local right = forScript:FindFirstChild("Right")
	if not main then return end

	trainModel = train
	mainZone   = main
	leftPart   = left
	rightPart  = right

	-- Jump pad lights
	jumpLights = {}
	local jumpPads = subway:FindFirstChild("JumpPads")
	if jumpPads then
		for _, jump in ipairs(jumpPads:GetChildren()) do
			if jump.Name == "JUMP" then
				local light = jump:FindFirstChild("Light")
				if light and light:IsA("BasePart") then
					table.insert(jumpLights, light)
				end
			end
		end
	end

	-- Ceiling lights — randomly pick half to flicker
	ceilingLights = {}
	flickerSet    = {}
	local lightsFolder = subway:FindFirstChild("Lights")
	if lightsFolder then
		for _, cl in ipairs(lightsFolder:GetChildren()) do
			if cl.Name == "Ceiling_Light" then
				local beamBase = cl:FindFirstChild("BeamBase")
				local lb = cl:FindFirstChild("lightbase")
				if beamBase then
					local beam = beamBase:FindFirstChildOfClass("Beam")
					local spot = beamBase:FindFirstChildOfClass("SpotLight")
					if beam or spot or lb then
						table.insert(ceilingLights, { beam = beam, spot = spot, lightbase = lb })
					end
				end
			end
		end
	end

	local indices = {}
	for i = 1, #ceilingLights do indices[i] = i end
	for i = #indices, 2, -1 do
		local j = math.random(1, i)
		indices[i], indices[j] = indices[j], indices[i]
	end
	for i = 1, math.floor(#indices / 2) do
		flickerSet[indices[i]] = true
	end

	-- Train start/end positions (hardcoded Z offsets for the subway track)
	local currentPivot = train:GetPivot()
	local pos = currentPivot.Position
	startPivot = CFrame.new(-96, pos.Y, 41.433)  * (currentPivot - currentPivot.Position)
	endPivot   = CFrame.new(-96, pos.Y, -336.16) * (currentPivot - currentPivot.Position)
	train:PivotTo(startPivot)

	print("[TrainEvent] Registered:", train:GetFullName())

	if RoundActive.Value and CurrentMapName.Value == "Map3" then
		onRoundStart()
	end
end

local function clearRefs()
	stopFlicker()
	stopTrainSound()
	trainModel = nil; mainZone = nil; leftPart = nil; rightPart = nil
	startPivot = nil; endPivot = nil
	jumpLights = {}; ceilingLights = {}; flickerSet = {}
	roundToken += 1
	moving = false
end

Workspace.ChildAdded:Connect(function(child)
	task.wait(0.2)
	if child:IsA("Model") and child.Name == "Subway" then setupFromModel(child) end
end)

Workspace.ChildRemoved:Connect(function(child)
	if child:IsA("Model") and child.Name == "Subway" then clearRefs() end
end)

Players.PlayerRemoving:Connect(function(plr)
	trainAffected[plr] = nil
end)

for _, child in ipairs(Workspace:GetChildren()) do
	if child:IsA("Model") and child.Name == "Subway" then setupFromModel(child) end
end

print("[TrainEvent] Loaded")