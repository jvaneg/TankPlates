local DEBUG = false
local DEBUG_VERBOSE = false -- Set to true for ALL debug messages

local function tp_print(msg)
  if type(msg) == "boolean" then msg = msg and "true" or "false" end
  DEFAULT_CHAT_FRAME:AddMessage(msg)
end

local function debug_print(msg)
  if DEBUG and DEBUG_VERBOSE then
    tp_print(msg)
  end
end

local function debug_always(msg)
  if DEBUG then
    tp_print(msg)
  end
end

-- Localization
local SUPERWOW_REQ
local cc_spells

if (GetLocale() == "ruRU") then
  SUPERWOW_REQ = "[|cff00ff00Tank|cffff0000Plates|r] для работы требует |cffffd200SuperWoW|r."
  cc_spells = {
    "Превращение",
    "Сковывание нежити",
    "Замораживающая ловушка",
    "Спячка",
    "Парализующий удар",
    "Ошеломление",
    "Волшебная пыль",
  }
else
  SUPERWOW_REQ = "[|cff00ff00Tank|cffff0000Plates|r] requires |cffffd200SuperWoW|r to operate."
  cc_spells = {
    "Polymorph",
    "Shackle Undead",
    "Freezing Trap",
    "Hibernate",
    "Gouge",
    "Sap",
    "Magic Dust",
  }
end

-- stop loading addon if no superwow
if not SetAutoloot then
  DEFAULT_CHAT_FRAME:AddMessage(SUPERWOW_REQ)
  return
end

-- Core variables
local player_guid = nil
local tracked_guids = {}
local tanks = {}  -- Array of {name = player_name, guid = guid}

-- in combat colours (filled at runtime from TankPlates_config by LoadColors)
local IN_COMBAT_UNIT_COLORS = {}

-- out of combat colours (filled at runtime from TankPlates_config by LoadColors)
local OUT_OF_COMBAT_UNIT_COLORS = {}

-- ============================================================
-- Colour config: defaults, persistence, and runtime loading
-- ============================================================

-- Hardcoded defaults stored as "r,g,b,a" strings (ShaguPlates convention).
-- These are written into TankPlates_config the first time the addon loads.
local TP_COLOR_DEFAULTS = {
  in_attacking_you     = "0.6,1,0,0.8",
  in_attacking_squishy = "0.9,0.2,0.3,0.8",
  in_crowd_controlled  = "1,1,0.3,0.8",
  in_attacking_tank    = "0.5,0.7,0.3,0.8",
  out_enemy_npc        = "0.9,0.2,0.3,0.8",
  out_neutral_npc      = "1,1,0.3,0.8",
  out_friendly_npc     = "0.6,1,0,0.8",
  out_enemy_player     = "0.9,0.2,0.3,0.8",
  out_friendly_player  = "0.2,0.6,1,0.8",
}

-- Parse a "r,g,b,a" color string into four numbers.
local function TP_ParseColor(s)
  local t = {}
  for v in string.gmatch(tostring(s or ""), "[^,]+") do
    table.insert(t, tonumber(v) or 1)
  end
  return (t[1] or 1), (t[2] or 1), (t[3] or 1), (t[4] or 1)
end

-- Sync TankPlates_config color strings into the live runtime color tables.
-- Called once on VARIABLES_LOADED and again after any in-game color change.
local function LoadColors()
  local c = TankPlates_config
  IN_COMBAT_UNIT_COLORS["ATTACKING_YOU"] = { TP_ParseColor(c.in_attacking_you) }
  IN_COMBAT_UNIT_COLORS["ATTACKING_SQUISHY"] = { TP_ParseColor(c.in_attacking_squishy) }
  IN_COMBAT_UNIT_COLORS["CROWD_CONTROLLED"] = { TP_ParseColor(c.in_crowd_controlled) }
  IN_COMBAT_UNIT_COLORS["ATTACKING_TANK"] = { TP_ParseColor(c.in_attacking_tank) }
  OUT_OF_COMBAT_UNIT_COLORS["ENEMY_NPC"] = { TP_ParseColor(c.out_enemy_npc) }
  OUT_OF_COMBAT_UNIT_COLORS["NEUTRAL_NPC"] = { TP_ParseColor(c.out_neutral_npc) }
  OUT_OF_COMBAT_UNIT_COLORS["FRIENDLY_NPC"] = { TP_ParseColor(c.out_friendly_npc) }
  OUT_OF_COMBAT_UNIT_COLORS["ENEMY_PLAYER"] = { TP_ParseColor(c.out_enemy_player) }
  OUT_OF_COMBAT_UNIT_COLORS["FRIENDLY_PLAYER"] = { TP_ParseColor(c.out_friendly_player) }
end

-- ============================================================
-- Colour settings UI
-- ============================================================

-- Build the settings frame once and cache it in TankPlatesSettingsFrame.
-- Uses ShaguPlates.api.CreateBackdrop / SkinButton for visual consistency,
-- and Blizzard's built-in ColorPickerFrame (the same colour wheel ShaguPlates
-- itself uses) for colour selection.
local function TP_BuildSettingsFrame()
  -- Frame already created on a previous call – reuse it.
  if TankPlatesSettingsFrame then
    return TankPlatesSettingsFrame
  end

  -- ShaguPlates api helpers (not plain globals; must be accessed via ShaguPlates.api)
  local CreateBackdrop = ShaguPlates.api.CreateBackdrop
  local SkinButton = ShaguPlates.api.SkinButton

  local f = CreateFrame("Frame", "TankPlatesSettingsFrame", UIParent)
  f:SetWidth(280)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:SetFrameStrata("DIALOG")
  f:SetToplevel(true)
  f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  f:Hide()

  -- ShaguPlates-styled backdrop (always available via RequiredDeps)
  CreateBackdrop(f)

  -- Dragging
  f:SetScript("OnMouseDown", function() this:StartMoving() end)
  f:SetScript("OnMouseUp",   function() this:StopMovingOrSizing() end)

  -- Title
  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOP", f, "TOP", 0, -10)
  title:SetText("TankPlates Colors")

  -- Close button
  local closeBtn = CreateFrame("Button", "TankPlatesSettingsClose", f, "UIPanelCloseButton")
  closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
  closeBtn:SetScript("OnClick", function() f:Hide() end)

  -- Layout cursor and swatch registry (for Reset)
  local yOffset = -28
  local swatches = {}

  local function AddSectionHeader(text)
    local hdr = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hdr:SetPoint("TOPLEFT", f, "TOPLEFT", 14, yOffset)
    hdr:SetText("|cffffff88" .. text .. "|r")
    yOffset = yOffset - 18
  end

  local function AddColorRow(key, label)
    -- Row label
    local lbl = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lbl:SetPoint("TOPLEFT", f, "TOPLEFT", 14, yOffset)
    lbl:SetText(label)

    -- Colour swatch button
    local swatch = CreateFrame("Button", nil, f)
    swatch:SetWidth(28)
    swatch:SetHeight(14)
    swatch:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, yOffset + 3)
    CreateBackdrop(swatch)

    -- Preview texture fills the swatch
    swatch.preview = swatch.backdrop:CreateTexture(nil, "OVERLAY")
    swatch.preview:SetAllPoints(swatch.backdrop)

    -- Seed preview from current config value
    local r, g, b, a = TP_ParseColor(TankPlates_config[key])
    swatch.preview:SetTexture(r, g, b, a)

    -- Click opens Blizzard's ColorPickerFrame (identical pattern to ShaguPlates)
    swatch:SetScript("OnClick", function()
      local cr, cg, cb, ca = TP_ParseColor(TankPlates_config[key])
      local myPreview = swatch.preview

      ColorPickerFrame.func = function()
        local nr, ng, nb = ColorPickerFrame:GetColorRGB()
        local na = 1 - OpacitySliderFrame:GetValue()
        -- Round to 1 decimal place
        local function rnd(v) return math.floor(v * 10 + 0.5) / 10 end
        nr, ng, nb, na = rnd(nr), rnd(ng), rnd(nb), rnd(na)
        myPreview:SetTexture(nr, ng, nb, na)
        TankPlates_config[key] = nr .. "," .. ng .. "," .. nb .. "," .. na
        LoadColors()
      end

      ColorPickerFrame.cancelFunc = function()
        myPreview:SetTexture(cr, cg, cb, ca)
      end

      ColorPickerFrame.opacityFunc = ColorPickerFrame.func
      ColorPickerFrame.opacity     = 1 - ca
      ColorPickerFrame.hasOpacity  = 1
      ColorPickerFrame:SetColorRGB(cr, cg, cb)
      ColorPickerFrame:SetFrameStrata("DIALOG")
      ShowUIPanel(ColorPickerFrame)
    end)

    table.insert(swatches, { key = key, swatch = swatch })
    yOffset = yOffset - 22
  end

  -- Rows
  AddSectionHeader("In Combat")
  AddColorRow("in_attacking_you",     "Attacking You")
  AddColorRow("in_attacking_squishy", "Non-Tank Has Aggro")
  AddColorRow("in_crowd_controlled",  "Crowd Controlled")
  AddColorRow("in_attacking_tank",    "Other Tank Has Aggro")
  AddSectionHeader("Out of Combat")
  AddColorRow("out_enemy_npc",        "Enemy NPC")
  AddColorRow("out_neutral_npc",      "Neutral NPC")
  AddColorRow("out_friendly_npc",     "Friendly NPC")
  AddColorRow("out_enemy_player",     "Enemy Player")
  AddColorRow("out_friendly_player",  "Friendly Player")

  -- Reset Defaults button
  local resetBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  resetBtn:SetWidth(110)
  resetBtn:SetHeight(20)
  resetBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 14, 10)
  resetBtn:SetText("Reset Defaults")
  resetBtn:SetScript("OnClick", function()
    for k, v in pairs(TP_COLOR_DEFAULTS) do
      TankPlates_config[k] = v
    end
    LoadColors()
    -- Refresh every swatch preview without rebuilding the frame
    for _, entry in ipairs(swatches) do
      local r, g, b, a = TP_ParseColor(TankPlates_config[entry.key])
      entry.swatch.preview:SetTexture(r, g, b, a)
    end
    tp_print("TankPlates colors reset to defaults.")
  end)
  SkinButton(resetBtn)

  -- Size the frame height to fit the content
  f:SetHeight(math.abs(yOffset) + 42)

  return f
end

-- Public toggle – creates frame on first call, then show/hides.
function TP_ToggleSettings()
  local f = TP_BuildSettingsFrame()
  if f:IsShown() then
    f:Hide()
  else
    f:Show()
  end
end

-- ShaguPlates-like unit type detection based on underlying Blizzard nameplate
local function GetUnitTypeFromRGB(red, green, blue)
  if red > .9 and green < .2 and blue < .2 then
    return "ENEMY_NPC"
  elseif red > .9 and green > .9 and blue < .2 then
    return "NEUTRAL_NPC"
  elseif red < .2 and green < .2 and blue > 0.9 then
    return "FRIENDLY_PLAYER"
  elseif red < .2 and green > .9 and blue < .2 then
    return "FRIENDLY_NPC"
  end
end

-- shackle, sheep, hibernate, magic dust, etc
local function UnitIsCC(unit)
  for i=1,40 do
    local dTexture,_,_,spell_id = UnitDebuff(unit,i)
    local name = SpellInfo(spell_id)
    if spell_id and name then
      local name = SpellInfo(spell_id)
      for _,spell in ipairs(cc_spells) do
        if string.find(name,"^"..spell) then
          return true
        end
      end
    end
  end
  return false
end

local function IsTank(guid)
  if not guid then return false end
  
  -- 1. Try exact GUID match (fastest and most accurate)
  for i, tank in ipairs(tanks) do
    if tank.guid == guid then
      return true
    end
  end
  
  -- 2. Fallback to name match (if GUIDs are somehow different)
  -- This handles cases where unit GUIDs might differ from target GUIDs on some servers
  local name = UnitName(guid)
  if name then
    for i, tank in ipairs(tanks) do
      if tank.name == name then
        if DEBUG then
           debug_print("IsTank: GUID mismatch but Name match for " .. name)
        end
        return true
      end
    end
  end
  
  return false
end

local function IsPlayerTank(guid)
  return guid == player_guid
end

-- Copied from shagu since it resembled what I was trying to do anyway
-- [ HookScript ]
-- Securely post-hooks a script handler.
-- 'f'          [frame]             the frame which needs a hook
-- 'script'     [string]            the handler to hook
-- 'func'       [function]          the function that should be added
function HookScript(f, script, func)
  local prev = f:GetScript(script)
  f:SetScript(script, function(a1,a2,a3,a4,a5,a6,a7,a8,a9)
    if prev then prev(a1,a2,a3,a4,a5,a6,a7,a8,a9) end
    func(a1,a2,a3,a4,a5,a6,a7,a8,a9)
  end)
end

local function IsNamePlate(frame)
  local guid = frame:GetName(1)
  return frame and (frame:IsShown() and frame:IsObjectType("Button"))
    and (guid and guid ~= "0x0000000000000000")
    and (frame:GetChildren() and frame:GetChildren():IsObjectType("StatusBar"))
end

local function UpdateTarget(guid,targetArg)
  if not guid then return end
  local _, targeting = UnitExists(guid.."target")
  targeting = targetArg or targeting
  if targeting ~= tracked_guids[guid].current_target then
    -- only update previous target if there is a current one
    if tracked_guids[guid].current_target then
      tracked_guids[guid].previous_target = tracked_guids[guid].current_target
    end
    
    -- Debug target changes
    local mob_name = UnitName(guid)
    local old_target = tracked_guids[guid].current_target and UnitName(tracked_guids[guid].current_target) or "none"
    local new_target = targeting and UnitName(targeting) or "none"
    debug_print("TARGET CHANGE - " .. mob_name .. ": " .. old_target .. " -> " .. new_target .. " [GUID: " .. tostring(targeting) .. "]")
    
    tracked_guids[guid].current_target = targeting
  end
end

local function InitPlate(plate)
  if plate.initialized then return end
  local guid = plate:GetName(1)

  for _, region in ipairs( { plate:GetRegions() } ) do
    if region:IsObjectType("FontString") and region:GetText() then
      local text = region:GetText()
      if not (tonumber(text) ~= nil or text == "??") then
        plate.namefontstring = region
      end
    end
  end

  if not plate.namefontstring then
    debug_print("tried to init a non-plate frame")
    return
  end

  HookScript(plate,"OnUpdate", function ()
    local guid = this:GetName(1)
    if not tracked_guids[guid] then
      debug_print("init loop hasn't grabbed this guid yet")
      return
    end
    tracked_guids[guid].tick = tracked_guids[guid].tick + arg1

    UpdateTarget(guid)

    -- cc check
    if tracked_guids[guid].tick > 0.1 then
      tracked_guids[guid].tick = 0
      tracked_guids[guid].cc = UnitIsCC(guid)
    end
  end)

  local origname = plate.namefontstring:GetText()

  -- helper that selects the correct bar to color; if ShaguPlates has created a
  -- custom overlay we direct our colours there instead of touching the Blizzard
  -- healthbar (which Shagu reads to determine its own colour).  We also tint a
  -- surrounding border/backdrop if one exists.
  local function SetHealthBarColor(bar, r, g, b, a)
    a = a or 1

    -- function that will paint a backdrop if present
    local function paintBorder(obj)
      if obj and obj.backdrop and obj.backdrop.SetBackdropBorderColor then
        obj.backdrop:SetBackdropBorderColor(r, g, b, a)
      elseif obj and obj.SetBackdropBorderColor then
        obj:SetBackdropBorderColor(r, g, b, a)
      end
    end

    if ShaguPlates and plate.nameplate and plate.nameplate.health then
      plate.nameplate.health:SetStatusBarColor(r, g, b, a)
      paintBorder(plate.nameplate.health)
    else
      bar:SetStatusBarColor(r, g, b, a)
      paintBorder(bar)
    end
  end


  local function UpdateHealth()
    local plate = this:GetParent()
    local guid = plate:GetName(1)
    if not guid then
      debug_print("plate didn't have guid?")
      return end
    if not tracked_guids[guid] then
      debug_print("plate init loop hasn't added this guid yet")
      return
    end
    local unit = tracked_guids[guid]

    if UnitIsUnit("target",guid) then
      -- plate.namefontstring:SetTextColor(1,0,1,1)
      plate.namefontstring:SetTextColor(1,1,0,1)
      -- plate.namefontstring:SetTextColor(0.825,0.144,0.825,1)
    else
      plate.namefontstring:SetTextColor(unpack(unit.unit_name_color))
    end

    if DEBUG then
      if unit.current_target then
        plate.namefontstring:SetText(UnitName(unit.current_target))
      else
        plate.namefontstring:SetText(origname)
      end
    end

    -- First, determine if this is a unit we should care to color.
    -- Is the player in combat, and is the unit in combat?
    -- if UnitAffectingCombat("player") and UnitAffectingCombat(guid) then
    if UnitAffectingCombat("player") and UnitAffectingCombat(guid) and
      not UnitCanAssist("player",guid) then -- don't color friendlies

      -- The cases we want 'green' for are:
      -- 1. Being the previous target if a mob is casting on someone else
      -- 2. Being targeted
      -- 3. Being the previous target when a mob has no current target

      local new_reason = nil
      local mob_name = UnitName(guid)
      
      if unit.cc then
        new_reason = "CC"
        SetHealthBarColor(this, unpack(IN_COMBAT_UNIT_COLORS['CROWD_CONTROLLED']))
      elseif (unit.casting and (unit.casting_at == player_guid or unit.previous_target == player_guid)) then
        new_reason = "CastingAtYou"
        -- casting on someone but was attacking you
        SetHealthBarColor(this, unpack(IN_COMBAT_UNIT_COLORS['ATTACKING_YOU']))
      elseif unit.current_target == player_guid then
        new_reason = "AttackingYou"
        -- attacking you
        SetHealthBarColor(this, unpack(IN_COMBAT_UNIT_COLORS['ATTACKING_YOU']))
      elseif not unit.casting and (not unit.current_target and unit.previous_target == player_guid) then
        new_reason = "Fleeing"
        -- fleeing but was attacking you
        SetHealthBarColor(this, unpack(IN_COMBAT_UNIT_COLORS['ATTACKING_YOU']))
      else
        -- not attacking you, check tank assignments
        
        -- Determine effective target for tank checks
        -- Priority: 1. Current Target 2. Casting At 3. Previous Target
        local effective_target = unit.current_target
        
        -- If mob is casting, they might not have a current_target, or we should care about who they are casting at
        if not effective_target and unit.casting and unit.casting_at then
           effective_target = unit.casting_at
        end
        
        -- If still no target (momentary gap), use previous target to prevent flashing
        if not effective_target and unit.previous_target then
           effective_target = unit.previous_target
        end
        
        if IsPlayerTank(effective_target) then
          new_reason = "PlayerTankAggro"
          SetHealthBarColor(this, unpack(IN_COMBAT_UNIT_COLORS['ATTACKING_YOU'])) -- YOU have aggro
        elseif IsTank(effective_target) then
          new_reason = "OtherTankAggro"
          SetHealthBarColor(this, unpack(IN_COMBAT_UNIT_COLORS['ATTACKING_TANK'])) -- other tank has aggro
        else
          new_reason = "NonTankAggro"
          -- non-tank has aggro
          SetHealthBarColor(this, unpack(IN_COMBAT_UNIT_COLORS['ATTACKING_SQUISHY'])) -- attacking other than tanks
        end
      end
      
      -- Only log when reason changes
      if new_reason ~= unit.last_color_reason then
        local target_name = unit.current_target and UnitName(unit.current_target) or "none"
        local prev_target_name = unit.previous_target and UnitName(unit.previous_target) or "none"
        local debug_msg = mob_name .. ": " .. (unit.last_color_reason or "Init") .. " -> " .. new_reason .. " (target: " .. target_name .. ")"
        
        -- Add detailed info for all transitions from OtherTankAggro
        if unit.last_color_reason == "OtherTankAggro" then
          debug_msg = debug_msg .. " [prev_target=" .. prev_target_name .. " IsTank(curr)=" .. tostring(IsTank(unit.current_target)) .. "]"
        end
        
        -- Add detailed GUID info for problematic transitions
        if new_reason == "AttackingYou" and unit.last_color_reason == "OtherTankAggro" then
          debug_msg = debug_msg .. " [BUG! curr=" .. tostring(unit.current_target) .. " player=" .. tostring(player_guid) .. " match=" .. tostring(unit.current_target == player_guid) .. "]"
        end
        
        debug_always(debug_msg)
        unit.last_color_reason = new_reason
      end
    else
      -- not currently applying any special colouring; use the base Blizzard
      -- colour to infer a unit type and fall back to that same colour.  This
      -- mirrors the logic ShaguPlates uses to decide default plate colours.
      local r,g,b,a = this:GetStatusBarColor()

      -- translate the raw colour back into a unit type and override with the
      -- canonical Shagu colours if we know them (keeps consistency when other
      -- addons tweak the raw bar colour).
      local utype = GetUnitTypeFromRGB(r,g,b)
      if utype then
        local col = OUT_OF_COMBAT_UNIT_COLORS[utype]
        if col then
          r, g, b, a = unpack(col)
        end
      end

      unit.healthbar_color = { r, g, b, a }
      SetHealthBarColor(this, r, g, b, a)
    end
  end

  HookScript(plate:GetChildren(), "OnUpdate", UpdateHealth)
  HookScript(plate:GetChildren(), "OnValueChanged", UpdateHealth)

  plate.initialized = true
end

local plateTick = 0
local cleanTick = 0
local function Update()
  plateTick = plateTick + arg1
  cleanTick = cleanTick + arg1
  if plateTick >= 0.075 then
    plateTick = 0 
    for _,plate in pairs({ WorldFrame:GetChildren() }) do
      if IsNamePlate(plate) then
        -- the plate can refer to a different unit constantly, check for new id's here and set the plate logic once
        -- to depend on its current guid
        InitPlate(plate)

        local guid = plate:GetName(1)
        if not tracked_guids[guid] then
          debug_print("adding "..guid.." "..UnitName(guid))
          -- store the original plate text color and health bar color, to revert to when needed
          tracked_guids[guid] = {
            unit_name_color = { plate.namefontstring:GetTextColor() },
            healthbar_color = { plate:GetChildren():GetStatusBarColor() },
            current_target = nil,
            previous_target = nil,
            tick = 0,
            cc = false,
            casting = false,
            casting_at = nil,
            last_color_reason = nil, -- Track last reason for color change
          }
        end
      end
    end
  end
  if cleanTick > 10 then
    local count = 0
    cleanTick = 0
    for guid,_ in pairs(tracked_guids) do
      count = count + 1
      if not UnitExists(guid) then
        tracked_guids[guid] = nil
      end
    end
    debug_print("table size: "..count)
  end
end

-- Helper function to check if name is already in tank list
local function IsInTankList(name)
  for _, tank in ipairs(tanks) do
    if tank.name == name then
      return true
    end
  end
  return false
end

-- Add unit to tank list
function TP_AddUnitToTankList(unit)
  if not UnitExists(unit) then
    tp_print("Unit does not exist")
    return
  end
  
  if not UnitIsPlayer(unit) then
    tp_print("Target must be a player")
    return
  end
  
  local name = UnitName(unit)
  local _, guid = UnitExists(unit)
  
  if IsInTankList(name) then
    tp_print(name .. " is already in the tank list")
    return
  end
  
  table.insert(tanks, {name = name, guid = guid})
  tp_print("Added " .. name .. " to tank list")
  debug_always("Added Tank: " .. name .. " GUID: " .. guid)
  TP_TankListScrollFrame_Update()
end

-- Add target to tank list
function TP_AddTargetToTankList()
  if not UnitExists("target") then
    tp_print("No target selected")
    return
  end
  TP_AddUnitToTankList("target")
end

-- Add player to tank list
function TP_AddPlayerToTankList()
  TP_AddUnitToTankList("player")
end

-- Clear tank list
function TP_ClearTankList()
  tanks = {}
  tp_print("Cleared tank list")
  TP_TankListScrollFrame_Update()
end

-- Update tank list scroll frame
function TP_TankListScrollFrame_Update()
  if not TankPlatesTankListFrameScrollFrame then
    return
  end
  
  local offset = FauxScrollFrame_GetOffset(TankPlatesTankListFrameScrollFrame)
  local numTanks = table.getn(tanks)
  FauxScrollFrame_Update(TankPlatesTankListFrameScrollFrame, numTanks, 10, 16)
  
  for i = 1, 10 do
    local button = getglobal("TankPlatesTankListFrameButton"..i)
    local buttonText = getglobal("TankPlatesTankListFrameButton"..i.."Text")
    local arrayIndex = i + offset
    
    if tanks[arrayIndex] then
      buttonText:SetText(arrayIndex .. " - " .. tanks[arrayIndex].name)
      button:SetID(arrayIndex)
      button:Show()
    else
      button:Hide()
    end
  end
end

-- Tank list button click handler (called from [X] button)
function TP_TankListButton_OnClick()
  -- Get ID from parent button (the [X] is a child of the main button)
  local id = this:GetParent():GetID()
  if id and tanks[id] then
    local name = tanks[id].name
    table.remove(tanks, id)
    tp_print("Removed " .. name .. " from tank list")
    TP_TankListScrollFrame_Update()
  end
end

-- Show/hide tank list UI
function TP_ToggleTankList()
  if not TankPlatesTankListFrame then
    tp_print("ERROR: Tank list frame not loaded. Check TankPlatesUI.xml")
    return
  end
  
  if TankPlatesTankListFrame:IsVisible() then
    TankPlatesTankListFrame:Hide()
  else
    TankPlatesTankListFrame:Show()
    TP_TankListScrollFrame_Update()
  end
end

local function SlashHandler(msg)
  local args = {}
  for word in string.gmatch(msg, "%S+") do
    table.insert(args, word)
  end
  
  -- No args or "tanklist" - show tank list UI
  if table.getn(args) == 0 or args[1] == "tanklist" then
    TP_ToggleTankList()
    return
  end

  -- "colors" / "settings" - open colour settings window
  if args[1] == "colors" or args[1] == "settings" then
    TP_ToggleSettings()
    return
  end
  
  -- "add" with name - add by name
  if args[1] == "add" and args[2] then
    local name = args[2]
    local unitid = nil
    
    -- Check if it's the player themselves
    if string.lower(name) == string.lower(UnitName("player")) then
      unitid = "player"
    else
      -- Check party members
      for i = 1, 4 do
        if UnitExists("party"..i) and string.lower(UnitName("party"..i)) == string.lower(name) then
          unitid = "party"..i
          break
        end
      end
      
      -- Check raid members if not found in party
      if not unitid then
        for i = 1, 40 do
          if UnitExists("raid"..i) and string.lower(UnitName("raid"..i)) == string.lower(name) then
            unitid = "raid"..i
            break
          end
        end
      end
    end
    
    if not unitid then
      tp_print("Player '" .. name .. "' not found. Must be in your raid/party.")
      return
    end
    
    TP_AddUnitToTankList(unitid)
    return
  end
  
  -- "clear" - clear all
  if args[1] == "clear" then
    TP_ClearTankList()
    return
  end
  
  -- Help text
  tp_print("TankPlates Commands:")
  tp_print("/tp - Show/hide tank list window")
  tp_print("/tp tanklist - Show/hide tank list window")
  tp_print("/tp add [name] - Add player to tank list")
  tp_print("/tp clear - Clear all tanks")
  tp_print("/tp colors - Open colour settings window")
  tp_print("")
  tp_print("Color Guide:")
  tp_print("Bright Green - You have aggro")
  tp_print("Dark Green - Other tank has aggro")
  tp_print("Red - Non-tank has aggro")
end

local function Events()
  if event == "ADDON_LOADED" then
    -- shagu can load after us; re-init plates so our hooks run last
    if arg1 == "ShaguPlates" then
      for _,plate in pairs({ WorldFrame:GetChildren() }) do
        if IsNamePlate(plate) then
          plate.initialized = nil          -- allow InitPlate to run again
          InitPlate(plate)
        end
      end
    end
  elseif event == "UNIT_CASTEVENT" then
    local _,source = UnitExists(arg1)
    local _,target = UnitExists(arg2)

    if not source then return end

    for guid,data in pairs(tracked_guids) do
      if source == guid then
        if arg3 == "START" then
          tracked_guids[guid].casting = true
          if target and target ~= "" then
            tracked_guids[guid].casting_at = target
          end
        elseif arg3 == "FAIL" or arg3 == "CAST" then
          tracked_guids[guid].casting = false
          tracked_guids[guid].casting_at = nil
        end
        break
      end
    end
  end
end

local function Init()
  if event == "VARIABLES_LOADED" then
    -- Initialise saved variable, writing any missing keys with their defaults.
    if not TankPlates_config then TankPlates_config = {} end
    for k, v in pairs(TP_COLOR_DEFAULTS) do
      if TankPlates_config[k] == nil then
        TankPlates_config[k] = v
      end
    end
    LoadColors()
  elseif event == "PLAYER_ENTERING_WORLD" then
    _,player_guid = UnitExists("player")
    debug_always("Player GUID: " .. tostring(player_guid))
    this:SetScript("OnEvent", Events)
    this:SetScript("OnUpdate", Update)
    this:UnregisterEvent("PLAYER_ENTERING_WORLD")
    this:UnregisterEvent("VARIABLES_LOADED")

    -- if shagu already present, make sure plates are hooked after it
    if ShaguPlates then
      for _,plate in pairs({ WorldFrame:GetChildren() }) do
        if IsNamePlate(plate) then
          plate.initialized = nil
          InitPlate(plate)
        end
      end
    end
  end
end

local tankplates = CreateFrame("Frame")
tankplates:SetScript("OnEvent", Init)
tankplates:RegisterEvent("VARIABLES_LOADED")
tankplates:RegisterEvent("PLAYER_ENTERING_WORLD")
tankplates:RegisterEvent("UNIT_CASTEVENT")
tankplates:RegisterEvent("ADDON_LOADED")  -- watch for ShaguPlates loading later

SLASH_TANKPLATES1 = "/tp"
SlashCmdList["TANKPLATES"] = SlashHandler

-- Confirm addon loaded
DEFAULT_CHAT_FRAME:AddMessage("[|cff00ff00Tank|cffff0000Plates|r] Loaded successfully. Type /tp for help.")
