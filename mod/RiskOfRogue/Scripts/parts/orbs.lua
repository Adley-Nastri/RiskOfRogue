-- Risk of Rogue: orbs.lua
-- RoR2 cards in Deadzone's item-orb menus: rolling, showing and granting them.
-- Runs in the shared mod environment set up by main.lua (see docs/DEVELOPMENT.md).

---------------------------------------------------------------------------
-- RoR2 cards in Deadzone's perk / augment orb menus
---------------------------------------------------------------------------
-- The host rolls one RoR2 card per perk/augment orb and tells every player which slot it
-- takes. Each player's HUD repaints that card in the orb menu; picking it cancels the game's
-- own reward (an invalid index) and the host closes the orb and gives the RoR2 item instead.
Offers = {} -- bundle key -> {slot = 0-based index, item = id}
function bundle_key(b)
  local x, y = loc(b)
  return string.format("%d_%d", math.floor(x / 10 + 0.5), math.floor(y / 10 + 0.5))
end
function orb_row_for_class(b)
  local cn = b:GetClass():GetFName():ToString()
  for _, r in ipairs(Data.ORBS) do if cn:find(r.class_match) then return r end end
end
function send_offer(pc, key, off) send(pc, "o|" .. key .. "|" .. off.slot .. "|" .. off.item) end
function roll_offer(b, tries)
  tries = tries or 0
  if not valid(b) or not orb_row_for_class(b) then return end
  local n = 0
  pcall(function() n = b.BundleItems:GetArrayNum() end)
  if n == 0 then
    if tries < 20 then after(500, function() roll_offer(b, tries + 1) end) end
    return
  end
  local key = bundle_key(b)
  if Offers[key] or math.random() > SYS.orb_ror2_chance then return end
  local rar = roll_rarity("orb_weight")
  local off = { slot = math.random(n) - 1, item = roll_item(rar) }
  Offers[key] = off
  log("orb " .. b:GetClass():GetFName():ToString() .. " offers " .. off.item .. " in slot " .. off.slot)
  for _, pc in ipairs(FindAllOf("ValPlayerController") or {}) do send_offer(pc, key, off) end
end
function grant_orb(pc, b, off, key)
  Offers[key] = nil
  local name = player_name(pc)
  after(0, function()
    pcall(function() b:DestroyPickup() end)
    give(name, off.item, 1)
    local st = pstate(name)
    -- Substandard Duplicator: a temporary extra copy
    local dup = count(st, "Duplicator")
    if dup > 0 then
      local it = Data.ITEM_BY_ID.Duplicator
      give(name, off.item, 1)
      after(math.floor((it.dur + it.dur_per * (dup - 1)) * 1000), function() take(name, off.item, 1) end)
    end
  end)
end

function find_named(root, name, depth)
  depth = depth or 0
  if not valid(root) or depth > 14 then return nil end
  if root:GetFName():ToString() == name then return root end
  local found
  pcall(function()
    for i = 0, root:GetChildrenCount() - 1 do
      found = found or find_named(root:GetChildAt(i), name, depth + 1)
    end
  end)
  if not found then pcall(function() local wt = root.WidgetTree; if valid(wt) then found = find_named(wt.RootWidget, name, depth + 1) end end) end
  return found
end
function find_all_class(root, cname, out, depth)
  depth = depth or 0
  if not valid(root) or depth > 14 then return out end
  if root:GetClass():GetFName():ToString() == cname then out[#out + 1] = root; return out end
  pcall(function() for i = 0, root:GetChildrenCount() - 1 do find_all_class(root:GetChildAt(i), cname, out, depth + 1) end end)
  pcall(function() local wt = root.WidgetTree; if valid(wt) then find_all_class(wt.RootWidget, cname, out, depth + 1) end end)
  return out
end
function find_all_named(root, name, out, depth)
  depth = depth or 0
  if not valid(root) or depth > 14 then return out end
  if root:GetFName():ToString() == name then out[#out + 1] = root end
  pcall(function() for i = 0, root:GetChildrenCount() - 1 do find_all_named(root:GetChildAt(i), name, out, depth + 1) end end)
  pcall(function() local wt = root.WidgetTree; if valid(wt) then find_all_named(wt.RootWidget, name, out, depth + 1) end end)
  return out
end

patched = {} -- card addr -> item id (repaint is cheap but avoids text churn)
function patch_orb_menu(tex)
  local ls = FindFirstOf("WBP_LootSelection_C")
  if not valid(ls) or not ls:IsVisible() then return end
  local b = ls.CachedBundle
  if not valid(b) then return end
  local okey = bundle_key(b)
  local off = Offers[okey]
  if not off then return end
  if not can_take(off.item) then ShownCards[okey] = nil; return end -- inventory full: no RoR2 card
  local lt = ls.LootType.TagName:ToString()
  local row
  for _, r in ipairs(Data.ORBS) do if r.loot_type == lt then row = r end end
  if not row then return end
  local cards = find_all_class(ls.DisplayTypeSwitcher, row.card_class, {})
  local card = cards[off.slot + 1]
  if not valid(card) then return end
  ShownCards[okey] = true
  local it = Data.ITEM_BY_ID[off.item]
  local rar = Data.RARITY_BY_ID[it.rarity]
  local nameW = find_named(card, row.name_widget)
  if valid(nameW) then
    nameW:SetText(FText(it.name))
    pcall(function() nameW:SetColorAndOpacity({ SpecifiedColor = { R = rar.color[1], G = rar.color[2], B = rar.color[3], A = 1 }, ColorUseRule = 0 }) end)
  end
  local typeW = find_named(card, row.type_widget)
  if valid(typeW) then typeW:SetText(FText("// " .. string.upper(Data.RARITY_BY_ID[it.rarity].name or it.rarity) .. " ITEM")) end
  local descs = find_all_named(card, row.desc_widget, {})
  for i, d in ipairs(descs) do
    pcall(function()
      if i == 1 then d:SetText(FText(it.pickup .. " " .. (it.desc_rich or it.desc))) else d:SetText(FText("")) end
    end)
  end
  local host = find_named(card, row.icon_host)
  local icon = valid(host) and find_named(host, row.icon_widget) or nil
  -- (item_def / set_icon are defined further down; reached through late-bound globals)
  local def_of, set_icon = rawget(_G, "R2_ITEM_DEF"), rawget(_G, "R2_SET_ICON")
  local d = def_of and def_of(it) or nil
  if valid(host) and valid(d) then
    local cur = nil
    pcall(function() cur = host.CachedDataAsset end)
    if not (valid(cur) and addr(cur) == addr(d)) then pcall(function() host:UpdateAsset(d, local_pc().PlayerState) end) end
  end
  if valid(icon) and valid(tex[it.id]) then
    if set_icon then pcall(set_icon, icon, tex[it.id]) else pcall(function() icon:SetBrushFromTexture(tex[it.id], false) end) end
  end
  for name in string.gmatch(row.hide_widgets, "[^,]+") do
    local w = find_named(card, name)
    if valid(w) then pcall(function() w:SetVisibility(HID) end) end
  end
end

