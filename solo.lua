-- ============================================================
-- AUTO SCAN + FEED MUTATION MACHINE (SIMPLE v4)
-- + Auto Deteksi Waktu Mesin
-- + Auto Stop Jika Tidak Ada Pet Eligible
-- ============================================================

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local LocalPlayer = Players.LocalPlayer

--// ============================================================
-- CONFIG
--// ============================================================
local CONFIG = {
    AUTO_FEED = false,
    SCAN_INTERVAL = 2,
    DRY_RUN = false,
    TARGET_AGE = 50,
    SKIP_MUTATIONS = {"Diamond"},
    DELAY_EQUIP = 0.8,
    DELAY_INSERT = 1,
    DELAY_COLLECT = 3,
    MAX_FEED_PER_CYCLE = 1,
    POLL_INTERVAL = 2,
    MUTATION_TIMEOUT = 600,
    
    -- ⭐ Auto stop
    AUTO_STOP_IF_EMPTY = true,
    EMPTY_CHECK_DELAY = 5,
    EMPTY_COUNT_THRESHOLD = 3,
}

--// ============================================================
-- LOAD MODULES
--// ============================================================
local playerDataModule = require(ReplicatedStorage.TS.state["player-data"])
local petAgeUtils = require(ReplicatedStorage.TS.utils["pet-age.utils"])

local getSharedTime, PET_MUTATION_TIME
pcall(function()
    getSharedTime = require(game:GetService("StarterPlayer").StarterPlayerScripts.TS.systems.core.sharedTime).getSharedTime
end)
pcall(function()
    PET_MUTATION_TIME = require(ReplicatedStorage.TS.constants).PET_MUTATION_TIME
end)

local inventoryStateModule
pcall(function()
    inventoryStateModule = require(LocalPlayer.PlayerScripts.TS.ui.features.toolbar["inventory.state"])
end)

--// ============================================================
-- GET REMOTES
--// ============================================================
local function getRemo(name)
    local ok, remote = pcall(function()
        return ReplicatedStorage
            :WaitForChild("rbxts_include", 10)
            :WaitForChild("node_modules", 10)
            :WaitForChild("@rbxts", 10)
            :WaitForChild("remo", 10)
            :WaitForChild("src", 10)
            :WaitForChild("container", 10)
            :WaitForChild(name, 10)
    end)
    return ok and remote or nil
end

local Remotes = {
    equipTool  = getRemo("tools.equipTool"),
    startMut   = getRemo("pets.startMutation"),
    collectMut = getRemo("pets.collectMutation"),
}

--// ============================================================
-- UTILS
--// ============================================================
local function getPlayerData()
    local ok, data = pcall(playerDataModule.getPlayerDataById, tostring(LocalPlayer.UserId))
    return ok and data or nil
end

local function getPetAge(petData)
    local ok, age = pcall(petAgeUtils.getPetAgeFromData, petData)
    return ok and age or 0
end

local function isSkippedMutation(petData)
    if not petData.mutation then return false end
    local mut = petData.mutation
    if type(mut) == "string" then
        for _, m in ipairs(CONFIG.SKIP_MUTATIONS) do
            if mut == m then return true end
        end
    elseif type(mut) == "table" then
        for _, m in ipairs(mut) do
            for _, skip in ipairs(CONFIG.SKIP_MUTATIONS) do
                if m == skip then return true end
            end
        end
    end
    return false
end

local function shortUUID(uuid)
    if not uuid then return "?" end
    return uuid:sub(1, 8) .. "..."
end

local function formatTime(seconds)
    seconds = math.floor(seconds or 0)
    if seconds < 0 then seconds = 0 end
    local mins = math.floor(seconds / 60)
    local secs = seconds % 60
    return string.format("%02d:%02d", mins, secs)
end

local function parseMutationResult(result)
    if result == nil or result == false then return nil end
    if type(result) == "string" then return result end
    if type(result) == "table" then
        return result.mutation or result.mutationType or result.name or result.type
    end
    return tostring(result)
end

--// ============================================================
-- REMOTE HELPERS
--// ============================================================
local function safeFire(remote, ...)
    if not remote then return false end
    local args = {...}
    local ok = pcall(function() remote:FireServer(table.unpack(args)) end)
    return ok
end

local function safeInvoke(remote, ...)
    if not remote then return false, "remote nil" end
    local args = {...}
    local ok, result = pcall(function() return remote:InvokeServer(table.unpack(args)) end)
    return ok, result
end

--// ============================================================
-- MACHINE STATE
--// ============================================================
local function getMachineState()
    local data = getPlayerData()
    if not data then return "Unknown", 0, 0 end
    
    local pm = data.petMutation
    if not pm then return "Idle", 0, 0 end
    if not pm.timeStarted then return "Idle", 0, 0 end
    
    local now
    if getSharedTime then
        local ok, t = pcall(getSharedTime)
        if ok and t then now = t else now = tick() end
    else
        now = tick()
    end
    
    local elapsed = now - pm.timeStarted
    local depletionRate = pm.depletionRate or 1
    local totalTime = (PET_MUTATION_TIME or 300) / depletionRate
    
    local remaining = math.max(0, totalTime - elapsed)
    local progress = math.clamp(elapsed / totalTime, 0, 1)
    
    if remaining <= 0 then return "Ready", 0, 1 end
    return "InProgress", remaining, progress
end

--// ============================================================
-- SCAN ELIGIBLE
--// ============================================================
local function findEligiblePets()
    if not inventoryStateModule then return {} end
    
    local ok, stacked = pcall(function() return inventoryStateModule.inventoryStackedData() end)
    if not ok or not stacked then return {} end
    
    local data = getPlayerData()
    if not data then return {} end
    
    local equippedSet = {}
    if data.equippedPets then
        for _, id in ipairs(data.equippedPets) do
            equippedSet[id] = true
        end
    end
    
    local eligible = {}
    local seen = {}
    
    for stackKey, item in pairs(stacked) do
        local tt = tostring(item.toolType):lower()
        if tt:find("pet") and item.items and item.items[1] then
            local petId = item.items[1].id
            local petData = item.items[1].data
            
            if petId and not seen[petId] and petData then
                seen[petId] = true
                
                local age = getPetAge(petData)
                local isMaxAge = age >= CONFIG.TARGET_AGE
                local isSkip = isSkippedMutation(petData)
                local isEquipped = equippedSet[petId] == true
                
                if isMaxAge and not isSkip and not isEquipped then
                    table.insert(eligible, {
                        id = petId,
                        data = petData,
                        age = age,
                        displayName = item.displayName or item.itemName or "?",
                        mutation = petData.mutation,
                    })
                end
            end
        end
    end
    
    table.sort(eligible, function(a, b) return a.age > b.age end)
    return eligible
end

--// ============================================================
-- FEED FUNCTION
--// ============================================================
local function feedPetToMachine(petEntry)
    local petId = petEntry.id
    local petName = petEntry.displayName
    
    print(string.format("[FEED] Pet: %s | ID: %s | Age: %d", petName, shortUUID(petId), petEntry.age))
    
    if CONFIG.DRY_RUN then
        print("  [DRY RUN] Skip eksekusi")
        return true
    end
    
    -- Cek mesin
    print("  ⏳ Cek mesin...")
    local waitIdle = 0
    while waitIdle < 60 do
        if not CONFIG.AUTO_FEED then return false end
        local state = getMachineState()
        if state == "Idle" then break end
        if state == "Ready" then
            print("  ⚠️ Mesin Ready, collect dulu...")
            safeInvoke(Remotes.collectMut)
            task.wait(3)
        end
        task.wait(2)
        waitIdle = waitIdle + 2
    end
    
    -- Step 1: Equip
    print("  🎒 Equip...")
    safeFire(Remotes.equipTool, petId, "pet")
    task.wait(CONFIG.DELAY_EQUIP)
    
    -- Step 2: Insert
    print("  🧬 Insert...")
    local ok, result = safeInvoke(Remotes.startMut, petId)
    if not ok or result == false or result == nil then
        print("  ❌ Insert gagal:", tostring(result))
        return false
    end
    print("  ✅ Insert OK")
    task.wait(CONFIG.DELAY_INSERT)
    
    -- Step 3: Tunggu
    print("  ⏳ Tunggu mutasi...")
    local waitStart = tick()
    local lastLog = 0
    
    while tick() - waitStart < CONFIG.MUTATION_TIMEOUT do
        if not CONFIG.AUTO_FEED then return false end
        
        local state, remaining, progress = getMachineState()
        if state == "Idle" then
            print("  ✅ Mesin IDLE (selesai)")
            break
        elseif state == "Ready" then
            print("  ✅ READY!")
            break
        end
        
        local now = tick()
        if now - lastLog >= 15 then
            print(string.format("  ⏳ Sisa: %s (%.0f%%)", formatTime(remaining), progress * 100))
            lastLog = now
        end
        
        task.wait(CONFIG.POLL_INTERVAL)
    end
    
    -- Step 4: Collect
    print("  📦 Collect...")
    task.wait(CONFIG.DELAY_COLLECT)
    
    local cok, cresult = safeInvoke(Remotes.collectMut)
    
    if cok and cresult ~= false and cresult ~= nil then
        local mutationResult = parseMutationResult(cresult)
        print("  🎉 Collect OK:", tostring(mutationResult))
        
        if mutationResult == "Diamond" then
            print("  💎💎💎 DIAMOND DIDAPAT!")
            pcall(function()
                game:GetService("StarterGui"):SetCore("SendNotification", {
                    Title = "💎 Diamond Mutation!",
                    Text = petName .. " berhasil dapat Diamond!",
                    Duration = 5,
                })
            end)
        end
        return true
    else
        print("  ⚠️ Collect gagal, retry...")
        for i = 1, 3 do
            task.wait(3)
            local rok, rresult = safeInvoke(Remotes.collectMut)
            if rok and rresult ~= false and rresult ~= nil then
                local mutationResult = parseMutationResult(rresult)
                print("  🎉 Collect OK (retry", i, "):", tostring(mutationResult))
                return true
            end
        end
        print("  ❌ Collect gagal 3x")
        return false
    end
end

--// ============================================================
-- MAIN LOOP
--// ============================================================
local isRunning = false
local emptyCount = 0

local function autoFeedLoop()
    if isRunning then return end
    isRunning = true
    emptyCount = 0
    
    while CONFIG.AUTO_FEED do
        print(string.rep("=", 50))
        print("🔍 Scan pet eligible...")
        
        local eligible = findEligiblePets()
        
        if #eligible == 0 then
            emptyCount = emptyCount + 1
            print(string.format("  ⏸ Tidak ada pet eligible (scan kosong #%d/%d)", 
                emptyCount, CONFIG.EMPTY_COUNT_THRESHOLD))
            
            -- ⭐ AUTO STOP
            if CONFIG.AUTO_STOP_IF_EMPTY and emptyCount >= CONFIG.EMPTY_COUNT_THRESHOLD then
                print("  🛑 Semua pet sudah diproses / tidak ada yang eligible!")
                print("  🛑 AUTO STOP...")
                
                if log then
                    log("🛑 AUTO STOP: Tidak ada pet eligible")
                    log(string.format("   (scan kosong %dx berturut-turut)", emptyCount))
                end
                
                pcall(function()
                    game:GetService("StarterGui"):SetCore("SendNotification", {
                        Title = "🛑 Auto Mutation STOP",
                        Text = "Semua pet sudah diproses!",
                        Duration = 5,
                    })
                end)
                
                _G.__autoMutStop()
                break
            end
            
            task.wait(CONFIG.EMPTY_CHECK_DELAY)
        else
            emptyCount = 0
            print(string.format("  ✅ %d pet eligible", #eligible))
            
            local fed = 0
            for _, petEntry in ipairs(eligible) do
                if fed >= CONFIG.MAX_FEED_PER_CYCLE then break end
                if not CONFIG.AUTO_FEED then break end
                
                local success = feedPetToMachine(petEntry)
                if success then
                    fed = fed + 1
                    print(string.format("  ✅ Fed %d/%d", fed, CONFIG.MAX_FEED_PER_CYCLE))
                else
                    print("  ❌ Feed gagal, skip pet ini")
                end
                task.wait(1)
            end
            
            task.wait(CONFIG.SCAN_INTERVAL)
        end
    end
    
    isRunning = false
end

--// ============================================================
-- GUI
--// ============================================================
local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "AutoMutationSimple"
ScreenGui.ResetOnSpawn = false
ScreenGui.Parent = LocalPlayer:WaitForChild("PlayerGui")

local Frame = Instance.new("Frame")
Frame.Size = UDim2.new(0, 380, 0, 380)
Frame.Position = UDim2.new(0, 20, 0.5, -190)
Frame.BackgroundColor3 = Color3.fromRGB(20, 20, 30)
Frame.BorderSizePixel = 0
Frame.Active = true
Frame.Draggable = true
Frame.Parent = ScreenGui
Instance.new("UICorner", Frame).CornerRadius = UDim.new(0, 10)

local stroke = Instance.new("UIStroke", Frame)
stroke.Color = Color3.fromRGB(120, 80, 200)
stroke.Thickness = 2

-- TITLE
local Title = Instance.new("TextLabel")
Title.Size = UDim2.new(1, 0, 0, 34)
Title.BackgroundColor3 = Color3.fromRGB(55, 40, 85)
Title.BorderSizePixel = 0
Title.Text = "🧬 AUTO MUTATION (v4 + Auto Stop)"
Title.TextColor3 = Color3.fromRGB(255, 255, 255)
Title.TextSize = 14
Title.Font = Enum.Font.GothamBold
Title.Parent = Frame
Instance.new("UICorner", Title).CornerRadius = UDim.new(0, 10)

local TitleFill = Instance.new("Frame")
TitleFill.Size = UDim2.new(1, 0, 0, 8)
TitleFill.Position = UDim2.new(0, 0, 1, -8)
TitleFill.BackgroundColor3 = Color3.fromRGB(55, 40, 85)
TitleFill.BorderSizePixel = 0
TitleFill.Parent = Title

-- CLOSE
local CloseBtn = Instance.new("TextButton")
CloseBtn.Size = UDim2.new(0, 26, 0, 26)
CloseBtn.Position = UDim2.new(1, -32, 0, 4)
CloseBtn.BackgroundColor3 = Color3.fromRGB(180, 50, 50)
CloseBtn.BorderSizePixel = 0
CloseBtn.Text = "✕"
CloseBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
CloseBtn.TextSize = 12
CloseBtn.Font = Enum.Font.GothamBold
CloseBtn.Parent = Title
Instance.new("UICorner", CloseBtn).CornerRadius = UDim.new(0, 6)

CloseBtn.MouseButton1Click:Connect(function()
    CONFIG.AUTO_FEED = false
    ScreenGui:Destroy()
end)

-- STATUS
local StatusLabel = Instance.new("TextLabel")
StatusLabel.Size = UDim2.new(1, -20, 0, 50)
StatusLabel.Position = UDim2.new(0, 10, 0, 42)
StatusLabel.BackgroundColor3 = Color3.fromRGB(30, 30, 45)
StatusLabel.BorderSizePixel = 0
StatusLabel.Text = "Status: OFF\nEligible: - pet"
StatusLabel.TextColor3 = Color3.fromRGB(255, 100, 100)
StatusLabel.TextSize = 12
StatusLabel.Font = Enum.Font.GothamBold
StatusLabel.TextXAlignment = Enum.TextXAlignment.Left
StatusLabel.TextYAlignment = Enum.TextYAlignment.Top
StatusLabel.Parent = Frame
Instance.new("UICorner", StatusLabel).CornerRadius = UDim.new(0, 6)

local StatusPadding = Instance.new("UIPadding", StatusLabel)
StatusPadding.PaddingTop = UDim.new(0, 6)
StatusPadding.PaddingLeft = UDim.new(0, 10)

-- MACHINE TIMER FRAME
local MachineFrame = Instance.new("Frame")
MachineFrame.Size = UDim2.new(1, -20, 0, 70)
MachineFrame.Position = UDim2.new(0, 10, 0, 98)
MachineFrame.BackgroundColor3 = Color3.fromRGB(25, 25, 40)
MachineFrame.BorderSizePixel = 0
MachineFrame.Parent = Frame
Instance.new("UICorner", MachineFrame).CornerRadius = UDim.new(0, 6)

local MachineStroke = Instance.new("UIStroke", MachineFrame)
MachineStroke.Color = Color3.fromRGB(100, 70, 150)
MachineStroke.Thickness = 1

local MachineTitle = Instance.new("TextLabel")
MachineTitle.Size = UDim2.new(1, -12, 0, 16)
MachineTitle.Position = UDim2.new(0, 6, 0, 4)
MachineTitle.BackgroundTransparency = 1
MachineTitle.Text = "⏱️ MESIN STATUS"
MachineTitle.TextColor3 = Color3.fromRGB(150, 150, 190)
MachineTitle.TextSize = 10
MachineTitle.Font = Enum.Font.GothamBold
MachineTitle.TextXAlignment = Enum.TextXAlignment.Left
MachineTitle.Parent = MachineFrame

local MachineStateLabel = Instance.new("TextLabel")
MachineStateLabel.Size = UDim2.new(0.5, -6, 0, 20)
MachineStateLabel.Position = UDim2.new(0, 6, 0, 22)
MachineStateLabel.BackgroundTransparency = 1
MachineStateLabel.Text = "⏸ IDLE"
MachineStateLabel.TextColor3 = Color3.fromRGB(150, 150, 170)
MachineStateLabel.TextSize = 14
MachineStateLabel.Font = Enum.Font.GothamBold
MachineStateLabel.TextXAlignment = Enum.TextXAlignment.Left
MachineStateLabel.Parent = MachineFrame

local MachineTimerLabel = Instance.new("TextLabel")
MachineTimerLabel.Size = UDim2.new(0.5, -6, 0, 20)
MachineTimerLabel.Position = UDim2.new(0.5, 0, 0, 22)
MachineTimerLabel.BackgroundTransparency = 1
MachineTimerLabel.Text = "00:00"
MachineTimerLabel.TextColor3 = Color3.fromRGB(180, 180, 200)
MachineTimerLabel.TextSize = 14
MachineTimerLabel.Font = Enum.Font.Code
MachineTimerLabel.TextXAlignment = Enum.TextXAlignment.Right
MachineTimerLabel.Parent = MachineFrame

local ProgressBg = Instance.new("Frame")
ProgressBg.Size = UDim2.new(1, -12, 0, 8)
ProgressBg.Position = UDim2.new(0, 6, 0, 50)
ProgressBg.BackgroundColor3 = Color3.fromRGB(40, 40, 55)
ProgressBg.BorderSizePixel = 0
ProgressBg.Parent = MachineFrame
Instance.new("UICorner", ProgressBg).CornerRadius = UDim.new(1, 0)

local ProgressFill = Instance.new("Frame")
ProgressFill.Size = UDim2.new(0, 0, 1, 0)
ProgressFill.BackgroundColor3 = Color3.fromRGB(120, 80, 200)
ProgressFill.BorderSizePixel = 0
ProgressFill.Parent = ProgressBg
Instance.new("UICorner", ProgressFill).CornerRadius = UDim.new(1, 0)

-- INFO
local InfoLabel = Instance.new("TextLabel")
InfoLabel.Size = UDim2.new(1, -20, 0, 50)
InfoLabel.Position = UDim2.new(0, 10, 0, 174)
InfoLabel.BackgroundColor3 = Color3.fromRGB(25, 25, 38)
InfoLabel.BorderSizePixel = 0
InfoLabel.Text = "Target Age: 50 | Skip: Diamond\nAuto Stop: ON (empty x3)"
InfoLabel.TextColor3 = Color3.fromRGB(180, 180, 220)
InfoLabel.TextSize = 10
InfoLabel.Font = Enum.Font.Code
InfoLabel.TextXAlignment = Enum.TextXAlignment.Left
InfoLabel.TextYAlignment = Enum.TextYAlignment.Top
InfoLabel.Parent = Frame
Instance.new("UICorner", InfoLabel).CornerRadius = UDim.new(0, 6)

local InfoPadding = Instance.new("UIPadding", InfoLabel)
InfoPadding.PaddingTop = UDim.new(0, 6)
InfoPadding.PaddingLeft = UDim.new(0, 10)

-- LOG
local LogLabel = Instance.new("TextLabel")
LogLabel.Size = UDim2.new(1, -20, 0, 60)
LogLabel.Position = UDim2.new(0, 10, 0, 230)
LogLabel.BackgroundColor3 = Color3.fromRGB(15, 15, 20)
LogLabel.BorderSizePixel = 0
LogLabel.Text = "[Log akan muncul di sini]"
LogLabel.TextColor3 = Color3.fromRGB(180, 200, 180)
LogLabel.TextSize = 9
LogLabel.Font = Enum.Font.Code
LogLabel.TextXAlignment = Enum.TextXAlignment.Left
LogLabel.TextYAlignment = Enum.TextYAlignment.Top
LogLabel.TextWrapped = true
LogLabel.Parent = Frame
Instance.new("UICorner", LogLabel).CornerRadius = UDim.new(0, 6)

local LogPadding = Instance.new("UIPadding", LogLabel)
LogPadding.PaddingTop = UDim.new(0, 4)
LogPadding.PaddingLeft = UDim.new(0, 6)

-- TOGGLE BUTTON
local ToggleBtn = Instance.new("TextButton")
ToggleBtn.Size = UDim2.new(1, -20, 0, 36)
ToggleBtn.Position = UDim2.new(0, 10, 1, -46)
ToggleBtn.BackgroundColor3 = Color3.fromRGB(60, 180, 60)
ToggleBtn.BorderSizePixel = 0
ToggleBtn.Text = "▶ START"
ToggleBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
ToggleBtn.TextSize = 14
ToggleBtn.Font = Enum.Font.GothamBold
ToggleBtn.Parent = Frame
Instance.new("UICorner", ToggleBtn).CornerRadius = UDim.new(0, 8)

-- LOG FUNCTION
local function log(msg)
    local time = os.date("%H:%M:%S")
    local newText = LogLabel.Text .. "\n[" .. time .. "] " .. msg
    local lines = {}
    for line in newText:gmatch("[^\n]+") do table.insert(lines, line) end
    while #lines > 4 do table.remove(lines, 1) end
    LogLabel.Text = table.concat(lines, "\n")
    print("[AutoMut] " .. msg)
end

-- ⭐ GLOBAL STOP FUNCTION
function _G.__autoMutStop()
    CONFIG.AUTO_FEED = false
    emptyCount = 0
    
    if ToggleBtn then
        ToggleBtn.Text = "▶ START"
        ToggleBtn.BackgroundColor3 = Color3.fromRGB(60, 180, 60)
    end
    if StatusLabel then
        StatusLabel.Text = "Status: STOPPED (auto)\nEligible: 0 pet"
        StatusLabel.TextColor3 = Color3.fromRGB(255, 180, 100)
    end
    
    print("[AutoMut] 🛑 Auto stop dipicu")
end

-- TOGGLE HANDLER
ToggleBtn.MouseButton1Click:Connect(function()
    CONFIG.AUTO_FEED = not CONFIG.AUTO_FEED
    
    if CONFIG.AUTO_FEED then
        emptyCount = 0
        ToggleBtn.Text = "⏹ STOP"
        ToggleBtn.BackgroundColor3 = Color3.fromRGB(200, 50, 50)
        StatusLabel.Text = "Status: RUNNING\nEligible: - pet"
        StatusLabel.TextColor3 = Color3.fromRGB(100, 255, 100)
        log("🚀 START")
        task.spawn(autoFeedLoop)
    else
        emptyCount = 0
        ToggleBtn.Text = "▶ START"
        ToggleBtn.BackgroundColor3 = Color3.fromRGB(60, 180, 60)
        StatusLabel.Text = "Status: OFF\nEligible: - pet"
        StatusLabel.TextColor3 = Color3.fromRGB(255, 100, 100)
        log("⏹ STOP (manual)")
    end
end)

-- TIMER UPDATE
task.spawn(function()
    while ScreenGui.Parent do
        local state, remaining, progress = getMachineState()
        
        if state == "Idle" then
            MachineStateLabel.Text = "⏸ IDLE"
            MachineStateLabel.TextColor3 = Color3.fromRGB(150, 150, 170)
            MachineTimerLabel.Text = "00:00"
            MachineTimerLabel.TextColor3 = Color3.fromRGB(120, 120, 140)
            ProgressFill.Size = UDim2.new(0, 0, 1, 0)
            ProgressFill.BackgroundColor3 = Color3.fromRGB(80, 80, 100)
            MachineStroke.Color = Color3.fromRGB(80, 80, 100)
        elseif state == "InProgress" then
            MachineStateLabel.Text = "⚙️ MUTATING"
            MachineStateLabel.TextColor3 = Color3.fromRGB(255, 200, 80)
            MachineTimerLabel.Text = formatTime(remaining)
            MachineTimerLabel.TextColor3 = Color3.fromRGB(255, 220, 100)
            ProgressFill.Size = UDim2.new(progress, 0, 1, 0)
            ProgressFill.BackgroundColor3 = Color3.fromRGB(255, 180, 60)
            MachineStroke.Color = Color3.fromRGB(255, 180, 60)
        elseif state == "Ready" then
            MachineStateLabel.Text = "✅ READY!"
            MachineStateLabel.TextColor3 = Color3.fromRGB(120, 255, 120)
            MachineTimerLabel.Text = "00:00"
            MachineTimerLabel.TextColor3 = Color3.fromRGB(120, 255, 120)
            ProgressFill.Size = UDim2.new(1, 0, 1, 0)
            ProgressFill.BackgroundColor3 = Color3.fromRGB(120, 255, 120)
            MachineStroke.Color = Color3.fromRGB(120, 255, 120)
        else
            MachineStateLabel.Text = "❓ UNKNOWN"
            MachineStateLabel.TextColor3 = Color3.fromRGB(200, 100, 100)
            MachineTimerLabel.Text = "--:--"
        end
        
        task.wait(0.5)
    end
end)

-- INFO UPDATE
task.spawn(function()
    while ScreenGui.Parent do
        local eligible = findEligiblePets()
        StatusLabel.Text = string.format(
            "Status: %s\nEligible: %d pet",
            CONFIG.AUTO_FEED and "RUNNING" or "OFF",
            #eligible
        )
        task.wait(3)
    end
end)

-- TOGGLE KEY
UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.KeyCode == Enum.KeyCode.RightShift then
        ScreenGui.Enabled = not ScreenGui.Enabled
    end
end)

-- PRINT
log("✅ GUI loaded (v4 + Auto Stop)")
log("🛑 Auto stop: ON (empty x" .. CONFIG.EMPTY_COUNT_THRESHOLD .. ")")
print("[AutoMut] ✅ Loaded! Tekan RightShift untuk toggle GUI.")
