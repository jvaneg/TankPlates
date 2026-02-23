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
        -- PFUI and ShaguPlates use enemy bar colors to determine types, this can really mess with things.
        -- For instance if we choose (0,0,1,1) blue, the shagu reads this as friendly player and may color based on class.
        -- Due to this yellow (neutral) has been chosen for now.
        SetHealthBarColor(this, 1, 1, 0, 1)
      elseif (unit.casting and (unit.casting_at == player_guid or unit.previous_target == player_guid)) then
        new_reason = "CastingAtYou"
        -- casting on someone but was attacking you
        SetHealthBarColor(this, 0, 1, 0, 1) -- green
      elseif unit.current_target == player_guid then
        new_reason = "AttackingYou"
        -- attacking you
        -- white confused ShaguPlates when it samples the underlying bar
        SetHealthBarColor(this, 0, 1, 0, 1) -- green (use same as others)
      elseif not unit.casting and (not unit.current_target and unit.previous_target == player_guid) then
        new_reason = "Fleeing"
        -- fleeing but was attacking you
        SetHealthBarColor(this, 0, 1, 0, 1) -- green
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
          SetHealthBarColor(this, 0, 1, 0, 1) -- bright green - YOU have aggro
        elseif IsTank(effective_target) then
          new_reason = "OtherTankAggro"
          SetHealthBarColor(this, 0, 0, 1, 1) -- blue - other tank has aggro
        else
          new_reason = "NonTankAggro"
          -- non-tank has aggro
          SetHealthBarColor(this, 1, 0, 0, 1) -- red
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
      SetHealthBarColor(this, unpack(unit.healthbar_color))
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
  if event == "PLAYER_ENTERING_WORLD" then
    _,player_guid = UnitExists("player")
    debug_always("Player GUID: " .. tostring(player_guid))
    this:SetScript("OnEvent", Events)
    this:SetScript("OnUpdate", Update)
    this:UnregisterEvent("PLAYER_ENTERING_WORLD")

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
tankplates:RegisterEvent("PLAYER_ENTERING_WORLD")
tankplates:RegisterEvent("UNIT_CASTEVENT")
tankplates:RegisterEvent("ADDON_LOADED")  -- watch for ShaguPlates loading later

SLASH_TANKPLATES1 = "/tp"
SlashCmdList["TANKPLATES"] = SlashHandler

-- Confirm addon loaded
DEFAULT_CHAT_FRAME:AddMessage("[|cff00ff00Tank|cffff0000Plates|r] Loaded successfully. Type /tp for help.")
