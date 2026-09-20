-- Core.lua: saved-variable bootstrap, the on/off switch, the slash command,
-- profile management, and the Settings-API options panel. Skin.lua owns the
-- actual reskinning; this file only decides whether it should be applied
-- and with which settings.

WabaUI = WabaUI or {}
local WabaUI = WabaUI

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")

-- One darkness slider per skin category (WabaUI.DEFAULT_INTENSITY, set in
-- Skin.lua). "overall" is a master multiplier shown at the top level; the
-- rest are grouped into a "Windows" subcategory since they're all standard
-- panels, each wanting its own amount of darkening.
local TOP_LEVEL_INTENSITY = {
    { key = "overall", label = "Overall darkness", tooltip = "Master multiplier applied on top of every category below." },
    { key = "minimap", label = "Minimap darkness", tooltip = "The minimap border ring." },
    { key = "chat", label = "Chat darkness", tooltip = "Chat frame and tab backgrounds." },
    { key = "tracker", label = "Objective tracker darkness", tooltip = "The quest objective tracker." },
}

local ACTION_BAR_INTENSITY = {
    { key = "actionbars", label = "Action bar darkness", tooltip = "Action bars and the bag bar." },
}

local UNIT_FRAME_INTENSITY = {
    { key = "unitframe_player", label = "Player frame darkness",
      tooltip = "The player portrait border and the health/mana bar fills. Kept lower by default so the bars stay readable." },
    { key = "unitframe_target", label = "Target/focus frame darkness",
      tooltip = "The target and focus frames' portrait border and health/mana bar fills." },
    { key = "unitframe_pet", label = "Pet frame darkness",
      tooltip = "The pet frame's portrait border and health/mana bar fills." },
    { key = "unitframe_party", label = "Party/raid frame darkness",
      tooltip = "Each party/raid group's outer border/background. Individual members' health bars aren't touched." },
}

local WINDOW_INTENSITY = {
    { key = "character", label = "Character panel darkness", tooltip = "The character sheet and equipment slots." },
    { key = "bags", label = "Bags darkness", tooltip = "The combined bags window." },
    { key = "merchant", label = "Merchant darkness", tooltip = "The vendor window." },
    { key = "friends", label = "Friends panel darkness", tooltip = "The friends/social window." },
    { key = "questmap", label = "Quest map darkness", tooltip = "The world map and quest log." },
    { key = "spellbook", label = "Spellbook darkness", tooltip = "The spellbook window." },
    { key = "loot", label = "Loot window darkness", tooltip = "The window that opens when looting a corpse or container." },
    { key = "npctext", label = "NPC dialogue darkness",
      tooltip = "The gossip/quest window that opens when talking to an NPC. Its text brightens automatically as this is darkened, so it stays readable." },
    { key = "other", label = "Other panels darkness", tooltip = "Any other standard window not covered above." },
}

-- Every class's localized display name <-> file token, built once from the
-- client's own CLASS_SORT_ORDER/LOCALIZED_CLASS_NAMES_MALE globals (already
-- populated by core FrameXML before any addon loads) so this list is always
-- correct for whatever flavor/expansion the addon is actually running under
-- - never hand-maintained here. The display name doubles as that class
-- profile's identifier everywhere else in this file (dropdown value,
-- WabaUISettingsDB.activeProfile, etc).
WabaUI.classProfileClassFileByName = {}
for _, classFile in ipairs(CLASS_SORT_ORDER or {}) do
    local name = LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[classFile]
    if name then
        WabaUI.classProfileClassFileByName[name] = classFile
    end
end

function WabaUI:IsClassProfileName(name)
    return name ~= nil and WabaUI.classProfileClassFileByName[name] ~= nil
end

function WabaUI:IsCustomProfile(name)
    return name ~= nil and name ~= "Default" and not WabaUI:IsClassProfileName(name)
        and WabaUISettingsDB.profiles ~= nil and WabaUISettingsDB.profiles[name] ~= nil
end

function WabaUI:IsReservedProfileName(name)
    return name == "Default" or WabaUI:IsClassProfileName(name)
end

-- A profile only covers the visual theme - tint color(s), darkness sliders,
-- and the action-bar "use overall" checkboxes - never the master "enabled"
-- switch, which stays a single global regardless of which profile is active.
function WabaUI:SnapshotProfileData()
    return {
        tintColor = WabaUISettingsDB.tintColor,
        forceActionBarArt = WabaUISettingsDB.forceActionBarArt,
        intensity = CopyTable(WabaUISettingsDB.intensity),
        categoryTintColor = CopyTable(WabaUISettingsDB.categoryTintColor),
        actionBarUseOverall = CopyTable(WabaUISettingsDB.actionBarUseOverall),
    }
end

-- Class profiles are never stored - they're rebuilt from the class's own
-- RAID_CLASS_COLORS entry every time they're selected, which is what makes
-- them impossible to "manually change": there's nothing persisted to edit,
-- selecting the profile again always reproduces the same theme. colorStr is
-- already an AARRGGBB string (the same format WabaUI.DEFAULT_TINT_COLOR
-- uses), so it drops straight into every tint color field unchanged.
function WabaUI:BuildClassProfileData(classFile)
    local classColor = RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
    local hex = (classColor and classColor.colorStr) or WabaUI.DEFAULT_TINT_COLOR
    local data = {
        tintColor = hex,
        forceActionBarArt = true,
        intensity = CopyTable(WabaUI.DEFAULT_INTENSITY),
        categoryTintColor = {},
        actionBarUseOverall = {},
    }
    for key in pairs(WabaUI.DEFAULT_INTENSITY) do
        if key ~= "overall" then
            data.categoryTintColor[key] = hex
        end
    end
    for _, bar in ipairs(WabaUI.ACTION_BARS) do
        data.actionBarUseOverall[bar.category] = true
    end
    for _, extra in ipairs(WabaUI.OVERALL_LINKED_EXTRAS) do
        data.actionBarUseOverall[extra.category] = true
    end
    return data
end

-- Resolves any profile name (Default, a class, or a custom profile) to its
-- settings table. Returns nil for a name that isn't any of those.
function WabaUI:GetProfileData(name)
    if name == nil or name == "Default" then
        return WabaUISettingsDB.profiles and WabaUISettingsDB.profiles.Default
    end
    local classFile = WabaUI.classProfileClassFileByName[name]
    if classFile then
        return WabaUI:BuildClassProfileData(classFile)
    end
    return WabaUISettingsDB.profiles and WabaUISettingsDB.profiles[name]
end

-- Pushes a full profile's data into every registered setting via SetValue,
-- the same way WabaUI:SetAllCategoryTintColors already pushes one color
-- into many swatches - each SetValue writes through to WabaUISettingsDB,
-- refreshes that control's displayed value, and fires its own
-- SetValueChangedCallback (which reapplies the skin for that category).
-- WabaUI.applyingProfile suppresses MarkProfileDirty while this is running,
-- so switching profiles doesn't get recorded as an edit to whichever
-- profile was active a moment ago.
function WabaUI:ApplyProfileData(data)
    if not data then return end
    self.applyingProfile = true
    if self.rootSettings then
        if self.rootSettings.tintColor then
            self.rootSettings.tintColor:SetValue(data.tintColor or WabaUI.DEFAULT_TINT_COLOR)
        end
        if self.rootSettings.forceActionBarArt then
            self.rootSettings.forceActionBarArt:SetValue(data.forceActionBarArt ~= false)
        end
    end
    for key, setting in pairs(self.intensitySettings or {}) do
        setting:SetValue((data.intensity and data.intensity[key]) or WabaUI.DEFAULT_INTENSITY[key] or 0)
    end
    for key, setting in pairs(self.categoryTintSettings or {}) do
        setting:SetValue((data.categoryTintColor and data.categoryTintColor[key]) or data.tintColor or WabaUI.DEFAULT_TINT_COLOR)
    end
    for key, setting in pairs(self.actionBarUseOverallSettings or {}) do
        local value = data.actionBarUseOverall and data.actionBarUseOverall[key]
        if value == nil then value = true end
        setting:SetValue(value)
    end
    self.applyingProfile = false
end

function WabaUI:ApplyProfile(name)
    local data = WabaUI:GetProfileData(name)
    if not data then
        print("|cff33ff99WabaUI|r: unknown profile \"" .. tostring(name) .. "\".")
        return
    end
    WabaUI:ApplyProfileData(data)
end

-- Called from every theme setting's SetValueChangedCallback. Whichever
-- profile is active gets the edit - unless a class profile is active, since
-- those can't be manually changed: the edit lands in Default instead, and
-- the profile dropdown falls back to show Default as active, matching what
-- actually just happened to the saved data.
function WabaUI:MarkProfileDirty()
    if self.applyingProfile then return end
    WabaUISettingsDB.profiles = WabaUISettingsDB.profiles or {}
    local active = WabaUISettingsDB.activeProfile or "Default"
    if WabaUI:IsCustomProfile(active) then
        WabaUISettingsDB.profiles[active] = WabaUI:SnapshotProfileData()
    else
        WabaUISettingsDB.profiles.Default = WabaUI:SnapshotProfileData()
        if active ~= "Default" and WabaUI.activeProfileSetting then
            WabaUI.activeProfileSetting:SetValue("Default")
        end
    end
end

-- The four profile-management actions, shared between the options panel's
-- buttons (see CreateOptionsPanel) and the "/wabaui profile" slash command,
-- so the two stay in sync instead of duplicating validation and messaging.
function WabaUI:SaveCurrentAsNewProfile(name)
    name = name and strtrim(name) or ""
    if name == "" then
        print("|cff33ff99WabaUI|r: profile name can't be empty.")
        return
    end
    if WabaUI:IsReservedProfileName(name) then
        print("|cff33ff99WabaUI|r: \"" .. name .. "\" is a reserved profile name.")
        return
    end
    WabaUISettingsDB.profiles[name] = WabaUI:SnapshotProfileData()
    WabaUI.activeProfileSetting:SetValue(name)
    print("|cff33ff99WabaUI|r: saved the current settings as profile \"" .. name .. "\" and made it active.")
end

function WabaUI:CreateProfileFrom(source, name)
    name = name and strtrim(name) or ""
    if name == "" then
        print("|cff33ff99WabaUI|r: profile name can't be empty.")
        return
    end
    if WabaUI:IsReservedProfileName(name) then
        print("|cff33ff99WabaUI|r: \"" .. name .. "\" is a reserved profile name.")
        return
    end
    local data = WabaUI:GetProfileData(source)
    if not data then
        print("|cff33ff99WabaUI|r: no profile named \"" .. tostring(source) .. "\".")
        return
    end
    WabaUISettingsDB.profiles[name] = CopyTable(data)
    WabaUI.activeProfileSetting:SetValue(name)
    print("|cff33ff99WabaUI|r: copied \"" .. source .. "\" into new profile \"" .. name .. "\".")
end

function WabaUI:CopyIntoActiveProfile(source)
    local active = WabaUISettingsDB.activeProfile or "Default"
    if not WabaUI:IsCustomProfile(active) then
        print("|cff33ff99WabaUI|r: select a custom profile first, or copy into a new one instead.")
        return
    end
    local data = WabaUI:GetProfileData(source)
    if not data then
        print("|cff33ff99WabaUI|r: no profile named \"" .. tostring(source) .. "\".")
        return
    end
    WabaUI:ApplyProfileData(CopyTable(data))
    WabaUI:MarkProfileDirty()
    print("|cff33ff99WabaUI|r: copied \"" .. source .. "\" into the active profile \"" .. active .. "\".")
end

function WabaUI:DeleteProfile(name)
    if not WabaUI:IsCustomProfile(name) then
        print("|cff33ff99WabaUI|r: \"" .. tostring(name) .. "\" isn't a custom profile.")
        return
    end
    WabaUISettingsDB.profiles[name] = nil
    if WabaUISettingsDB.activeProfile == name then
        WabaUI.activeProfileSetting:SetValue("Default")
    end
    print("|cff33ff99WabaUI|r: deleted profile \"" .. name .. "\".")
end

local function CreateColorSwatch(category, tintCategory, label)
    local variable = "WABAUI_COLOR_" .. tintCategory:upper()
    local setting = Settings.RegisterAddOnSetting(category, variable, tintCategory,
        WabaUISettingsDB.categoryTintColor, Settings.VarType.String, label .. " color",
        WabaUISettingsDB.tintColor or WabaUI.DEFAULT_TINT_COLOR)
    setting:SetValueChangedCallback(function(_, value)
        WabaUI:RefreshCategory(tintCategory)
        WabaUI:MarkProfileDirty()
    end)
    Settings.CreateColorSwatch(category, setting,
        "This panel's own tint color, overriding the master tint color above just for it.")
    WabaUI.categoryTintSettings[tintCategory] = setting
end

local function CreateSliders(category, infoList, sliderOptions)
    for _, info in ipairs(infoList) do
        local variable = "WABAUI_INTENSITY_" .. info.key:upper()
        local setting = Settings.RegisterAddOnSetting(category, variable, info.key,
            WabaUISettingsDB.intensity, Settings.VarType.Number, info.label, WabaUI.DEFAULT_INTENSITY[info.key])
        setting:SetValueChangedCallback(function(_, value)
            WabaUI:RefreshCategory(info.key)
            WabaUI:MarkProfileDirty()
        end)
        Settings.CreateSlider(category, setting, sliderOptions, info.tooltip)
        WabaUI.intensitySettings[info.key] = setting
        if info.key ~= "overall" then
            CreateColorSwatch(category, info.key, info.label)
        end
    end
end

local function CreateOverallLinkedControls(category, sliderOptions, entries)
    for _, entry in ipairs(entries) do
        local useOverallSetting = Settings.RegisterAddOnSetting(category,
            "WABAUI_ACTIONBAR_USEOVERALL_" .. entry.key:upper(), entry.category,
            WabaUISettingsDB.actionBarUseOverall, Settings.VarType.Boolean,
            "Use overall slider for " .. entry.label, true)
        useOverallSetting:SetValueChangedCallback(function(_, value)
            WabaUI:RefreshCategory(entry.category)
            WabaUI:MarkProfileDirty()
        end)
        Settings.CreateCheckbox(category, useOverallSetting,
            "Uncheck to darken the " .. entry.label .. " with its own slider below instead of the overall action bar slider.")
        WabaUI.actionBarUseOverallSettings[entry.category] = useOverallSetting

        local variable = "WABAUI_INTENSITY_" .. entry.category:upper()
        local intensitySetting = Settings.RegisterAddOnSetting(category, variable, entry.category,
            WabaUISettingsDB.intensity, Settings.VarType.Number, entry.label .. " darkness",
            WabaUI.DEFAULT_INTENSITY[entry.category])
        intensitySetting:SetValueChangedCallback(function(_, value)
            WabaUI:RefreshCategory(entry.category)
            WabaUI:MarkProfileDirty()
        end)
        Settings.CreateSlider(category, intensitySetting, sliderOptions,
            "Used instead of the overall action bar slider when the checkbox above is unchecked.")
        WabaUI.intensitySettings[entry.category] = intensitySetting

        CreateColorSwatch(category, entry.category, entry.label)
    end
end

-- Options for the profile dropdown: Default, then every class (in the
-- client's own CLASS_SORT_ORDER), then any custom profiles the player has
-- saved, alphabetically.
local function GetProfileOptions()
    local container = Settings.CreateControlTextContainer()
    container:Add("Default", "Default")
    for _, classFile in ipairs(CLASS_SORT_ORDER or {}) do
        local name = LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[classFile]
        if name then
            container:Add(name, name)
        end
    end
    local customNames = {}
    for name in pairs(WabaUISettingsDB.profiles or {}) do
        if WabaUI:IsCustomProfile(name) then
            table.insert(customNames, name)
        end
    end
    table.sort(customNames)
    for _, name in ipairs(customNames) do
        container:Add(name, name)
    end
    return container:GetData()
end

-- Name-entry and confirm popups for the profile buttons in CreateOptionsPanel
-- below - the Settings API has no text-entry control of its own, so this is
-- the standard WoW pattern for it. This client's popups are built on
-- GameDialogMixin, which keeps the edit box at self.EditBox (capitalized,
-- reachable through the public self:GetEditBox()/GetEditBoxText() methods)
-- rather than the classic lowercase self.editBox - use the methods, not the
-- field, so this keeps working if that internal name ever moves again.
-- EditBoxOnEnterPressed runs on the edit box itself (its first argument),
-- not the dialog; :GetParent() on it gets back to the dialog. Whatever was
-- passed as the 4th argument to StaticPopup_Show is delivered as OnAccept's
-- second parameter and as EditBoxOnEnterPressed's second parameter too.
StaticPopupDialogs["WABAUI_SAVE_NEW_PROFILE"] = {
    text = "Save the current WabaUI settings as a new profile named:",
    button1 = ACCEPT,
    button2 = CANCEL,
    hasEditBox = true,
    maxLetters = 32,
    OnShow = function(self)
        local editBox = self:GetEditBox()
        editBox:SetText("")
        editBox:SetFocus()
    end,
    OnAccept = function(self)
        WabaUI:SaveCurrentAsNewProfile(self:GetEditBoxText())
    end,
    EditBoxOnEnterPressed = function(editBox)
        local dialog = editBox:GetParent()
        WabaUI:SaveCurrentAsNewProfile(editBox:GetText())
        dialog:Hide()
    end,
    EditBoxOnEscapePressed = function(editBox)
        editBox:GetParent():Hide()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

StaticPopupDialogs["WABAUI_COPY_INTO_NEW_PROFILE"] = {
    text = "Copy \"%s\" into a new profile named:",
    button1 = ACCEPT,
    button2 = CANCEL,
    hasEditBox = true,
    maxLetters = 32,
    OnShow = function(self)
        local editBox = self:GetEditBox()
        editBox:SetText("")
        editBox:SetFocus()
    end,
    OnAccept = function(self, source)
        WabaUI:CreateProfileFrom(source, self:GetEditBoxText())
    end,
    EditBoxOnEnterPressed = function(editBox, source)
        local dialog = editBox:GetParent()
        WabaUI:CreateProfileFrom(source, editBox:GetText())
        dialog:Hide()
    end,
    EditBoxOnEscapePressed = function(editBox)
        editBox:GetParent():Hide()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

StaticPopupDialogs["WABAUI_DELETE_PROFILE"] = {
    text = "Delete the profile \"%s\"? This can't be undone.",
    button1 = YES,
    button2 = NO,
    OnAccept = function(self, name)
        WabaUI:DeleteProfile(name)
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

local function CreateOptionsPanel()
    local category = Settings.RegisterVerticalLayoutCategory("WabaUI")
    local layout = SettingsPanel:GetLayout(category)

    -- category -> setting, filled in by CreateColorSwatch below as each
    -- panel's swatch is created, so the master swatch's callback (further
    -- down) can push a new color into every one of them at once, and so
    -- WabaUI:ApplyProfileData can push a whole profile into every one at
    -- once.
    WabaUI.categoryTintSettings = {}
    WabaUI.intensitySettings = {}
    WabaUI.actionBarUseOverallSettings = {}
    WabaUI.rootSettings = {}

    local activeProfileSetting = Settings.RegisterAddOnSetting(category, "WABAUI_ACTIVE_PROFILE", "activeProfile",
        WabaUISettingsDB, Settings.VarType.String, "Profile", "Default")
    activeProfileSetting:SetValueChangedCallback(function(_, value)
        WabaUI:ApplyProfile(value)
    end)
    Settings.CreateDropdown(category, activeProfileSetting, GetProfileOptions,
        "Pick a saved profile, or one of the built-in per-class color themes. Class themes can't be edited directly - " ..
        "changing a setting while one is active saves the change to Default instead.")
    WabaUI.activeProfileSetting = activeProfileSetting

    -- "Copy from" doesn't need to persist between sessions - it's just the
    -- source picker for the two copy buttons below - so it's a proxy
    -- setting backed by a plain Lua field instead of WabaUISettingsDB.
    local function GetCopySourceValue()
        return WabaUI.copySourceProfile or "Default"
    end
    local function SetCopySourceValue(value)
        WabaUI.copySourceProfile = value
    end
    local copySourceSetting = Settings.RegisterProxySetting(category, "WABAUI_COPY_SOURCE", Settings.VarType.String,
        "Copy from", "Default", GetCopySourceValue, SetCopySourceValue)
    Settings.CreateDropdown(category, copySourceSetting, GetProfileOptions,
        "Pick a profile here, then use one of the copy buttons below.")

    local saveNewInitializer = CreateSettingsButtonInitializer("", "Save as New Profile",
        function() StaticPopup_Show("WABAUI_SAVE_NEW_PROFILE") end,
        "Saves the current settings as a new custom profile and makes it active.", false)
    layout:AddInitializer(saveNewInitializer)

    local copyIntoNewInitializer = CreateSettingsButtonInitializer("", "Copy Into New Profile",
        function()
            local source = GetCopySourceValue()
            if not WabaUI:GetProfileData(source) then
                print("|cff33ff99WabaUI|r: no profile named \"" .. tostring(source) .. "\".")
                return
            end
            StaticPopup_Show("WABAUI_COPY_INTO_NEW_PROFILE", source, nil, source)
        end,
        "Copies the profile picked above into a new custom profile and makes it active.", false)
    layout:AddInitializer(copyIntoNewInitializer)

    local copyIntoActiveInitializer = CreateSettingsButtonInitializer("", "Copy Into Active Profile",
        function() WabaUI:CopyIntoActiveProfile(GetCopySourceValue()) end,
        "Overwrites the active custom profile with the profile picked above. Only works while a custom profile is active.", false)
    layout:AddInitializer(copyIntoActiveInitializer)

    local deleteProfileInitializer = CreateSettingsButtonInitializer("", "Delete Active Profile",
        function()
            local active = WabaUISettingsDB.activeProfile or "Default"
            if not WabaUI:IsCustomProfile(active) then
                print("|cff33ff99WabaUI|r: select a custom profile to delete first.")
                return
            end
            StaticPopup_Show("WABAUI_DELETE_PROFILE", active, nil, active)
        end,
        "Deletes the active custom profile. Only works while a custom profile is active.", false)
    layout:AddInitializer(deleteProfileInitializer)

    local enabledSetting = Settings.RegisterAddOnSetting(category, "WABAUI_ENABLED", "enabled",
        WabaUISettingsDB, Settings.VarType.Boolean, "Enable dark mode", true)
    enabledSetting:SetValueChangedCallback(function(_, value)
        WabaUI:SetEnabled(value)
    end)
    Settings.CreateCheckbox(category, enabledSetting,
        "Reskin standard panels, the minimap border, action bars, and chat frames in dark tones.")

    -- A quick "set every panel to this color" tool, independent of the
    -- per-category darkness sliders below: darkness controls how far a
    -- piece lerps toward its color, this just bulk-writes that color.
    -- Defaults to the near-black WabaUI always used before this was
    -- configurable. Each panel below still has its own swatch to give it a
    -- different color afterward - this one doesn't stay "linked", it's a
    -- one-time push, not a live master.
    local tintColorSetting = Settings.RegisterAddOnSetting(category, "WABAUI_TINT_COLOR", "tintColor",
        WabaUISettingsDB, Settings.VarType.String, "Tint color (all panels)", WabaUI.DEFAULT_TINT_COLOR)
    tintColorSetting:SetValueChangedCallback(function(_, value)
        WabaUI:SetAllCategoryTintColors(value)
        WabaUI:MarkProfileDirty()
    end)
    Settings.CreateColorSwatch(category, tintColorSetting,
        "Sets every panel below to this color at once. Change any panel's own swatch afterward to give it a different color.")
    WabaUI.rootSettings.tintColor = tintColorSetting

    local sliderOptions = Settings.CreateSliderOptions(0, 1, 0.05)
    sliderOptions:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, FormatPercentageRounded)
    CreateSliders(category, TOP_LEVEL_INTENSITY, sliderOptions)

    local actionBarsSubcategory = Settings.RegisterVerticalLayoutSubcategory(category, "Action Bars")
    CreateSliders(actionBarsSubcategory, ACTION_BAR_INTENSITY, sliderOptions)

    local forceArtSetting = Settings.RegisterAddOnSetting(actionBarsSubcategory, "WABAUI_FORCE_ACTIONBAR_ART",
        "forceActionBarArt", WabaUISettingsDB, Settings.VarType.Boolean, "Match extra bars' art to the main bar", true)
    forceArtSetting:SetValueChangedCallback(function(_, value)
        WabaUI:SetForceActionBarArt(value)
        WabaUI:MarkProfileDirty()
    end)
    Settings.CreateCheckbox(actionBarsSubcategory, forceArtSetting,
        "Forces the Main Action Bar's ornate button border onto the extra action bars (MultiBar1-7), " ..
        "for bars whose own Edit Mode \"Hide Bar Art\" checkbox isn't reachable in this client.")
    WabaUI.rootSettings.forceActionBarArt = forceArtSetting

    CreateOverallLinkedControls(actionBarsSubcategory, sliderOptions, WabaUI.ACTION_BARS)
    CreateOverallLinkedControls(actionBarsSubcategory, sliderOptions, WabaUI.OVERALL_LINKED_EXTRAS)

    local unitFramesSubcategory = Settings.RegisterVerticalLayoutSubcategory(category, "Unit Frames")
    CreateSliders(unitFramesSubcategory, UNIT_FRAME_INTENSITY, sliderOptions)

    local windowsSubcategory = Settings.RegisterVerticalLayoutSubcategory(category, "Windows")
    CreateSliders(windowsSubcategory, WINDOW_INTENSITY, sliderOptions)

    Settings.RegisterAddOnCategory(category)
    WabaUI.optionsCategoryID = category:GetID()
end

function WabaUI:SetEnabled(enabled)
    self.settings.enabled = enabled
    if enabled then
        self:ApplyAll()
    else
        self:RevertAll()
    end
end

-- Pushes hex into every per-category color setting (see CreateColorSwatch),
-- as if the player had opened each panel's own swatch and picked the same
-- color. Going through setting:SetValue (not writing WabaUISettingsDB.
-- categoryTintColor directly) keeps each swatch's own displayed color and
-- its SetValueChangedCallback/RefreshCategory in sync, the same as if a
-- person clicked it themselves.
function WabaUI:SetAllCategoryTintColors(hex)
    for _, setting in pairs(self.categoryTintSettings or {}) do
        setting:SetValue(hex)
    end
end

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local loadedAddon = ...
        if loadedAddon == "WabaUI" then
            WabaUISettingsDB = WabaUISettingsDB or { enabled = true }
            if WabaUISettingsDB.forceActionBarArt == nil then
                WabaUISettingsDB.forceActionBarArt = true
            end
            WabaUISettingsDB.tintColor = WabaUISettingsDB.tintColor or WabaUI.DEFAULT_TINT_COLOR
            WabaUISettingsDB.intensity = WabaUISettingsDB.intensity or {}
            WabaUISettingsDB.categoryTintColor = WabaUISettingsDB.categoryTintColor or {}
            for key, default in pairs(WabaUI.DEFAULT_INTENSITY) do
                if WabaUISettingsDB.intensity[key] == nil then
                    WabaUISettingsDB.intensity[key] = default
                end
                -- "overall" isn't a real paintable category (see
                -- CreateSliders in Core.lua), so it never gets its own
                -- swatch and doesn't need a color entry here either.
                if key ~= "overall" and WabaUISettingsDB.categoryTintColor[key] == nil then
                    WabaUISettingsDB.categoryTintColor[key] = WabaUISettingsDB.tintColor
                end
            end
            WabaUISettingsDB.actionBarUseOverall = WabaUISettingsDB.actionBarUseOverall or {}
            for _, bar in ipairs(WabaUI.ACTION_BARS) do
                if WabaUISettingsDB.actionBarUseOverall[bar.category] == nil then
                    WabaUISettingsDB.actionBarUseOverall[bar.category] = true
                end
            end
            for _, extra in ipairs(WabaUI.OVERALL_LINKED_EXTRAS) do
                if WabaUISettingsDB.actionBarUseOverall[extra.category] == nil then
                    WabaUISettingsDB.actionBarUseOverall[extra.category] = true
                end
            end

            -- The Default profile is just a persisted snapshot of the
            -- fields above. On a first run (or an upgrade from before
            -- profiles existed) it's seeded from whatever's already in
            -- WabaUISettingsDB, so nothing changes for existing players.
            WabaUISettingsDB.profiles = WabaUISettingsDB.profiles or {}
            WabaUI.settings = WabaUISettingsDB
            if not WabaUISettingsDB.profiles.Default then
                WabaUISettingsDB.profiles.Default = WabaUI:SnapshotProfileData()
            end
            WabaUISettingsDB.activeProfile = WabaUISettingsDB.activeProfile or "Default"

            CreateOptionsPanel()
            if WabaUI.settings.enabled then
                WabaUI:ApplyAll()
            end
        end
    end
end)

SLASH_WABAUI1 = "/wabaui"
SlashCmdList["WABAUI"] = function(msg)
    msg = msg or ""
    local cmd = msg:match("^(%S*)"):lower()

    if cmd == "on" then
        WabaUI:SetEnabled(true)
        print("|cff33ff99WabaUI|r: dark mode ON")
    elseif cmd == "off" then
        WabaUI:SetEnabled(false)
        print("|cff33ff99WabaUI|r: dark mode OFF")
    elseif cmd == "options" then
        Settings.OpenToCategory(WabaUI.optionsCategoryID)
    elseif cmd == "profile" then
        local rest = msg:match("^%S+%s*(.*)$") or ""
        local sub, args = rest:match("^(%S*)%s*(.-)$")
        sub = sub:lower()

        if sub == "save" then
            if args == "" then
                print("|cff33ff99WabaUI|r: usage: /wabaui profile save <name>")
            else
                WabaUI:SaveCurrentAsNewProfile(args)
            end
        elseif sub == "copy" then
            if args == "" then
                print("|cff33ff99WabaUI|r: usage: /wabaui profile copy <source> [as <new name>]")
            else
                local source, dest = args:match("^(.-)%s+as%s+(.+)$")
                source = source or args
                if dest then
                    WabaUI:CreateProfileFrom(source, dest)
                else
                    WabaUI:CopyIntoActiveProfile(source)
                end
            end
        elseif sub == "delete" then
            if args == "" then
                print("|cff33ff99WabaUI|r: usage: /wabaui profile delete <name>")
            else
                WabaUI:DeleteProfile(args)
            end
        else
            print("|cff33ff99WabaUI|r: active profile: " .. (WabaUISettingsDB.activeProfile or "Default"))
            print("|cff33ff99WabaUI|r: /wabaui profile save <name> | copy <source> [as <name>] | delete <name>")
        end
    else
        print("|cff33ff99WabaUI|r: dark mode " .. (WabaUI.settings.enabled and "ON" or "OFF") ..
            " (/wabaui on|off|options|profile)")
    end
end
