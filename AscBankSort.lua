-- AscBankSort.lua
-- Adds a Sort button to Bank and Guild Bank (Ascension-compatible).
-- Bank: uses SortBags / SortBankBags when available.
-- Guild Bank: custom swap-based sorter (since SortGuildBankItems may not exist).

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
-- Guild bank sorter (compact + deterministic)
-- ==========================================

-- Trade Goods "profession group" order.
-- We map Blizzard Trade Goods subclasses into these buckets.
-- Edit this order to taste.
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
for i, name in ipairs(TG_GROUP_ORDER) do
    TG_GROUP_INDEX[name] = i
end

-- Map Trade Goods subclass -> group.
-- NOTE: subclass strings are locale-dependent; you're enUS so these should match.
local TG_SUBCLASS_TO_GROUP = {
    ["Enchanting"] = "Enchanting",
    ["Gems"] = "Jewelcrafting",

    ["Elemental"] = "Alchemy",        -- often shared, but tends to fit here
    ["Herb"] = "Herbalism",

    ["Metal & Stone"] = "Blacksmithing/Mining",
    ["Parts"] = "Engineering",
    ["Devices"] = "Engineering",

    ["Leather"] = "Leatherworking/Skinning",
    ["Cloth"] = "Tailoring",

    ["Meat"] = "Cooking",

    -- fallback-ish subclasses some servers use:
    ["Other"] = "Other Trade Goods",
    ["Junk"] = "Other Trade Goods",
}

local sorter = {
    running = false,
    queue = {},
    tab = nil,
    t = 0,

    pass = 0,
    maxPass = 10,         -- how many times to retry before stopping
	
    repassPending = false,
    repassDelay = 0,
}


local function GetItemNameSafe(link)
    if not link then return nil end
    local name = GetItemInfo(link) -- can be nil if not cached
    return name
end

local function GetItemString(link)
    if not link then return nil end
    -- Pull the "item:..." payload (stable-ish)
    local itemString = link:match("|H(item:[%-:%d]+)|h")
    return itemString or link
end

local function GetSlotState(tab, slot)
    local link = GetGuildBankItemLink(tab, slot)
    if not link then
        return nil
    end
    local _, count, locked = GetGuildBankItemInfo(tab, slot)
    local name = GetItemNameSafe(link) or GetItemString(link)

    local _, _, quality, _, _, class, subclass = GetItemInfo(link)
    quality = quality or 0
    class = class or ""
    subclass = subclass or ""

    return {
        link = link,
        itemString = GetItemString(link),
        name = name,
        count = count or 1,
        locked = locked and true or false,

        quality = quality,
        class = class,
        subclass = subclass,
    }
end

local function ClassifyItem(state)
    -- Returns:
    -- isTradeGood, groupIndex, groupName, quality, subclass, name
    if not state or not state.link then
        return false, 999, "Other", 0, "", ""
    end

    local isTrade = (state.class == "Trade Goods")
    local groupName = "Other"
    local groupIndex = 999

    if isTrade then
        groupName = TG_SUBCLASS_TO_GROUP[state.subclass] or "Other Trade Goods"
        groupIndex = TG_GROUP_INDEX[groupName] or 999
    end

    return isTrade, groupIndex, groupName, (state.quality or 0), (state.subclass or ""), (state.name or "")
end

local function ItemLess(a, b)
    local aTrade, aGroupIdx, _, aQ, aSub, aName = ClassifyItem(a)
    local bTrade, bGroupIdx, _, bQ, bSub, bName = ClassifyItem(b)

    -- 1) Trade goods first
    if aTrade ~= bTrade then
        return aTrade and true or false
    end

    -- 2) If trade goods: by profession-group
    if aTrade and bTrade and aGroupIdx ~= bGroupIdx then
        return aGroupIdx < bGroupIdx
    end

    -- 3) Within same trade group (or both non-trade): subclass as a consistent secondary
    if aSub ~= bSub then
        return aSub < bSub
    end

    -- 4) Quality (higher first)
    if aQ ~= bQ then
        return aQ > bQ
    end

    -- 5) Name A->Z
    if aName ~= bName then
        return aName < bName
    end

    -- 6) Larger stacks first
    if (a.count or 1) ~= (b.count or 1) then
        return (a.count or 1) > (b.count or 1)
    end

    -- Final tiebreakers
    if a.itemString ~= b.itemString then
        return a.itemString < b.itemString
    end
    return (a.slot or 0) < (b.slot or 0)
end

local function QueueSwap(tab, fromSlot, toSlot)
    if fromSlot == toSlot then return end
    sorter.queue[#sorter.queue + 1] = { tab = tab, from = fromSlot, to = toSlot }
end

local function ExecuteOneSwap(job)
    sorter.didSwapThisPass = true
    PickupGuildBankItem(job.tab, job.from)
    PickupGuildBankItem(job.tab, job.to)
end


local function BuildLayout(tab)
    -- Returns:
    --   cur[slot] = key or nil
    --   emptySlots = { ... }
    --   slotsByKey[key] = {slot1, slot2, ...}
    local cur = {}
    local emptySlots = {}
    local slotsByKey = {}

    local function makeKey(state)
        -- Stronger than link#count: itemString#count
        return (state.itemString or "") .. "#" .. tostring(state.count or 1)
    end

    for slot = 1, 98 do
        local state = GetSlotState(tab, slot)
        if not state then
            cur[slot] = nil
            emptySlots[#emptySlots + 1] = slot
        else
            local key = makeKey(state)
            cur[slot] = key
            slotsByKey[key] = slotsByKey[key] or {}
            table.insert(slotsByKey[key], slot)
        end
    end

    return cur, emptySlots, slotsByKey
end

local function StartGuildBankSortCurrentTab()
    if sorter.running then
        Print("Sort already running.", 1, 1, 0)
        return
    end
	    sorter.pass = (sorter.pass or 0) + 1
    if sorter.maxPass and sorter.pass > sorter.maxPass then
        Print("Sort stopped (max passes reached).", 1, 0.6, 0.2)
        return
    end
    sorter.didSwapThisPass = false

    if not GuildBankFrame or not GuildBankFrame:IsShown() then
        Print("Open the Guild Bank first.", 1, 0.2, 0.2)
        return
    end

    local tab = (GetCurrentGuildBankTab and GetCurrentGuildBankTab()) or nil
    if not tab or tab < 1 then
        Print("Could not detect current guild bank tab.", 1, 0.2, 0.2)
        return
    end

    -- Snapshot all items
    local items = {}
    for slot = 1, 98 do
        local state = GetSlotState(tab, slot)
        if state then
            state.slot = slot
            items[#items + 1] = state
        end
    end

    if #items == 0 then
        Print("This tab is empty.", 1, 1, 0)
        return
    end

    table.sort(items, ItemLess)

    -- Build desired keys: items first (compacted), then empties
    local desired = {}
    local function makeKey(state)
        return (state.itemString or "") .. "#" .. tostring(state.count or 1)
    end
    for i = 1, #items do
        desired[i] = makeKey(items[i])
    end
    for i = #items + 1, 98 do
        desired[i] = nil
    end

    -- Current layout maps
    local curKeyBySlot, emptySlots, slotsByKey = BuildLayout(tab)

    -- Helper to pop a slot that contains a given key
    local function popSlotForKey(key)
        local list = slotsByKey[key]
        if not list or #list == 0 then return nil end
        local s = list[1]
        table.remove(list, 1)
        return s
    end

    -- Helper to find an empty slot AFTER a given index
    local function findEmptyAfter(idx)
        for i = 1, #emptySlots do
            local s = emptySlots[i]
            if s > idx then
                table.remove(emptySlots, i)
                return s
            end
        end
        return nil
    end

    sorter.queue = {}

    for dest = 1, 98 do
        local want = desired[dest]
        local have = curKeyBySlot[dest]

        if want == have then
            -- already correct (including nil/nil)
        elseif want == nil then
            -- We want empty here. If there's an item here, swap it with an empty slot later.
            if have ~= nil then
                local emptyLater = findEmptyAfter(dest)
                if emptyLater then
                    QueueSwap(tab, dest, emptyLater)

                    -- Update maps as-if swapped
                    curKeyBySlot[emptyLater] = have
                    curKeyBySlot[dest] = nil

                    -- moved key to emptyLater; track it
                    slotsByKey[have] = slotsByKey[have] or {}
                    table.insert(slotsByKey[have], emptyLater)
                end
            end
        else
            -- We want a specific item key here.
            local from = popSlotForKey(want)
            if from and from ~= dest then
                QueueSwap(tab, from, dest)

                -- Update maps as-if swapped
                local destKey = curKeyBySlot[dest]
                curKeyBySlot[dest] = want
                curKeyBySlot[from] = destKey

                -- destKey moved to 'from'
                if destKey ~= nil then
                    slotsByKey[destKey] = slotsByKey[destKey] or {}
                    table.insert(slotsByKey[destKey], from)
                else
                    -- dest was empty, now empty moved to 'from'
                    emptySlots[#emptySlots + 1] = from
                end
            end
        end
    end

    if #sorter.queue == 0 then
        Print("Already sorted (or nothing to do).", 1, 1, 0)
        return
    end

    sorter.running = true
    sorter.tab = tab
    sorter.t = 0
    Print(("Sorting guild tab %d... (%d moves)"):format(tab, #sorter.queue), 1, 1, 0)
end

-- Throttled runner
local runner = runner or CreateFrame("Frame")
runner:SetScript("OnUpdate", function(_, elapsed)
    -- If we're between passes, count down then re-run.
    if not sorter.running and sorter.repassPending then
        sorter.repassDelay = (sorter.repassDelay or 0) - elapsed
        if sorter.repassDelay <= 0 then
            sorter.repassPending = false
            StartGuildBankSortCurrentTab()
        end
        return
    end

    if not sorter.running then return end

    sorter.t = sorter.t + elapsed
    if sorter.t < 0.12 then return end
    sorter.t = 0

        local job = table.remove(sorter.queue, 1)
        if not job then
        sorter.running = false

        if sorter.didSwapThisPass then
            sorter.repassPending = true
            sorter.repassDelay = 0.40
            Print(("Guild bank sort pass %d complete..."):format(sorter.pass or 1), 0.2, 1, 0.2)
        else
            -- No swaps happened, so we're truly done or blocked.
            sorter.repassPending = false
            Print("Guild bank sort complete.", 0.2, 1, 0.2)
        end
        return
    end



    ExecuteOneSwap(job)
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
			sorter.pass = 0
			sorter.repassPending = false
			sorter.repassDelay = 0
			StartGuildBankSortCurrentTab()
		end

    )
end

-- =========================
-- Event hooks + safe OnShow hooks
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
    elseif event == "ADDON_LOADED" and arg1 == "AscBankSort" then
        -- If frames already exist, HookScript them safely.
        if BankFrame and BankFrame.HookScript then
            BankFrame:HookScript("OnShow", CreateBankButton)
        end
        if GuildBankFrame and GuildBankFrame.HookScript then
            GuildBankFrame:HookScript("OnShow", CreateGuildBankButton)
        end
    end
end)

-- Also attempt to hook once at load time (won't error if frames not created yet)
if BankFrame and BankFrame.HookScript then
    BankFrame:HookScript("OnShow", CreateBankButton)
end
if GuildBankFrame and GuildBankFrame.HookScript then
    GuildBankFrame:HookScript("OnShow", CreateGuildBankButton)
end
