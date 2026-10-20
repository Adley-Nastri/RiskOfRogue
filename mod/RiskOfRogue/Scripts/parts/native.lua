-- Risk of Rogue: native.lua
-- RoR2 items as native Deadzone items: definitions, inventory slots, tooltips.
-- Runs in the shared mod environment set up by main.lua (see docs/DEVELOPMENT.md).

---------------------------------------------------------------------------
-- RoR2 items as native Deadzone items.
-- Each RoR2 item gets its own Deadzone item definition (a rooted copy of a vanilla
-- ValAbilityAsset carrying the RoR2 name, description and rarity). Deadzone's own widgets then
-- draw it: the item row under the minimap (fed through the display's OnItemIdsChanged, with
-- GetAssetById hooked to resolve RoR2 ids), the Tab menu and end-of-run grids (UpdateAsset on
-- the next free slot) and Deadzone's own hover tooltip. Only RoR2 items stack (x2, x3...).
---------------------------------------------------------------------------
INV = Data.INV
Native = { defs = {}, by_name = {}, tex = nil, hooked = false, resolve_ok = nil, pushed = "" }
-- Put an icon into a Deadzone item slot the way Deadzone does: only the material's Icon texture
-- parameter changes, so the slot keeps its rarity border and frame. Falls back to a plain brush.
function Native.set_icon(img, tex)
  local ok = pcall(function()
    local mid = img:GetDynamicMaterial()
    if not valid(mid) then error("no material") end
    mid:SetTextureParameterValue(FName(INV.icon_param), tex)
  end)
  if not ok then img:SetBrushFromTexture(tex, false) end
  return ok
end
_G.R2_SET_ICON = Native.set_icon
function ror2_name(id) return "RoR2_" .. id end
function ror2_asset_id(id)
  return { PrimaryAssetType = { Name = FName(INV.asset_type) }, PrimaryAssetName = FName(ror2_name(id)) }
end
function item_def(it)
  local d = Native.defs[it.id]
  if valid(d) then return d end
  d = StaticFindObject("/Engine/Transient." .. ror2_name(it.id))
  if not valid(d) then
    local tmpl = StaticFindObject(INV.item_template)
    if not valid(tmpl) then pcall(function() tmpl = LoadAsset(INV.item_template) end) end
    if not valid(tmpl) then return nil end
    -- RF_Transient | RF_MarkAsRootSet: never saved, never garbage-collected
    d = StaticConstructObject(tmpl:GetClass(), StaticFindObject("/Engine/Transient"), FName(ror2_name(it.id)), 0xC0, 0, false, false, tmpl)
  end
  if not valid(d) then return nil end
  local rar = Data.RARITY_BY_ID[it.rarity]
  d.DisplayName = FText(it.name)
  d.Description = FText(it.pickup .. "\n" .. (it.desc_rich or ("<em>" .. it.desc .. "</>")) .. "\n// " .. string.upper(Data.RARITY_BY_ID[it.rarity].name or it.rarity) .. " ITEM")
  d.Rarity = rar.dz_rarity
  pcall(function() d.MaxStackSize = 999 end)
  pcall(function() d.AssetId = ror2_asset_id(it.id) end)
  Native.defs[it.id] = d
  Native.by_name[ror2_name(it.id)] = it
  return d
end
_G.R2_ITEM_DEF = item_def
function id_name(e)
  local s = nil
  pcall(function() s = e.PrimaryAssetName:ToString() end)
  return s
end
function ror2_item_for(e)
  local n = id_name(e)
  return n and Native.by_name[n] or nil
end

function install_native_hooks()
  if Native.hooked then return end
  Native.hooked = true
  -- RoR2 ids resolve to their definitions wherever Deadzone's UI looks an item up
  local ok, err = pcall(function()
    RegisterHook(INV.get_asset_fn, function() end, function(ctx, asset_id)
      local it = ror2_item_for(asset_id:get())
      if it then return item_def(it) end
    end)
  end)
  log("hook GetAssetById: " .. tostring(ok) .. " " .. tostring(err or ""))
  -- the HUD row's material gets the RoR2 icon
  ok, err = pcall(function()
    RegisterHook(INV.brush_fn, function(self, asset_id, mid)
      local it = ror2_item_for(asset_id:get())
      local m = mid:get()
      if it and valid(m) and Native.tex and valid(Native.tex[it.id]) then
        m:SetTextureParameterValue(FName(INV.icon_param), Native.tex[it.id])
        m:SetScalarParameterValue(FName("Rarity"), Data.RARITY_BY_ID[it.rarity].dz_rarity - 1)
      end
    end)
  end)
  log("hook UpdateBrushForItem: " .. tostring(ok) .. " " .. tostring(err or ""))
end

function vanilla_ids(pc)
  local list = {}
  pcall(function()
    local a = pc.PlayerState[INV.owned_items]
    for i = 1, a:GetArrayNum() do
      local e = a[i]
      list[#list + 1] = { PrimaryAssetType = { Name = e.PrimaryAssetType.Name }, PrimaryAssetName = e.PrimaryAssetName }
    end
  end)
  return list
end
function vanilla_count(pc)
  local n = 0
  pcall(function() n = pc.PlayerState[INV.owned_items]:GetArrayNum() end)
  return n
end
function owned_list()
  local list = {}
  for _, it in ipairs(Data.ITEMS) do
    local n = View.items[it.id] or 0
    if n > 0 then list[#list + 1] = { id = it.id, n = n } end
  end
  return list
end
INVENTORY_SLOTS = 18
can_take = function(id)
  if (View.items[id] or 0) > 0 then return true end
  local pc = local_pc()
  if not valid(pc) then return false end
  return vanilla_count(pc) + #owned_list() < INVENTORY_SLOTS
end

-- HUD item row under the minimap
function find_hud_display()
  for _, w in ipairs(FindAllOf(INV.hud_display_class) or {}) do
    if valid(w) then
      local fn = w:GetFullName()
      if fn:find("^" .. INV.hud_display_class .. " /Engine/Transient") and fn:find(INV.hud_display_owner) then return w end
    end
  end
end
function shown_ids(disp)
  local s = {}
  pcall(function()
    local a = disp.ActiveItemIds
    for i = 1, a:GetArrayNum() do local n = id_name(a[i]); if n then s[n] = true end end
  end)
  return s
end
function push_hud(pc, list)
  local disp = find_hud_display()
  if not valid(disp) then return end
  local shown = shown_ids(disp)
  local want, key = {}, ""
  for _, e in ipairs(list) do
    if item_def(Data.ITEM_BY_ID[e.id]) then want[ror2_name(e.id)] = true; key = key .. e.id .. "," end
  end
  local stale = false
  for n in pairs(want) do if not shown[n] then stale = true end end
  for n in pairs(shown) do if Native.by_name[n] and not want[n] then stale = true end end
  if not stale then return end
  local ids = vanilla_ids(pc)
  for _, e in ipairs(list) do if want[ror2_name(e.id)] then ids[#ids + 1] = ror2_asset_id(e.id) end end
  local ok, err = pcall(function() disp:OnItemIdsChanged(ids) end)
  if not ok and Native.pushed ~= key then log("HUD item row: " .. tostring(err)) end
  Native.pushed = key
end

-- Tab menu / end-of-run grids: RoR2 items take the slots after the vanilla items
function fill_slot(slot, it, n, ps)
  local d = item_def(it)
  if not valid(d) then return end
  local cur = nil
  pcall(function() cur = slot.CachedDataAsset end)
  if not (valid(cur) and addr(cur) == addr(d)) then
    pcall(function() slot:UpdateAsset(d, ps) end)
  end
  pcall(function() slot.bTooltipDisabled = false end)
  local icon, stack = slot[INV.slot_icon], slot[INV.slot_stack]
  local tex = Native.tex and Native.tex[it.id]
  if valid(icon) and valid(tex) then Native.set_icon(icon, tex); icon:SetVisibility(VIS) end
  if valid(stack) then
    stack:SetText(FText(n > 1 and ("x" .. n) or ""))
    stack:SetVisibility(n > 1 and VIS or HID)
  end
end
-- The end-of-run "Items:" row only makes a slot for each vanilla item, so RoR2 items get slots
-- of the same class added after them, at the row's own scale. Added once per results screen
-- (keyed by the row's address), then refilled like the other grids.
Native.end_rows = {}
function patch_end_row(list, pc, ps)
  if #list == 0 then return end
  for _, row in ipairs(FindAllOf(INV.end_row_class) or {}) do
    local fn = valid(row) and row:GetFullName() or ""
    if fn:find("^[%w_]+ /Engine/Transient") and fn:find(INV.end_grid_owner) and row:IsVisible() then
      local grid = row[INV.end_row_grid]
      if valid(grid) then
        local key = addr(grid)
        local mine = Native.end_rows[key]
        if not mine then
          mine = {}
          Native.end_rows = { [key] = mine } -- older results screens are gone
        end
        local n = grid:GetChildrenCount()
        local first = n > #mine and grid:GetChildAt(0) or nil
        local scale = INV.end_row_scale
        if valid(first) then pcall(function() scale = first.ScaleOverride end) end
        local wbl = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
        local proto = valid(first) and first or FindFirstOf(INV.end_row_slot)
        local slot_cls = valid(proto) and proto:GetClass() or nil
        for i, e in ipairs(list) do
          if not valid(mine[i]) and valid(wbl) and valid(slot_cls) then
            local w = wbl:Create(pc, slot_cls, pc)
            if valid(w) then
              grid:AddChildToHorizontalBox(w)
              pcall(function() w:UpdateScaleOverride(scale) end)
              mine[i] = w
            end
          end
          if valid(mine[i]) then fill_slot(mine[i], Data.ITEM_BY_ID[e.id], e.n, ps) end
        end
      end
    end
  end
end
patch_inventory = function(tex, pc)
  Native.tex = tex
  local list = owned_list()
  local ps = pc.PlayerState
  for _, g in ipairs(FindAllOf("UI_Equipment_Perks_Items_C") or {}) do
    local fn = valid(g) and g:GetFullName() or ""
    if fn:find("^[%w_]+ /Engine/Transient") and g:IsVisible() then
      if fn:find(INV.tab_grid_owner) or fn:find(INV.end_grid_owner) then
        local grid = find_named(g, "ItemGrid")
        if valid(grid) then
          local start = vanilla_count(pc)
          INVENTORY_SLOTS = grid:GetChildrenCount()
          for i, e in ipairs(list) do
            local idx = start + i - 1
            if idx < INVENTORY_SLOTS then
              local slot = grid:GetChildAt(idx)
              if valid(slot) then fill_slot(slot, Data.ITEM_BY_ID[e.id], e.n, ps) end
            end
          end
        end
      end
    end
  end
  patch_end_row(list, pc, ps)
  -- The item row under the minimap is parked: feeding it RoR2 ids needed native hooks
  -- (GetAssetById / UpdateBrushForItem) that crashed the mod loader. See MODLOG.
end
function update_tip() end -- Deadzone's own tooltip is used now

