--[[
    PopSystem.server.lua
    Handles bubble-popping (rescue) logic between runners.
    Range-based with motion tolerance and symmetric progress decay.
]]

local Players    = game:GetService("Players")
local RS         = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SSS        = game:GetService("ServerScriptService")

-- Bot support
local ParticipantUtils
task.defer(function()
	local Modules = SSS:FindFirstChild("Modules")
	if Modules and Modules:FindFirstChild("ParticipantUtils") then
		ParticipantUtils = require(Modules.ParticipantUtils)
	end
end)

local function getAllParticipants()
	if ParticipantUtils then return ParticipantUtils.getAllParticipants() end
	return Players:GetPlayers()
end

local function isBot(p)
	if ParticipantUtils then return ParticipantUtils.isBot(p) end
	return false
end

-- Remotes
local Remotes   = RS:FindFirstChild("Remotes") or Instance.new("Folder", RS); Remotes.Name = "Remotes"; Remotes.Parent = RS
local PopStart  = Remotes:FindFirstChild("PopAttemptStart")  or Instance.new("RemoteEvent", Remotes); PopStart.Name  = "PopAttemptStart";  PopStart.Parent  = Remotes
local PopCancel = Remotes:FindFirstChild("PopAttemptCancel") or Instance.new("RemoteEvent", Remotes); PopCancel.Name = "PopAttemptCancel"; PopCancel.Parent = Remotes
local PopFX     = Remotes:FindFirstChild("PopBubblePopped")  or Instance.new("RemoteEvent", Remotes); PopFX.Name     = "PopBubblePopped";  PopFX.Parent     = Remotes
local PopProgress = Remotes:FindFirstChild("PopAttemptProgress") or Instance.new("RemoteEvent", Remotes)
PopProgress.Name = "PopAttemptProgress"; PopProgress.Parent = Remotes

-- Round flag
local RoundActive = RS:FindFirstChild("RoundActive")
if not RoundActive then
	RoundActive = Instance.new("BoolValue"); RoundActive.Name = "RoundActive"; RoundActive.Value = false; RoundActive.Parent = RS
end

-- Tuning
local POP_RANGE          = 10.0
local TOUCH_POP_RANGE    = 7
local HOLD_TIME          = 0.5
local OUT_OF_RANGE_GRACE = 0.15
local COOLDOWN           = 3.0
local IFRAME_AFTER       = 2.0
local START_RATE_PER_SEC = 8
local MOVE_SLOP          = 1.0
local DECAY_RATE         = 1.0

-- State
local attempts, lastRescueAt = {}, {}
local rlWindowStart, rlCount = {}, {}

-- Helpers
local function hrpOf(p)
	local c = p and p.Character
	return c and c:FindFirstChild("HumanoidRootPart") or nil
end

local function dist(a, b)
	local ah, bh = hrpOf(a), hrpOf(b)
	if not ah or not bh then return math.huge end
	return (ah.Position - bh.Position).Magnitude
end

-- 3D pop SFX — tries RS/SFX/Pop, then RS/Pop, then any Sound named "Pop"
local SFXFolder = RS:FindFirstChild("SFX")
local POP_SFX   = SFXFolder and SFXFolder:FindFirstChild("Pop") or nil
if not POP_SFX then
	local maybe = RS:FindFirstChild("Pop")
	if maybe and maybe:IsA("Sound") then POP_SFX = maybe end
end
if not POP_SFX then
	for _, v in ipairs(RS:GetDescendants()) do
		if v:IsA("Sound") and v.Name == "Pop" then POP_SFX = v; break end
	end
end

local function playPopAt(pos: Vector3)
	if not POP_SFX then return end
	local att = Instance.new("Attachment")
	att.WorldPosition = pos
	att.Parent = workspace.Terrain

	local s = POP_SFX:Clone()
	s.Parent = att
	s:Play()

	s.Ended:Connect(function()
		if att then att:Destroy() end
	end)
	task.delay(4, function()
		if att and att.Parent then att:Destroy() end
	end)
end

-- Rate limiter
local function allowedStart(p)
	local bucket = math.floor(os.clock())
	if rlWindowStart[p] ~= bucket then rlWindowStart[p] = bucket; rlCount[p] = 0 end
	rlCount[p] = (rlCount[p] or 0) + 1
	return rlCount[p] <= START_RATE_PER_SEC
end

-- Gate for starting an attempt (we pause inside monitor for cooldown/not-bubbled cases)
local function canStartAttempt(rescuer, target)
	if not RoundActive.Value then return false end
	if not rescuer or not target then return false end
	if rescuer == target then return false end
	if rescuer:GetAttribute("Role") ~= "Runner" then return false end
	if target:GetAttribute("Role")  ~= "Runner" then return false end
	if rescuer:GetAttribute("Eliminated") == true then return false end
	if target:GetAttribute("Eliminated")  == true then return false end
	if target:GetAttribute("TrainBubbled") == true then return false end
	if dist(rescuer, target) > POP_RANGE + 1.0 then return false end
	return true
end

-- Final check right before applying the rescue
local function okToPopNow(rescuer, target)
	if not RoundActive.Value then return false end
	if not rescuer or not target then return false end
	if rescuer == target then return false end
	if rescuer:GetAttribute("Role") ~= "Runner" then return false end
	if target:GetAttribute("Role")  ~= "Runner" then return false end
	if rescuer:GetAttribute("Eliminated") == true then return false end
	if target:GetAttribute("Eliminated")  == true then return false end
	if target:GetAttribute("Bubbled")     ~= true then return false end
	if target:GetAttribute("TrainBubbled") == true then return false end
	if dist(rescuer, target) > POP_RANGE + MOVE_SLOP then return false end
	return true
end

local function applyRescue(rescuer, target)
	if not okToPopNow(rescuer, target) then return false end

	target:SetAttribute("Bubbled", false)
	target:SetAttribute("InvincibleUntil", os.clock() + IFRAME_AFTER)
	target:SetAttribute("TaggableUntilUnix", os.time() + math.ceil(IFRAME_AFTER))

	local ls = nil
	if isBot(rescuer) then
		local char = rescuer.Character
		ls = char and char:FindFirstChild("leaderstats")
	else
		ls = rescuer:FindFirstChild("leaderstats")
	end
	if ls and ls:FindFirstChild("Points") then ls.Points.Value += 2 end

	local h = hrpOf(target)
	if h then playPopAt(h.Position) end

	PopFX:FireAllClients({ runner = target.UserId, rescuer = rescuer.UserId, inv = IFRAME_AFTER })
	return true
end

local function cancelAttempt(rescuer)
	local e = attempts[rescuer]
	if e then e.alive = false end
	attempts[rescuer] = nil
	if not isBot(rescuer) then
		PopProgress:FireClient(rescuer, { alpha = 0, target = 0, done = true })
	end
end

local function monitor(rescuer, target)
	local acc, outTimer, lastT = 0, 0, os.clock()
	local lastAlpha, lastSendT = -1, 0
	local PROGRESS_HZ = 20
	local PROGRESS_STEP = 0.03

	while attempts[rescuer] and attempts[rescuer].alive do
		RunService.Heartbeat:Wait()
		local now = os.clock(); local dt = now - lastT; lastT = now

		if not RoundActive.Value then break end
		if not rescuer.Parent or not target.Parent then break end
		if rescuer:GetAttribute("Eliminated") == true then break end
		if target:GetAttribute("Eliminated")  == true then break end

		local rescuerCD      = (now - (lastRescueAt[rescuer] or -1e9)) < COOLDOWN
		local targetPoppable = (target:GetAttribute("Bubbled") == true)
			and (target:GetAttribute("TrainBubbled") ~= true)

		local within = (not rescuerCD) and targetPoppable
			and (dist(rescuer, target) <= POP_RANGE + MOVE_SLOP)

		if within then
			acc = math.min(HOLD_TIME, acc + dt)
			outTimer = 0
		else
			outTimer += dt
			if outTimer > OUT_OF_RANGE_GRACE then
				acc = math.max(0, acc - dt * DECAY_RATE)
			end
		end

		local alpha = (HOLD_TIME > 0) and (acc / HOLD_TIME) or 0
		alpha = math.clamp(alpha, 0, 1)
		if (math.abs(alpha - lastAlpha) >= PROGRESS_STEP) or (now - lastSendT >= (1/PROGRESS_HZ)) then
			lastAlpha = alpha
			lastSendT = now
			if not isBot(rescuer) then
				PopProgress:FireClient(rescuer, { alpha = alpha, target = target and target.UserId or 0 })
			end
		end

		if acc >= HOLD_TIME then
			cancelAttempt(rescuer)
			if applyRescue(rescuer, target) then
				lastRescueAt[rescuer] = now
			end
			return
		end
	end
	cancelAttempt(rescuer)
end

-- Mobile/bot auto-rescue (no button needed)
RunService.Heartbeat:Connect(function(dt)
	if not RoundActive.Value then return end

	for _, rescuer in ipairs(getAllParticipants()) do
		if rescuer:GetAttribute("Role") == "Runner"
			and rescuer:GetAttribute("Eliminated") ~= true
			and rescuer:GetAttribute("Bubbled") ~= true
			and (rescuer:GetAttribute("IsMobile") == true or isBot(rescuer))
			and rescuer:GetAttribute("MobileAutoEnabled") ~= false
			and not attempts[rescuer] then

			local inCD = (os.clock() - (lastRescueAt[rescuer] or -1e9)) < COOLDOWN
			if not inCD then
				local best, bestD
				for _, target in ipairs(getAllParticipants()) do
					if target ~= rescuer
						and target:GetAttribute("Role") == "Runner"
						and target:GetAttribute("Eliminated") ~= true
						and target:GetAttribute("Bubbled") == true
						and target:GetAttribute("TrainBubbled") ~= true then
						local d = dist(rescuer, target)
						if d <= (TOUCH_POP_RANGE + MOVE_SLOP) and (not bestD or d < bestD) then
							best, bestD = target, d
						end
					end
				end
				if best then
					attempts[rescuer] = { alive = true, target = best }
					task.spawn(monitor, rescuer, best)
				end
			end
		end
	end
end)

-- Remote handlers
PopStart.OnServerEvent:Connect(function(rescuer, targetUid)
	if not RoundActive.Value then return end
	if not allowedStart(rescuer) then return end

	local target
	for _, p in ipairs(Players:GetPlayers()) do
		if p.UserId == targetUid then target = p; break end
	end
	if not target then return end

	if not canStartAttempt(rescuer, target) then return end

	if attempts[rescuer] then cancelAttempt(rescuer) end
	attempts[rescuer] = { alive = true, target = target }
	task.spawn(monitor, rescuer, target)
end)

PopCancel.OnServerEvent:Connect(function(rescuer)
	cancelAttempt(rescuer)
end)

Players.PlayerRemoving:Connect(function(p)
	cancelAttempt(p)
	lastRescueAt[p] = nil
	rlWindowStart[p], rlCount[p] = nil, nil
end)