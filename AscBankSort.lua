-- Ascension WoW (custom 3.3.5a)

local function Print(msg, r, g, b)
    if UIErrorsFrame then
        UIErrorsFrame:AddMessage(tostring(msg), r or 1, g or 1, b or 0)
    end
end

local function MakeButton(parent, name, text, width, height, point, rel, relPoint, x, y, onClick)
    local b = CreateFrame("Button", name, parent, "UIPanelButtonTemplate")
    b:SetText(text)
    b:SetWidth(width or 80)
    b:SetHeight(height or 22)
    b:SetPoint(point, rel, relPoint, x, y)
    b:SetScript("OnClick", onClick)
    b:Show()
    return b
end

local function CursorHasItem()
    local t = GetCursorInfo()
    return t ~= nil
end

local function ClearCursorSafe()
    if CursorHasItem() then
        ClearCursor()
    end
end

-- =========================
-- Bank button (built-in sort)
-- =========================
local bankBtnCreated = false
local function CreateBankButton()
    if bankBtnCreated then return end
    if not BankFrame then return end
    bankBtnCreated = true

    MakeButton(
        BankFrame,
        "AscBankSort_BankButton",
        "Sort",
        70, 22,
        "TOPRIGHT", BankFrame, "TOPRIGHT", -40, -32,
        function()
            local did = false
            if SortBags then SortBags(); did = true end
            if SortBankBags then SortBankBags(); did = true end
            if did then
                Print("Sorting bags/bank...", 1, 1, 0)
            else
                Print("SortBags/SortBankBags not available on this client.", 1, 0.2, 0.2)
            end
        end
    )
end

-- ==========================================
-- Guild bank sorter
-- ==========================================

local TG_GROUP_ORDER = {
    "Enchanting",
    "Jewelcrafting",
    "Alchemy",
    "Blacksmithing/Mining",
    "Engineering",
    "Leatherworking/Skinning",
    "Tailoring",
    "Herbalism",
    "Cooking",
    "Other Trade Goods",
}
local TG_GROUP_INDEX = {}
for i, name in ipairs(TG_GROUP_ORDER) do TG_GROUP_INDEX[name] = i end

local TG_SUBCLASS_TO_GROUP = {
    ["Enchanting"] = "Enchanting",
    ["Gems"] = "Jewelcrafting",

    ["Elemental"] = "Alchemy",
    ["Herb"] = "Herbalism",

    ["Metal & Stone"] = "Blacksmithing/Mining",
    ["Parts"] = "Engineering",
    ["Devices"] = "Engineering",

    ["Leather"] = "Leatherworking/Skinning",
    ["Cloth"] = "Tailoring",

    ["Meat"] = "Cooking",

    ["Other"] = "Other Trade Goods",
    ["Junk"] = "Other Trade Goods",
}

local itemInfoCache = {}
local function GetItemString(link)
    if not link then return nil end
    local itemString = link:match("|H(item:[%-:%d]+)|h")
    return itemString or link
end

local function GetCachedInfo(link)
    if not link then
        return { name = "", quality = 0, iLevel = 0, class = "", subclass = "", itemString = "" }
    end
    local itemString = GetItemString(link)
    local cached = itemInfoCache[itemString]
    if cached then return cached end

    local name, _, quality, iLevel, _, class, subclass = GetItemInfo(link)
    cached = {
        name = name or itemString,
        quality = quality or 0,
        iLevel = iLevel or 0,
        class = class or "",
        subclass = subclass or "",
        itemString = itemString,
    }
    itemInfoCache[itemString] = cached
    return cached
end

local function GetSlotState(tab, slot)
    local link = GetGuildBankItemLink(tab, slot)
    if not link then return nil end
    local _, count, locked = GetGuildBankItemInfo(tab, slot)
    local info = GetCachedInfo(link)
    return {
        slot = slot,
        link = link,
        itemString = info.itemString,
        name = info.name,
        count = count or 1,
        locked = locked and true or false,
        quality = info.quality,
        iLevel = info.iLevel,
        class = info.class,
        subclass = info.subclass,
    }
end

local function ClassifyItem(state)
    if not state then
        return false, 999, 0, 0, "", ""
    end

    local isTrade = (state.class == "Trade Goods")
    local groupIdx = 999

    if isTrade then
        local groupName = TG_SUBCLASS_TO_GROUP[state.subclass] or "Other Trade Goods"
        groupIdx = TG_GROUP_INDEX[groupName] or 999
    end

    return isTrade, groupIdx, (state.quality or 0), (state.iLevel or 0), (state.subclass or ""), (state.name or "")
end

local function ItemLess(a, b)
    local aTrade, aGroupIdx, aQ, aILvl, aSub, aName = ClassifyItem(a)
    local bTrade, bGroupIdx, bQ, bILvl, bSub, bName = ClassifyItem(b)

    if aTrade ~= bTrade then
        return aTrade and true or false
    end

    if aTrade and bTrade and aGroupIdx ~= bGroupIdx then
        return aGroupIdx < bGroupIdx
    end

    if aSub ~= bSub then return aSub < bSub end
    if aQ ~= bQ then return aQ > bQ end
    if aILvl ~= bILvl then return aILvl > bILvl end
    if aName ~= bName then return aName < bName end
    if a.itemString ~= b.itemString then return a.itemString < b.itemString end
    return (a.slot or 0) < (b.slot or 0)
end

local function ComputeLayoutHash(tab)
    local parts = {}
    for slot = 1, 98 do
        local st = GetSlotState(tab, slot)
        if st then
            parts[#parts + 1] = st.itemString .. ":" .. tostring(st.count or 1)
        else
            parts[#parts + 1] = "nil"
        end
    end
    return table.concat(parts, "|")
end

local function CanActOnSlot(tab, slot)
    if not slot then return true end
    local _, _, locked = GetGuildBankItemInfo(tab, slot)
    return not locked
end

local sorter = {
    running = false,
    tab = nil,

    buffer = nil,   
    bufferSlot = nil,  

    tick = 0,

    awaiting = false,
    tries = 0,
    maxTries = 10,

    -- speed tuning (reliability-first with adaptive backoff)
    baseTickInterval = 0.03,   -- start fast (lower = faster)
    maxTickInterval  = 0.50,   -- back off up to this if laggy
    tickInterval     = 0.03,

    baseConfirmDelay = 0.30,   -- wait after a move before verifying
    maxConfirmDelay  = 1.00,   -- back off up to this if laggy
    confirmDelay     = 0.18,
    confirmT = 0,

    lastSig = nil,
}

local function EnqueueMove(fromSlot, toSlot)
    if fromSlot == toSlot then return end
    sorter.queue[#sorter.queue + 1] = { from = fromSlot, to = toSlot }
end

local function SlotSig(tab, slot)
    local link = GetGuildBankItemLink(tab, slot)
    if not link then return "nil" end

    local itemString = link:match("|H(item:[%-:%d]+)|h") or link
    local _, count = GetGuildBankItemInfo(tab, slot)
    return itemString .. ":" .. tostring(count or 1)
end

local function PairSig(tab, a, b)
    return SlotSig(tab, a) .. "|" .. SlotSig(tab, b)
end

local function TripleSig(tab, a, b, c)
    return SlotSig(tab, a) .. "|" .. SlotSig(tab, b) .. "|" .. SlotSig(tab, c)
end

local function JobSig(tab, job)
    if sorter.bufferSlot then
        return TripleSig(tab, job.from, job.to, sorter.bufferSlot)
    else
        return PairSig(tab, job.from, job.to)
    end
end

local function EnqueueSwapViaBuffer(a, b, buffer)
    EnqueueMove(a, buffer)
    EnqueueMove(b, a)
    EnqueueMove(buffer, b)
end

local function ExecuteAtomicMove(tab, fromSlot, toSlot)
    PickupGuildBankItem(tab, fromSlot)
    PickupGuildBankItem(tab, toSlot)
    ClearCursorSafe()
end

local function FindRightmostEmpty(tab)
    for slot = 98, 1, -1 do
        if not GetGuildBankItemLink(tab, slot) then
            return slot
        end
    end
    return nil
end

local function BuildPlan(tab)
    local buffer = FindRightmostEmpty(tab)
    sorter.buffer = buffer

    local cur = {}
    local items = {}
    for slot = 1, 98 do
        local st = GetSlotState(tab, slot)
        if st and slot ~= buffer then
            cur[slot] = st.itemString
            items[#items + 1] = st
        else
            cur[slot] = nil
        end
    end

    if #items == 0 then
        return 0
    end

    table.sort(items, ItemLess)

    local desired = {}
    local k = #items
    for i = 1, k do desired[i] = items[i].itemString end
    for i = k + 1, 98 do desired[i] = nil end

    local moves = 0

    local function FindSource(dest, key)
        for s = dest + 1, 98 do
            if s ~= buffer and cur[s] == key then
                return s
            end
        end
        return nil
    end

    for dest = 1, k do
        if dest == buffer then
        end

        local want = desired[dest]
        local have = cur[dest]

        if have == want then
        else
            local src = FindSource(dest, want)
            if src then
                if buffer then
                    if have ~= nil then
                        EnqueueSwapViaBuffer(dest, src, buffer)
                        cur[src] = have
                        cur[dest] = want
                        moves = moves + 3
                    else
                        EnqueueMove(src, dest)
                        cur[dest] = want
                        cur[src] = nil
                        moves = moves + 1
                    end
                else
                    EnqueueMove(src, dest)
                    cur[dest] = want
                    cur[src] = have 
                    moves = moves + 1
                end
            end
        end
    end

    return moves
end

local function StartGuildBankSortCurrentTab()
    if sorter.running then
        Print("Sort already running.", 1, 1, 0)
        return
    end
    if not GuildBankFrame or not GuildBankFrame:IsShown() then
        Print("Open the Guild Bank first.", 1, 0.2, 0.2)
        return
    end

    local tab = (GetCurrentGuildBankTab and GetCurrentGuildBankTab()) or nil
    if not tab or tab < 1 then
        Print("Could not detect current guild bank tab.", 1, 0.2, 0.2)
        return
    end

    sorter.tab = tab
    sorter.queue = {}
    sorter.awaiting = false
    sorter.tries = 0
    sorter.confirmT = 0

    sorter.tickInterval = sorter.baseTickInterval
    sorter.confirmDelay = sorter.baseConfirmDelay

    local moves = BuildPlan(tab)

    sorter.bufferSlot = sorter.buffer

    sorter.lastSig = nil

    if moves == 0 or #sorter.queue == 0 then
        Print("Already sorted (or nothing to do).", 1, 1, 0)
        return
    end

    sorter.running = true
    sorter.tick = 0

    if sorter.buffer then
        Print(("Sorting guild tab %d... (%d moves, using empty buffer slot %d)"):format(tab, #sorter.queue, sorter.buffer), 1, 1, 0)
    else
        Print(("Sorting guild tab %d... (%d moves, NO empty slot available)"):format(tab, #sorter.queue), 1, 0.8, 0.2)
    end
end

local runner = runner or CreateFrame("Frame")
runner:SetScript("OnUpdate", function(_, elapsed)
    if not sorter.running then return end

    sorter.tick = sorter.tick + elapsed

    if sorter.awaiting then
        sorter.confirmT = sorter.confirmT + elapsed
        if sorter.confirmT < sorter.confirmDelay then
            return
        end

        sorter.confirmT = 0

        local job = sorter.queue[1]
        if not job then
            sorter.running = false
            Print("Guild bank sort complete.", 0.2, 1, 0.2)
            return
        end

        local curSig = JobSig(sorter.tab, job)

        if curSig ~= sorter.lastSig then
            sorter.lastSig = nil
            sorter.awaiting = false
            sorter.tries = 0
            table.remove(sorter.queue, 1)

            if sorter.tickInterval > sorter.baseTickInterval then
                sorter.tickInterval = math.max(sorter.baseTickInterval, sorter.tickInterval - 0.002)
            end
            if sorter.confirmDelay > sorter.baseConfirmDelay then
                sorter.confirmDelay = math.max(sorter.baseConfirmDelay, sorter.confirmDelay - 0.02)
            end
        else
            sorter.tries = sorter.tries + 1
            sorter.awaiting = false
            sorter.lastSig = nil

            sorter.tickInterval = math.min(sorter.maxTickInterval, sorter.tickInterval + 0.01)
            sorter.confirmDelay  = math.min(sorter.maxConfirmDelay, sorter.confirmDelay + 0.05)

            if sorter.tries >= sorter.maxTries then
                sorter.running = false
                Print("Sort stopped: move not applying (server/client refusing or too much lag). Try again.", 1, 0.6, 0.2)
            end
        end

        return
    end

    if sorter.tick < sorter.tickInterval then return end
    sorter.tick = 0

    local job = sorter.queue[1]
    if not job then
        sorter.running = false
        Print("Guild bank sort complete.", 0.2, 1, 0.2)
        return
    end

    ClearCursorSafe()

    if not CanActOnSlot(sorter.tab, job.from) or not CanActOnSlot(sorter.tab, job.to) then
        return
    end
    if sorter.bufferSlot and (not CanActOnSlot(sorter.tab, sorter.bufferSlot)) then
        return
    end

    sorter.lastSig = JobSig(sorter.tab, job)

    ExecuteAtomicMove(sorter.tab, job.from, job.to)
    sorter.awaiting = true
    sorter.confirmT = 0
end)

-- =========================
-- Guild bank button creation
-- =========================
local gbankBtnCreated = false
local function CreateGuildBankButton()
    if gbankBtnCreated then return end
    if not GuildBankFrame then return end
    gbankBtnCreated = true

    MakeButton(
        GuildBankFrame,
        "AscBankSort_GBankButton",
        "Sort",
        70, 22,
        "TOPRIGHT", GuildBankFrame, "TOPRIGHT", -60, -32,
        function()
            sorter.running = false
            sorter.queue = {}
            sorter.awaiting = false
            sorter.tries = 0
            sorter.buffer = nil
            sorter.bufferSlot = nil
            sorter.lastSig = nil

            sorter.tickInterval = sorter.baseTickInterval
            sorter.confirmDelay = sorter.baseConfirmDelay
            StartGuildBankSortCurrentTab()
        end
    )
end

-- =========================
-- Events / hooks
-- =========================
local f = CreateFrame("Frame")
f:RegisterEvent("BANKFRAME_OPENED")
f:RegisterEvent("GUILDBANKFRAME_OPENED")
f:RegisterEvent("ADDON_LOADED")

f:SetScript("OnEvent", function(_, event, arg1)
    if event == "BANKFRAME_OPENED" then
        CreateBankButton()
    elseif event == "GUILDBANKFRAME_OPENED" then
        CreateGuildBankButton()
    elseif event == "ADDON_LOADED" then
        if arg1 == "AscBankSort" then
            if BankFrame and BankFrame.HookScript then
                BankFrame:HookScript("OnShow", CreateBankButton)
            end
            if GuildBankFrame and GuildBankFrame.HookScript then
                GuildBankFrame:HookScript("OnShow", CreateGuildBankButton)
            end
        end
    end
end)

if BankFrame and BankFrame.HookScript then
    BankFrame:HookScript("OnShow", CreateBankButton)
end
if GuildBankFrame and GuildBankFrame.HookScript then
    GuildBankFrame:HookScript("OnShow", CreateGuildBankButton)
end
