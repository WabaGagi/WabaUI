-- Core.lua: saved-variable bootstrap, the on/off switch, the slash command,
-- and the Settings-API options panel. Skin.lua owns the actual reskinning;
-- this file only decides whether it should be applied.

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

-- One color swatch per real tint category (never "overall" - that's a
-- darkness multiplier, not a paintable category; the master swatch in
-- CreateOptionsPanel covers it). Independent of the darkness slider next to
-- it: darkness controls how far a piece lerps, this controls what color it
-- lerps toward. Defaults to whatever the master swatch currently holds, so
-- every panel starts out matching it until individually overridden.
-- WabaUI.categoryTintSettings (category -> setting) lets the master
-- swatch push a new color into every one of these at once.
local function CreateColorSwatch(category, tintCategory, label)
    local variable = "WABAUI_COLOR_" .. tintCategory:upper()
    local setting = Settings.RegisterAddOnSetting(category, variable, tintCategory,
        WabaUISettingsDB.categoryTintColor, Settings.VarType.String, label .. " color",
        WabaUISettingsDB.tintColor or WabaUI.DEFAULT_TINT_COLOR)
    setting:SetValueChangedCallback(function(_, value)
        WabaUI:RefreshCategory(tintCategory)
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
        end)
        Settings.CreateSlider(category, setting, sliderOptions, info.tooltip)
        if info.key ~= "overall" then
            CreateColorSwatch(category, info.key, info.label)
        end
    end
end

-- One checkbox + one slider per entry (WabaUI.ACTION_BARS and
-- WabaUI.OVERALL_LINKED_EXTRAS, both built in Skin.lua). The checkbox
-- picks whether that entry darkens with its own slider or rides the master
-- "Action bar darkness" slider above; its own slider only matters when
-- unchecked. Its color swatch is always independent of the checkbox, though
-- - color and darkness are separate axes, so there's no "use overall color"
-- toggle to match.
local function CreateOverallLinkedControls(category, sliderOptions, entries)
    for _, entry in ipairs(entries) do
        local useOverallSetting = Settings.RegisterAddOnSetting(category,
            "WABAUI_ACTIONBAR_USEOVERALL_" .. entry.key:upper(), entry.category,
            WabaUISettingsDB.actionBarUseOverall, Settings.VarType.Boolean,
            "Use overall slider for " .. entry.label, true)
        useOverallSetting:SetValueChangedCallback(function(_, value)
            WabaUI:RefreshCategory(entry.category)
        end)
        Settings.CreateCheckbox(category, useOverallSetting,
            "Uncheck to darken the " .. entry.label .. " with its own slider below instead of the overall action bar slider.")

        local variable = "WABAUI_INTENSITY_" .. entry.category:upper()
        local intensitySetting = Settings.RegisterAddOnSetting(category, variable, entry.category,
            WabaUISettingsDB.intensity, Settings.VarType.Number, entry.label .. " darkness",
            WabaUI.DEFAULT_INTENSITY[entry.category])
        intensitySetting:SetValueChangedCallback(function(_, value)
            WabaUI:RefreshCategory(entry.category)
        end)
        Settings.CreateSlider(category, intensitySetting, sliderOptions,
            "Used instead of the overall action bar slider when the checkbox above is unchecked.")

        CreateColorSwatch(category, entry.category, entry.label)
    end
end

local function CreateOptionsPanel()
    local category = Settings.RegisterVerticalLayoutCategory("WabaUI")

    local enabledSetting = Settings.RegisterAddOnSetting(category, "WABAUI_ENABLED", "enabled",
        WabaUISettingsDB, Settings.VarType.Boolean, "Enable dark mode", true)
    enabledSetting:SetValueChangedCallback(function(_, value)
        WabaUI:SetEnabled(value)
    end)
    Settings.CreateCheckbox(category, enabledSetting,
        "Reskin standard panels, the minimap border, action bars, and chat frames in dark tones.")

    -- category -> setting, filled in by CreateColorSwatch below as each
    -- panel's swatch is created, so the master swatch's callback (further
    -- down) can push a new color into every one of them at once.
    WabaUI.categoryTintSettings = {}

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
    end)
    Settings.CreateColorSwatch(category, tintColorSetting,
        "Sets every panel below to this color at once. Change any panel's own swatch afterward to give it a different color.")

    local sliderOptions = Settings.CreateSliderOptions(0, 1, 0.05)
    sliderOptions:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, FormatPercentageRounded)
    CreateSliders(category, TOP_LEVEL_INTENSITY, sliderOptions)

    local actionBarsSubcategory = Settings.RegisterVerticalLayoutSubcategory(category, "Action Bars")
    CreateSliders(actionBarsSubcategory, ACTION_BAR_INTENSITY, sliderOptions)

    local forceArtSetting = Settings.RegisterAddOnSetting(actionBarsSubcategory, "WABAUI_FORCE_ACTIONBAR_ART",
        "forceActionBarArt", WabaUISettingsDB, Settings.VarType.Boolean, "Match extra bars' art to the main bar", true)
    forceArtSetting:SetValueChangedCallback(function(_, value)
        WabaUI:SetForceActionBarArt(value)
    end)
    Settings.CreateCheckbox(actionBarsSubcategory, forceArtSetting,
        "Forces the Main Action Bar's ornate button border onto the extra action bars (MultiBar1-7), " ..
        "for bars whose own Edit Mode \"Hide Bar Art\" checkbox isn't reachable in this client.")

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
            WabaUI.settings = WabaUISettingsDB
            CreateOptionsPanel()
            if WabaUI.settings.enabled then
                WabaUI:ApplyAll()
            end
        end
    end
end)

SLASH_WABAUI1 = "/wabaui"
SlashCmdList["WABAUI"] = function(msg)
    local cmd = (msg or ""):match("^(%S*)"):lower()

    if cmd == "on" then
        WabaUI:SetEnabled(true)
        print("|cff33ff99WabaUI|r: dark mode ON")
    elseif cmd == "off" then
        WabaUI:SetEnabled(false)
        print("|cff33ff99WabaUI|r: dark mode OFF")
    elseif cmd == "options" then
        Settings.OpenToCategory(WabaUI.optionsCategoryID)
    else
        print("|cff33ff99WabaUI|r: dark mode " .. (WabaUI.settings.enabled and "ON" or "OFF") ..
            " (/wabaui on|off|options)")
    end
end
