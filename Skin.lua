-- Skin.lua: darkens standard Blizzard panels, the minimap border, action
-- bars, and chat frames by multiplying their existing textures' vertex
-- color - no custom art ships with this addon. Every tint is reversible:
-- each touched piece remembers its original color from the first time it
-- was seen, so toggling WabaDark off restores the exact original look.
--
-- Darkness is per-category and lives on a 0-1 slider (Core.lua wires these
-- up in the options panel): different UI areas need different amounts of
-- darkening, and different players want different windows darkened by
-- different amounts - the character panel and the objective tracker don't
-- have to agree. "overall" is a master multiplier layered on top of every
-- other category, for a single quick dimmer that doesn't erase the
-- per-category ratios.

WabaDark = WabaDark or {}
local WabaDark = WabaDark

-- Every action bar this addon treats individually, for both darkening and
-- (for the extra bars) forced matching art - see the "Extra action bar art"
-- section below. "horizontal" marks bars that get a cloned Main Action Bar
-- background plaque: that art is a horizontal strip, and would come out
-- stretched/distorted on the two vertical sidebars (MultiBarLeft/Right).
local ACTION_BARS = {
    { key = "main",        name = "MainActionBar",       category = "actionbar_main",        label = "Main action bar",           isMain = true,  horizontal = true },
    { key = "bottomleft",  name = "MultiBarBottomLeft",  category = "actionbar_bottomleft",  label = "Action bar (bottom left)",  isMain = false, horizontal = true },
    { key = "bottomright", name = "MultiBarBottomRight", category = "actionbar_bottomright", label = "Action bar (bottom right)", isMain = false, horizontal = true },
    { key = "left",        name = "MultiBarLeft",        category = "actionbar_left",        label = "Action bar (left side)",    isMain = false, horizontal = false },
    { key = "right",       name = "MultiBarRight",       category = "actionbar_right",       label = "Action bar (right side)",   isMain = false, horizontal = false },
    { key = "extra1",      name = "MultiBar5",           category = "actionbar_extra1",      label = "Extra action bar 1",        isMain = false, horizontal = true },
    { key = "extra2",      name = "MultiBar6",           category = "actionbar_extra2",      label = "Extra action bar 2",        isMain = false, horizontal = true },
    { key = "extra3",      name = "MultiBar7",           category = "actionbar_extra3",      label = "Extra action bar 3",        isMain = false, horizontal = true },
}
WabaDark.ACTION_BARS = ACTION_BARS -- Core.lua builds a checkbox + slider per bar from this same list

local ACTION_BAR_BY_NAME = {}
for _, bar in ipairs(ACTION_BARS) do
    ACTION_BAR_BY_NAME[bar.name] = bar
end

-- Non-action-bar pieces that still ride the master "actionbars" slider by
-- default but can opt into their own slider, the same checkbox pattern as
-- each action bar (see CreateOverallLinkedControls in Core.lua). Kept
-- separate from ACTION_BARS since these don't go through SetBarArt's
-- forced-art machinery - they're not action bars, just things that visually
-- belong in the same "action bar darkness" family.
local OVERALL_LINKED_EXTRAS = {
    { key = "bags", category = "bagbar", label = "Bag bar" },
    { key = "endcaps", category = "actionbar_endcaps", label = "Gryphon-head end caps" },
}
WabaDark.OVERALL_LINKED_EXTRAS = OVERALL_LINKED_EXTRAS

-- Vertex-color tinting is multiplicative (result = texture * tint), so it
-- can only ever darken a texture's existing hue, never neutralize it - a
-- mid-gray tint on a brown texture still reads as a dim brown. Intensity
-- 0 leaves a piece at its original color; intensity 1 lerps it all the way
-- to GetDarkTarget(category) (or GetCenterDarkTarget(category) for a
-- nine-slice panel's fill, which is allowed to go a touch darker than its
-- border for definition). Each category has its own tint color, defaulting
-- to whatever the master "Tint color" swatch held when that category was
-- first seen (WabaDark.settings.categoryTintColor) - "darkness" (how far a
-- piece lerps) and "tint color" (what it lerps toward) are two independent
-- controls, and every panel can be given its own of each.
WabaDark.DEFAULT_INTENSITY = {
    overall = 1.0,
    character = 0.85,
    bags = 0.85,
    merchant = 0.85,
    friends = 0.85,
    questmap = 0.85,
    spellbook = 0.85,
    minimap = 0.85,
    chat = 0.85,
    actionbars = 0.6,
    tracker = 0.85,
    loot = 0.85,
    npctext = 0.85,
    unitframe_player = 0.4, -- lower than most: the health/mana fill itself needs to stay readable
    unitframe_target = 0.4,
    unitframe_pet = 0.4,
    unitframe_party = 0.85, -- just a border/background piece, not a health fill, so no need to go easy
    other = 0.85, -- anything ShowUIPanel catches that isn't in FRAME_CATEGORIES below
}
for _, bar in ipairs(ACTION_BARS) do
    WabaDark.DEFAULT_INTENSITY[bar.category] = WabaDark.DEFAULT_INTENSITY.actionbars
end
for _, extra in ipairs(OVERALL_LINKED_EXTRAS) do
    WabaDark.DEFAULT_INTENSITY[extra.category] = WabaDark.DEFAULT_INTENSITY.actionbars
end

-- Default tint color (AARRGGBB, the format CreateColorFromHexString/
-- Settings.CreateColorSwatch both use): near-black, matching the fixed
-- DARK_TARGET this addon used before the color picker was added.
WabaDark.DEFAULT_TINT_COLOR = "FF0D0D0F"

-- A nine-slice panel's fill is allowed to go a touch darker than its
-- border for definition - previously a separate fixed color
-- (CENTER_DARK_TARGET), now just a fraction of whatever tint color is
-- picked, preserving that same ~0.4x relationship.
local CENTER_TARGET_SCALE = 0.4

-- GetDarkTarget/GetCenterDarkTarget are called per-category (each panel can
-- now have its own color - see WabaDark.categoryTintSettings in Core.lua)
-- from hooks that can fire many times a second (NineSliceUtil.ApplyLayout,
-- MainActionBarMixin:UpdateDividers - tooltips and layout churn re-trigger
-- these constantly), so re-parsing a hex string and allocating a new Color +
-- tables on every call would leak garbage fast (this addon's memory usage
-- climbed continuously before this cache was added). Cache each category's
-- parsed result separately and only redo the work when THAT category's
-- saved hex string actually changes - every other call is just a table
-- lookup plus a string comparison.
local tintTargetCache = {} -- category -> { hex = "AARRGGBB", dark = {r,g,b}, center = {r,g,b} }

local function ResolveCategoryTintColorHex(category)
    local settings = WabaDark.settings
    local perCategory = settings and settings.categoryTintColor
    local hex = perCategory and perCategory[category]
    if not hex or hex == "" then
        hex = (settings and settings.tintColor) or WabaDark.DEFAULT_TINT_COLOR
    end
    return hex
end

local function GetTintTargets(category)
    category = category or "other"
    local hex = ResolveCategoryTintColorHex(category)
    local cached = tintTargetCache[category]
    if cached and cached.hex == hex then
        return cached
    end
    local ok, color = pcall(CreateColorFromHexString, hex)
    if not ok or not color then
        ok, color = pcall(CreateColorFromHexString, WabaDark.DEFAULT_TINT_COLOR)
    end
    local r, g, b
    if ok and color then
        r, g, b = color:GetRGB()
    else
        -- Last-resort fallback if even the default fails to parse, so this
        -- never leaves the cache empty and re-attempts the parse every call.
        r, g, b = 0.05, 0.05, 0.06
    end
    cached = {
        hex = hex,
        dark = { r, g, b },
        center = { r * CENTER_TARGET_SCALE, g * CENTER_TARGET_SCALE, b * CENTER_TARGET_SCALE },
    }
    tintTargetCache[category] = cached
    return cached
end

local function GetDarkTarget(category)
    return GetTintTargets(category).dark
end

local function GetCenterDarkTarget(category)
    return GetTintTargets(category).center
end

WabaDark.tinted = {}         -- list of { category = "character", apply = function(enabled) ... end }
WabaDark.tintedByFrame = {}  -- container/region -> its entry in WabaDark.tinted, for de-dup

local function IsEnabled()
    return WabaDark.settings and WabaDark.settings.enabled
end

-- Each individual action bar can either ride the master "actionbars" slider
-- or use its own (WabaDark.settings.actionBarUseOverall[category], a
-- per-bar checkbox wired up in Core.lua) - resolve that redirection once
-- here so every other category keeps working exactly as before.
local function GetIntensity(category)
    local settings = WabaDark.settings
    local useOverall = settings and settings.actionBarUseOverall and settings.actionBarUseOverall[category]
    local effectiveCategory = useOverall and "actionbars" or category
    local intensity = settings and settings.intensity
    local value = intensity and intensity[effectiveCategory]
    if value == nil then
        value = WabaDark.DEFAULT_INTENSITY[effectiveCategory] or WabaDark.DEFAULT_INTENSITY.other
    end
    local overall = (intensity and intensity.overall) or WabaDark.DEFAULT_INTENSITY.overall
    return value * overall
end

local function TintColorFor(original, target, category)
    local t = GetIntensity(category)
    return
        original[1] + (target[1] - original[1]) * t,
        original[2] + (target[2] - original[2]) * t,
        original[3] + (target[3] - original[3]) * t,
        original[4]
end

-- Every single-texture tint (plain regions, button slot art) shares this:
-- capture the original color once, register a reversible apply(enabled)
-- closure, and de-dup by the texture object itself.
local function TintSingleTexture(texture, category)
    if not texture or WabaDark.tintedByFrame[texture] then
        return
    end
    local r, g, b, a = texture:GetVertexColor()
    local original = { r or 1, g or 1, b or 1, a or 1 }
    local apply = function(enabled)
        if enabled then
            texture:SetVertexColor(TintColorFor(original, GetDarkTarget(category), category))
        else
            texture:SetVertexColor(unpack(original))
        end
    end
    local entry = { category = category, apply = apply }
    WabaDark.tintedByFrame[texture] = entry
    table.insert(WabaDark.tinted, entry)
    apply(IsEnabled())
end

-- Nine-slice panels: anything Blizzard builds from the shared border system
-- (Blizzard_SharedXML/NineSlice.lua). Hooking the shared ApplyLayout call
-- catches these generically instead of guessing frame names.
local function MakeNineSliceTint(container)
    local br, bg, bb, ba = container:GetBorderColor()
    local cr, cg, cb, ca = container:GetCenterColor()
    local originalBorder = { br or 1, bg or 1, bb or 1, ba or 1 }
    local originalCenter = { cr or 1, cg or 1, cb or 1, ca or 1 }
    return function(enabled, category)
        if enabled then
            container:SetBorderColor(TintColorFor(originalBorder, GetDarkTarget(category), category))
            container:SetCenterColor(TintColorFor(originalCenter, GetCenterDarkTarget(category), category))
        else
            container:SetBorderColor(unpack(originalBorder))
            container:SetCenterColor(unpack(originalCenter))
        end
    end
end

-- Unlike other apply closures, a nine-slice one needs its category passed
-- in at call time rather than captured, because the SAME container can
-- first be seen via the generic ApplyLayout hook (no context, "other") and
-- later recognized as belonging to a specific panel (e.g. CharacterFrame.
-- NineSlice) - see the category-upgrade logic in WabaDark:TintNineSlice.
function WabaDark:TintNineSlice(container, category)
    if not container or not container.SetBorderColor or not container.SetCenterColor then
        return
    end
    category = category or "other"

    local entry = self.tintedByFrame[container]
    if not entry then
        local ok, rawApply = pcall(MakeNineSliceTint, container)
        if not ok or not rawApply then
            return
        end
        entry = {
            category = category,
            apply = function(enabled) rawApply(enabled, entry.category) end,
        }
        self.tintedByFrame[container] = entry
        table.insert(self.tinted, entry)
    elseif category ~= "other" then
        entry.category = category
    end

    entry.apply(IsEnabled())
end

hooksecurefunc(NineSliceUtil, "ApplyLayout", function(container)
    WabaDark:TintNineSlice(container)
end)

-- Plain textures that aren't nine-slice panels. This client (WoW Forever /
-- "Camelot", per the UI source) turns out to be a classic-lineage codebase
-- where standard windows (bags, character, quest log, etc.) don't route
-- through NineSliceUtil at all - they paint their border as plain Texture
-- regions directly on the frame. Regions are discovered at runtime.
--
-- Deliberately NOT recursive into arbitrary children: many panels parent
-- item/spell icon buttons directly under themselves, and blindly walking
-- the whole frame tree would darken those icons along with the chrome.
-- Instead we also probe a short list of conventional child key names
-- Blizzard commonly uses for a panel's background/border/header sub-piece.
local CHROME_CHILD_KEYS = { "Inset", "NineSlice", "Bg", "Background", "Border", "Header" }

local function TintTextureRegionsOf(frame, category)
    if not frame or not frame.GetRegions then
        return
    end

    for _, region in ipairs({ frame:GetRegions() }) do
        if region.GetObjectType and region:GetObjectType() == "Texture" then
            TintSingleTexture(region, category)
        end
    end

    for _, key in ipairs(CHROME_CHILD_KEYS) do
        local child = frame[key]
        if child and child ~= frame then
            if child.SetBorderColor and child.SetCenterColor then
                -- A real nine-slice child (e.g. CharacterFrame.NineSlice via
                -- PortraitFrameBaseTemplate) - route through the dedicated
                -- handler instead of tinting its pieces as loose regions,
                -- so there's exactly one place that owns its original color.
                WabaDark:TintNineSlice(child, category)
            elseif child.GetRegions then
                TintTextureRegionsOf(child, category)
            end
        end
    end
end

-- NPC interaction text (Blizzard_UIPanels_Game/*/QuestFrame.xml): the
-- gossip/quest greeting, detail, progress and reward panels shown while
-- talking to an NPC get their border/background darkened by the generic
-- ShowUIPanel hook above (FRAME_CATEGORIES["QuestFrame"] = "npctext"), but
-- Blizzard picks their text color assuming that background stays close to
-- its native light "Parchment" tone (QuestFrame_SetTextColor in
-- QuestFrame.lua). Once the npctext slider drags that background most of
-- the way to black, that same dark text loses all contrast against it.
-- Retail has its own light/dark text switch for this (QuestTextContrast),
-- but this client's Lua doesn't carry that accessibility feature, so
-- WabaDark brightens the text itself, blending it toward a warm light
-- target with the SAME per-category intensity used to darken the
-- background - the two always move together on one slider.
local LIGHT_TEXT_TARGET = { 0.95, 0.89, 0.72 }

-- Unlike TintSingleTexture, this re-reads "original" on every call instead
-- of caching it once: these panels reuse the same FontString objects across
-- different NPCs (persistent ones like GreetingText, and pooled ones like
-- the quest title buttons), and Blizzard resets their color to the plain
-- material color every time the panel repopulates. Re-reading
-- GetTextColor() here happens right after that reset (see the OnShow hooks
-- below), so it always captures Blizzard's clean color for this NPC rather
-- than a stale tint left over from the last one.
local function TintSingleFontString(fontString, category)
    if not fontString or not fontString.GetTextColor then
        return
    end
    local r, g, b, a = fontString:GetTextColor()
    local original = { r or 1, g or 1, b or 1, a or 1 }
    local entry = WabaDark.tintedByFrame[fontString]
    if entry then
        entry.original = original
    else
        entry = { category = category, original = original }
        entry.apply = function(enabled)
            if enabled then
                fontString:SetTextColor(TintColorFor(entry.original, LIGHT_TEXT_TARGET, entry.category))
            else
                fontString:SetTextColor(unpack(entry.original))
            end
        end
        WabaDark.tintedByFrame[fontString] = entry
        table.insert(WabaDark.tinted, entry)
    end
    entry.apply(IsEnabled())
end

-- Recurses into every descendant rather than a short chrome-key whitelist
-- (contrast TintTextureRegionsOf above): these panels are pure
-- dialogue/reward content with no icon grid to accidentally wander into,
-- and only FontString regions are ever touched here, so a full walk is safe.
local function TintFontStringRegionsOf(frame, category)
    if not frame or not frame.GetRegions then
        return
    end
    for _, region in ipairs({ frame:GetRegions() }) do
        if region.GetObjectType and region:GetObjectType() == "FontString" then
            TintSingleFontString(region, category)
        end
    end
    if frame.GetChildren then
        for _, child in ipairs({ frame:GetChildren() }) do
            TintFontStringRegionsOf(child, category)
        end
    end
end

-- The four panels each populate their scroll child's text synchronously
-- inside their own OnShow, which runs before ours (HookScript chains after
-- Blizzard's own script) - but pooled pieces (quest title buttons, reward
-- item buttons) can still be laid out a frame late, so this is deferred via
-- C_Timer.After(0, ...) for the same taint-safety reason used elsewhere in
-- this file: never do real work on the same call stack as whatever
-- triggered the show.
local NPC_DIALOG_SCROLL_FRAMES = {
    "QuestGreetingScrollFrame",
    "QuestDetailScrollFrame",
    "QuestProgressScrollFrame",
    "QuestRewardScrollFrame",
}

local function TintNpcDialogText()
    C_Timer.After(0, function()
        for _, name in ipairs(NPC_DIALOG_SCROLL_FRAMES) do
            TintFontStringRegionsOf(_G[name], "npctext")
        end
    end)
end

for _, panelName in ipairs({
    "QuestFrameGreetingPanel", "QuestFrameDetailPanel", "QuestFrameProgressPanel", "QuestFrameRewardPanel",
}) do
    local panel = _G[panelName]
    if panel then
        panel:HookScript("OnShow", TintNpcDialogText)
    end
end

-- GossipFrame (Blizzard_UIPanels_Game/Shared/GossipFrameShared.lua +
-- Mainline/GossipFrame.lua) is the OTHER half of the NPC interaction
-- screen - the initial gossip/quest-list greeting (what QUEST_GREETING used
-- to show on its own in classic), separate from the QuestFrame panels above
-- which only take over once a specific quest is clicked into. Its rows are
-- virtualized by an internal WowScrollBoxList view that recycles a small
-- pool of row frames, so walking the scroll box's current children (like
-- TintFontStringRegionsOf above) would miss rows created after the walk, or
-- simply not exist yet the moment GossipFrame is shown. Hooking the mixin
-- Setup methods XML assigns to each row template instead sidesteps that:
-- hooksecurefunc replaces the function stored in the shared mixin TABLE, and
-- Mixin() only copies a table's functions onto a row frame the first time
-- one is created (GossipFrameSharedMixin:Update lazily creates exactly one
-- instance of each row type on the player's first NPC interaction, then
-- reuses it for every NPC afterward) - so installing these hooks here at
-- addon-load time, always before that first interaction, is enough to catch
-- every future :Setup() call. Same pattern already used above for
-- EditModeActionBarSystemMixin and MainActionBarMixin.
if GossipGreetingTextMixin then
    hooksecurefunc(GossipGreetingTextMixin, "Setup", function(self)
        TintSingleFontString(self.GreetingText, "npctext")
    end)
end

local function TintGossipButtonText(self)
    if self.GetFontString then
        TintSingleFontString(self:GetFontString(), "npctext")
    end
end
if GossipOptionButtonMixin then
    hooksecurefunc(GossipOptionButtonMixin, "Setup", TintGossipButtonText)
end
if GossipAvailableQuestButtonMixin then
    hooksecurefunc(GossipAvailableQuestButtonMixin, "Setup", TintGossipButtonText)
end
if GossipActiveQuestButtonMixin then
    hooksecurefunc(GossipActiveQuestButtonMixin, "Setup", TintGossipButtonText)
end

-- Belt-and-suspenders on top of the per-row hooks above: GossipFrame itself
-- (unlike the virtual row templates) is a real, non-virtual, toplevel frame
-- that's already fully created by the time addons load, so hooking its OWN
-- Update method (a plain function field on the GossipFrame instance, safe to
-- hooksecurefunc the same way CompactPartyFrame_Generate is hooked above)
-- and re-walking its ScrollBox with TintFontStringRegionsOf afterward
-- directly re-tints whatever is actually on screen for this NPC, regardless
-- of exactly which internal pooling path put it there. Deferred a frame so
-- this never runs on the same call stack as whatever triggered the update.
if GossipFrame then
    local function TintGossipScrollBoxText()
        C_Timer.After(0, function()
            TintFontStringRegionsOf(GossipFrame.GreetingPanel and GossipFrame.GreetingPanel.ScrollBox, "npctext")
        end)
    end
    if GossipFrame.Update then
        hooksecurefunc(GossipFrame, "Update", TintGossipScrollBoxText)
    end
    GossipFrame:HookScript("OnShow", TintGossipScrollBoxText)
end

-- Slot-style buttons (action buttons, bag buttons, equipment slots) draw
-- their border separately from their contents (an item/spell icon), so
-- tinting only the border darkens the slot frame without touching whatever
-- icon happens to be sitting inside it. Different button templates name
-- their border piece differently: classic-style ItemButtonTemplate slots
-- use GetNormalTexture(), while modern ActionButtonTemplate slots use a
-- named "SlotArt" region when filled and "SlotBackground" when empty
-- (Blizzard_ActionBar/Mainline/ActionButtonTemplate.xml) - try all of them.
local BUTTON_BORDER_KEYS = { "SlotArt", "SlotBackground" }

local function TintButtonBorder(button, category)
    if not button then
        return
    end
    if button.GetNormalTexture then
        TintSingleTexture(button:GetNormalTexture(), category)
    end
    for _, key in ipairs(BUTTON_BORDER_KEYS) do
        TintSingleTexture(button[key], category)
    end
end

local function TintButtonBordersOf(frame, category)
    if not frame or not frame.GetChildren then
        return
    end
    for _, child in ipairs({ frame:GetChildren() }) do
        TintButtonBorder(child, category)
    end
end

-- Generic catch-all for toggled panels: ShowUIPanel(frame, ...) is the
-- shared, version-stable entry point standard windows use to open (bags,
-- character, spellbook, quest log, friends, merchant, ...), so hooking it
-- catches them by behavior instead of guessing frame names. We still map
-- known names to their own category so each window gets its own slider;
-- anything unrecognized falls into "other" rather than a wrong bucket.
local FRAME_CATEGORIES = {
    ContainerFrameCombinedBags = "bags",
    CharacterFrame = "character",
    PaperDollItemsFrame = "character",
    MerchantFrame = "merchant",
    FriendsFrame = "friends",
    QuestMapFrame = "questmap",
    SpellBookFrame = "spellbook",
    QuestFrame = "npctext", -- the quest detail/progress/reward panels shown after picking a specific quest
    GossipFrame = "npctext", -- the initial gossip/quest-list greeting shown when talking to an NPC
}

hooksecurefunc("ShowUIPanel", function(frame)
    local name = frame and frame.GetName and frame:GetName()
    local category = (name and FRAME_CATEGORIES[name]) or "other"
    TintTextureRegionsOf(frame, category)
end)

-- LootFrame (Blizzard_UIPanels_Game/Mainline/LootFrame.xml) pops open via
-- LootFrame:Show() driven by the LOOT_OPENED event, never through
-- ShowUIPanel, so the generic hook above never reaches it. It already has a
-- plain (non-secure) OnShow script, so HookScript is safe here - it chains
-- onto Blizzard's own handler instead of replacing it.
if LootFrame then
    LootFrame:HookScript("OnShow", function()
        TintTextureRegionsOf(LootFrame, "loot")
    end)
end

-- Persistent HUD pieces that are never routed through ShowUIPanel (they're
-- already on screen at login, not toggled open/closed), plus a defensive
-- pass over the core windows above in case ShowUIPanel never fires for them
-- (e.g. they were already open before this addon loaded).
local PERSISTENT_FRAMES = {
    { name = "MinimapCluster", category = "minimap" },
    { name = "MinimapBackdrop", category = "minimap" }, -- round ring texture (atlas ui-hud-minimap-frame) lives here
    { name = "ObjectiveTrackerFrame", category = "tracker" },
    { name = "BagsBar", category = "bagbar" }, -- the row of bag-toggle buttons next to the minimap cluster
    { name = "StatusTrackingBarManager", category = "actionbars" },
    { name = "ContainerFrameCombinedBags", category = "bags" },
    { name = "CharacterFrame", category = "character" },
    { name = "PaperDollItemsFrame", category = "character" }, -- equipment slots on the character panel
    { name = "MerchantFrame", category = "merchant" },
    { name = "FriendsFrame", category = "friends" },
    { name = "QuestMapFrame", category = "questmap" },
    { name = "SpellBookFrame", category = "spellbook" },
}
for _, bar in ipairs(ACTION_BARS) do
    table.insert(PERSISTENT_FRAMES, { name = bar.name, category = bar.category })
end

-- Frames whose child buttons need their slot border (not their icon)
-- darkened via TintButtonBordersOf's frame:GetChildren() walk - see above.
-- Action bars and BagsBar are deliberately NOT listed here:
-- - Every action button is parented to a "ButtonContainer" wrapper frame,
--   not to the bar itself (ActionBarMixin:ActionBar_OnLoad in
--   Blizzard_ActionBar/Shared/ActionBar.lua creates buttonContainer, then
--   parents the actual CheckButton to THAT), so bar:GetChildren() only ever
--   finds those containers - which have no SlotArt/NormalTexture of their
--   own - and TintButtonBorder silently no-ops on all of them.
-- - BagsBar's 4 non-backpack bag buttons are nested inside a BagSlotCluster
--   child frame (Blizzard_MainMenuBarBagButtons/Mainline/
--   MainMenuBarBagButtons.xml), not direct children of BagsBar either -
--   GetChildren() only reaches the backpack button. TintBagBarButtons below
--   uses MainMenuBarBagManager:EnumerateBagButtons() instead, which returns
--   every registered bag button regardless of nesting.
-- PaperDollItemsFrame's equipment slots ARE plain direct children, so
-- GetChildren() genuinely works there.
local BUTTON_BAR_FRAMES = {
    { name = "PaperDollItemsFrame", category = "character" },
}

-- Bag buttons are ItemButton widgets, not the ActionButtonTemplate lineage
-- TintButtonBorder targets - GetNormalTexture() exists and does get tinted,
-- but a live region dump showed the actual visible gold border comes from
-- separate, unnamed Texture regions only reachable via GetRegions()
-- (repeated hits on fileID 7948326 - the same UI-HUD-ActionBar-IconFrame
-- sprite sheet action buttons use - all still at full vertex-color
-- brightness). Tint every region except the bag's own icon, the same
-- exclusion TintTextureRegionsOf's CHROME_CHILD_KEYS design avoids more
-- generally elsewhere in this file - this keeps the icon artwork itself
-- untouched while catching whichever named/unnamed piece draws that border.
local function TintBagButtonChrome(button, category)
    if not button or not button.GetRegions then
        return
    end
    for _, region in ipairs({ button:GetRegions() }) do
        if region ~= button.icon and region ~= button.Icon
            and region.GetObjectType and region:GetObjectType() == "Texture" then
            TintSingleTexture(region, category)
        end
    end
end

-- See the BUTTON_BAR_FRAMES comment above: this reaches every registered
-- bag button (backpack + the 4 nested bag slots) regardless of which frame
-- actually parents it.
local function TintBagBarButtons()
    if not MainMenuBarBagManager or not MainMenuBarBagManager.EnumerateBagButtons then
        return
    end
    for _, button in MainMenuBarBagManager:EnumerateBagButtons() do
        TintButtonBorder(button, "bagbar")
        TintBagButtonChrome(button, "bagbar")
    end
end

-- Chained global lookups for pieces nested too deep for CHROME_CHILD_KEYS
-- to reach, e.g. MainActionBar.EndCaps.LeftEndCap's gryphon-head texture
-- (Blizzard_ActionBar/Camelot/MainMenuBarEndCaps.xml). Tagged with their own
-- "actionbar_endcaps" category (see OVERALL_LINKED_EXTRAS above), not
-- "actionbar_main", so the end caps can be darkened separately from the
-- main action bar's own plaque/buttons instead of always riding the same
-- slider as them.
local PERSISTENT_DEEP_PATHS = {
    { path = { "MainActionBar", "EndCaps", "LeftEndCap" }, category = "actionbar_endcaps" },
    { path = { "MainActionBar", "EndCaps", "RightEndCap" }, category = "actionbar_endcaps" },
}

local function ResolveDeepChild(path)
    local obj = _G[path[1]]
    for i = 2, #path do
        if not obj then
            return nil
        end
        obj = obj[path[i]]
    end
    return obj
end

-- Player/Target/Focus/Pet frames' portrait/bar border art and their
-- HealthBar/Mana(Power)Bar. Most of these pieces have no global name, only
-- nested parentKeys (PetFrame is the exception - its pieces are all plain
-- globals) - reached with ResolveDeepChild the same way as EndCaps above.
-- Borders are plain Textures (TintSingleTexture); the bars are StatusBars,
-- so their fill texture needs GetStatusBarTexture() first.
--
-- CompactUnitFrame's party/raid frames are handled separately below, not
-- here: CompactUnitFrame_UpdateHealthColor already produced a "secret
-- value" taint crash once in this project (see WabaQuest history) by
-- comparing protected health-derived numbers, and it also actively repaints
-- frame.healthBar/frame.background on every health update - fighting it
-- for those pieces would just get overwritten. These four frames use plain
-- TargetFrameHealthBarMixin/PetHealthBarMixin-style StatusBars with no such
-- logic, so this never reads or compares Blizzard's health value at all:
-- GetStatusBarTexture() just returns the widget reference, and
-- SetVertexColor only ever multiplies whatever color Blizzard already
-- assigned, the same safe, standard operation already used everywhere else
-- in this file.
local SIMPLE_UNIT_FRAMES = {
    {
        category = "unitframe_player",
        border = { "PlayerFrame", "PlayerFrameContainer", "FrameTexture" },
        healthBar = { "PlayerFrame", "PlayerFrameContent", "PlayerFrameContentMain", "HealthBarsContainer", "HealthBar" },
        powerBar = { "PlayerFrame", "PlayerFrameContent", "PlayerFrameContentMain", "ManaBarArea", "ManaBar" },
    },
    {
        category = "unitframe_target",
        border = { "TargetFrame", "TargetFrameContainer", "FrameTexture" },
        healthBar = { "TargetFrame", "TargetFrameContent", "TargetFrameContentMain", "HealthBarsContainer", "HealthBar" },
        powerBar = { "TargetFrame", "TargetFrameContent", "TargetFrameContentMain", "ManaBar" },
    },
    {
        -- FocusFrame inherits TargetFrameTemplate, so it carries the exact
        -- same parentKey names (TargetFrameContainer, TargetFrameContent,
        -- etc.) under the FocusFrame global instead of TargetFrame.
        category = "unitframe_target",
        border = { "FocusFrame", "TargetFrameContainer", "FrameTexture" },
        healthBar = { "FocusFrame", "TargetFrameContent", "TargetFrameContentMain", "HealthBarsContainer", "HealthBar" },
        powerBar = { "FocusFrame", "TargetFrameContent", "TargetFrameContentMain", "ManaBar" },
    },
    {
        category = "unitframe_pet",
        border = { "PetFrameTexture" },
        healthBar = { "PetFrameHealthBar" },
        powerBar = { "PetFrameManaBar" },
    },
}

local function TintStatusBarFill(statusBar, category)
    if not statusBar or not statusBar.GetStatusBarTexture then
        return
    end
    TintSingleTexture(statusBar:GetStatusBarTexture(), category)
end

local function TintSimpleUnitFrames()
    for _, unitFrame in ipairs(SIMPLE_UNIT_FRAMES) do
        TintSingleTexture(ResolveDeepChild(unitFrame.border), unitFrame.category)
        TintStatusBarFill(ResolveDeepChild(unitFrame.healthBar), unitFrame.category)
        TintStatusBarFill(ResolveDeepChild(unitFrame.powerBar), unitFrame.category)
    end
end

-- CompactPartyFrame/CompactRaidGroup (Blizzard_UnitFrame/Shared/
-- CompactPartyFrame.xml/.lua and CompactRaidGroup.xml/.lua): darkens only
-- each group's outer border/background frame (a plain Texture on atlas
-- "options_frame_child" - CompactPartyFrameBorderFrame for the party, and
-- CompactRaidGroup1BorderFrame..CompactRaidGroup8BorderFrame for raid
-- groups, since CompactPartyFrameTemplate and CompactRaidGroupTemplate
-- share this same borderFrame structure), never anything on the individual
-- member frames (CompactPartyFrameMember1-5, CompactRaidGroup#MemberN).
-- CompactUnitFrame_UpdateHealthColor (Blizzard_UnitFrame/Shared/
-- CompactUnitFrame.lua) actively repaints frame.healthBar and
-- frame.background via SetVertexColor/SetStatusBarColor on every health
-- update, and reads frame.healthBar:GetStatusBarColor() to decide whether
-- to - the same comparison that threw a "secret value" taint error once in
-- this project (see WabaQuest history). Neither border frame is ever
-- touched by that function, so tinting them carries none of that risk:
-- it's the exact same plain TintTextureRegionsOf call already used for
-- dozens of other frames in this file, just aimed at frames Blizzard's
-- health-color logic doesn't know exist.
--
-- Both groups are created lazily on first use (CompactPartyFrame_Generate
-- takes no arguments; CompactRaidGroup_GenerateForGroup takes the group
-- index), not at login, if the player isn't already grouped - hooking these
-- (plain top-level functions, not mixin methods shared with any per-tick
-- health-update call chain) catches them whenever a party/raid actually
-- forms. hooksecurefunc's hook receives the CALL's arguments, not the
-- hooked function's return values, so there's no "didCreate" to check here
-- (unlike what the return value offers) - just re-tint unconditionally,
-- which is a cheap no-op via TintSingleTexture's de-dup on repeat calls.
local NUM_RAID_GROUPS = 8

local function TintCompactPartyFrameBorder()
    TintTextureRegionsOf(_G["CompactPartyFrameBorderFrame"], "unitframe_party")
end

local function TintCompactRaidGroupBorder(groupIndex)
    TintTextureRegionsOf(_G["CompactRaidGroup" .. groupIndex .. "BorderFrame"], "unitframe_party")
end

local function TintAllCompactRaidGroupBorders()
    for i = 1, NUM_RAID_GROUPS do
        TintCompactRaidGroupBorder(i)
    end
end

hooksecurefunc("CompactPartyFrame_Generate", TintCompactPartyFrameBorder)
hooksecurefunc("CompactRaidGroup_GenerateForGroup", TintCompactRaidGroupBorder)

-- Extra action bar art: each extra bar (everything in ACTION_BARS except
-- the Main Action Bar) carries its own Edit Mode "Hide Bar Art" setting
-- (Enum.EditModeActionBarSetting.HideBarArt) that decides whether its
-- buttons use the Main Action Bar's ornate UI-HUD-ActionBar-IconFrame
-- border or the plain IconFrame-AddRow one (see
-- EditModeActionBarSystemMixin:UpdateSystemSettingHideBarArt and
-- BaseActionButtonMixin:UpdateButtonArt in the Blizzard UI source) - but
-- this client's Edit Mode panel doesn't surface that checkbox for these
-- bars, so a bar stuck on the plain art can't be fixed in-game.

-- Sets a button's border art directly by manipulating its Texture objects
-- and NormalTexture/PushedTexture (plain, unprotected Button API - the same
-- kind of call TintButtonBorder already makes elsewhere in this file), never
-- by calling into a Blizzard mixin method like UpdateButtonArt or
-- UpdateSystemSettingHideBarArt. Those mixin calls run as insecure addon
-- code reaching into Blizzard's own EditMode/ActionBar logic, and doing that
-- from inside a hook that fires mid-way through Edit Mode's own setup is
-- what tainted a whole Edit Mode entry once already. Reproducing the atlas
-- swap ourselves (values from BaseActionButtonMixin:UpdateButtonArt in
-- Blizzard_ActionBar/Mainline/ActionButtonOverrides.lua) keeps this to the
-- same plain texture/atlas calls the rest of Skin.lua already uses safely.
local function SetButtonBarArt(button, showOrnateArt)
    if not (button.SlotArt and button.SlotBackground and button.NormalTexture and button.PushedTexture) then
        return
    end
    if showOrnateArt then
        button.SlotArt:Show()
        button.SlotBackground:Hide()
        button:SetNormalAtlas("UI-HUD-ActionBar-IconFrame")
        button.NormalTexture:SetSize(46, 45)
        button:SetPushedAtlas("UI-HUD-ActionBar-IconFrame-Down")
        button.PushedTexture:SetSize(46, 45)
    else
        button.SlotArt:Hide()
        button.SlotBackground:Show()
        button:SetNormalAtlas("UI-HUD-ActionBar-IconFrame-AddRow")
        button.NormalTexture:SetSize(51, 51)
        button:SetPushedAtlas("UI-HUD-ActionBar-IconFrame-AddRow-Down")
        button.PushedTexture:SetSize(51, 51)
    end
end

-- Neither the Main Action Bar's native BorderArt nor our cloned copy of it
-- below turned out to be more than a thin frame/corner graphic - there's no
-- actual filled background behind the buttons to darken, just the game
-- world showing through the gaps (confirmed live: BorderArt's own vertex
-- color already tracks the slider correctly, it's just not opaque). This
-- gives every bar a real one: a plain color fill, sitting one layer further
-- back than BorderArt so its frame trim still draws on top. Being a flat
-- color rather than a stretched image, it doesn't distort on the vertical
-- bars the way BorderArt's atlas would, so every bar gets one, not just the
-- horizontal ones - and it's plugged into the normal tinted-texture list
-- (WabaDark.tinted) like everything else, so it darkens with the same
-- slider and disappears (not just lightens) when WabaDark is turned off,
-- matching "toggling WabaDark off restores the exact original look" - a
-- panel Blizzard never drew shouldn't linger at some in-between color.
local PANEL_BASE_COLOR = { 0.35, 0.27, 0.16, 1 }

local function EnsureBackgroundPanel(bar, category)
    if bar.WabaDarkBackgroundPanel then
        return bar.WabaDarkBackgroundPanel
    end
    local panel = bar:CreateTexture(nil, "BACKGROUND", nil, -4)
    panel:SetColorTexture(unpack(PANEL_BASE_COLOR))
    panel:SetPoint("TOPLEFT", bar, "TOPLEFT", -6, 6)
    panel:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 4, -5)
    bar.WabaDarkBackgroundPanel = panel

    -- Declared, then assigned separately (not `local entry = { ... entry ... }`)
    -- because the closure below needs to see this SAME local on every call -
    -- a table constructor's own fields can't see the local it's initializing.
    local entry
    entry = {
        category = category,
        apply = function(enabled)
            if enabled then
                panel:Show()
                panel:SetVertexColor(TintColorFor(PANEL_BASE_COLOR, GetDarkTarget(entry.category), entry.category))
            else
                panel:Hide()
            end
        end,
    }
    WabaDark.tintedByFrame[panel] = entry
    table.insert(WabaDark.tinted, entry)
    entry.apply(IsEnabled())

    return panel
end

-- The Main Action Bar has a "BorderArt" background texture connecting its
-- buttons into one plaque (Blizzard_ActionBar/Mainline/MainActionBar.xml,
-- same atlas and anchor offsets used here); the extra bars don't have this
-- piece at all - it's not hidden, it's simply never created for them.
local function EnsureBorderArt(bar)
    if bar.BorderArt then
        return bar.BorderArt
    end
    local borderArt = bar:CreateTexture(nil, "BACKGROUND", nil, -3)
    borderArt:SetAtlas("UI-HUD-ActionBar-Frame")
    borderArt:SetPoint("TOPLEFT", bar, "TOPLEFT", -6, 6)
    borderArt:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 4, -5)
    bar.BorderArt = borderArt
    return borderArt
end

local function SetBarArt(bar, barEntry, showOrnateArt)
    bar.hideBarArt = not showOrnateArt
    local borderArt = barEntry.horizontal and EnsureBorderArt(bar) or nil
    if borderArt then
        borderArt:SetShown(showOrnateArt)
    end
    for _, button in pairs(bar.actionButtons or {}) do
        SetButtonBarArt(button, showOrnateArt)
        -- Registers the button's textures for dark-mode tinting the first
        -- time (these bars aren't necessarily seen yet by the login pass
        -- above when this runs first), and is a cheap no-op afterwards.
        TintButtonBorder(button, barEntry.category)
    end
    -- Picks up the newly-created BorderArt (and anything else on the bar)
    -- for the same tinting, and re-applies dark-mode's already-captured
    -- tint on every call: SetNormalAtlas above resets a texture's vertex
    -- color on this client, which would otherwise silently undo darkening
    -- every time bar art gets forced again (e.g. on every Edit Mode visit).
    TintTextureRegionsOf(bar, barEntry.category)
    WabaDark:RefreshCategory(barEntry.category)
end

-- Re-applies the current setting to every extra bar. Deferred a frame via
-- C_Timer.After so this never runs on the same call stack as whatever
-- triggered it (login, a settings checkbox, Edit Mode opening) - a hook
-- that did real work inline here once tainted a whole Edit Mode entry.
function WabaDark:RefreshForcedActionBarArt()
    C_Timer.After(0, function()
        local enabled = self.settings and self.settings.forceActionBarArt
        for _, barEntry in ipairs(ACTION_BARS) do
            if not barEntry.isMain then
                local bar = _G[barEntry.name]
                if bar then
                    SetBarArt(bar, barEntry, enabled)
                end
            end
        end
    end)
end

function WabaDark:SetForceActionBarArt(enabled)
    self.settings.forceActionBarArt = enabled
    self:RefreshForcedActionBarArt()
end

-- Blizzard recomputes hideBarArt on its own for every EditModeActionBarSystemMixin
-- bar - including the Main Action Bar - whenever Edit Mode re-applies a
-- layout. For the extra bars that would silently undo our forced art (and,
-- via the vertex-color-reset side effect above, the darkening too); for the
-- Main Action Bar it doesn't touch hideBarArt at all, but the same
-- vertex-color reset still applies to whatever native art it just
-- reapplied, which is why its own background used to stop darkening after
-- opening Edit Mode. Reassert forced art on the extra bars, and just
-- re-tint the Main Action Bar (never touching its native art/hideBarArt).
hooksecurefunc(EditModeActionBarSystemMixin, "UpdateSystemSettingHideBarArt", function(bar)
    local name = bar.GetName and bar:GetName()
    local barEntry = name and ACTION_BAR_BY_NAME[name]
    if not barEntry then
        return
    end
    if not barEntry.isMain and WabaDark.settings and WabaDark.settings.forceActionBarArt then
        WabaDark:RefreshForcedActionBarArt()
    else
        C_Timer.After(0, function()
            WabaDark:RefreshCategory(barEntry.category)
        end)
    end
end)

-- The Main Action Bar draws thin dividers between groups of buttons
-- (MainActionBarMixin:UpdateDividers in Blizzard_ActionBar/Shared/
-- MainActionBar.lua) using pooled nine-slice frames (ThreeSliceVerticalLayout/
-- ThreeSliceHorizontalLayout - TopEdge/BottomEdge/Center pieces). They were
-- never tinted, but only became a visibly wrong bright seam once the buttons
-- around them started actually darkening (the actionButtons fix above) -
-- before that everything nearby was similarly bright and it blended in.
-- Only the Main Action Bar has enableDividers set, so this never applies to
-- the extra bars. EnumerateActive + TintTextureRegionsOf (not
-- GetBorderColor/SetBorderColor) is used deliberately: a divider's pieces
-- are plain Texture regions, reachable that way regardless of exactly which
-- nine-slice piece names this layout type uses.
local function TintMainActionBarDividers()
    local mainBar = _G["MainActionBar"]
    local barEntry = mainBar and ACTION_BAR_BY_NAME[mainBar:GetName()]
    if not barEntry then
        return
    end
    if mainBar.HorizontalDividersPool then
        for divider in mainBar.HorizontalDividersPool:EnumerateActive() do
            TintTextureRegionsOf(divider, barEntry.category)
        end
    end
    if mainBar.VerticalDividersPool then
        for divider in mainBar.VerticalDividersPool:EnumerateActive() do
            TintTextureRegionsOf(divider, barEntry.category)
        end
    end
end

-- Catches dividers created later (Edit Mode entry/exit, icon size or count
-- changes all call UpdateDividers again).
hooksecurefunc(MainActionBarMixin, "UpdateDividers", TintMainActionBarDividers)

local function SkinPersistentFrames()
    -- Catches dividers already created before this addon's hook was
    -- installed (Blizzard's own UI loads before addons, and the initial
    -- UpdateDividers call happens as part of that).
    TintMainActionBarDividers()
    TintBagBarButtons()
    TintSimpleUnitFrames()
    TintCompactPartyFrameBorder() -- defensive: catches CompactPartyFrame/CompactRaidGroups already existing (player was already grouped before login)
    TintAllCompactRaidGroupBorders()

    for _, bar in ipairs(ACTION_BARS) do
        local barFrame = _G[bar.name]
        if barFrame then
            EnsureBackgroundPanel(barFrame, bar.category)
            -- The real fix for action bar buttons never being reached by
            -- TintButtonBordersOf (see BUTTON_BAR_FRAMES above): go straight
            -- to barFrame.actionButtons, the same array SetBarArt already
            -- uses for the extra bars, instead of GetChildren().
            for _, button in pairs(barFrame.actionButtons or {}) do
                TintButtonBorder(button, bar.category)
            end
        end
    end

    for _, entry in ipairs(PERSISTENT_FRAMES) do
        TintTextureRegionsOf(_G[entry.name], entry.category)
    end

    for _, entry in ipairs(PERSISTENT_DEEP_PATHS) do
        TintTextureRegionsOf(ResolveDeepChild(entry.path), entry.category)
    end

    for _, entry in ipairs(BUTTON_BAR_FRAMES) do
        TintButtonBordersOf(_G[entry.name], entry.category)
    end

    local numChatWindows = NUM_CHAT_WINDOWS or 10
    for i = 1, numChatWindows do
        TintTextureRegionsOf(_G["ChatFrame" .. i], "chat")
        TintTextureRegionsOf(_G["ChatFrame" .. i .. "Tab"], "chat")
    end

    WabaDark:RefreshForcedActionBarArt()
end

local skinFrame = CreateFrame("Frame")
skinFrame:RegisterEvent("PLAYER_LOGIN")
skinFrame:SetScript("OnEvent", SkinPersistentFrames)

function WabaDark:ApplyAll()
    for _, entry in ipairs(self.tinted) do
        entry.apply(true)
    end
end

function WabaDark:RevertAll()
    for _, entry in ipairs(self.tinted) do
        entry.apply(false)
    end
end

-- Re-applies the current intensity to everything already tinted in one
-- category, so dragging its slider updates on-screen frames immediately.
-- Category "overall" refreshes everything, since it multiplies every other
-- category's value. Refreshing "actionbars" (the master action-bar slider)
-- also refreshes any individual action bar currently set to "use overall",
-- since those entries are still tagged with their own actionbar_* category,
-- not "actionbars" - GetIntensity is what actually redirects them.
function WabaDark:RefreshCategory(category)
    local enabled = IsEnabled()
    local useOverallMap = self.settings and self.settings.actionBarUseOverall
    for _, entry in ipairs(self.tinted) do
        local matches = category == "overall"
            or entry.category == category
            or (category == "actionbars" and useOverallMap and useOverallMap[entry.category])
        if matches then
            entry.apply(enabled)
        end
    end
end
