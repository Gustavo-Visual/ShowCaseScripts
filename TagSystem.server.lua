--[[
    TagSystem.server.lua (Script)
    Path: ServerScriptService → Gameplay
    Parent: Gameplay
    Properties:
        Disabled: false
        RunContext: Enum.RunContext.Legacy
    Exported: 2025-12-07 23:49:36
]]
-- Server-side tag controller shared by desktop and mobile input paths.
--
-- High-level behavior:
-- 1. A chaser starts or auto-starts a tag attempt on a nearby runner.
-- 2. The server tracks hold progress while both players stay eligible.
-- 3. Progress decays instead of hard-resetting if contact is briefly broken.
-- 4. When the hold completes, the runner is bubbled and the chaser gets credit.
-- 5. The server broadcasts progress and final effects so clients stay in sync.
--
-- Design goals:
-- - Use one shared attempt engine for PC and mobile so both paths behave alike.
-- - Keep tag validation authoritative on the server.
-- - Avoid false cancels when a finish is already effectively complete.
-- - Mirror important state to attributes so other systems can inspect it.

local Players    = game:GetService("Players")
local RS         = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local AnalyticsService = game:GetService("AnalyticsService")
local SSS        = game:GetService("ServerScriptService")

local AntiCheatService = require(SSS.Modules:WaitForChild("AntiCheatService"))
local BubbleLockoutService = require(SSS.Modules:WaitForChild("BubbleLockoutService"))

-- Wrapper around the anti-cheat remote budget checks.
-- If the service is unavailable, the script falls back to allowing the request.
local function allowRemote(plr: Player, action: string, limit: number, window: number, opts)
	if not AntiCheatService then
		return true
	end
	return AntiCheatService.AllowRemote(plr, action, limit, window, opts)
end

-- Create or reuse the remotes consumed by the tag system.
-- This lets the script self-bootstrap instead of depending on manual setup.
local Remotes = RS:FindFirstChild("Remotes") or Instance.new("Folder")
Remotes.Name = "Remotes"; Remotes.Parent = RS

local TagStart    = Remotes:FindFirstChild("TagAttemptStart")  or Instance.new("RemoteEvent")
TagStart.Name = "TagAttemptStart";  TagStart.Parent = Remotes

local TagCancel   = Remotes:FindFirstChild("TagAttemptCancel") or Instance.new("RemoteEvent")
TagCancel.Name = "TagAttemptCancel"; TagCancel.Parent = Remotes

local TagFX       = Remotes:FindFirstChild("TagBubbleApplied") or Instance.new("RemoteEvent")
TagFX.Name = "TagBubbleApplied"; TagFX.Parent = Remotes

-- Progress updates are streamed to the acting chaser so the client can render
-- a hold meter without estimating progress locally.
local TagProgress = Remotes:FindFirstChild("TagAttemptProgress") or Instance.new("RemoteEvent")
TagProgress.Name = "TagAttemptProgress"; TagProgress.Parent = Remotes

-- DeviceHello lets the client declare whether it is running in a touch-driven
-- input mode, which the server uses to enable automatic mobile tagging.
local DeviceHello = Remotes:FindFirstChild("DeviceHello") or Instance.new("RemoteEvent")
DeviceHello.Name = "DeviceHello"; DeviceHello.Parent = Remotes

-- RoundActive is treated as server-owned state. If the value does not already
-- exist, this script creates it so tag logic has a clear on/off switch.
local RoundActive = RS:FindFirstChild("RoundActive")
if not RoundActive then
	RoundActive = Instance.new("BoolValue")
	RoundActive.Name = "RoundActive"
	RoundActive.Value = false
	RoundActive.Parent = RS
end

-- Tunable gameplay values are grouped here so the tag feel can be adjusted
-- without digging through the attempt logic below.
-- Desktop / helper-triggered tagging.
local TAG_RANGE_E        = 11.0
local HOLD_TIME_E        = 0.6
-- Mobile tagging starts from proximity/contact rather than an explicit button.
local TOUCH_TAG_RANGE    = 7
local TOUCH_HOLD_TIME    = 0.5
-- Shared timing and state windows.
local OUT_OF_RANGE_GRACE = 0.40
local RETAG_COOLDOWN     = 2.0
local BUBBLE_TIME        = 5.0
local INVINCIBLE_OUT     = 2.0
local START_RATE_PER_SEC = 6
-- Small distance slack keeps tagging from feeling too brittle while moving.
local MOVE_SLOP          = 1.50
local DECAY_RATE         = 0.60
-- Throttle progress updates so the server sends enough data for smooth UI
-- without spamming remotes every frame.
local PROGRESS_HZ        = 20         -- send at most 20/s
local PROGRESS_STEP      = 0.03       -- only send if alpha changed by ≥ this
-- If the finish moment fails its final validation, keep the attempt almost
-- complete so the system can retry instead of fully discarding progress.
local FINISH_RETRY_BACKOFF = 0.08
-- =================

-- Sound lookup for the bubble auto-pop effect.
-- Preferred location is ReplicatedStorage/SFX/Pop, but the search falls back
-- to any Sound named "Pop" so the script is less fragile to asset layout.
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

-- Plays the pop sound as positional audio at the supplied world position.
-- A temporary Attachment is used because 3D sounds need an in-world parent.
local function playPopAt(pos: Vector3)
	if not POP_SFX then return end
	local a = Instance.new("Attachment")
	a.WorldPosition = pos
	a.Parent = workspace.Terrain

	local s = POP_SFX:Clone()
	s.Parent = a
	s:Play()

	s.Ended:Connect(function()
		if a then a:Destroy() end
	end)
	task.delay(4, function()
		if a and a.Parent then a:Destroy() end
	end)
end

-- Runtime state.
-- attempts[chaser] tracks the live attempt owned by a specific chaser:
-- {
--     alive = bool,
--     target = Player,
--     holdTime = number,
--     range = number,
--     accum = number,
--     outT = number,
--     lastAlpha = number,
--     lastSendT = number,
-- }
local attempts           = {}
-- lastSuccessAt stores the last confirmed successful bubble time per chaser.
local lastSuccessAt      = {}  -- [chaser] = os.clock()
-- Fallback per-second rate limiter used if the anti-cheat service is absent.
local rlWindowStart, rlCount = {}, {}
-- Weak-key table so disconnected players do not stay strongly referenced.
local isMobile           = setmetatable({}, {__mode="k"}) -- [player] = bool

-- Convenience accessor for a player's HumanoidRootPart.
local function hrp(plr)
	local c = plr and plr.Character
	return c and c:FindFirstChild("HumanoidRootPart") or nil
end

-- Distance helper used by nearly all range checks in the tag flow.
local function dist(a, b)
	local ah, bh = hrp(a), hrp(b)
	if not ah or not bh then return math.huge end
	return (ah.Position - bh.Position).Magnitude
end

-- Applies the post-bubble lockout handled by BubbleLockoutService.
local function setRunnerLockout(runner, seconds)
	BubbleLockoutService.SetRunnerLockout(runner, seconds)
end

-- Records the chaser's cooldown in both local runtime state and a replicated
-- attribute so other systems and clients can inspect it.
local function setChaserCooldown(chaser, seconds)
	lastSuccessAt[chaser] = os.clock()
	chaser:SetAttribute("TagCooldownUntilUnix", os.time() + math.ceil(seconds or 0))
end

-- Initialize player attributes the tag system expects to exist.
for _,p in ipairs(Players:GetPlayers()) do
	p:SetAttribute("IsMobile", false)
	p:SetAttribute("TagCooldownUntilUnix", 0)
end
Players.PlayerAdded:Connect(function(p)
	p:SetAttribute("IsMobile", false)
	p:SetAttribute("TagCooldownUntilUnix", 0)
end)

-- Client-reported device mode. The server still decides behavior, but this
-- signal tells it whether the player should use the mobile auto-attempt path.
DeviceHello.OnServerEvent:Connect(function(plr, touchFlag)
	if not allowRemote(plr, "DeviceHello", 1, 60, {logOnDrop = false}) then return end
	isMobile[plr] = (touchFlag == true)
	plr:SetAttribute("IsMobile", isMobile[plr] == true)
end)

-- Final authority check run at the exact moment a bubble would be applied.
-- This prevents stale attempts from succeeding after the game state changed.
local function okToTagNow(chaser, runner, useRange)
	if not RoundActive.Value then return false end
	if not chaser or not runner then return false end
	if chaser == runner then return false end
	if chaser:GetAttribute("Role") ~= "Chaser" then return false end
	if runner:GetAttribute("Role")  ~= "Runner" then return false end
	if chaser:GetAttribute("Eliminated") == true then return false end
	if runner:GetAttribute("Eliminated")  == true then return false end
	if runner:GetAttribute("Bubbled")     == true then return false end
	if BubbleLockoutService.IsRunnerLocked(runner) then return false end
	if dist(chaser, runner) > (useRange + MOVE_SLOP) then return false end
	return true
end

-- Applies the actual tag result once an attempt finishes successfully.
-- This is where score, analytics, bubble state, and client effects are fired.
local function bubbleRunner(chaser, runner)
	local range = (attempts[chaser] and attempts[chaser].range) or TAG_RANGE_E
	if not okToTagNow(chaser, runner, range) then return false end

	-- BubbleToken acts like a generation counter so delayed cleanup only affects
	-- the bubble instance created by this specific tag.
	local token = (runner:GetAttribute("BubbleToken") or 0) + 1
	runner:SetAttribute("BubbleToken", token)
	runner:SetAttribute("Bubbled", true)
	setRunnerLockout(runner, BUBBLE_TIME + INVINCIBLE_OUT)

	-- Reward the chaser if the leaderstats container exposes Points.
	local ls = chaser:FindFirstChild("leaderstats")
	if ls and ls:FindFirstChild("Points") then ls.Points.Value += 5 end

	-- Notify any contract or quest system listening for completed tags.
	local contractSignal = RS:FindFirstChild("ContractTagSignal")
	if contractSignal then contractSignal:Fire(chaser) end

	-- Analytics is wrapped in pcall so gameplay is not affected by telemetry issues.
	pcall(function()
		AnalyticsService:LogCustomEvent(chaser, "TagMade", 1)
	end)

	-- Broadcast the bubble event so all clients can play the same response.
	TagFX:FireAllClients({ runner = runner.UserId, chaser = chaser.UserId, duration = BUBBLE_TIME })

	-- Auto-release the bubble after its duration expires.
	-- The token check prevents this delayed callback from undoing a newer bubble.
	task.delay(BUBBLE_TIME, function()
		if runner and runner.Parent then
			-- Only release the bubble if the runner is still using the same token.
			if runner:GetAttribute("Bubbled") == true
				and runner:GetAttribute("BubbleToken") == token then
				runner:SetAttribute("Bubbled", false)
				runner:SetAttribute("InvincibleUntil", os.clock() + INVINCIBLE_OUT)

				-- Play the pop at the runner's current world position for spatial feedback.
				local h = hrp(runner)
				if h then playPopAt(h.Position) end
			end
		end
	end)
	return true
end

-- Clears a chaser's in-progress attempt and forces the client meter to reset.
local function cancelAttempt(chaser)
	local a = attempts[chaser]
	if a then a.alive = false end
	attempts[chaser] = nil
	-- Push an explicit zeroed progress state so UI does not linger visually.
	TagProgress:FireClient(chaser, { alpha = 0, target = 0, done = true })
end

-- Starts a fresh attempt for the given chaser/runner pair.
-- If the chaser is already holding on the same runner, progress is preserved.
local function beginAttempt(chaser, runner, holdTime, range)
	local a = attempts[chaser]
	if a and a.target == runner then return end -- keep progress if same target
	cancelAttempt(chaser)
	attempts[chaser] = {
		alive    = true,
		target   = runner,
		holdTime = holdTime,
		range    = range,
		accum    = 0,
		outT     = 0,
		lastAlpha= -1,
		lastSendT= 0,
	}
end

-- Sends hold progress to the client with throttling to avoid per-frame spam.
local function sendProgress(chaser, a)
	local now = os.clock()
	local alpha = (a.holdTime > 0) and (a.accum / a.holdTime) or 0
	alpha = math.clamp(alpha, 0, 1)
	if (math.abs(alpha - (a.lastAlpha or -1)) >= PROGRESS_STEP) or (now - (a.lastSendT or 0) >= (1/PROGRESS_HZ)) then
		a.lastAlpha = alpha
		a.lastSendT = now
		TagProgress:FireClient(chaser, { alpha = alpha, target = a.target and a.target.UserId or 0 })
	end
end

-- Shared attempt loop.
-- Heartbeat is the single source of truth for:
-- - auto-starting mobile attempts
-- - growing or decaying hold progress
-- - pushing progress updates
-- - finishing attempts once they are fully charged
RunService.Heartbeat:Connect(function(dt)
	if not RoundActive.Value then
		for k in pairs(attempts) do cancelAttempt(k) end
		return
	end

	-- Mobile chasers can begin attempts automatically when a valid runner is close.
	for _, chaser in ipairs(Players:GetPlayers()) do
		if chaser:GetAttribute("Role") == "Chaser"
			and chaser:GetAttribute("Eliminated") ~= true
			and (isMobile[chaser] == true or chaser:GetAttribute("IsMobile") == true)
			and chaser:GetAttribute("MobileAutoEnabled") ~= false
			and attempts[chaser] == nil then

			-- Do not begin a new attempt while the chaser is in the retag cooldown.
			local inCD = (os.clock() - (lastSuccessAt[chaser] or -1e9)) < RETAG_COOLDOWN
			if not inCD then
				local best, bestD
				-- Choose the nearest eligible runner inside the mobile range window.
				for _, runner in ipairs(Players:GetPlayers()) do
					if runner ~= chaser
						and runner:GetAttribute("Role") == "Runner"
						and runner:GetAttribute("Eliminated") ~= true
						and runner:GetAttribute("Bubbled") ~= true
						and not BubbleLockoutService.IsRunnerLocked(runner) then
						local d = dist(chaser, runner)
						if d <= (TOUCH_TAG_RANGE + MOVE_SLOP) and (not bestD or d < bestD) then best, bestD = runner, d end
					end
				end
				if best then
					beginAttempt(chaser, best, TOUCH_HOLD_TIME, TOUCH_TAG_RANGE)
				end
			end
		end
	end

	-- Update every live attempt using the same logic regardless of input source.
	for chaser, a in pairs(attempts) do
		if not a or not a.alive then
			attempts[chaser] = nil
		else
			local runner = a.target
			if not chaser.Parent or not runner or not runner.Parent
				or chaser:GetAttribute("Eliminated") == true
				or runner:GetAttribute("Eliminated") == true then
				cancelAttempt(chaser)
			else
				local runnerLocked = (runner:GetAttribute("Bubbled") == true)
					or BubbleLockoutService.IsRunnerLocked(runner)
				local chaserCD    = (os.clock() - (lastSuccessAt[chaser] or -1e9)) < RETAG_COOLDOWN

				local within = (not runnerLocked) and (not chaserCD)
					and (dist(chaser, runner) <= (a.range + MOVE_SLOP))

				-- In range: build progress. Out of range: wait briefly, then decay.
				if within then
					a.accum = math.min(a.holdTime, a.accum + dt)
					a.outT  = 0
				else
					a.outT  = a.outT + dt
					if a.outT > OUT_OF_RANGE_GRACE then
						a.accum = math.max(0, a.accum - dt * DECAY_RATE)
					end
				end

				-- Keep the client meter synchronized with the authoritative server state.
				sendProgress(chaser, a)

				-- Only clear the attempt after the bubble has actually been applied.
				-- If final validation fails, nudge the attempt slightly back and retry.
				if a.accum >= a.holdTime then
					if bubbleRunner(chaser, runner) then
						cancelAttempt(chaser)
						setChaserCooldown(chaser, RETAG_COOLDOWN)
					else
						a.accum = math.max(0, a.holdTime - FINISH_RETRY_BACKOFF)
						a.outT  = 0
						sendProgress(chaser, a) -- reflect the nudge immediately
					end
				end
			end
		end
	end
end)

-- Fallback start-rate limiter for the desktop path when AntiCheatService is not
-- present. It limits how many start requests can be accepted per second.
local function allowedTagStart(plr)
	local t = math.floor(os.clock())
	if rlWindowStart[plr] ~= t then rlWindowStart[plr] = t; rlCount[plr] = 0 end
	rlCount[plr] = (rlCount[plr] or 0) + 1
	return rlCount[plr] <= START_RATE_PER_SEC
end

-- Desktop or helper-driven attempts enter through this remote.
-- The remote only starts the attempt; completion is still handled by Heartbeat.
TagStart.OnServerEvent:Connect(function(chaser, runnerUserId)
	if not RoundActive.Value then return end
	if AntiCheatService then
		if not allowRemote(chaser, "TagAttemptStart", 6, 1, {suspicionOnAbuse = 4}) then return end
	elseif not allowedTagStart(chaser) then
		return
	end

	-- Resolve the requested runner from the replicated user id.
	local runner
	for _, p in ipairs(Players:GetPlayers()) do
		if p.UserId == runnerUserId then runner = p; break end
	end
	if not runner then return end

	-- Initial sanity checks for the requested pair.
	-- Cooldown is not enforced here because the shared attempt loop already pauses
	-- attempts when the chaser is still cooling down.
	if chaser == runner then return end
	if chaser:GetAttribute("Role") ~= "Chaser" then return end
	if runner:GetAttribute("Role")  ~= "Runner" then return end
	if chaser:GetAttribute("Eliminated") == true then return end
	if runner:GetAttribute("Eliminated") == true then return end
	if dist(chaser, runner) > (TAG_RANGE_E + MOVE_SLOP + 1.0) then return end

	beginAttempt(chaser, runner, HOLD_TIME_E, TAG_RANGE_E)
end)

-- Explicit client-side cancel request, mainly used by the desktop path.
TagCancel.OnServerEvent:Connect(function(chaser)
	if not allowRemote(chaser, "TagAttemptCancel", 20, 1) then return end
	cancelAttempt(chaser)
end)

-- Clean up all per-player runtime state when a player leaves the server.
Players.PlayerRemoving:Connect(function(plr)
	cancelAttempt(plr)
	lastSuccessAt[plr] = nil
	rlWindowStart[plr], rlCount[plr] = nil, nil
	isMobile[plr] = nil
end)
