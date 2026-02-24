local api = require("api")
local michaelClientLib = require("buff_dementia/michael_client")

-- Try to load TTP's static buff list
local ok, staticBuffList = pcall(require, "TrackThatPlease/static_buff_list")
if not ok then staticBuffList = nil end

local buff_dementia = {
    name = "Buff Dementia",
    author = "Iridiscent",
    version = "2.0.0",
    desc = "Configurable buff bar"
}

-- Defaults
local DEFAULT_SETTINGS = {
    enabled = true,
    x = 300,
    y = 300,
    icon_size = 36,
    icon_spacing = 2,
    font_size = 11,
    buffs_per_row = 0,
    tracked_icons = {
        { icon_id = 7689, buff_ids = {7689, 7687}, name = "" },
    }
}

-- Bar state
local settings
local barWindow
local iconSlots = {}
local INACTIVE_ALPHA = 0.3
local updateTimer = 0
local UPDATE_INTERVAL = 1000
local activeBuffs = {}

-- Config state
local settingsWindow
local configGroups = {}
local currentGroupIndex = 1
local suppressNameChange = false
local allBuffs = {}
local ddsData = {}
local filteredBuffs = {}
local buffScrollList
local perRowEditBox
local searchEditBox
local groupDropdown
local groupNameEditBox
local showOnlyMissCB
local categoryDropdown
local filteredCountLabel
local pageSize = 50
local buffScrollListWidth = 605

-- Category filter
local CATEGORY_ALL = 1
local CATEGORY_SELECTED = 2
local categories = {"All buffs", "Selected buffs"}
local currentCategory = CATEGORY_ALL

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

local function FormatTime(timeLeft)
    if timeLeft > 5940000 then
        return string.format("%dh", math.floor(timeLeft / 3600000))
    elseif timeLeft > 60000 then
        return string.format("%dm", math.floor(timeLeft / 60000))
    elseif timeLeft >= 10000 then
        return string.format("%ds", math.floor(timeLeft / 1000))
    else
        return string.format("%.1f", timeLeft / 1000)
    end
end

local function GetBuffIconPath(buffId)
    local path = ddsData[buffId]
    if path then return "game/ui/icon/" .. path end
    return nil
end

local function DeepCopyGroups(source, asString)
    local copy = {}
    if not source then return copy end
    for _, entry in ipairs(source) do
        local rawId = tonumber(entry.icon_id) or 0
        local group = {
            icon_id = asString and string.format("%d", rawId) or rawId,
            buff_ids = {},
            name = entry.name or "",
            show_only_miss = entry.show_only_miss or false
        }
        if entry.buff_ids then
            for _, bid in ipairs(entry.buff_ids) do
                local rawBid = tonumber(bid) or 0
                table.insert(group.buff_ids, asString and string.format("%d", rawBid) or rawBid)
            end
        end
        table.insert(copy, group)
    end
    return copy
end

------------------------------------------------------------------------
-- Bar UI
------------------------------------------------------------------------

local function BuildBar()
    for i = 1, #iconSlots do
        if iconSlots[i].timeLabel then
            iconSlots[i].timeLabel:Show(false)
            api.Interface:Free(iconSlots[i].timeLabel)
        end
        if iconSlots[i].icon then
            iconSlots[i].icon:Show(false)
            api.Interface:Free(iconSlots[i].icon)
        end
    end
    iconSlots = {}

    local tracked = settings.tracked_icons
    if not tracked or #tracked == 0 then
        if barWindow then barWindow:Show(false) end
        return
    end

    local iconSize = settings.icon_size
    local spacing = settings.icon_spacing
    local count = #tracked
    local perRow = settings.buffs_per_row or 0
    if perRow <= 0 then perRow = count end

    for i = 1, count do
        local entry = tracked[i]

        local icon = CreateItemIconButton("btwIcon" .. i, barWindow)
        icon:Show(true)
        F_SLOT.ApplySlotSkin(icon, icon.back, SLOT_STYLE.BUFF)
        icon:SetExtent(iconSize, iconSize)
        icon:Clickable(false)

        local col = (i - 1) % perRow
        local row = math.floor((i - 1) / perRow)
        local offsetX = col * (iconSize + spacing)
        local offsetY = row * (iconSize + spacing)
        icon:AddAnchor("TOPLEFT", barWindow, offsetX, offsetY)

        local cachedPath = nil
        local numIconId = tonumber(entry.icon_id) or 0
        if numIconId > 0 then
            local tooltip = api.Ability:GetBuffTooltip(numIconId)
            if tooltip and tooltip.path then
                cachedPath = tooltip.path
                F_SLOT.SetIconBackGround(icon, cachedPath)
            end
        end

        icon:SetAlpha(INACTIVE_ALPHA)

        local timeLabel = barWindow:CreateChildWidget("label", "btwTime" .. i, 0, true)
        timeLabel:SetText("")
        timeLabel:AddAnchor("CENTER", icon, "CENTER", 0, 0)
        timeLabel.style:SetFontSize(settings.font_size)
        timeLabel.style:SetAlign(ALIGN.CENTER)
        timeLabel.style:SetShadow(true)
        timeLabel.style:SetOutline(true)
        timeLabel.style:SetColor(1, 1, 1, 1)
        timeLabel:Show(false)

        iconSlots[i] = { icon = icon, timeLabel = timeLabel, cachedPath = cachedPath }
    end

    local cols = math.min(count, perRow)
    local rows = math.ceil(count / perRow)
    local barWidth = iconSize * cols + spacing * (cols - 1)
    local barHeight = iconSize * rows + spacing * (rows - 1)
    barWindow:SetExtent(barWidth, barHeight)
    barWindow:Show(true)
end

------------------------------------------------------------------------
-- Per-frame update
------------------------------------------------------------------------

local function OnUpdate(dt)
    updateTimer = updateTimer + dt
    if updateTimer < UPDATE_INTERVAL then return end
    updateTimer = 0

    local tracked = settings.tracked_icons
    if not tracked or #tracked == 0 then return end

    for k in pairs(activeBuffs) do activeBuffs[k] = nil end
    local buffCount = api.Unit:UnitBuffCount("player") or 0
    for i = 1, buffCount do
        local buff = api.Unit:UnitBuff("player", i)
        if buff and buff.buff_id then
            local id = math.floor(tonumber(buff.buff_id) or 0)
            local t = buff.timeLeft or 0
            local existing = activeBuffs[id]
            if existing == nil then
                activeBuffs[id] = { timeLeft = t, path = buff.path }
            elseif t < existing.timeLeft then
                existing.timeLeft = t
                existing.path = buff.path
            end
        end
    end

    for i = 1, #tracked do
        local entry = tracked[i]
        local slot = iconSlots[i]
        if not slot then break end

        local lowestTime = nil
        local matchedPath = nil
        if entry.buff_ids then
            for _, bid in ipairs(entry.buff_ids) do
                local info = activeBuffs[tonumber(bid)]
                if info then
                    if lowestTime == nil or info.timeLeft < lowestTime then
                        lowestTime = info.timeLeft
                        matchedPath = info.path
                    end
                end
            end
        end

        if matchedPath and matchedPath ~= slot.cachedPath then
            slot.cachedPath = matchedPath
            F_SLOT.SetIconBackGround(slot.icon, matchedPath)
        end

        if entry.show_only_miss then
            if lowestTime then
                slot.icon:SetAlpha(0)
                slot.timeLabel:SetText("")
                slot.timeLabel:Show(false)
            else
                slot.icon:SetAlpha(INACTIVE_ALPHA)
                slot.timeLabel:SetText("")
                slot.timeLabel:Show(false)
            end
        else
            if lowestTime then
                slot.icon:SetAlpha(1)
                slot.timeLabel:SetAlpha(1)
                if lowestTime > 0 then
                    slot.timeLabel:SetText(FormatTime(lowestTime))
                    slot.timeLabel:Show(true)
                else
                    slot.timeLabel:SetText("")
                    slot.timeLabel:Show(false)
                end
            else
                slot.icon:SetAlpha(INACTIVE_ALPHA)
                slot.timeLabel:SetText("")
                slot.timeLabel:Show(false)
            end
        end
    end
end

------------------------------------------------------------------------
-- Config: buff data
------------------------------------------------------------------------

local function InitBuffData()
    allBuffs = {}
    if not staticBuffList then return end
    ddsData = staticBuffList.ddsData or {}
    for _, buff in ipairs(staticBuffList.ALL_BUFFS) do
        table.insert(allBuffs, {
            id = buff.id,
            name = buff.name,
            iconPath = GetBuffIconPath(buff.id)
        })
    end
    table.sort(allBuffs, function(a, b)
        return string.lower(a.name) < string.lower(b.name)
    end)
end

local function IsBuffInCurrentGroup(buffId)
    local group = configGroups[currentGroupIndex]
    if not group then return false end
    for _, bid in ipairs(group.buff_ids) do
        if bid == buffId then return true end
    end
    return false
end

local function IsBuffIconForCurrentGroup(buffId)
    local group = configGroups[currentGroupIndex]
    if not group then return false end
    return group.icon_id == buffId
end

local function ToggleBuffInCurrentGroup(buffId)
    local group = configGroups[currentGroupIndex]
    if not group then return end
    for i, bid in ipairs(group.buff_ids) do
        if bid == buffId then
            table.remove(group.buff_ids, i)
            if group.icon_id == buffId then
                group.icon_id = group.buff_ids[1] or 0
            end
            return
        end
    end
    table.insert(group.buff_ids, buffId)
    if not group.icon_id or group.icon_id == 0 then
        group.icon_id = buffId
    end
end

local function SetIconForCurrentGroup(buffId)
    local group = configGroups[currentGroupIndex]
    if not group then return end
    group.icon_id = buffId
    for _, bid in ipairs(group.buff_ids) do
        if bid == buffId then return end
    end
    table.insert(group.buff_ids, buffId)
end

local function SaveConfig()
    settings.tracked_icons = DeepCopyGroups(configGroups, true)
    if perRowEditBox then
        local val = tonumber(perRowEditBox:GetText()) or 0
        if val < 0 then val = 0 end
        settings.buffs_per_row = val
    end
    api.SaveSettings()
    BuildBar()
    updateTimer = UPDATE_INTERVAL -- force immediate buff check on next frame
end

local CommitChange

------------------------------------------------------------------------
-- Config: scroll list callbacks
------------------------------------------------------------------------

-- Forward declarations
local FillBuffList
local UpdateGroupDropdown
local CreateConfigWindow

local function DataSetFunc(subItem, data, setValue)
    if setValue then
        subItem.buffId = data.id

        local formattedText = string.format(
            "%s |cFFFFE4B5[%d]|r",
            data.name,
            data.id
        )
        subItem.textbox:SetText(formattedText)

        if data.iconPath then
            F_SLOT.SetIconBackGround(subItem.subItemIcon, data.iconPath)
        end

        -- Checkmark: tracked in current group?
        local isTracked = IsBuffInCurrentGroup(data.id)
        if isTracked then
            subItem.checkmarkIcon:SetCoords(852, 49, 15, 15)
        else
            subItem.checkmarkIcon:SetCoords(832, 49, 15, 15)
        end
        subItem.checkmarkIcon:Show(true)

        -- Gold border: is this the display icon?
        local isIcon = IsBuffIconForCurrentGroup(data.id)
        subItem.iconBorder:Show(isIcon)
    end
end

local function LayoutSetFunc(frame, rowIndex, colIndex, subItem)
    local rowHeight = 45
    subItem:SetExtent(buffScrollListWidth - 50, rowHeight)

    -- Row background
    local background = subItem:CreateImageDrawable(TEXTURE_PATH.HUD, "background")
    background:SetCoords(453, 145, 230, 23)
    background:AddAnchor("TOPLEFT", subItem, 0, 2)
    background:AddAnchor("BOTTOMRIGHT", subItem, 0, -2)

    -- Buff icon button
    local iconSize = 28
    local subItemIcon = CreateItemIconButton("btwCfgIcon", subItem)
    subItemIcon:SetExtent(iconSize, iconSize)
    subItemIcon:Show(true)
    F_SLOT.ApplySlotSkin(subItemIcon, subItemIcon.back, SLOT_STYLE.BUFF)
    subItemIcon:AddAnchor("LEFT", subItem, 5, 0)
    subItem.subItemIcon = subItemIcon

    -- Icon marker (small gold indicator at top-left corner when buff is the display icon)
    local iconMarker = subItem:CreateChildWidget("label", "iconMarker", 0, true)
    iconMarker:SetExtent(14, 14)
    iconMarker:AddAnchor("BOTTOMRIGHT", subItemIcon, "BOTTOMRIGHT", 2, 2)
    iconMarker.style:SetFontSize(12)
    iconMarker.style:SetColor(1, 0.84, 0, 1)
    iconMarker.style:SetShadow(true)
    iconMarker.style:SetOutline(true)
    iconMarker.style:SetAlign(ALIGN.CENTER)
    iconMarker:SetText("IC")
    iconMarker:Show(false)
    subItem.iconBorder = iconMarker

    -- Click icon to set as display icon for current group
    function subItemIcon:OnClick()
        local buffId = subItem.buffId
        if buffId and configGroups[currentGroupIndex] then
            SetIconForCurrentGroup(buffId)
            CommitChange()
        end
    end
    subItemIcon:SetHandler("OnClick", subItemIcon.OnClick)

    -- Name textbox
    local nameTextbox = subItem:CreateChildWidget("textbox", "nameTextbox", 0, true)
    nameTextbox:AddAnchor("LEFT", subItemIcon, "RIGHT", 5, 0)
    nameTextbox:AddAnchor("RIGHT", subItem, -35, 0)
    nameTextbox.style:SetAlign(ALIGN.LEFT)
    nameTextbox.style:SetFontSize(13)
    ApplyTextColor(nameTextbox, FONT_COLOR.WHITE)
    subItem.textbox = nameTextbox

    -- Checkmark indicator (right side)
    local checkmarkIcon = subItem:CreateImageDrawable(TEXTURE_PATH.HUD, "overlay")
    checkmarkIcon:SetExtent(18, 18)
    checkmarkIcon:AddAnchor("RIGHT", subItem, -8, 0)
    checkmarkIcon:Show(true)
    subItem.checkmarkIcon = checkmarkIcon

    -- Click overlay for toggling buff in current group
    local clickOverlay = subItem:CreateChildWidget("button", "clickOverlay", 0, true)
    clickOverlay:AddAnchor("TOPLEFT", subItem, 40, 0)
    clickOverlay:AddAnchor("BOTTOMRIGHT", subItem, 0, 0)

    function clickOverlay:OnClick()
        local buffId = subItem.buffId
        if buffId and configGroups[currentGroupIndex] then
            ToggleBuffInCurrentGroup(buffId)
            CommitChange()
        end
    end
    clickOverlay:SetHandler("OnClick", clickOverlay.OnClick)
end

------------------------------------------------------------------------
-- Config: fill list with filtered buffs
------------------------------------------------------------------------

FillBuffList = function(pageIndex, searchText)
    if not buffScrollList then return end
    local startingIndex = ((pageIndex - 1) * pageSize) + 1
    buffScrollList:DeleteAllDatas()

    filteredBuffs = {}
    searchText = searchText or ""

    local group = configGroups[currentGroupIndex]

    if currentCategory == CATEGORY_SELECTED then
        -- Show only buffs selected in the current group
        if group and group.buff_ids then
            for _, bid in ipairs(group.buff_ids) do
                -- Find buff info from allBuffs
                for _, buff in ipairs(allBuffs) do
                    if buff.id == bid then
                        if searchText == "" or string.find(buff.name:lower(), searchText:lower(), 1, true) then
                            table.insert(filteredBuffs, {
                                id = buff.id,
                                name = buff.name,
                                iconPath = buff.iconPath,
                                relevanceScore = 0
                            })
                        end
                        break
                    end
                end
            end
        end
    else
        -- Show all buffs
        for _, buff in ipairs(allBuffs) do
            if searchText == "" or string.find(buff.name:lower(), searchText:lower(), 1, true) then
                local relevanceScore = 0
                if searchText ~= "" then
                    local lowerName = buff.name:lower()
                    local lowerSearch = searchText:lower()
                    if lowerName == lowerSearch then
                        relevanceScore = 1000
                    elseif lowerName:sub(1, #lowerSearch) == lowerSearch then
                        relevanceScore = 500
                    else
                        relevanceScore = 100 + (100 - string.len(buff.name))
                    end
                end
                table.insert(filteredBuffs, {
                    id = buff.id,
                    name = buff.name,
                    iconPath = buff.iconPath,
                    relevanceScore = relevanceScore
                })
            end
        end
    end

    -- Pagination
    local maxPages = math.ceil(#filteredBuffs / pageSize)
    if maxPages < 1 then maxPages = 1 end
    buffScrollList:SetPageByItemCount(#filteredBuffs, pageSize)
    buffScrollList.pageControl:SetPageCount(maxPages)
    if buffScrollList.curPageIdx and buffScrollList.curPageIdx > maxPages then
        buffScrollList:SetCurrentPage(maxPages)
    end

    -- Count label
    if filteredCountLabel then
        if #filteredBuffs > pageSize then
            local startIdx = ((pageIndex - 1) * pageSize) + 1
            local endIdx = math.min(startIdx + pageSize - 1, #filteredBuffs)
            filteredCountLabel:SetText(string.format("Displayed: %d-%d / %d", startIdx, endIdx, #filteredBuffs))
        else
            filteredCountLabel:SetText(string.format("Displayed: %d", #filteredBuffs))
        end
    end

    -- Sort by relevance then alphabetically
    if #filteredBuffs <= 400 and #filteredBuffs > 0 then
        table.sort(filteredBuffs, function(a, b)
            if a.relevanceScore ~= b.relevanceScore then
                return a.relevanceScore > b.relevanceScore
            else
                return string.lower(a.name) < string.lower(b.name)
            end
        end)
    end

    -- Populate scroll list page
    local count = 1
    for i = startingIndex, math.min(startingIndex + pageSize - 1, #filteredBuffs) do
        local buff = filteredBuffs[i]
        if buff then
            buffScrollList:InsertData(count, 1, buff, false)
            count = count + 1
        end
    end
end

------------------------------------------------------------------------
-- Config: group dropdown
------------------------------------------------------------------------

UpdateGroupDropdown = function()
    if not groupDropdown then return end
    local items = {}
    for i = 1, #configGroups do
        local group = configGroups[i]
        local buffCount = group.buff_ids and #group.buff_ids or 0
        local groupName = "Group " .. i
        if group.name and group.name ~= "" then
            groupName = group.name
        elseif group.icon_id and group.icon_id > 0 then
            for _, buff in ipairs(allBuffs) do
                if buff.id == group.icon_id then
                    groupName = buff.name
                    break
                end
            end
        end
        table.insert(items, string.format("%s (%d)", groupName, buffCount))
    end
    if #items == 0 then
        table.insert(items, "(no groups)")
    end
    groupDropdown.dropdownItem = items
    if currentGroupIndex > #configGroups then
        currentGroupIndex = #configGroups
    end
    if currentGroupIndex < 1 then currentGroupIndex = 1 end
    groupDropdown:Select(math.max(currentGroupIndex, 1))
end

CommitChange = function()
    SaveConfig()
    UpdateGroupDropdown()
    FillBuffList(buffScrollList and buffScrollList.curPageIdx or 1, searchEditBox and searchEditBox:GetText() or "")
end

------------------------------------------------------------------------
-- Config: open window (refresh from saved settings)
------------------------------------------------------------------------

local function OpenConfigWindow()
    if not settingsWindow then
        CreateConfigWindow()
    end
    configGroups = DeepCopyGroups(settings.tracked_icons)
    currentGroupIndex = 1
    currentCategory = CATEGORY_ALL
    UpdateGroupDropdown()
    if categoryDropdown then categoryDropdown:Select(CATEGORY_ALL) end
    if searchEditBox then searchEditBox:SetText("") end
    if groupNameEditBox then
        suppressNameChange = true
        local group = configGroups[currentGroupIndex]
        groupNameEditBox:SetText(group and group.name or "")
        suppressNameChange = false
    end
    if perRowEditBox then perRowEditBox:SetText(tostring(settings.buffs_per_row or 0)) end
    if showOnlyMissCB then
        local group = configGroups[currentGroupIndex]
        showOnlyMissCB:SetChecked(group and group.show_only_miss or false)
    end
    FillBuffList(1, "")
    settingsWindow:Show(true)
end

------------------------------------------------------------------------
-- Config: create the settings window
------------------------------------------------------------------------

CreateConfigWindow = function()
    settingsWindow = api.Interface:CreateWindow("btwSettingsWindow", "Buff Dementia Settings", 0, 0)
    settingsWindow:AddAnchor("CENTER", "UIParent", 0, 0)
    settingsWindow:SetExtent(680, 680)
    settingsWindow:Show(false)

    local leftPad = 40
    local rowY = 50

    -- Group label
    local groupLabel = settingsWindow:CreateChildWidget("label", "btwGroupLabel", 0, true)
    groupLabel:AddAnchor("TOPLEFT", settingsWindow, leftPad, rowY)
    groupLabel:SetExtent(50, 20)
    groupLabel:SetText("Icon:")
    groupLabel.style:SetFontSize(12)
    ApplyTextColor(groupLabel, FONT_COLOR.DARK_GRAY)

    -- Group dropdown
    groupDropdown = api.Interface:CreateComboBox(settingsWindow)
    groupDropdown:AddAnchor("LEFT", groupLabel, "RIGHT", 8, 0)
    groupDropdown:SetWidth(200)
    groupDropdown:SetHeight(28)
    groupDropdown.dropdownItem = {"(no groups)"}
    groupDropdown:Select(1)

    function groupDropdown:SelectedProc()
        local idx = self:GetSelectedIndex()
        if idx and idx >= 1 and idx <= #configGroups then
            currentGroupIndex = idx
            if groupNameEditBox then
                suppressNameChange = true
                groupNameEditBox:SetText(configGroups[idx].name or "")
                suppressNameChange = false
            end
            if showOnlyMissCB then
                showOnlyMissCB:SetChecked(configGroups[idx].show_only_miss or false)
            end
            FillBuffList(1, searchEditBox:GetText())
        end
    end

    -- New Group button
    local newBtn = settingsWindow:CreateChildWidget("button", "btwNewGroupBtn", 0, true)
    api.Interface:ApplyButtonSkin(newBtn, BUTTON_BASIC.DEFAULT)
    newBtn:SetExtent(60, 26)
    newBtn:SetText("New")
    newBtn:AddAnchor("LEFT", groupDropdown, "RIGHT", 12, 0)
    function newBtn:OnClick()
        table.insert(configGroups, { icon_id = 0, buff_ids = {}, name = "", show_only_miss = false })
        currentGroupIndex = #configGroups
        if groupNameEditBox then
            suppressNameChange = true
            groupNameEditBox:SetText("")
            suppressNameChange = false
        end
        CommitChange()
    end
    newBtn:SetHandler("OnClick", newBtn.OnClick)

    -- Delete Group button
    local delBtn = settingsWindow:CreateChildWidget("button", "btwDelGroupBtn", 0, true)
    api.Interface:ApplyButtonSkin(delBtn, BUTTON_BASIC.DEFAULT)
    delBtn:SetExtent(60, 26)
    delBtn:SetText("Delete")
    delBtn:AddAnchor("LEFT", newBtn, "RIGHT", 8, 0)
    function delBtn:OnClick()
        if #configGroups > 0 then
            table.remove(configGroups, currentGroupIndex)
            if currentGroupIndex > #configGroups then
                currentGroupIndex = #configGroups
            end
            if currentGroupIndex < 1 then currentGroupIndex = 1 end
            if groupNameEditBox then
                suppressNameChange = true
                local group = configGroups[currentGroupIndex]
                groupNameEditBox:SetText(group and group.name or "")
                suppressNameChange = false
            end
            CommitChange()
        end
    end
    delBtn:SetHandler("OnClick", delBtn.OnClick)

    -- Move Up button
    local upBtn = settingsWindow:CreateChildWidget("button", "btwUpBtn", 0, true)
    api.Interface:ApplyButtonSkin(upBtn, BUTTON_BASIC.DEFAULT)
    upBtn:SetExtent(60, 26)
    upBtn:SetText("Up")
    upBtn:AddAnchor("LEFT", delBtn, "RIGHT", 8, 0)
    function upBtn:OnClick()
        if currentGroupIndex > 1 then
            local tmp = configGroups[currentGroupIndex]
            configGroups[currentGroupIndex] = configGroups[currentGroupIndex - 1]
            configGroups[currentGroupIndex - 1] = tmp
            currentGroupIndex = currentGroupIndex - 1
            CommitChange()
        end
    end
    upBtn:SetHandler("OnClick", upBtn.OnClick)

    -- Move Down button
    local downBtn = settingsWindow:CreateChildWidget("button", "btwDownBtn", 0, true)
    api.Interface:ApplyButtonSkin(downBtn, BUTTON_BASIC.DEFAULT)
    downBtn:SetExtent(60, 26)
    downBtn:SetText("Dn")
    downBtn:AddAnchor("LEFT", upBtn, "RIGHT", 8, 0)
    function downBtn:OnClick()
        if currentGroupIndex < #configGroups then
            local tmp = configGroups[currentGroupIndex]
            configGroups[currentGroupIndex] = configGroups[currentGroupIndex + 1]
            configGroups[currentGroupIndex + 1] = tmp
            currentGroupIndex = currentGroupIndex + 1
            CommitChange()
        end
    end
    downBtn:SetHandler("OnClick", downBtn.OnClick)

    rowY = rowY + 40

    -- Category filter label
    local categoryLabel = settingsWindow:CreateChildWidget("label", "btwCategoryLabel", 0, true)
    categoryLabel:AddAnchor("TOPLEFT", settingsWindow, leftPad, rowY)
    categoryLabel:SetExtent(50, 20)
    categoryLabel:SetText("Show:")
    categoryLabel.style:SetFontSize(12)
    ApplyTextColor(categoryLabel, FONT_COLOR.DARK_GRAY)

    -- Category dropdown
    categoryDropdown = api.Interface:CreateComboBox(settingsWindow)
    categoryDropdown:AddAnchor("LEFT", categoryLabel, "RIGHT", 8, 0)
    categoryDropdown:SetWidth(140)
    categoryDropdown:SetHeight(28)
    categoryDropdown.dropdownItem = categories
    categoryDropdown:Select(currentCategory)

    function categoryDropdown:SelectedProc()
        local idx = self:GetSelectedIndex()
        if idx and idx ~= currentCategory then
            currentCategory = idx
            searchEditBox:SetText("")
            FillBuffList(1, "")
        end
    end

    -- Search label
    local searchLabel = settingsWindow:CreateChildWidget("label", "btwSearchLabel", 0, true)
    searchLabel:AddAnchor("LEFT", categoryDropdown, "RIGHT", 20, 0)
    searchLabel:SetExtent(55, 20)
    searchLabel:SetText("Search:")
    searchLabel.style:SetFontSize(12)
    ApplyTextColor(searchLabel, FONT_COLOR.DARK_GRAY)

    -- Search edit box
    searchEditBox = W_CTRL.CreateEdit("btwSearchEdit", settingsWindow)
    searchEditBox:SetExtent(180, 28)
    searchEditBox:AddAnchor("LEFT", searchLabel, "RIGHT", 5, 0)
    searchEditBox.style:SetFontSize(FONT_SIZE.LARGE)
    searchEditBox.style:SetAlign(ALIGN.LEFT)

    function searchEditBox:OnTextChanged()
        local text = self:GetText()
        -- Auto-switch to "All buffs" when typing a search
        if text ~= "" and currentCategory == CATEGORY_SELECTED then
            currentCategory = CATEGORY_ALL
            categoryDropdown:Select(CATEGORY_ALL)
        end
        FillBuffList(1, text)
    end
    searchEditBox:SetHandler("OnTextChanged", searchEditBox.OnTextChanged)

    -- Per Row label
    local perRowLabel = settingsWindow:CreateChildWidget("label", "btwPerRowLabel", 0, true)
    perRowLabel:AddAnchor("LEFT", searchEditBox, "RIGHT", 20, 0)
    perRowLabel:SetExtent(55, 20)
    perRowLabel:SetText("Per Row:")
    perRowLabel.style:SetFontSize(12)
    ApplyTextColor(perRowLabel, FONT_COLOR.DARK_GRAY)

    -- Per Row edit box
    perRowEditBox = W_CTRL.CreateEdit("btwPerRowEdit", settingsWindow)
    perRowEditBox:SetExtent(50, 28)
    perRowEditBox:AddAnchor("LEFT", perRowLabel, "RIGHT", 5, 0)
    perRowEditBox.style:SetFontSize(FONT_SIZE.LARGE)
    perRowEditBox.style:SetAlign(ALIGN.CENTER)
    perRowEditBox:SetText(tostring(settings.buffs_per_row or 0))

    function perRowEditBox:OnTextChanged()
        SaveConfig()
    end
    perRowEditBox:SetHandler("OnTextChanged", perRowEditBox.OnTextChanged)

    rowY = rowY + 40

    -- Add by ID
    local addByIdLabel = settingsWindow:CreateChildWidget("label", "btwAddByIdLabel", 0, true)
    addByIdLabel:AddAnchor("TOPLEFT", settingsWindow, leftPad, rowY)
    addByIdLabel:SetExtent(65, 20)
    addByIdLabel:SetText("Add by ID:")
    addByIdLabel.style:SetFontSize(12)
    ApplyTextColor(addByIdLabel, FONT_COLOR.DARK_GRAY)

    local addByIdEditBox = W_CTRL.CreateEdit("btwAddByIdEdit", settingsWindow)
    addByIdEditBox:SetExtent(80, 28)
    addByIdEditBox:AddAnchor("LEFT", addByIdLabel, "RIGHT", 5, 0)
    addByIdEditBox.style:SetFontSize(FONT_SIZE.LARGE)
    addByIdEditBox.style:SetAlign(ALIGN.CENTER)

    local addByIdBtn = settingsWindow:CreateChildWidget("button", "btwAddByIdBtn", 0, true)
    api.Interface:ApplyButtonSkin(addByIdBtn, BUTTON_BASIC.DEFAULT)
    addByIdBtn:SetExtent(60, 26)
    addByIdBtn:SetText("Add")
    addByIdBtn:AddAnchor("LEFT", addByIdEditBox, "RIGHT", 8, 0)
    function addByIdBtn:OnClick()
        local text = addByIdEditBox:GetText()
        local buffId = tonumber(text)
        if not buffId or buffId <= 0 then return end
        buffId = math.floor(buffId)

        if #configGroups == 0 then
            table.insert(configGroups, { icon_id = 0, buff_ids = {}, show_only_miss = false })
            currentGroupIndex = 1
        end

        local group = configGroups[currentGroupIndex]
        for _, bid in ipairs(group.buff_ids) do
            if bid == buffId then
                addByIdEditBox:SetText("")
                return
            end
        end
        table.insert(group.buff_ids, buffId)
        if group.icon_id == 0 then
            group.icon_id = buffId
        end

        addByIdEditBox:SetText("")
        CommitChange()
    end
    addByIdBtn:SetHandler("OnClick", addByIdBtn.OnClick)

    -- Icon Name label + edit box
    local iconNameLabel = settingsWindow:CreateChildWidget("label", "btwIconNameLabel", 0, true)
    iconNameLabel:AddAnchor("LEFT", addByIdBtn, "RIGHT", 20, 0)
    iconNameLabel:SetExtent(70, 20)
    iconNameLabel:SetText("Icon Name:")
    iconNameLabel.style:SetFontSize(12)
    ApplyTextColor(iconNameLabel, FONT_COLOR.DARK_GRAY)

    groupNameEditBox = W_CTRL.CreateEdit("btwGroupNameEdit", settingsWindow)
    groupNameEditBox:SetExtent(180, 28)
    groupNameEditBox:AddAnchor("LEFT", iconNameLabel, "RIGHT", 5, 0)
    groupNameEditBox.style:SetFontSize(FONT_SIZE.LARGE)
    groupNameEditBox.style:SetAlign(ALIGN.LEFT)

    function groupNameEditBox:OnTextChanged()
        if suppressNameChange then return end
        local group = configGroups[currentGroupIndex]
        if not group then return end
        group.name = groupNameEditBox:GetText() or ""
        SaveConfig()
        UpdateGroupDropdown()
    end
    groupNameEditBox:SetHandler("OnTextChanged", groupNameEditBox.OnTextChanged)

    -- "Show only if miss" checkbox
    showOnlyMissCB = api.Interface:CreateWidget("checkbutton", "btwShowOnlyMissCB", settingsWindow)
    showOnlyMissCB:SetExtent(18, 17)
    showOnlyMissCB:AddAnchor("LEFT", groupNameEditBox, "RIGHT", 12, 0)

    local function SetCBBackground(state, x, y)
        local bg = showOnlyMissCB:CreateImageDrawable("ui/button/check_button.dds", "background")
        bg:SetExtent(18, 17)
        bg:AddAnchor("CENTER", showOnlyMissCB, 0, 0)
        bg:SetCoords(x, y, 18, 17)
        if state == "normal" then
            showOnlyMissCB:SetNormalBackground(bg)
        elseif state == "highlight" then
            showOnlyMissCB:SetHighlightBackground(bg)
        elseif state == "pushed" then
            showOnlyMissCB:SetPushedBackground(bg)
        elseif state == "disabled" then
            showOnlyMissCB:SetDisabledBackground(bg)
        elseif state == "checked" then
            showOnlyMissCB:SetCheckedBackground(bg)
        elseif state == "disabledChecked" then
            showOnlyMissCB:SetDisabledCheckedBackground(bg)
        end
    end
    SetCBBackground("normal", 0, 0)
    SetCBBackground("highlight", 0, 0)
    SetCBBackground("pushed", 0, 0)
    SetCBBackground("disabled", 0, 17)
    SetCBBackground("checked", 18, 0)
    SetCBBackground("disabledChecked", 18, 17)

    local group = configGroups[currentGroupIndex]
    showOnlyMissCB:SetChecked(group and group.show_only_miss or false)

    function showOnlyMissCB:OnCheckChanged()
        local g = configGroups[currentGroupIndex]
        if not g then return end
        g.show_only_miss = self:GetChecked()
        CommitChange()
    end
    showOnlyMissCB:SetHandler("OnCheckChanged", showOnlyMissCB.OnCheckChanged)

    local missLabel = settingsWindow:CreateChildWidget("label", "btwMissLabel", 0, true)
    missLabel:AddAnchor("LEFT", showOnlyMissCB, "RIGHT", 4, 0)
    missLabel:SetExtent(60, 20)
    missLabel:SetText("Show only when not buffed")
    missLabel.style:SetFontSize(11)
    ApplyTextColor(missLabel, FONT_COLOR.DARK_GRAY)

    rowY = rowY + 35

    -- Hint label (above list)
    local hintLabel = settingsWindow:CreateChildWidget("label", "btwHintLabel", 0, true)
    hintLabel:SetText("Click row = toggle buff  |  Click icon = set display icon")
    hintLabel.style:SetFontSize(11)
    ApplyTextColor(hintLabel, FONT_COLOR.DARK_GRAY)
    hintLabel.style:SetAlign(ALIGN.LEFT)
    hintLabel:AddAnchor("TOPLEFT", settingsWindow, leftPad, rowY)
    hintLabel:SetExtent(500, 16)

    rowY = rowY + 22

    -- Buff scroll list
    buffScrollList = W_CTRL.CreatePageScrollListCtrl("btwBuffScrollList", settingsWindow)
    buffScrollList:SetWidth(buffScrollListWidth)
    buffScrollList:AddAnchor("TOPLEFT", settingsWindow, leftPad, rowY)
    buffScrollList:AddAnchor("BOTTOMRIGHT", settingsWindow, -15, -40)
    buffScrollList:InsertColumn("", buffScrollListWidth - 5, 0, DataSetFunc, nil, nil, LayoutSetFunc)
    buffScrollList:InsertRows(10, false)
    buffScrollList:SetColumnHeight(1)

    function buffScrollList:OnPageChangedProc(curPageIdx)
        FillBuffList(curPageIdx, searchEditBox:GetText())
    end

    -- Count label (below list, left)
    filteredCountLabel = settingsWindow:CreateChildWidget("label", "btwCountLabel", 0, true)
    filteredCountLabel:SetText("Displayed: 0")
    ApplyTextColor(filteredCountLabel, FONT_COLOR.BLACK)
    filteredCountLabel.style:SetAlign(ALIGN.LEFT)
    filteredCountLabel.style:SetFontSize(11)
    filteredCountLabel:AddAnchor("BOTTOMLEFT", settingsWindow, leftPad, -12)

    -- Donate label (below list, right)
    local donateLabel = settingsWindow:CreateChildWidget("label", "btwDonateLabel", 0, true)
    donateLabel:SetText("Accepting donations in gold to mail nickname: Iridiscent")
    ApplyTextColor(donateLabel, FONT_COLOR.DARK_GRAY)
    donateLabel.style:SetAlign(ALIGN.RIGHT)
    donateLabel.style:SetFontSize(11)
    donateLabel:AddAnchor("BOTTOMRIGHT", settingsWindow, -10, -12)

    -- On hide: clear list data
    function settingsWindow:OnHide()
        if buffScrollList then
            buffScrollList:DeleteAllDatas()
        end
    end
    settingsWindow:SetHandler("OnHide", settingsWindow.OnHide)
end

------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------

local function OnLoad()
    settings = api.GetSettings("buff_dementia")
    for k, v in pairs(DEFAULT_SETTINGS) do
        if settings[k] == nil then
            settings[k] = v
        end
    end
    settings.tracked_icons = DeepCopyGroups(settings.tracked_icons, true)
    api.SaveSettings()

    -- Create bar window
    barWindow = api.Interface:CreateEmptyWindow("buffDementiaBar")
    barWindow:Show(true)
    barWindow:Clickable(true)
    barWindow:EnableDrag(true)
    barWindow:AddAnchor("TOPLEFT", "UIParent", settings.x, settings.y)

    function barWindow:OnDragStart()
        barWindow:StartMoving()
        api.Cursor:ClearCursor()
        api.Cursor:SetCursorImage(CURSOR_PATH.MOVE, 0, 0)
    end

    function barWindow:OnDragStop()
        barWindow:StopMovingOrSizing()
        api.Cursor:ClearCursor()
        local px, py = barWindow:GetOffset()
        settings.x = px
        settings.y = py
        api.SaveSettings()
    end

    barWindow:SetHandler("OnDragStart", barWindow.OnDragStart)
    barWindow:SetHandler("OnDragStop", barWindow.OnDragStop)

    BuildBar()

    -- Init config
    InitBuffData()

    -- Register ESC menu
    michaelClientLib:initializeMichaelClient()
    local configMenu = ADDON:GetContent(UIC.SYSTEM_CONFIG_FRAME)
    configMenu.michaelClient:AddAddon("Buff Dementia", function()
        OpenConfigWindow()
    end)

    api.On("UPDATE", OnUpdate)
    api.Log:Info("Buff Dementia loaded.")
end

local function OnUnload()
    settings.tracked_icons = DeepCopyGroups(settings.tracked_icons, true)
    api.On("UPDATE", function() end)

    -- Free bar icon widgets
    for i = 1, #iconSlots do
        if iconSlots[i].timeLabel then api.Interface:Free(iconSlots[i].timeLabel) end
        if iconSlots[i].icon then api.Interface:Free(iconSlots[i].icon) end
    end
    iconSlots = {}

    if barWindow then
        barWindow:Show(false)
        api.Interface:Free(barWindow)
        barWindow = nil
    end

    if settingsWindow then
        settingsWindow:Show(false)
        api.Interface:Free(settingsWindow)
        settingsWindow = nil
    end
    buffScrollList = nil
    searchEditBox = nil
    groupDropdown = nil
    groupNameEditBox = nil
    showOnlyMissCB = nil
    categoryDropdown = nil
    filteredCountLabel = nil
    configGroups = {}
    filteredBuffs = {}
    allBuffs = {}
    ddsData = {}
    activeBuffs = {}

    api.Log:Info("Buff Dementia unloaded.")
end

buff_dementia.OnLoad = OnLoad
buff_dementia.OnUnload = OnUnload
return buff_dementia
