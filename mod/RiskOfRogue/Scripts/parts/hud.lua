-- Risk of Rogue: hud.lua
-- The mod HUD: build it (clock, buff row, ticker, banner) and draw it every refresh.
-- Runs in the shared mod environment set up by main.lua (see docs/DEVELOPMENT.md).

function build_hud(pc)
  local w = new("/Script/UMG.UserWidget", pc, "RiskOfRogueHUD")
  local wt = new("/Script/UMG.WidgetTree", w, "WT")
  w.WidgetTree = wt
  local canvas = new("/Script/UMG.CanvasPanel", wt, "Root")
  wt.RootWidget = canvas
  local krl = cls("/Script/Engine.Default__KismetRenderingLibrary")
  local tex = {}
  for _, it in ipairs(Data.ITEMS) do tex[it.id] = krl:ImportFileAsTexture2D(pc, MOD .. "icons/" .. it.icon .. ".png") end
  for _, b in ipairs(Data.BUFFS) do tex["buff_" .. b.id] = krl:ImportFileAsTexture2D(pc, MOD .. "icons/" .. b.icon .. ".png") end
  local H = { w = w, pc = pc, tex = tex, slots = {} }
  -- Imported textures are transient: keep each one referenced by a hidden image so the
  -- garbage collector can't free it while the HUD might still show it.
  local ki = 0
  for _, t in pairs(tex) do
    ki = ki + 1
    local keep = new("/Script/UMG.Image", wt, "TexKeep" .. ki)
    keep:SetBrushFromTexture(t, false)
    canvas:AddChildToCanvas(keep)
    keep:SetVisibility(HID)
  end

  -- difficulty clock (top right, under the currency counters)
  H.clock_bg, H.clock_bg_slot = image(wt, canvas, "ClockBg")
  H.clock_bg:SetColorAndOpacity({ R = 0.05, G = 0.05, B = 0.07, A = 0.55 })
  anchor(H.clock_bg_slot, 1, 0, -24, 64, 250, 76, 1, 0)
  H.clock, H.clock_slot = text(wt, canvas, "ClockTime", 26)
  anchor(H.clock_slot, 1, 0, -36, 66, nil, nil, 1, 0)
  H.tier, H.tier_slot = text(wt, canvas, "ClockTier", 15)
  anchor(H.tier_slot, 1, 0, -36, 104, nil, nil, 1, 0)
  H.bar_bg, H.bar_bg_slot = image(wt, canvas, "BarBg")
  H.bar_bg:SetColorAndOpacity({ R = 1, G = 1, B = 1, A = 0.15 })
  anchor(H.bar_bg_slot, 1, 0, -36, 128, 226, 6, 1, 0)
  H.bar, H.bar_slot = image(wt, canvas, "Bar")
  anchor(H.bar_slot, 1, 0, -262, 128, 0, 6, 0, 0)

  -- pickup banner (lower centre)
  H.ban_bg, H.ban_bg_slot = image(wt, canvas, "BanBg")
  H.ban_bg:SetColorAndOpacity({ R = 0.03, G = 0.03, B = 0.05, A = 0.7 })
  anchor(H.ban_bg_slot, 0.5, 1, 0, -170, 560, 92, 0.5, 1)
  H.ban_icon, H.ban_icon_slot = image(wt, canvas, "BanIcon")
  anchor(H.ban_icon_slot, 0.5, 1, -270, -178, 76, 76, 0, 1)
  H.ban_name, H.ban_name_slot = text(wt, canvas, "BanName", 24)
  anchor(H.ban_name_slot, 0.5, 1, -180, -218, nil, nil, 0, 1)
  H.ban_desc, H.ban_desc_slot = text(wt, canvas, "BanDesc", 16)
  anchor(H.ban_desc_slot, 0.5, 1, -180, -186, nil, nil, 0, 1)
  for _, x in ipairs({ H.ban_bg, H.ban_icon, H.ban_name, H.ban_desc }) do x:SetVisibility(HID) end

  -- RoR2 buff row (just above Deadzone's health bar, bottom left)
  H.buffs = {}
  for i = 1, #Data.BUFFS do
    local img, sl = image(wt, canvas, "Buff" .. i)
    anchor(sl, 0, 1, 40 + (i - 1) * 38, -112 + (i - 1) * 38 * math.tan(math.rad(SYS.buff_row_tilt_deg)), 34, 34, 0, 1)
    pcall(function() img:SetRenderTransformAngle(SYS.buff_row_tilt_deg) end)
    img:SetVisibility(HID)
    -- stack count in the icon's lower right corner, like RoR2's BuffIcon
    local cnt, csl = text(wt, canvas, "BuffCount" .. i, 11)
    pcall(function() cnt:SetRenderTransformAngle(SYS.buff_row_tilt_deg) end)
    cnt:SetVisibility(HID)
    H.buffs[i] = { img = img, slot = sl, cnt = cnt, cslot = csl }
  end

  -- proc ticker (right middle)
  H.tick = {}
  for i = 1, 4 do
    local tb, s = text(wt, canvas, "Tick" .. i, 15)
    anchor(s, 1, 0.5, -40, -40 + 24 * i, nil, nil, 1, 0)
    tb:SetVisibility(HID)
    H.tick[i] = tb
  end

  -- test menu (F1), left middle; hidden until opened
  H.menu_bg, H.menu_bg_slot = image(wt, canvas, "MenuBg")
  H.menu_bg:SetColorAndOpacity({ R = 0.02, G = 0.03, B = 0.05, A = 0.86 })
  H.menu_lines = {}
  local MENU_ROWS = 20
  local nlines = math.min(#Data.ITEMS, MENU_ROWS) + 19
  local width = 520
  anchor(H.menu_bg_slot, 0, 0.5, 24, 0, width, 26 + nlines * 21, 0, 0.5)
  for i = 1, nlines do
    local tb, sl = text(wt, canvas, "Menu" .. i, i == 1 and 18 or 14)
    anchor(sl, 0, 0.5, 40, -(nlines * 21) / 2 + (i - 1) * 21, nil, nil, 0, 0)
    tb:SetVisibility(HID)
    H.menu_lines[i] = tb
  end
  -- up to 3 HUD buff icons per item row, in a column after the item names
  H.menu_icons = {}
  for i = 1, nlines do
    H.menu_icons[i] = {}
    for k = 1, 3 do
      local img, sl = image(wt, canvas, "MenuIcon" .. i .. "_" .. k)
      anchor(sl, 0, 0.5, 380 + (k - 1) * 22, -(nlines * 21) / 2 + (i - 1) * 21 + 1, 18, 18, 0, 0)
      img:SetVisibility(HID)
      pcall(function() img:ForceVolatile(true) end)
      H.menu_icons[i][k] = { img = img, shown = nil }
    end
  end
  H.menu_bg:SetVisibility(HID)

  -- the game's HUD uses Slate invalidation caching; mark our widgets volatile so updates repaint
  pcall(function() canvas:ForceVolatile(true) end)
  pcall(function() w:ForceVolatile(true) end)
  for _, x in ipairs({ H.clock_bg, H.clock, H.tier, H.bar_bg, H.bar, H.ban_bg, H.ban_icon, H.ban_name, H.ban_desc }) do pcall(function() x:ForceVolatile(true) end) end
  for _, t in ipairs(H.tick) do pcall(function() t:ForceVolatile(true) end) end
  for _, t in ipairs(H.menu_lines) do pcall(function() t:ForceVolatile(true) end) end
  pcall(function() H.menu_bg:ForceVolatile(true) end)
  for _, b in ipairs(H.buffs) do pcall(function() b.img:ForceVolatile(true); b.cnt:ForceVolatile(true) end) end
  w:AddToViewport(40)
  log("HUD built")
  return H
end

function fmt_clock(secs)
  secs = math.floor(secs)
  return string.format("%02d:%02d", secs // 60, secs % 60)
end

function draw_hud()
  local pc = local_pc()
  if not valid(pc) then HUD = nil; return end
  if HUD == nil or not valid(HUD.w) or addr(HUD.pc) ~= addr(pc) then
    local ok, h = pcall(build_hud, pc)
    if not ok then log("HUD build failed: " .. tostring(h)); return end
    HUD = h
  end
  local H = HUD
  local okp, errp = pcall(patch_orb_menu, H.tex)
  if not okp then log("orb menu patch: " .. tostring(errp)) end
  -- shown only while Deadzone's own HUD (the visor) is: hidden in the pause menu and other screens
  local visor_on = true
  pcall(function()
    if not valid(H.visor) then
      H.visor = nil
      for _, v in ipairs(FindAllOf("UI_Game_Visor_C") or {}) do
        if valid(v) and not v:GetFullName():find("Default__") then H.visor = v; break end
      end
    end
    if H.visor then visor_on = H.visor:IsVisible() and true or false end
  end)
  local show = View.in_run and visor_on
  -- clock
  for _, x in ipairs({ H.clock_bg, H.clock, H.tier, H.bar_bg, H.bar }) do x:SetVisibility(show and VIS or HID) end
  if show then
    local ti = tier_index(View.clock)
    local t = Data.DIFFICULTY_TIERS[ti]
    H.clock:SetText(FText(fmt_clock(View.clock)))
    H.tier:SetText(FText(t.name))
    color(H.tier, t.color)
    color(H.clock, { 1, 1, 1 })
    local nxt = Data.DIFFICULTY_TIERS[ti + 1]
    local frac = 1
    if nxt then frac = clamp((View.clock / 60 - t.start_min) / (nxt.start_min - t.start_min), 0, 1) end
    H.bar:SetColorAndOpacity({ R = t.color[1], G = t.color[2], B = t.color[3], A = 0.95 })
    H.bar_slot:SetSize({ X = 226 * frac, Y = 6 })
  end
  -- RoR2 items inside Deadzone's own inventory views
  local okg, errg = pcall(patch_inventory, H.tex, pc)
  if not okg then log("inventory patch: " .. tostring(errg)) end
  -- banner
  while #View.banners > 3 do table.remove(View.banners, 1) end
  while #View.banners > 0 and now_ms - View.banners[1].t > SYS.pickup_banner_ms do table.remove(View.banners, 1); if View.banners[1] then View.banners[1].t = now_ms end end
  local b = View.banners[1]
  local it = b and Data.ITEM_BY_ID[b.id]
  if not visor_on then it = nil end
  for _, x in ipairs({ H.ban_bg, H.ban_icon, H.ban_name, H.ban_desc }) do x:SetVisibility(it and VIS or HID) end
  if it then
    if valid(H.tex[it.id]) then H.ban_icon:SetBrushFromTexture(H.tex[it.id], false) end
    H.ban_name:SetText(FText(it.name))
    color(H.ban_name, Data.RARITY_BY_ID[it.rarity].color)
    H.ban_desc:SetText(FText(it.pickup))
    color(H.ban_desc, { 0.85, 0.85, 0.85 })
  end
  -- buffs
  local active = {}
  for _, b in ipairs(Data.BUFFS) do
    local untilT = View.buffs[b.id]
    if untilT and untilT > now_ms and show then active[#active + 1] = { b = b, left = untilT - now_ms } end
  end
  for i, slot in ipairs(H.buffs) do
    local a = active[i]
    if a then
      if valid(H.tex["buff_" .. a.b.id]) then slot.img:SetBrushFromTexture(H.tex["buff_" .. a.b.id], false) end
      local bx, by = 40 + (i - 1) * 38, -112 + (i - 1) * 38 * math.tan(math.rad(SYS.buff_row_tilt_deg))
      anchor(slot.slot, 0, 1, bx, by, 34, 34, 0, 1)
      -- drawn exactly as the icon's own PNG colours, no tint, no fade
      slot.img:SetColorAndOpacity({ R = 1, G = 1, B = 1, A = 1 })
      if slot.iv ~= 1 then slot.img:SetVisibility(VIS); slot.iv = 1 end
      local n = (View.bcount[a.b.id] or 1) + a.b.offset
      if SYS.buff_show_stacks == 1 and a.b.stack == 1 and n > 1 then
        slot.cnt:SetText(FText(a.b.stack_pct == 1 and (n .. "%") or ("x" .. n)))
        color(slot.cnt, { 1, 1, 1 })
        anchor(slot.cslot, 0, 1, bx + 37, by + 3, nil, nil, 1, 1)
        if slot.cv ~= 1 then slot.cnt:SetVisibility(VIS); slot.cv = 1 end
      else
        if slot.cv ~= 0 then slot.cnt:SetVisibility(HID); slot.cv = 0 end
      end
    else
      if slot.iv ~= 0 then slot.img:SetVisibility(HID); slot.iv = 0 end
      if slot.cv ~= 0 then slot.cnt:SetVisibility(HID); slot.cv = 0 end
    end
  end
  -- ticker
  for i = 1, 4 do
    local e = View.ticker[i]
    if e and now_ms - e.t < 5000 and show then
      H.tick[i]:SetText(FText(e.text)); color(H.tick[i], { 0.95, 0.9, 0.6 }, 1 - (now_ms - e.t) / 5000)
      H.tick[i]:SetVisibility(VIS)
    else H.tick[i]:SetVisibility(HID) end
  end
  draw_menu(H)
end

