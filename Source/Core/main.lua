local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")
local Teams = game:GetService("Teams")
local LocalPlayer = Players.LocalPlayer

local function uiParent()
    local ok, h = pcall(function() return gethui and gethui() end)
    if ok and h then return h end
    return LocalPlayer:WaitForChild("PlayerGui")
end

local Cfg = {
    infStam = false,
    stamDouble = false,
    reach = false,
    reachComp = false,
    reachSize = Vector3.new(8, 8, 8),
    reachOffset = Vector3.zero,
    reachColor = Color3.fromRGB(255, 255, 255),
    reachTrans = 0.5,
    speed = false,
    sv = 26,
    jump = false,
    jv = 65,
    pred = false,
    predTime = 1.2,
    predThickness = 2,
    predNames = true,
    antiShield = false,
    antiFoul = false,
    antiAnkle = false,
    antiOffside = false,
    antiSlowdown = false,
    betterReact = false,
    mobileMovement = false,
    breakReact = false,
    antiMiss = false,
    smartShot = false,
    neverMiss = false,
    neverMissDist = 30,
    autoTake = false,
    freeKickShoot = true,
    freeKickGreen = true,
    penaltyShoot = true,
    penaltyGreen = true,
    pieceAim = true,
    pieceDelay = 0.6,
    kickPower = 0.85,
    kickStyle = "Inside Foot Curled",
    kickTarget = "Top Right",
    mobileMode = "Auto",
    diveEnabled = false,
    diveLead = 0.15,
    diveCatch = false,
}

local function isMobile()
    if Cfg.mobileMode == "Mobile" then return true end
    if Cfg.mobileMode == "Keyboard" then return false end
    return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

local function rulesOn()
    return Cfg.antiShield or Cfg.antiFoul or Cfg.antiAnkle or Cfg.antiOffside
        or Cfg.antiSlowdown or Cfg.betterReact or Cfg.breakReact
end

local function shotOn()
    return Cfg.smartShot or Cfg.neverMiss or Cfg.antiMiss
end

local function piecesOn()
    return Cfg.freeKickShoot or Cfg.freeKickGreen or Cfg.penaltyShoot or Cfg.penaltyGreen
end

local function stamOn()
    return Cfg.infStam or Cfg.stamDouble or Cfg.speed
end

local function keeperOn()
    return Cfg.diveEnabled or Cfg.diveCatch
end

local function anySimFeature()
    return Cfg.reach or stamOn() or Cfg.jump or Cfg.pred or keeperOn() or rulesOn() or shotOn()
end

local mech, Root, React, Network, RootScript = nil, nil, nil, nil, nil
local stamTables = {}
local stamValue = nil
local moveController = nil
local reachAdorn = nil
local cachedChar, cachedHRP, cachedHum, cachedCollide = nil, nil, nil, nil
local touchLimbs = {}
local charConnections = {}
local lastBallScan, lastFallbackScan = 0, 0
local _lastTouch = setmetatable({}, { __mode = "k" })
local cachedBalls = {}
local ballSet = setmetatable({}, { __mode = "k" })
local patchedActors = setmetatable({}, { __mode = "k" })

local TOUCH_NAMES = {
    "Collide", "RightUpperLeg", "RightLowerLeg", "RightFoot", "RightBoot",
    "LeftUpperLeg", "LeftLowerLeg", "LeftFoot", "LeftBoot",
    "UpperTorso", "LowerTorso", "Head"
}

local function rebuildTouchLimbs()
    table.clear(touchLimbs)
    local c = cachedChar
    if not c then return end
    for _, name in ipairs(TOUCH_NAMES) do
        local part = c:FindFirstChild(name)
        if part and part:IsA("BasePart") then
            table.insert(touchLimbs, part)
        end
    end
end

local function rebuildCharParts()
    local c = cachedChar
    if not c then return end
    cachedHRP = c:FindFirstChild("HumanoidRootPart")
    cachedCollide = c:FindFirstChild("Collide")
    cachedHum = c:FindFirstChildOfClass("Humanoid")
    rebuildTouchLimbs()
end

local function cacheCharacter(c)
    for _, conn in ipairs(charConnections) do conn:Disconnect() end
    table.clear(charConnections)
    cachedChar, cachedHRP, cachedHum, cachedCollide = c, nil, nil, nil
    table.clear(touchLimbs)
    if not c then return end
    rebuildCharParts()
    table.insert(charConnections, c.ChildAdded:Connect(function(child)
        if child:IsA("BasePart") or child:IsA("Humanoid") then
            task.defer(rebuildCharParts)
        end
    end))
    table.insert(charConnections, c.ChildRemoved:Connect(function()
        task.defer(rebuildCharParts)
    end))
end

cacheCharacter(LocalPlayer.Character)

local function findMoveController()
    if moveController and moveController.Parent then return moveController end
    moveController = nil
    local ps = LocalPlayer:FindFirstChild("PlayerScripts")
    if not ps then return nil end
    for _, d in ipairs(ps:GetDescendants()) do
        if d:IsA("LocalScript") and d.Name == "movementController" then
            moveController = d
            break
        end
    end
    if not moveController then
        for _, d in ipairs(ps:GetDescendants()) do
            if d:IsA("LuaSourceContainer") and d:FindFirstChild("stamina")
                and d:GetAttribute("canSprint") ~= nil then
                moveController = d
                break
            end
        end
    end
    return moveController
end

local function findStaminaValue()
    if stamValue and stamValue.Parent then return end
    stamValue = nil
    local mc = findMoveController()
    if mc then
        local s = mc:FindFirstChild("stamina")
        if s and (s:IsA("IntValue") or s:IsA("NumberValue")) then
            stamValue = s
            return
        end
    end
    local ps = LocalPlayer:FindFirstChild("PlayerScripts")
    if not ps then return end
    for _, v in ipairs(ps:GetDescendants()) do
        if (v:IsA("IntValue") or v:IsA("NumberValue")) and v.Name:lower():find("stamina", 1, true) then
            stamValue = v
            break
        end
    end
end

local mechScanBusy = false
local lastMechScan = 0

local function findMechObjects(force)
    if not getgc or mechScanBusy then return end
    local now = os.clock()
    if not force and now - lastMechScan < 4 then return end
    lastMechScan = now
    mechScanBusy = true
    task.spawn(function()
        local ok, objects = pcall(getgc, true)
        if ok and type(objects) == "table" then
            local foundMech, foundRoot, foundNetwork
            local staminaTmp = {}
            local processed = 0
            for _, v in ipairs(objects) do
                if type(v) == "table" then
                    if not foundMech and type(rawget(v, "overlapCheck")) == "function"
                        and type(rawget(v, "react")) == "function" then
                        foundMech = v
                    end
                    if not foundRoot and type(rawget(v, "react")) == "function"
                        and type(rawget(v, "overlapCheck")) == "function"
                        and type(rawget(v, "getLookVector")) == "function" then
                        foundRoot = v
                    end
                    if not foundNetwork and type(rawget(v, "fetch")) == "function"
                        and type(rawget(v, "send")) == "function"
                        and type(rawget(v, "add")) == "function" then
                        foundNetwork = v
                    end
                    if rawget(v, "sprintSpeed") ~= nil or rawget(v, "maxStamina") ~= nil
                        or rawget(v, "stamina") ~= nil or rawget(v, "Stamina") ~= nil then
                        if #staminaTmp < 30 then table.insert(staminaTmp, v) end
                    end
                end
                processed += 1
                if processed >= 4000 then
                    processed = 0
                    task.wait()
                end
            end
            if foundMech then mech = foundMech end
            if foundRoot then
                Root = foundRoot
                React = foundRoot.react
                if not RootScript then
                    local ps = LocalPlayer:FindFirstChild("PlayerScripts")
                    if ps then
                        for _, d in ipairs(ps:GetDescendants()) do
                            if d:IsA("LocalScript") and d.Name:lower():find("root") then
                                RootScript = d
                                break
                            end
                        end
                    end
                end
            end
            if foundNetwork then Network = foundNetwork end
            if #staminaTmp > 0 then stamTables = staminaTmp end
        end
        mechScanBusy = false
    end)
end

local function needMech()
    return Cfg.reach or rulesOn() or shotOn() or stamOn() or keeperOn() or Cfg.autoTake
end

local function validBall(b)
    return b ~= nil and b:IsA("BasePart") and b.Parent ~= nil
        and b:IsDescendantOf(Workspace) and not b:FindFirstAncestor("replay")
end

local function addBall(b)
    if ballSet[b] then return end
    if not validBall(b) then return end
    ballSet[b] = true
    table.insert(cachedBalls, b)
end

local function removeBall(b)
    if not ballSet[b] then return end
    ballSet[b] = nil
    for i = #cachedBalls, 1, -1 do
        if cachedBalls[i] == b then
            table.remove(cachedBalls, i)
            break
        end
    end
end

local fallbackScanRunning = false

local function fallbackBallScan()
    if fallbackScanRunning then return end
    fallbackScanRunning = true
    task.spawn(function()
        local processed = 0
        local queue = { Workspace }
        local index = 1
        while index <= #queue do
            if not (Cfg.reach or Cfg.pred or keeperOn()) then break end
            local parent = queue[index]
            queue[index] = false
            index += 1
            if parent and (parent == Workspace or parent.Parent ~= nil) then
                local ok, children = pcall(function() return parent:GetChildren() end)
                if ok then
                    for _, child in ipairs(children) do
                        if child:IsA("BasePart") and child:GetAttribute("possessor") ~= nil
                            and child:FindFirstChild("network") and child:FindFirstChild("properties") then
                            addBall(child)
                        end
                        if child:IsA("Folder") or child:IsA("Model") then
                            table.insert(queue, child)
                        end
                        processed += 1
                        if processed >= 150 then
                            processed = 0
                            task.wait()
                        end
                    end
                end
            end
        end
        fallbackScanRunning = false
    end)
end

local function getBalls()
    for i = #cachedBalls, 1, -1 do
        local b = cachedBalls[i]
        if not validBall(b) then
            ballSet[b] = nil
            table.remove(cachedBalls, i)
        end
    end
    if #cachedBalls > 0 then return cachedBalls end
    local now = os.clock()
    if now - lastBallScan < 0.5 then return cachedBalls end
    lastBallScan = now
    for _, b in ipairs(CollectionService:GetTagged("Ball")) do addBall(b) end
    if #cachedBalls > 0 then return cachedBalls end
    local g = Workspace:FindFirstChild("game") or Workspace:FindFirstChild("Game")
    if g then
        local folder = g:FindFirstChild("balls")
        local server = folder and folder:FindFirstChild("server")
        if server then
            for _, b in ipairs(server:GetChildren()) do
                if b:IsA("BasePart") then addBall(b) end
            end
        end
        local engine = g:FindFirstChild("Engine")
        if engine then
            local b = engine:FindFirstChild("Ball")
            if b and b:IsA("BasePart") then addBall(b) end
        end
    end
    if #cachedBalls > 0 then return cachedBalls end
    if now - lastFallbackScan >= 8 then
        lastFallbackScan = now
        fallbackBallScan()
    end
    return cachedBalls
end

CollectionService:GetInstanceAddedSignal("Ball"):Connect(function(b)
    if Cfg.reach or Cfg.pred or keeperOn() then task.defer(addBall, b) end
end)
CollectionService:GetInstanceRemovedSignal("Ball"):Connect(removeBall)

pcall(function()
    if hookmetamethod then
        local orig
        local function checkArg(a)
            if type(a) == "string" then
                local l = string.lower(a)
                return string.find(l, "tamper", 1, true)
                    or string.find(l, "velocity", 1, true)
                    or string.find(l, "crash", 1, true)
            end
            return false
        end
        local function hookFn(self, ...)
            local m = getnamecallmethod()
            if (m == "FireServer" or m == "InvokeServer") and not checkcaller() then
                local n = select("#", ...)
                if n > 0 and checkArg(select(1, ...)) then return nil end
                if n > 1 and checkArg(select(2, ...)) then return nil end
                if n > 2 and checkArg(select(3, ...)) then return nil end
                if n > 3 and checkArg(select(4, ...)) then return nil end
            end
            return orig(self, ...)
        end
        if newcclosure then
            orig = hookmetamethod(game, "__namecall", newcclosure(hookFn))
        else
            orig = hookmetamethod(game, "__namecall", hookFn)
        end
    end
end)

local function applyRuleFlags(d)
    if type(d) ~= "table" then return end
    if Cfg.antiShield then d.exemptShielding = true end
    if Cfg.antiFoul then d.checkFoul = false end
    if Cfg.antiAnkle then d.checkAnkle = false end
    if Cfg.antiOffside then d.checkOffside = false end
    if Cfg.antiSlowdown then d.applySlowdown = false end
    if Cfg.betterReact then d.ignoreReactDecline = true end
    if Cfg.breakReact then d.specialTool = true end
end

local function hookMech()
    if not mech or rawget(mech, "hk") then return end
    local oldOC = mech.overlapCheck
    local oldReact = mech.react
    if type(oldOC) ~= "function" or type(oldReact) ~= "function" then return end
    pcall(function()
        mech.overlapCheck = function(self, limb, ball, specialTool)
            if Cfg.reach then return true end
            return oldOC(self, limb, ball, specialTool)
        end
        mech.react = function(s, d, ...)
            if Cfg.reach and type(d) == "table" then
                d.ignoreReactDecline = true
                d.exemptShielding = true
                d.specialTool = true
                d.forceNetworkOwner = true
            end
            applyRuleFlags(d)
            return oldReact(s, d, ...)
        end
        rawset(mech, "hk", true)
    end)
end

local actorPayload = [==[
if _G._astralisActorPatched then return end
_G._astralisActorPatched = true
for _, o in ipairs(getgc(true)) do
    if type(o) == "table"
        and rawget(o, "overlapCheck") ~= nil
        and rawget(o, "react") ~= nil then
        pcall(function()
            rawset(o, "overlapCheck", function() return true end)
        end)
    end
end
]==]
local runActor = run_on_actor or (getfenv and getfenv().run_on_actor)
local actorLoopRunning = false

local function patchActorsOnce()
    if not runActor or not getactors then return end
    local ok, actors = pcall(getactors)
    if not ok or type(actors) ~= "table" then return end
    for _, actor in ipairs(actors) do
        if not Cfg.reach then return end
        if not patchedActors[actor] then
            local success = pcall(runActor, actor, actorPayload)
            if success then patchedActors[actor] = true end
            task.wait()
        end
    end
end

local function startActorLoop()
    if actorLoopRunning then return end
    actorLoopRunning = true
    task.spawn(function()
        while Cfg.reach do
            patchActorsOnce()
            task.wait(8)
        end
        actorLoopRunning = false
    end)
end

local function doTouchBall(h, b)
    if not b.CanTouch then b.CanTouch = true end
    firetouchinterest(h, b, 0)
    firetouchinterest(h, b, 1)
    if cachedCollide and cachedCollide.Parent and cachedCollide ~= h then
        firetouchinterest(cachedCollide, b, 0)
        firetouchinterest(cachedCollide, b, 1)
    end
    for i = 1, #touchLimbs do
        local part = touchLimbs[i]
        if part and part.Parent then
            firetouchinterest(part, b, 0)
            firetouchinterest(part, b, 1)
        end
    end
    local rd = b:FindFirstChild("ReactDecline")
    if rd then rd:Destroy() end
    local tc = b:FindFirstChild("TouchCooldown")
    if tc then tc:Destroy() end
end

local function touchBall(b)
    if not b or not b.Parent or not firetouchinterest then return end
    local nowT = os.clock()
    local last = _lastTouch[b]
    if last and nowT - last < 0.12 then return end
    _lastTouch[b] = nowT
    local h = cachedHRP
    if not h or not h.Parent then return end
    pcall(doTouchBall, h, b)
end

local function boxCheck(part, position, offset, size)
    local rel = part.CFrame:PointToObjectSpace(position) - offset
    return math.abs(rel.X) <= size.X * 0.5
        and math.abs(rel.Y) <= size.Y * 0.5
        and math.abs(rel.Z) <= size.Z * 0.5
end

local function updateAdorns()
    local hrp = cachedHRP
    if Cfg.reach and hrp and hrp.Parent then
        if not reachAdorn or not reachAdorn.Parent then
            reachAdorn = Instance.new("BoxHandleAdornment")
            reachAdorn.AlwaysOnTop = false
            reachAdorn.ZIndex = 0
            reachAdorn.Parent = uiParent()
        end
        if reachAdorn.Adornee ~= hrp then reachAdorn.Adornee = hrp end
        if reachAdorn.Size ~= Cfg.reachSize then reachAdorn.Size = Cfg.reachSize end
        local offset = CFrame.new(Cfg.reachOffset)
        if reachAdorn.CFrame ~= offset then reachAdorn.CFrame = offset end
        if reachAdorn.Color3 ~= Cfg.reachColor then reachAdorn.Color3 = Cfg.reachColor end
        if reachAdorn.Transparency ~= Cfg.reachTrans then reachAdorn.Transparency = Cfg.reachTrans end
        if not reachAdorn.Visible then reachAdorn.Visible = true end
    elseif reachAdorn and reachAdorn.Visible then
        reachAdorn.Visible = false
    end
end

local function syncStaminaTable(v)
    if Cfg.infStam then
        local st = rawget(v, "stamina")
        if st then
            if type(st) == "table" then
                pcall(function() st.Value = 100 end)
            else
                rawset(v, "stamina", 100)
            end
        end
        if rawget(v, "Stamina") ~= nil then rawset(v, "Stamina", 100) end
        if rawget(v, "maxStamina") ~= nil then rawset(v, "maxStamina", 100) end
    elseif Cfg.stamDouble then
        local maxS = rawget(v, "maxStamina")
        if type(maxS) == "number" then
            local st = rawget(v, "stamina")
            if type(st) == "table" then
                pcall(function() st.Value = math.min(st.Value * 1.02, maxS) end)
            end
        end
    end
    if Cfg.speed then
        if rawget(v, "sprintSpeed") ~= nil then rawset(v, "sprintSpeed", Cfg.sv) end
        if rawget(v, "MaxSpeed") ~= nil then rawset(v, "MaxSpeed", Cfg.sv) end
        if rawget(v, "WalkSpeed") ~= nil then rawset(v, "WalkSpeed", Cfg.sv) end
        if rawget(v, "_speed") ~= nil then rawset(v, "_speed", Cfg.sv) end
    elseif rawget(v, "sprintSpeed") ~= nil and rawget(v, "sprintSpeed") ~= 22 then
        rawset(v, "sprintSpeed", 22)
    end
end

local function syncStaminaAndSpeed()
    if Cfg.infStam or Cfg.stamDouble then
        if stamValue and stamValue.Parent then
            pcall(function()
                stamValue.Value = Cfg.infStam and 100 or math.min(stamValue.Value * 2, 100)
            end)
        end
        local mc = moveController
        if mc and mc.Parent then
            if Cfg.infStam then
                pcall(function() mc:SetAttribute("stamina", 100) end)
            end
            pcall(function() mc:SetAttribute("canSprint", true) end)
        end
    end
    for i = 1, #stamTables do
        pcall(syncStaminaTable, stamTables[i])
    end
end

local NetClamps = setmetatable({}, { __mode = "k" })
local lastClampScan = 0

local function buildNetClamp(goalModel)
    local visual = goalModel:FindFirstChild("GoalVisual")
    local root = visual and visual:FindFirstChild("RootPart")
    local back = root and root:FindFirstChild("Back_Root")
    if not back then return nil end
    local inv = root.CFrame:Inverse()
    local bottom, topPos, maxV = nil, nil, -1
    for _, bone in ipairs(back:GetChildren()) do
        if bone:IsA("Bone") then
            local u, v = string.match(bone.Name, "(%d+) (%d+)$")
            if u == "0" and v then
                local vn = tonumber(v)
                local p = root.CFrame:PointToObjectSpace(bone.WorldPosition)
                if vn == 0 then bottom = p end
                if vn > maxV then maxV, topPos = vn, p end
            end
        end
    end
    if not bottom or not topPos or maxV <= 0 then return nil end
    local d = topPos - bottom
    local n = Vector3.new(0, -d.Z, d.Y)
    if n.Magnitude < 0.001 then return nil end
    n = n.Unit
    return {
        cframe = root.CFrame,
        inverse = inv,
        normal = n,
        offset = bottom:Dot(n) + 1.4 - 0.875,
        halfWidth = math.abs(bottom.X) + 1,
        top = math.max(topPos.Y, bottom.Y) + 2,
        stretch = bottom.Z > 10.08 and bottom.Z / 9.6 or nil,
    }
end

local function getNetClamp(goalName)
    local pitch = Workspace:FindFirstChild("pitch")
    local nets = pitch and pitch:FindFirstChild("nets")
    local model = nets and nets:FindFirstChild(goalName)
    if not model then return nil end
    local cached = NetClamps[model]
    if cached ~= nil then
        if cached == false then return nil end
        return cached
    end
    local now = os.clock()
    if now - lastClampScan < 2 then return nil end
    lastClampScan = now
    local clamp = buildNetClamp(model)
    NetClamps[model] = clamp or false
    return clamp
end

local function netDisplayPosition(clamp, worldPos)
    local p = clamp.inverse * worldPos
    if p.Z <= 0 or p.Y >= clamp.top or math.abs(p.X) >= clamp.halfWidth then
        return worldPos
    end
    local changed = false
    if clamp.stretch then
        p = Vector3.new(p.X, p.Y, p.Z * clamp.stretch)
        changed = true
    end
    local d = p:Dot(clamp.normal) - clamp.offset
    if d > 0 then
        p -= clamp.normal * d
        changed = true
    end
    if not changed then return worldPos end
    return clamp.cframe * p
end

local function Force(Object)
    if Object:IsA("BodyForce") then return Object.Force end
    if not Object:IsA("VectorForce") or not Object.Enabled then return end
    if not Object.Attachment0 then return end
    local Attachment = Object.RelativeTo == Enum.ActuatorRelativeTo.Attachment0 and Object.Attachment0
        or Object.RelativeTo == Enum.ActuatorRelativeTo.Attachment1 and Object.Attachment1
    if Object.RelativeTo == Enum.ActuatorRelativeTo.World then return Object.Force end
    return Attachment and Attachment.WorldCFrame:VectorToWorldSpace(Object.Force)
end

local function ShotImpact(Ball, Args, Velocity, Goal, Depth, Sign)
    local Launch = Velocity
    local Speed = Vector3.new(Velocity.X, 0, Velocity.Z).Magnitude
    local Direction = Args.curveType or "none"
    local Angle = Args.lookAngleAtRelease or (RootScript and RootScript:GetAttribute("CurrentLookAngle_0_60"))
    local Knuckle = Args.spinType == "knuckle" and (not Angle or Angle > 10)
    local Lateral = Direction == "left" or Direction == "right"
    local Flat = Velocity.Y <= 2 and not Args.simpleFinesseCurve
    local Duration = Speed / (Flat and 220 or Args.risingShot and 40 or 120)
    local Strength = (Args.finesseShot and 1.8 or Args.trivelaShot and 1.7 or 1) * (Args.curveMultiplier or 1)
    local Density = (Ball.CustomPhysicalProperties or Ball.CurrentPhysicalProperties).Density
    local Gravity = Ball:FindFirstChild("gravity")
    local Base = Vector3.new(0, -Workspace.Gravity, 0) + (Gravity and Force(Gravity) or Vector3.zero) / Ball.AssemblyMass
    local Position, Step = Ball.Position, 1 / 120
    local Previous = (Goal.CFrame:PointToObjectSpace(Position).Z - Depth) * Sign
    for i = 1, 180 do
        local Time, Acceleration = (i - 0.5) * Step, Base
        if Args.curve and not (Flat and Time >= Duration * 3) then
            local Side = Direction == "left" and 1 or Direction == "right" and -1 or 0
            if Knuckle then
                Side = Direction == "right" and -1 or 1
                if Time >= Duration / 1.3 then Side = -Side end
            end
            local Spin = Vector3.new(Launch.Z, 0, -Launch.X).Unit * -16
                + Vector3.new(0, Side * 50 * Strength / (Knuckle and 15 or 1), 0)
            if Direction == "none" and not Knuckle then Spin *= 2.15 end
            local Curve = Spin:Cross(Args.simpleFinesseCurve and Vector3.new(Launch.X, 7, Launch.Z) or Launch)
            Curve = Curve.Magnitude > 0 and Curve.Unit * (500 * Density * Strength) or Vector3.zero
            Curve *= Knuckle and Vector3.new(1.5, 0.075, 1.5) or Vector3.new(0.5, 0, 0.5)
            if Args.risingShot then
                Curve *= Vector3.new(0.375, 1, 0.375)
                Curve += Vector3.new(0, -Base.Y * Ball.AssemblyMass * ((Args.power - 60) / 40), 0)
            end
            local Age = Time
            local Length, EndY = Duration * (Lateral and 1 or 1.15), Lateral and -0.5 or -0.25
            if Knuckle and Time >= Duration / 1.3 then
                Age, Length, EndY = Time - Duration / 1.3, Duration - Duration / 1.3, -0.5
            end
            Curve *= Vector3.new(1, 1, 1):Lerp(Vector3.new(0.25, EndY, 0.25), math.clamp(Age / Length, 0, 1))
            Acceleration += Curve / Ball.AssemblyMass
        end
        local NextVelocity = Time < 0.3 and Launch or Velocity + Acceleration * Step
        local Next = Position + (Velocity + NextVelocity) * (Step / 2)
        local Current = (Goal.CFrame:PointToObjectSpace(Next).Z - Depth) * Sign
        if Current <= 0 then
            local Alpha = Previous / (Previous - Current)
            return Position:Lerp(Next, Alpha), (i - 1 + Alpha) * Step
        end
        Position, Velocity, Previous = Next, NextVelocity, Current
    end
end

local function SmartShotTarget(Goal, Ball, Depth, Width, Height)
    local teamName = LocalPlayer.Team and LocalPlayer.Team.Name or ""
    local defending = string.find(teamName, "Home", 1, true) and "Away" or "Home"
    local keeperRoot, bestDist
    for _, candidate in ipairs(Players:GetPlayers()) do
        local team = candidate.Team
        if candidate ~= LocalPlayer and team and string.find(team.Name, defending, 1, true) then
            local role = candidate:GetAttribute("Position") or candidate:GetAttribute("Role")
            local isKeeper = string.find(string.lower(team.Name), "gk", 1, true)
            if type(role) == "string" then
                local label = string.lower(role)
                isKeeper = isKeeper or label == "gk" or label == "goalkeeper"
            end
            if isKeeper then
                local character = candidate.Character
                local root = character and character:FindFirstChild("HumanoidRootPart")
                local humanoid = character and character:FindFirstChildOfClass("Humanoid")
                if root and humanoid and humanoid.Health > 0 then
                    local distance = (root.Position - Goal.Position).Magnitude
                    if distance < 65 and (not bestDist or distance < bestDist) then
                        keeperRoot, bestDist = root, distance
                    end
                end
            end
        end
    end
    local keeper
    if keeperRoot then keeper = Goal.CFrame:PointToObjectSpace(keeperRoot.Position) end
    local picked, topScore
    for _, x in ipairs({ -0.88, -0.64, -0.3, 0, 0.3, 0.64, 0.88 }) do
        for _, y in ipairs({ 0.88, 0.81, 0.71, 0.56 }) do
            local point = Vector3.new(Width * x, Height * y, Depth)
            local score = math.abs(x) * 2 + y * 1.2
            if keeper then
                local dx = (point.X - keeper.X) / math.max(Width, 1)
                local dy = (point.Y - keeper.Y) / math.max(Height, 1)
                score = math.sqrt(dx * dx + 0.5 * dy * dy) * 10 + y * 1.4
            end
            local world = Goal.CFrame:PointToWorldSpace(point)
            score -= math.max((world - Ball.Position).Magnitude - 85, 0) * math.abs(x) / 110
            score -= math.abs(x) * 0.4
            if not topScore or score > topScore then picked, topScore = world, score end
        end
    end
    return picked
end

local ShotWrapped = false

local function resolveGoal()
    local Folder = Workspace:FindFirstChild("game")
    Folder = Folder and Folder:FindFirstChild("points")
    Folder = Folder and Folder:FindFirstChild("goals")
    local Team = LocalPlayer.Team and LocalPlayer.Team.Name or ""
    local lowerTeam = string.lower(Team)
    local homeTeam = lowerTeam:find("home", 1, true) ~= nil
    local awayTeam = lowerTeam:find("away", 1, true) ~= nil
    local goalName
    if homeTeam or awayTeam then goalName = homeTeam and "away" or "home" end
    local Goal = goalName and Folder and Folder:FindFirstChild(goalName)
    if Goal and not Goal:IsA("BasePart") then Goal = nil end
    if not Goal and goalName then
        local pitch = Workspace:FindFirstChild("pitch")
        local nets = pitch and pitch:FindFirstChild("nets")
        local model = nets and nets:FindFirstChild(goalName == "home" and "Home" or "Away")
        Goal = model and model:FindFirstChild("Collide")
        if Goal and not Goal:IsA("BasePart") then Goal = nil end
    end
    return Goal, goalName
end

local function hookSmartShot()
    if ShotWrapped or not Root or type(React) ~= "function" then return end
    local BaseReact = React
    local ShotFunc
    ShotFunc = function(Self, Args)
        local aimAssist = Cfg.smartShot or Cfg.neverMiss or Cfg.antiMiss
        if aimAssist and type(Args) == "table"
            and (tostring(Args.updateStats):lower() == "shots"
                or Args.finesseShot == true or Args.trivelaShot == true or Args.risingShot == true)
            and typeof(Args.vector) == "Vector3" then
            local Ball = Args.ball
            local Goal, goalName = resolveGoal()
            if Goal and Ball and Ball.Parent and not Ball.Anchored then
                local Velocity, Offset = Args.vector, Goal.Position - Ball.Position
                local Speed = Vector3.new(Velocity.X, 0, Velocity.Z).Magnitude
                local Radius = math.min(Ball.Size.X, Ball.Size.Y, Ball.Size.Z) / 2
                local Width, Height = Goal.Size.X / 2 - Radius - 1, Goal.Size.Y / 2 - Radius - 0.75
                local Local = Goal.CFrame:PointToObjectSpace(Ball.Position)
                local Sign = math.sign(Local.Z)
                local Depth = Sign * (Goal.Size.Z / 2 - Radius - 0.2)
                if Speed > 5 and Width > 0 and Height > 0
                    and math.abs(Local.Z) > Goal.Size.Z / 2 + Radius
                    and Offset.Magnitude > 0.001
                    and Velocity:Dot(Offset) > Velocity.Magnitude * Offset.Magnitude * 0.5 then
                    local clamp = goalName and getNetClamp(goalName == "home" and "Home" or "Away")
                    local Hit = ShotImpact(Ball, Args, Velocity, Goal, Depth, Sign)
                    local DisplayHit = Hit
                    if Hit and clamp then
                        DisplayHit = netDisplayPosition(clamp, Hit)
                    end
                    local Point = DisplayHit and Goal.CFrame:PointToObjectSpace(DisplayHit) or Vector3.zero
                    if Cfg.smartShot or not Hit or math.abs(Point.X) > Width or math.abs(Point.Y) > Height then
                        local outside = Hit and math.max(math.abs(Point.X) - Width, math.abs(Point.Y) - Height, 0) or 0
                        local limit = math.clamp(Cfg.neverMissDist, 0, 30)
                        if Cfg.neverMiss and not Cfg.smartShot and outside > limit then
                            return BaseReact(Self, Args)
                        end
                        local Target = Goal.CFrame:PointToWorldSpace(Vector3.new(
                            math.clamp(Point.X, -Width, Width), math.clamp(Point.Y, -Height, Height), Depth))
                        if Cfg.smartShot then
                            Target = SmartShotTarget(Goal, Ball, Depth, Width, Height) or Target
                        end
                        local Aim = Velocity
                        if Cfg.smartShot then
                            local delta = Target - Ball.Position
                            local time = math.clamp(delta.Magnitude / math.max(Velocity.Magnitude, 1), 0.15, 2.4)
                            local ballistic = delta / time + Vector3.new(0, Workspace.Gravity * time / 2, 0)
                            if ballistic.Magnitude > 0.001 then Aim = ballistic.Unit * Velocity.Magnitude end
                        end
                        for i = 1, 5 do
                            local Impact, Time = ShotImpact(Ball, Args, Aim, Goal, Depth, Sign)
                            if not Impact then
                                if Cfg.neverMiss then
                                    local delta = Target - Ball.Position
                                    local time = math.clamp(delta.Magnitude / math.max(Velocity.Magnitude, 1), 0.08, 3)
                                    local guess = delta / time + Vector3.new(0, Workspace.Gravity * time / 2, 0)
                                    if guess.Magnitude > 0.01 then Aim = guess.Unit * Velocity.Magnitude end
                                end
                                break
                            end
                            if clamp then Impact = netDisplayPosition(clamp, Impact) end
                            if (Target - Impact).Magnitude < 0.1 then break end
                            Aim += (Target - Impact) / Time
                            local Flat = Vector3.new(Aim.X, 0, Aim.Z)
                            if Flat.Magnitude < 1 then break end
                            Aim = Flat.Unit * math.min(Speed, 140) + Vector3.new(0, math.clamp(Aim.Y, -80, 80), 0)
                        end
                        local Impact = ShotImpact(Ball, Args, Aim, Goal, Depth, Sign)
                        if Impact and clamp then Impact = netDisplayPosition(clamp, Impact) end
                        local Safe = Impact and Goal.CFrame:PointToObjectSpace(Impact)
                        if (Safe and math.abs(Safe.X) <= Width + 0.15 and math.abs(Safe.Y) <= Height + 0.15)
                            or ((Cfg.neverMiss or Cfg.smartShot) and not Hit and Aim.Magnitude > 0.01) then
                            Args.vector = Aim
                        end
                    end
                end
            end
        end
        return BaseReact(Self, Args)
    end
    Root.react = ShotFunc
    ShotWrapped = true
end

local PredictFolder, PredictLines, PredictMarker, PredictInfo, PredictLabel

local function buildPredictVisuals()
    if PredictFolder then PredictFolder:Destroy() end
    PredictFolder = Instance.new("Folder")
    PredictFolder.Name = "AstralisPred"
    PredictFolder.Parent = uiParent()
    PredictLines = {}
    for i = 1, 48 do
        local Line = Instance.new("LineHandleAdornment")
        Line.Adornee = Workspace.Terrain
        Line.AlwaysOnTop, Line.ZIndex, Line.Thickness = true, 2, Cfg.predThickness
        Line.Transparency, Line.Visible = 0.15, false
        Line.Parent = PredictFolder
        PredictLines[i] = Line
    end
    PredictMarker = Instance.new("SphereHandleAdornment")
    PredictMarker.Adornee, PredictMarker.AlwaysOnTop, PredictMarker.ZIndex = Workspace.Terrain, true, 2
    PredictMarker.Radius, PredictMarker.Transparency, PredictMarker.Visible = 0.35, 0.25, false
    PredictMarker.Parent = PredictFolder
    PredictInfo = Instance.new("BillboardGui")
    PredictInfo.Adornee, PredictInfo.AlwaysOnTop, PredictInfo.Enabled = Workspace.Terrain, true, false
    PredictInfo.Size = UDim2.fromOffset(190, 40)
    PredictInfo.Parent = PredictFolder
    PredictLabel = Instance.new("TextLabel")
    PredictLabel.Size, PredictLabel.BackgroundTransparency = UDim2.fromScale(1, 1), 1
    PredictLabel.Font, PredictLabel.TextSize, PredictLabel.TextStrokeTransparency = Enum.Font.GothamBold, 19, 0.2
    PredictLabel.Parent = PredictInfo
end

local function HidePath()
    if not PredictLines then return end
    for i = 1, #PredictLines do PredictLines[i].Visible = false end
    if PredictMarker then PredictMarker.Visible = false end
    if PredictInfo then PredictInfo.Enabled = false end
end

local function FutureForce(Model, State, Time)
    local Value = Model.Value
    if Model.Curve then
        local Duration = State.Duration
        local Switch = Duration / 1.3
        local Age = State.Time - Model.Created + Time
        if State.Flat and Age >= Duration * 3 then return Vector3.zero end
        if State.Reverse and not Model.Flipped and Age >= Switch then
            local Start = Model.Initial * Vector3.new(-1, 1, -1)
            return Start:Lerp(Start * Vector3.new(0.25, -0.5, 0.25), math.clamp((Age - Switch) / (Duration - Switch), 0, 1))
        end
        local Target = Model.Initial * Vector3.new(0.25, not Model.Flipped and State.Args.direction == "none" and -0.25 or -0.5, 0.25)
        if Model.Rate.Magnitude > 0.001 then
            local Remaining = (Target - Value):Dot(Model.Rate) / Model.Rate:Dot(Model.Rate)
            return Value + Model.Rate * math.min(Time, math.max(Remaining, 0))
        end
        return Value
    end
    return Value + Model.Rate * math.min(Time, 0.1)
end

local function Forecast(Ball, State, Params)
    local Position, Velocity = Ball.Position, Ball.AssemblyLinearVelocity
    local Radius, Mass = math.min(Ball.Size.X, Ball.Size.Y, Ball.Size.Z) / 2, Ball.AssemblyMass
    local Points, Step = { Position }, Cfg.predTime / 48
    local Ground = Workspace:Raycast(Position, Vector3.new(0, -Radius - 0.1, 0), Params)
    Ground = Ground and Velocity.Y <= 1 and Ground.Normal.Y > 0.5 and Ground or nil
    if Ground then Position = Ground.Position + Ground.Normal * (Radius + 0.02) end
    for i = 1, 48 do
        local Time, Acceleration = (i - 0.5) * Step, Vector3.new(0, -Workspace.Gravity, 0)
        for Object, Model in pairs(State.Forces) do
            if Model.Value then Acceleration += FutureForce(Model, State, Time) / Mass end
        end
        Acceleration += State.Residual * math.exp(-Time / 0.25)
        if Ground then
            Velocity -= Ground.Normal * math.min(Velocity:Dot(Ground.Normal), 0)
            Acceleration -= Ground.Normal * math.min(Acceleration:Dot(Ground.Normal), 0)
        end
        local NextVelocity = Velocity + Acceleration * Step
        for Object, Model in pairs(State.Forces) do
            if Model.Controller and State.Time + Time - Model.Created < 0.3 then
                local Change = (Object.Velocity - NextVelocity) * (1 - math.exp(-Object.P * Step / Mass))
                local Limit = Object.MaxForce * (Step / Mass)
                NextVelocity += Vector3.new(math.clamp(Change.X, -Limit.X, Limit.X),
                    math.clamp(Change.Y, -Limit.Y, Limit.Y), math.clamp(Change.Z, -Limit.Z, Limit.Z))
            end
        end
        if Ground then NextVelocity -= Ground.Normal * math.min(NextVelocity:Dot(Ground.Normal), 0) end
        local Move = (Velocity + NextVelocity) * (Step / 2)
        if Move.Magnitude < 0.001 then break end
        local Hit = Workspace:Spherecast(Position, Radius, Move, Params)
        if Hit and not (Ground and Hit.Normal.Y > 0.5) then
            Points[#Points + 1] = Position + Move.Unit * math.max(Hit.Distance - 0.01, 0)
            break
        end
        Position, Velocity = Position + Move, NextVelocity
        Points[#Points + 1] = Position
        if Ground then
            Ground = Workspace:Raycast(Position, Vector3.new(0, -Radius - 0.15, 0), Params)
            Ground = Ground and Ground.Normal.Y > 0.5 and Ground or nil
        end
    end
    return Points
end

local LastCatch, LastDive = -math.huge, -math.huge

local function AutoCatch(Ball)
    if not Cfg.diveCatch or not Ball or not Root or os.clock() - LastCatch < 0.65 then return end
    local Character = LocalPlayer.Character
    local Part = Character and Character:FindFirstChild("HumanoidRootPart")
    local Humanoid = Character and Character:FindFirstChildOfClass("Humanoid")
    local Core = Root.toolData and Root.toolData.GK and Root.toolData.GK.activeController
    local Bind = Core and Core.equipped and Core.binds and Core.binds.catch
    if not Part or not Humanoid or Humanoid.Health <= 0 or Root.character ~= Character
        or not Bind or Bind.using or Root:isHolding()
        or (RootScript and (RootScript:GetAttribute("forceDisable") or RootScript:GetAttribute("charging")
            or RootScript:GetAttribute("catchCooldown") or RootScript:GetAttribute("ragdoll")
            or (RootScript:GetAttribute("globalOverride") and not RootScript:GetAttribute("diving"))))
        or UserInputService:GetFocusedTextBox() then return end
    local Delta = Ball.Position - Part.Position
    if Delta.Magnitude > 14 then return end
    local Velocity = Ball.AssemblyLinearVelocity - Part.AssemblyLinearVelocity
    local Time = Velocity.Magnitude > 1 and math.clamp(-Delta:Dot(Velocity) / Velocity:Dot(Velocity), 0, 0.25) or 0
    if (Delta + Velocity * Time).Magnitude > 4.5 + math.min(Ball.Size.X, Ball.Size.Y, Ball.Size.Z) / 2
        or not Root.gkCheck or not Root:gkCheck() then return end
    LastCatch = os.clock()
    task.spawn(function()
        if Cfg.diveCatch and LocalPlayer.Character == Character and Root.character == Character
            and Root.toolData.GK.activeController == Core and Core.equipped and not Bind.using
            and Ball.Parent and not Ball.Anchored and not Ball:GetAttribute("catch")
            and not Root:isHolding() and not (RootScript and RootScript:GetAttribute("forceDisable")) then
            Bind:inputBegan(Root)
        end
    end)
end

local function AutoDive(Ball, Points)
    if not Cfg.diveEnabled or not Root or os.clock() - LastDive < 1.8 then return end
    local Character = LocalPlayer.Character
    local Part = Character and Character:FindFirstChild("HumanoidRootPart")
    local Humanoid = Character and Character:FindFirstChildOfClass("Humanoid")
    local Core = Root.toolData and Root.toolData.GK and Root.toolData.GK.activeController
    if not Part or not Humanoid or Humanoid.Health <= 0 or Root.character ~= Character
        or not Core or not Core.equipped or not Core.binds or Root:isHolding()
        or (RootScript and (RootScript:GetAttribute("globalOverride") or RootScript:GetAttribute("charging")
            or RootScript:GetAttribute("ragdoll") or RootScript:GetAttribute("forceDisable"))) then return end
    if UserInputService:GetFocusedTextBox() then return end
    local Step = Cfg.predTime / 48
    local Motion = Part.AssemblyLinearVelocity * Vector3.new(1, 0, 1)
    local Depth = 0.75 + math.min(Ball.Size.X, Ball.Size.Y, Ball.Size.Z) / 2
    local Previous = Part.CFrame:PointToObjectSpace(Points[1])
    for i = 2, #Points do
        local Current = Part.CFrame:PointToObjectSpace(Points[i] - Motion * ((i - 1) * Step))
        if Previous.Z < -Depth and Current.Z >= -Depth then
            local Alpha = (-Depth - Previous.Z) / (Current.Z - Previous.Z)
            local Position = Previous:Lerp(Current, Alpha)
            local Time = (i - 2 + Alpha) * Step
            local High = Position.Y > 0.75
            if math.abs(Position.X) > (High and 12 or 10) or Position.Y < -4 or Position.Y > 7 then return end
            local Lead = math.clamp(math.max(0.11, (math.abs(Position.X) - 2.5) / 23,
                High and (Position.Y - 2.5) / 12 or 0) + Cfg.diveLead, 0.15, 0.45)
            if Time > Lead then return end
            local Direction = math.abs(Position.X) <= 1.5 and "straight" or Position.X > 0 and "right" or "left"
            local Bind = Core.binds[High and "high dive" or "low dive"]
            if not Bind or Bind.using or not Root.gkCheck or not Root:gkCheck() then return end
            LastDive = os.clock()
            task.spawn(function()
                if Cfg.diveEnabled and LocalPlayer.Character == Character and Root.character == Character
                    and Root.toolData.GK.activeController == Core and Core.equipped
                    and Ball.Parent and not Ball.Anchored and not Ball:GetAttribute("catch") and not Root:isHolding()
                    and not Bind.using and not (RootScript and (RootScript:GetAttribute("globalOverride")
                        or RootScript:GetAttribute("forceDisable"))) then
                    Bind:inputBegan(Root, Direction)
                end
            end)
            return
        end
        Previous = Current
    end
end

local PredictionBall, Sample, LastPrediction
local Cast = RaycastParams.new()
Cast.FilterType, Cast.RespectCanCollide = Enum.RaycastFilterType.Exclude, true

RunService.Heartbeat:Connect(function()
    if not (Cfg.pred or keeperOn()) then
        if PredictLines then HidePath() end
        Sample = nil
        return
    end
    local Ball, Now = PredictionBall, os.clock()
    if not Ball or not Ball.Parent or Ball.Anchored or Ball:GetAttribute("catch") then
        HidePath()
        Sample = nil
        return
    end
    if LastPrediction and Now - LastPrediction < 1 / 15 then return end
    LastPrediction = Now
    if not PredictFolder then buildPredictVisuals() end
    local Velocity = Ball.AssemblyLinearVelocity
    if Velocity.Magnitude < 0.15 then HidePath() Sample = nil return end
    if not Sample or Sample.Ball ~= Ball then
        Sample = { Ball = Ball, Velocity = Velocity, Time = Now, Args = {}, Forces = {} }
    end
    local Elapsed = Now - Sample.Time
    local Properties = Ball:FindFirstChild("properties")
    local Args = Properties and Properties:FindFirstChild("args")
    if Args ~= Sample.Folder then Sample.Args, Sample.Folder, Sample.Loaded = {}, Args, false end
    if Args and not Sample.Loaded and Args:FindFirstChild("loaded") then
        for i, v in pairs(Args:GetChildren()) do
            if v:IsA("ValueBase") then Sample.Args[v.Name] = v.Value end
        end
        Sample.Loaded = true
    end
    local Shot = Sample.Args
    local Launch = typeof(Shot.vector) == "Vector3" and Shot.vector or Velocity
    local Speed = Vector3.new(Launch.X, 0, Launch.Z).Magnitude
    Sample.Flat = Launch.Y <= 2 and not Shot.simpleFinesseCurve
    Sample.Duration = math.max(Speed / (Sample.Flat and 220 or Shot.risingShot and 40 or 120), 0.05)
    Sample.Knuckle = Shot.spinType == "knuckle"
    Sample.Reverse = Sample.Knuckle and (not Shot.lookAngleAtRelease or Shot.lookAngleAtRelease > 10)
    local Active, Total, Controller = {}, Vector3.zero, false
    for i, v in pairs(Ball:GetChildren()) do
        local Value = Force(v)
        if Value or v:IsA("BodyVelocity") then
            local Previous = Sample.Forces[v]
            local Model = {
                Value = Value, Created = Previous and Previous.Created or Now,
                Initial = Previous and Previous.Initial or Value,
                Rate = Value and Previous and Previous.Value and Elapsed > 0 and (Value - Previous.Value) / Elapsed or Vector3.zero,
                Curve = v:IsA("BodyForce") and Shot.curve == true,
                Controller = v:IsA("BodyVelocity"),
                Flipped = Previous and Previous.Flipped or false,
            }
            if Value then
                Total += Value
                Sample.Knuckle = Sample.Knuckle or v.Name:lower() == "knuckle" and Value.Magnitude > 0.01
                if Model.Initial and Vector3.new(Value.X, 0, Value.Z):Dot(Vector3.new(Model.Initial.X, 0, Model.Initial.Z)) < 0 then
                    Model.Flipped, Model.Initial = true, Value
                end
            end
            Active[v], Controller = Model, Controller or Model.Controller
        end
    end
    local Acceleration = Vector3.new(0, -Workspace.Gravity, 0) + Total / Ball.AssemblyMass
    local Residual = Elapsed > 0 and (Velocity - Sample.Velocity) / Elapsed - Acceleration or Vector3.zero
    Sample.Residual = not Controller and Residual.Magnitude < 250 and Residual or Vector3.zero
    Sample.Forces, Sample.Time, Sample.Velocity = Active, Now, Velocity
    local Excluded = CollectionService:GetTagged("Ball")
    if Cfg.diveEnabled and LocalPlayer.Character then Excluded[#Excluded + 1] = LocalPlayer.Character end
    Cast.FilterDescendantsInstances = Excluded
    Cast.CollisionGroup = Ball.CollisionGroup
    local Points = Forecast(Ball, Sample, Cast)
    AutoDive(Ball, Points)
    if not Cfg.pred then HidePath() return end
    local Horizontal = Vector3.new(Velocity.X, 0, Velocity.Z)
    local Side = Horizontal.Magnitude > 0 and Total - Horizontal.Unit * Total:Dot(Horizontal.Unit) or Total
    local Curved = Shot.curve == true
        or (Horizontal.Magnitude > 0.1 and Vector3.new(Side.X, 0, Side.Z).Magnitude / Ball.AssemblyMass > 1.7)
    local Kind = Curved and "CURVE" or "STRAIGHT"
    local Color = Curved and Color3.fromRGB(186, 94, 255) or Color3.fromRGB(70, 170, 255)
    for i = 1, #PredictLines do
        local v = PredictLines[i]
        local From, To = Points[i], Points[i + 1]
        v.Visible = From ~= nil and To ~= nil and (To - From).Magnitude > 0.001
        if v.Visible then
            v.CFrame = Workspace.Terrain.CFrame:ToObjectSpace(CFrame.lookAt(From, To))
            v.Length, v.Color3 = (To - From).Magnitude, Color
        end
    end
    PredictMarker.Visible = #Points > 1
    PredictInfo.Enabled = PredictMarker.Visible and Cfg.predNames
    PredictMarker.CFrame = Workspace.Terrain.CFrame:ToObjectSpace(CFrame.new(Points[#Points]))
    PredictMarker.Color3 = Color
    PredictInfo.StudsOffsetWorldSpace = Points[#Points] - Workspace.Terrain.Position + Vector3.new(0, 1, 0)
    PredictLabel.Text, PredictLabel.TextColor3 = Kind, Color
end)

local Take, TakeConn, References
local autoTakeInitDone = false

local function initAutoTake()
    if autoTakeInitDone or not Root or not React then return end
    local ok, refs = pcall(function() return getfenv(React)._G._references end)
    if not ok or not refs or not refs.RemoteEvent then return end
    References = refs
    autoTakeInitDone = true
    local function TakePiece()
        if not Cfg.autoTake or not Take or not Take.Parent or Take:GetAttribute("taker") then return end
        if References.Main and References.Main.cards and References.Main.cards.red:FindFirstChild(LocalPlayer.Name) then return end
        local Remote = Take:FindFirstChild("take")
        if not Remote then return end
        Remote:FireServer()
        Take = nil
    end
    if TakeConn then TakeConn:Disconnect() end
    TakeConn = References.RemoteEvent.OnClientEvent:Connect(function(Name, Folder)
        if not Cfg.autoTake then return end
        if Name == "takePrompt" then
            Take = Folder
            TakePiece()
        elseif Name == "takeClear" and Take and Take.Name == Folder then
            Take = nil
        end
    end)
end

local VK = {
    Space = 0x20, W = 0x57, A = 0x41, S = 0x53, D = 0x44,
    One = 0x31, Two = 0x32, Three = 0x33, Four = 0x34,
}
local hasKeys = type(keypress) == "function" and type(keyrelease) == "function"
local hasConns = type(getconnections) == "function"
local heldKeys = {}
local PieceBegan, PieceEnded = {}, {}

local function snapshotPiece()
    local snap = { began = {}, ended = {} }
    if not hasConns then return snap end
    pcall(function()
        for _, c in ipairs(getconnections(UserInputService.InputBegan)) do snap.began[c] = true end
        for _, c in ipairs(getconnections(UserInputService.InputEnded)) do snap.ended[c] = true end
    end)
    return snap
end

local function refreshPiece(snap)
    PieceBegan, PieceEnded = {}, {}
    if not hasConns or not snap then return end
    pcall(function()
        for _, c in ipairs(getconnections(UserInputService.InputBegan)) do
            if not snap.began[c] then table.insert(PieceBegan, c) end
        end
        for _, c in ipairs(getconnections(UserInputService.InputEnded)) do
            if not snap.ended[c] then table.insert(PieceEnded, c) end
        end
    end)
end

local function fireFake(list, keyName)
    if #list == 0 then return false end
    local fake = {
        KeyCode = Enum.KeyCode[keyName],
        UserInputType = Enum.UserInputType.Keyboard,
        Position = Vector3.zero,
    }
    local hit = false
    for _, c in ipairs(list) do
        if c.Fire then
            if pcall(c.Fire, c, fake, false) then hit = true end
        elseif c.Function then
            if pcall(c.Function, fake, false) then hit = true end
        end
    end
    return hit
end

local function fireSignal(signal)
    if not signal or not hasConns then return false end
    local ok, list = pcall(getconnections, signal)
    if not ok or type(list) ~= "table" or #list == 0 then return false end
    local hit = false
    for _, c in ipairs(list) do
        if c.Fire then
            if pcall(c.Fire, c) then hit = true end
        elseif c.Function then
            if pcall(c.Function) then hit = true end
        end
    end
    return hit
end

local function keyDown(name)
    if heldKeys[name] then return end
    heldKeys[name] = true
    local done = fireFake(PieceBegan, name)
    if not done and hasKeys and not isMobile() then
        if not pcall(keypress, VK[name]) then pcall(keypress, Enum.KeyCode[name]) end
    end
end

local function keyUp(name)
    if not heldKeys[name] then return end
    heldKeys[name] = nil
    local done = fireFake(PieceEnded, name)
    if not done and hasKeys and not isMobile() then
        if not pcall(keyrelease, VK[name]) then pcall(keyrelease, Enum.KeyCode[name]) end
    end
end

local function keyTap(name)
    keyDown(name)
    task.wait()
    keyUp(name)
end

local function releaseAllKeys()
    for name in pairs(heldKeys) do keyUp(name) end
end

local function overlayGui(model, partName)
    local overlay = model:FindFirstChild("Overlay")
    local part = overlay and overlay:FindFirstChild(partName)
    if not part then return nil end
    local folder = LocalPlayer.PlayerGui:FindFirstChild("billboardUI")
    if not folder then return nil end
    for _, g in ipairs(folder:GetChildren()) do
        if (g:IsA("BillboardGui") or g:IsA("SurfaceGui")) and g.Adornee == part then return g end
    end
    return nil
end

local function guiChild(gui, name)
    local main = gui and gui:FindFirstChild("Main")
    local container = main and main:FindFirstChild("Container")
    return container and container:FindFirstChild(name)
end

local function bindButton(gui)
    local bind = guiChild(gui, "Bind")
    return bind and bind:FindFirstChild("Button")
end

local function controlsInner(model)
    local gui = overlayGui(model, "Controls")
    local container = guiChild(gui, "Container")
    return container
end

local function styleButton(model, styleName)
    local inner = controlsInner(model)
    local frame = inner and inner:FindFirstChild(styleName)
    return frame and frame:FindFirstChild("Button")
end

local TARGET_FRACTIONS = {
    ["Top Right"] = { x = 0.85, y = 0.9 },
    ["Top Left"] = { x = -0.85, y = 0.9 },
    ["Bottom Right"] = { x = 0.8, y = -0.6 },
    ["Bottom Left"] = { x = -0.8, y = -0.6 },
}

local STYLE_KEY = {
    ["Inside Foot Curled"] = "One",
    ["Outside Foot Curled"] = "Two",
    ["No Curl"] = "Three",
    ["Knuckle"] = "Four",
}

local function applyStyle(model)
    local btn = styleButton(model, Cfg.kickStyle)
    if btn and fireSignal(btn.MouseButton1Click) then return end
    local key = STYLE_KEY[Cfg.kickStyle]
    if key then keyTap(key) end
end

local function driveAxis(read, target, posKey, negKey, tol, deadline)
    while os.clock() < deadline do
        local ok, value = pcall(read)
        if not ok or type(value) ~= "number" then break end
        if math.abs(value - target) <= tol then break end
        if value < target then
            keyUp(negKey)
            keyDown(posKey)
        else
            keyUp(posKey)
            keyDown(negKey)
        end
        task.wait()
    end
    keyUp(posKey)
    keyUp(negKey)
end

local function timedAxis(target, posKey, negKey)
    if math.abs(target) < 0.05 then return end
    local key = target > 0 and posKey or negKey
    keyDown(key)
    task.wait(math.clamp(math.abs(target) / 6, 0.05, 1.5))
    keyUp(key)
end

local function runFreeKick(model, snap)
    task.wait(0.45)
    if not model.Parent then return end
    refreshPiece(snap)

    applyStyle(model)
    task.wait(0.05)

    local frac = TARGET_FRACTIONS[Cfg.kickTarget] or TARGET_FRACTIONS["Top Right"]

    if Cfg.pieceAim then
        local origin = model:FindFirstChild("Origin")
        local cam = Workspace.CurrentCamera
        if origin and cam then
            local base = origin.CFrame:ToObjectSpace(cam.CFrame)
            driveAxis(function()
                local rot = origin.CFrame:ToObjectSpace(cam.CFrame) * base:Inverse()
                local _, yaw = rot:ToOrientation()
                return -math.deg(yaw) / 5
            end, frac.x * 30, "D", "A", 0.7, os.clock() + 6)
            timedAxis(frac.y > 0 and frac.y * 3 or frac.y * 4, "W", "S")
        end
    end
    releaseAllKeys()
    if not model.Parent then return end

    if Cfg.freeKickShoot then
        task.wait(math.max(Cfg.pieceDelay, 0.2))
        if not model.Parent then return end
        refreshPiece(snap)
        local powerFrame = guiChild(overlayGui(model, "Power"), "Power")
        local button = bindButton(overlayGui(model, "Take"))
        local started = button and fireSignal(button.MouseButton1Down)
        if not started then keyDown("Space") end
        local chargeDeadline = os.clock() + 1.8
        while os.clock() < chargeDeadline and model.Parent do
            if powerFrame and powerFrame.Parent
                and powerFrame.Size.X.Scale >= math.clamp(Cfg.kickPower, 0.1, 1) then
                break
            end
            task.wait()
        end
        local ended = button and fireSignal(button.MouseButton1Up)
        if not ended then keyUp("Space") end
        heldKeys["Space"] = nil
    end

    if Cfg.freeKickGreen then
        local frame, gui
        local deadline = os.clock() + 8
        while os.clock() < deadline and model.Parent do
            gui = overlayGui(model, "Composure")
            frame = guiChild(gui, "Composure")
            if frame and frame.Parent and gui.Enabled then break end
            frame = nil
            task.wait()
        end
        if frame then
            refreshPiece(snap)
            if Cfg.freeKickShoot then
                frame.Size = UDim2.new(frame.Size.X.Scale, frame.Size.X.Offset, 0.1, 0)
                heldKeys["Space"] = nil
                keyDown("Space")
                task.wait()
                keyUp("Space")
            else
                while model.Parent and frame.Parent and Cfg.freeKickGreen do
                    frame.Size = UDim2.new(frame.Size.X.Scale, frame.Size.X.Offset, 0.1, 0)
                    task.wait()
                end
            end
        end
    end
    releaseAllKeys()
end

local function runPenalty(model, snap)
    task.wait(0.45)
    if not model.Parent then return end
    refreshPiece(snap)

    local overlay = model:FindFirstChild("Overlay")
    local aim = overlay and overlay:FindFirstChild("Aim")
    local composure = overlay and overlay:FindFirstChild("Composure")
    local frac = TARGET_FRACTIONS[Cfg.kickTarget] or TARGET_FRACTIONS["Top Right"]

    if Cfg.pieceAim and aim then
        local base = aim.CFrame
        local deadline = os.clock() + 5
        driveAxis(function()
            return -base:ToObjectSpace(aim.CFrame).Position.X / 5
        end, frac.x * 3, "D", "A", 0.16, deadline)
        driveAxis(function()
            return base:ToObjectSpace(aim.CFrame).Position.Y / 5
        end, frac.y > 0 and frac.y * 1 or frac.y * 0.7, "W", "S", 0.12, deadline)
    end
    releaseAllKeys()
    if not model.Parent or not composure then return end

    if Cfg.penaltyShoot then
        task.wait(math.max(Cfg.pieceDelay, 0.2))
        if not model.Parent then return end
        refreshPiece(snap)
        composure.Size = Vector3.new(3, composure.Size.Y, 3)
        local button = bindButton(overlayGui(model, "Mobile"))
        local fired = button and fireSignal(button.MouseButton1Click)
        if not fired then
            heldKeys["Space"] = nil
            keyDown("Space")
            task.wait()
            keyUp("Space")
        end
    elseif Cfg.penaltyGreen then
        while model.Parent and composure.Parent and Cfg.penaltyGreen do
            if composure.Size.X > 3 then
                composure.Size = Vector3.new(3, composure.Size.Y, 3)
            end
            task.wait()
        end
    end
    releaseAllKeys()
end

local PieceActive = setmetatable({}, { __mode = "k" })
local pieceWatchConn = nil

local function handlePiece(model)
    if not piecesOn() or PieceActive[model] then return end
    if not model:IsA("Model") or model.Name ~= LocalPlayer.Name then return end
    PieceActive[model] = true
    local snap = snapshotPiece()
    task.spawn(function()
        local isFK, isPEN = false, false
        local deadline = os.clock() + 5
        while os.clock() < deadline and model.Parent do
            isFK = model:FindFirstChild("ExitToLongFreekick") ~= nil
            isPEN = model:FindFirstChild("ExitToFreeMovement") ~= nil
            if isFK or isPEN then break end
            task.wait()
        end
        if not model.Parent then
            releaseAllKeys()
            return
        end
        if isFK and (Cfg.freeKickShoot or Cfg.freeKickGreen) then
            pcall(runFreeKick, model, snap)
        elseif isPEN and (Cfg.penaltyShoot or Cfg.penaltyGreen) then
            pcall(runPenalty, model, snap)
        end
        releaseAllKeys()
        PieceBegan, PieceEnded = {}, {}
    end)
end

local function startPieceWatcher()
    if pieceWatchConn then return end
    local g = Workspace:FindFirstChild("game")
    local debugFolder = g and g:FindFirstChild("debug")
    if not debugFolder then
        task.spawn(function()
            local deadline = os.clock() + 60
            while not debugFolder and os.clock() < deadline and piecesOn() do
                task.wait(2)
                local gg = Workspace:FindFirstChild("game")
                debugFolder = gg and gg:FindFirstChild("debug")
            end
            if debugFolder and piecesOn() and not pieceWatchConn then
                startPieceWatcher()
            end
        end)
        return
    end
    pieceWatchConn = debugFolder.ChildAdded:Connect(function(child)
        if not piecesOn() then return end
        handlePiece(child)
    end)
    for _, child in ipairs(debugFolder:GetChildren()) do
        handlePiece(child)
    end
end

local function stopPieceWatcher()
    if pieceWatchConn then
        pieceWatchConn:Disconnect()
        pieceWatchConn = nil
    end
    releaseAllKeys()
end

local lastReachCheck = 0
local lastStamSync = 0
local lastMechRetry = 0

local function simStep(dt)
    if not anySimFeature() then
        if reachAdorn and reachAdorn.Visible then reachAdorn.Visible = false end
        return
    end

    local now = os.clock()
    local c = LocalPlayer.Character
    if c ~= cachedChar then cacheCharacter(c) end

    local h = cachedHRP
    if h and not h.Parent then h = nil end
    local hum = cachedHum
    if hum and not hum.Parent then hum = nil end

    if needMech() and (not mech or not Root) and now - lastMechRetry >= 4 then
        lastMechRetry = now
        findMechObjects()
        if stamOn() then findStaminaValue() end
        if Cfg.autoTake then initAutoTake() end
    end

    if Cfg.reach or rulesOn() then hookMech() end
    if shotOn() then hookSmartShot() end

    if stamOn() then
        if #stamTables == 0 and now - lastMechRetry >= 4 then
            lastMechRetry = now
            findMechObjects()
            findStaminaValue()
        end
        if now - lastStamSync >= 0.1 then
            lastStamSync = now
            syncStaminaAndSpeed()
        end
    end

    if h and hum and hum.Health > 0 and Cfg.speed then
        if hum.WalkSpeed ~= Cfg.sv then hum.WalkSpeed = Cfg.sv end
        local md = hum.MoveDirection
        if md.Magnitude > 0 then
            h.CFrame = h.CFrame + md.Unit * ((Cfg.sv - 16) * 0.45 * dt)
        end
    end

    if Cfg.reach and h and now - lastReachCheck >= 0.02 then
        lastReachCheck = now
        local balls = getBalls()
        local offset = Cfg.reachOffset
        local size = Cfg.reachSize
        local hPos = h.Position
        local maxDim = math.max(size.X, size.Y, size.Z)
        local threshold = maxDim * 0.9 + offset.Magnitude + 4
        for i = 1, #balls do
            local b = balls[i]
            if b and b.Parent then
                if not (Cfg.reachComp and b:GetAttribute("networkOwner") == LocalPlayer.UserId) then
                    local bPos = b.Position
                    if (bPos - hPos).Magnitude <= threshold and boxCheck(h, bPos, offset, size) then
                        touchBall(b)
                    end
                end
            end
        end
        updateAdorns()
    end

    if (Cfg.pred or keeperOn()) and h then
        local balls = getBalls()
        local Nearest, Distance = nil, math.huge
        local Tracked, TrackDistance = nil, math.huge
        for i = 1, #balls do
            local v = balls[i]
            if v and v.Parent then
                local Range = (v.Position - h.Position).Magnitude
                if Range < Distance then Nearest, Distance = v, Range end
                if not v.Anchored and not v:GetAttribute("catch") and Range < TrackDistance then
                    Tracked, TrackDistance = v, Range
                end
            end
        end
        PredictionBall = Tracked
        if Cfg.diveCatch then AutoCatch(Nearest) end
    end
end

RunService.PreSimulation:Connect(function(dt)
    pcall(simStep, dt)
end)

UserInputService.JumpRequest:Connect(function()
    if Cfg.jump then
        local h = cachedHRP
        local hum = cachedHum
        if h and h.Parent and hum and hum.Parent and hum.FloorMaterial ~= Enum.Material.Air then
            local vel = h.AssemblyLinearVelocity
            h.AssemblyLinearVelocity = Vector3.new(vel.X, Cfg.jv, vel.Z)
        end
    end
end)

LocalPlayer.CharacterAdded:Connect(function(c)
    releaseAllKeys()
    cacheCharacter(c)
    stamValue = nil
    moveController = nil
    if needMech() then
        task.spawn(function()
            task.wait(1.5)
            findStaminaValue()
            findMechObjects(true)
            if Cfg.autoTake then
                autoTakeInitDone = false
                initAutoTake()
            end
        end)
    end
end)

local Airflow = loadstring(game:HttpGet("https://raw.githubusercontent.com/PookiePepelsss/Airflow-UI/refs/heads/main/Source.luau"))()

Airflow:LoadFont({ Name = "ValleySans" })

local Window = Airflow:CreateWindow({
    Name = "Astralis V2.8 (PAID)",
    LoadingSubtitle = "2.8",
    Theme = "Default",
    ToggleUIKeybind = "RightShift",
    OpenButton = { Title = "Astralis", Icon = "wind" },
    ConfigurationSaving = { Enabled = true, FolderName = "Astralis", FileName = "default" },
    Home = {
        Name = "Home",
        Stats = { "FPS", "Ping", "Executor", "Game", "Region", "Time" },
        Pages = {
            {
                Name = "Changelog",
                Icon = "scroll-text",
                Entries = {
                    { Title = "v2.8", Tag = "Latest", Changes = {
                        "Full touch support", "Input-driven set pieces", "Forced green on FK + penalty",
                        "Closed-loop aim", "Smart shot / anti miss", "Auto dive + catch",
                    } },
                },
            },
        },
    },
})

local MainTab = Window:CreateTab({ Name = "Main", Icon = "crosshair" })
local PlayerTab = Window:CreateTab({ Name = "Player", Icon = "person-standing" })
local RulesTab = Window:CreateTab({ Name = "Rules", Icon = "shield" })
local BallTab = Window:CreateTab({ Name = "Ball", Icon = "circle" })
local KeeperTab = Window:CreateTab({ Name = "Goalkeeper", Icon = "hand" })
local PiecesTab = Window:CreateTab({ Name = "Set Pieces", Icon = "flag" })
local ConfigTab = Window:CreateTab({ Name = "Config", Icon = "settings" })

local function onShootingChanged()
    if shotOn() then
        findMechObjects(true)
        task.spawn(function()
            local deadline = os.clock() + 8
            while not Root and os.clock() < deadline do task.wait(0.5) end
            hookSmartShot()
        end)
    end
end

local function onPiecesChanged()
    if piecesOn() then
        startPieceWatcher()
        local g = Workspace:FindFirstChild("game")
        local debugFolder = g and g:FindFirstChild("debug")
        if debugFolder then
            for _, child in ipairs(debugFolder:GetChildren()) do
                if not PieceActive[child] then handlePiece(child) end
            end
        end
    else
        stopPieceWatcher()
    end
end

MainTab:CreateSection("Reach")
MainTab:CreateToggle({ Name = "Player Reach", Flag = "PlayerReach", CurrentValue = false, Callback = function(v)
    Cfg.reach = v
    if v then
        findMechObjects(true)
        startActorLoop()
        updateAdorns()
    elseif reachAdorn and reachAdorn.Visible then
        reachAdorn.Visible = false
    end
end })
MainTab:CreateToggle({ Name = "Comp Reach (skip owned balls)", Flag = "ReachComp", CurrentValue = false, Callback = function(v) Cfg.reachComp = v end })
MainTab:CreateSlider({ Name = "Reach Size X", Range = { 1, 20 }, Increment = 1, CurrentValue = 8, Flag = "ReachX", Callback = function(v) Cfg.reachSize = Vector3.new(v, Cfg.reachSize.Y, Cfg.reachSize.Z) end })
MainTab:CreateSlider({ Name = "Reach Size Y", Range = { 1, 20 }, Increment = 1, CurrentValue = 8, Flag = "ReachY", Callback = function(v) Cfg.reachSize = Vector3.new(Cfg.reachSize.X, v, Cfg.reachSize.Z) end })
MainTab:CreateSlider({ Name = "Reach Size Z", Range = { 1, 20 }, Increment = 1, CurrentValue = 8, Flag = "ReachZ", Callback = function(v) Cfg.reachSize = Vector3.new(Cfg.reachSize.X, Cfg.reachSize.Y, v) end })
MainTab:CreateSlider({ Name = "Reach Transparency", Range = { 0, 10 }, Increment = 1, CurrentValue = 5, Flag = "ReachTrans", Callback = function(v) Cfg.reachTrans = v / 10 end })
MainTab:CreateColorPicker({ Name = "Reach Color", Color = Color3.fromRGB(255, 255, 255), Flag = "ReachColor", Callback = function(c) Cfg.reachColor = c end })

MainTab:CreateSection("Shooting")
MainTab:CreateToggle({ Name = "Anti Miss", Flag = "AntiMiss", CurrentValue = false, Callback = function(v)
    Cfg.antiMiss = v
    onShootingChanged()
end })
MainTab:CreateToggle({ Name = "Never Miss", Flag = "NeverMiss", CurrentValue = false, Callback = function(v)
    Cfg.neverMiss = v
    onShootingChanged()
end })
MainTab:CreateSlider({ Name = "Never Miss Max Distance", Range = { 0, 30 }, Increment = 1, CurrentValue = 30, Flag = "NeverMissDist", Callback = function(v) Cfg.neverMissDist = v end })
MainTab:CreateToggle({ Name = "Smart Shot (keeper-aware)", Flag = "SmartShot", CurrentValue = false, Callback = function(v)
    Cfg.smartShot = v
    onShootingChanged()
end })

MainTab:CreateSection("Choose Team")
for _, v in ipairs({ "Home", "Home GK", "Away", "Away GK" }) do
    MainTab:CreateButton({ Name = v, Callback = function()
        if not Network then findMechObjects(true) end
        task.spawn(function()
            local deadline = os.clock() + 6
            while not Network and os.clock() < deadline do task.wait(0.4) end
            local Team = Teams:FindFirstChild(v)
            if Network and Team then pcall(Network.fetch, Network, "team", Team) end
        end)
    end })
end

PlayerTab:CreateSection("Movement")
PlayerTab:CreateToggle({ Name = "Infinite Stamina", Flag = "InfStam", CurrentValue = false, Callback = function(v)
    Cfg.infStam = v
    if v then
        findMechObjects(true)
        findStaminaValue()
    end
end })
PlayerTab:CreateToggle({ Name = "2x Stamina", Flag = "StamDouble", CurrentValue = false, Callback = function(v)
    Cfg.stamDouble = v
    if v then
        findMechObjects(true)
        findStaminaValue()
    end
end })
PlayerTab:CreateToggle({ Name = "Speed Boost", Flag = "SpeedBoost", CurrentValue = false, Callback = function(v)
    Cfg.speed = v
    if v then
        findMechObjects(true)
    else
        if cachedHum and cachedHum.Parent then cachedHum.WalkSpeed = 16 end
        for i = 1, #stamTables do
            pcall(function()
                if rawget(stamTables[i], "sprintSpeed") ~= nil then
                    rawset(stamTables[i], "sprintSpeed", 22)
                end
            end)
        end
    end
end })
PlayerTab:CreateSlider({ Name = "Speed Value", Range = { 16, 30 }, Increment = 1, CurrentValue = 26, Flag = "SpeedVal", Callback = function(v) Cfg.sv = v end })
PlayerTab:CreateToggle({ Name = "Jump Boost", Flag = "JumpBoost", CurrentValue = false, Callback = function(v) Cfg.jump = v end })
PlayerTab:CreateSlider({ Name = "Jump Power", Range = { 50, 70 }, Increment = 1, CurrentValue = 65, Flag = "JumpPow", Callback = function(v) Cfg.jv = v end })
PlayerTab:CreateToggle({ Name = "Mobile Movement UI", Flag = "MobileMovement", CurrentValue = false, Callback = function(v)
    Cfg.mobileMovement = v
    pcall(function()
        local main = LocalPlayer.PlayerGui:FindFirstChild("main")
        local mobile = main and main:FindFirstChild("mobile")
        if mobile then mobile.Visible = v end
    end)
end })

RulesTab:CreateSection("Contact Rules")
local function ruleCallback(key)
    return function(v)
        Cfg[key] = v
        if v then
            findMechObjects(true)
            task.spawn(function()
                local deadline = os.clock() + 8
                while not mech and os.clock() < deadline do task.wait(0.5) end
                hookMech()
            end)
        end
    end
end
RulesTab:CreateToggle({ Name = "Anti Shield", Flag = "AntiShield", CurrentValue = false, Callback = ruleCallback("antiShield") })
RulesTab:CreateToggle({ Name = "Anti Foul", Flag = "AntiFoul", CurrentValue = false, Callback = ruleCallback("antiFoul") })
RulesTab:CreateToggle({ Name = "Anti Ankle", Flag = "AntiAnkle", CurrentValue = false, Callback = ruleCallback("antiAnkle") })
RulesTab:CreateToggle({ Name = "Anti Offside", Flag = "AntiOffside", CurrentValue = false, Callback = ruleCallback("antiOffside") })
RulesTab:CreateToggle({ Name = "Anti Slowdown", Flag = "AntiSlowdown", CurrentValue = false, Callback = ruleCallback("antiSlowdown") })
RulesTab:CreateSection("Reactions")
RulesTab:CreateToggle({ Name = "Better React", Flag = "BetterReact", CurrentValue = false, Callback = ruleCallback("betterReact") })
RulesTab:CreateToggle({ Name = "Break React", Flag = "BreakReactToggle", CurrentValue = false, Callback = ruleCallback("breakReact") })

BallTab:CreateSection("Prediction")
BallTab:CreateToggle({ Name = "Ball Prediction", Flag = "BallPred", CurrentValue = false, Callback = function(v)
    Cfg.pred = v
    if v then
        if not PredictFolder then buildPredictVisuals() end
    else
        HidePath()
    end
end })
BallTab:CreateSlider({ Name = "Prediction Time", Range = { 0.5, 3 }, Increment = 0.1, CurrentValue = 1.2, Flag = "PredTime", Callback = function(v) Cfg.predTime = v end })
BallTab:CreateSlider({ Name = "Beam Thickness", Range = { 1, 10 }, Increment = 0.5, CurrentValue = 2, Flag = "PredThickness", Callback = function(v)
    Cfg.predThickness = v
    if PredictLines then
        for _, l in pairs(PredictLines) do l.Thickness = v end
    end
end })
BallTab:CreateDropdown({ Name = "Shot Names", Options = { "Show", "Hide" }, CurrentOption = "Show", Flag = "PredNames", Callback = function(v)
    Cfg.predNames = v == "Show"
end })

KeeperTab:CreateSection("Auto Dive")
KeeperTab:CreateToggle({ Name = "Auto Dive", Flag = "AutoDive", CurrentValue = false, Callback = function(v)
    Cfg.diveEnabled = v
    if v then findMechObjects(true) end
end })
KeeperTab:CreateSlider({ Name = "Dive Lead", Range = { 0.03, 0.2 }, Increment = 0.01, CurrentValue = 0.15, Flag = "DiveLead", Callback = function(v) Cfg.diveLead = v end })
KeeperTab:CreateSection("Catching")
KeeperTab:CreateToggle({ Name = "Auto Catch", Flag = "AutoCatch", CurrentValue = false, Callback = function(v)
    Cfg.diveCatch = v
    if v then findMechObjects(true) end
end })

PiecesTab:CreateSection("Set Piece Selection")
PiecesTab:CreateToggle({ Name = "Auto Take", Flag = "AutoTake", CurrentValue = false, Callback = function(v)
    Cfg.autoTake = v
    if v then
        findMechObjects(true)
        task.spawn(function()
            local deadline = os.clock() + 8
            while not React and os.clock() < deadline do task.wait(0.5) end
            initAutoTake()
        end)
    end
end })
PiecesTab:CreateSection("Free Kicks")
PiecesTab:CreateToggle({ Name = "Free Kick Auto Shoot", Flag = "FKShoot", CurrentValue = true, Callback = function(v)
    Cfg.freeKickShoot = v
    onPiecesChanged()
end })
PiecesTab:CreateToggle({ Name = "Free Kick Perfect Green", Flag = "FKGreen", CurrentValue = true, Callback = function(v)
    Cfg.freeKickGreen = v
    onPiecesChanged()
end })
PiecesTab:CreateSection("Penalties")
PiecesTab:CreateToggle({ Name = "Penalty Auto Shoot", Flag = "PenShoot", CurrentValue = true, Callback = function(v)
    Cfg.penaltyShoot = v
    onPiecesChanged()
end })
PiecesTab:CreateToggle({ Name = "Penalty Perfect Green", Flag = "PenGreen", CurrentValue = true, Callback = function(v)
    Cfg.penaltyGreen = v
    onPiecesChanged()
end })
PiecesTab:CreateSection("Aiming")
PiecesTab:CreateToggle({ Name = "Auto Aim", Flag = "PieceAim", CurrentValue = true, Callback = function(v) Cfg.pieceAim = v end })
PiecesTab:CreateSlider({ Name = "Shot Delay", Range = { 0.2, 3 }, Increment = 0.1, CurrentValue = 0.6, Flag = "PieceDelay", Callback = function(v) Cfg.pieceDelay = v end })
PiecesTab:CreateSlider({ Name = "Free Kick Power", Range = { 10, 100 }, Increment = 5, CurrentValue = 85, Flag = "KickPower", Callback = function(v) Cfg.kickPower = v / 100 end })
PiecesTab:CreateDropdown({ Name = "Free Kick Style", Options = { "Inside Foot Curled", "Outside Foot Curled", "No Curl", "Knuckle" }, CurrentOption = "Inside Foot Curled", Flag = "KickStyle", Callback = function(v) Cfg.kickStyle = v end })
PiecesTab:CreateDropdown({ Name = "Set Piece Target", Options = { "Top Right", "Top Left", "Bottom Right", "Bottom Left" }, CurrentOption = "Top Right", Flag = "KickTarget", Callback = function(v) Cfg.kickTarget = v end })

ConfigTab:CreateSection("Interface")
ConfigTab:CreateDropdown({ Name = "Input Mode", Options = { "Auto", "Mobile", "Keyboard" }, CurrentOption = "Auto", Flag = "MobileMode", Callback = function(v)
    Cfg.mobileMode = v
end })
ConfigTab:CreateThemePicker({ Flag = "Theme" })
ConfigTab:CreateConfigManager({ Name = "Configs" })

task.defer(function()
    Window:LoadConfig()
    if piecesOn() then startPieceWatcher() end
    if Cfg.reach then startActorLoop() end
    if needMech() then
        findMechObjects(true)
        findStaminaValue()
    end
end)

pcall(function()
    Airflow:Notify({ Title = "Astralis", Content = "Loaded v2.8 (PAID)", Icon = "bell", Type = "Success", Duration = 3 })
end)