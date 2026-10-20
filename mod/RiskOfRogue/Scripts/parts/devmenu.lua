-- Risk of Rogue: devmenu.lua
-- Developer test menu (F1) and its keys. Only active with devtools.txt.
-- Runs in the shared mod environment set up by main.lua (see docs/DEVELOPMENT.md).

---------------------------------------------------------------------------
-- test menu: F1 opens it; the other keys only work while it is open (host or solo)
---------------------------------------------------------------------------
Dev = { open = false, god = false, sel = 1, msg = "", msg_t = 0 }
-- Developer tools (F1 test menu, god mode, self-test, test-command file) only exist when the file
-- devtools.txt is in the mod folder. The release build ships without it.
do local f = io.open(MOD .. "devtools.txt", "r"); Dev.enabled = f ~= nil; if f then f:close() end end
KEYS = {
  { "F1", "open / close this menu" },
  { "F2", "god mode on / off" },
  { "Up / Down  (or F3 / F4)", "select an item  (PgUp / PgDn: 10 at a time)" },
  { "Right / Enter  (or F5)", "give 1 of the selected item" },
  { "Left / Backspace  (or F6)", "remove 1 of the selected item" },
  { "F7", "give 1 of every RoR2 item" },
  { "F8", "remove all RoR2 items" },
  { "F9", "difficulty clock: jump to next tier" },
  { "F10", "kill enemies within 30 m (procs fire)" },
  { "Home", "run the item self-test (press again to stop)" },
  { "End", "re-test only the items that failed last time" },
}
function dev_msg(t) Dev.msg = t; Dev.msg_t = now_ms; log("test menu: " .. t) end
-- which HUD buff icons an item can show (the rings' ready/cooldown icons belong to both rings)
function Dev.icons_for(id)
  if not Dev.ibuf then
    Dev.ibuf = {}
    for _, b in ipairs(Data.BUFFS) do
      local owners = { b.item }
      if b.event == "ringcd" or b.event == "ringready" then owners = { "FireRing", "IceRing" } end
      for _, o in ipairs(owners) do Dev.ibuf[o] = Dev.ibuf[o] or {}; table.insert(Dev.ibuf[o], b.id) end
    end
  end
  return Dev.ibuf[id]
end
function Dev.menu_icons(H, rows)
  for i, set in ipairs(H.menu_icons or {}) do
    local ids = rows and rows[i] or nil
    for k, e in ipairs(set) do
      local id = ids and ids[k] or nil
      if e.shown ~= id then
        e.shown = id
        if id and valid(H.tex["buff_" .. id]) then e.img:SetBrushFromTexture(H.tex["buff_" .. id], false); e.img:SetVisibility(VIS)
        else e.img:SetVisibility(HID) end
      end
    end
  end
end
draw_menu = function(H)
  local show = Dev.open
  H.menu_bg:SetVisibility(show and VIS or HID)
  for _, tb in ipairs(H.menu_lines) do tb:SetVisibility(show and VIS or HID) end
  if not show then Dev.menu_icons(H, nil); return end
  local lines = {}
  local function add(t, c) lines[#lines + 1] = { t, c or { 0.88, 0.88, 0.88 } } end
  add("RISK OF ROGUE  //  TEST MENU", { 1, 0.85, 0.35 })
  add("God mode: " .. (Dev.god and "ON" or "off") .. "     Clock: " .. string.format("%02d:%02d", math.floor(View.clock) // 60, math.floor(View.clock) % 60) .. " " .. Data.DIFFICULTY_TIERS[tier_index(View.clock)].name,
      Dev.god and { 0.5, 1, 0.5 } or nil)
  add(" ")
  local rows = 20
  local first = clamp(Dev.sel - rows // 2, 1, math.max(1, #Data.ITEMS - rows + 1))
  add(string.format("Item %d / %d   (PgUp / PgDn jump 10)", Dev.sel, #Data.ITEMS), { 0.6, 0.65, 0.7 })
  for i = first, math.min(#Data.ITEMS, first + rows - 1) do
    local it = Data.ITEMS[i]
    local n = View.items[it.id] or 0
    local mark = (i == Dev.sel) and "> " or "   "
    local c = Data.RARITY_BY_ID[it.rarity].color
    if i ~= Dev.sel then c = { c[1] * 0.75, c[2] * 0.75, c[3] * 0.75 } end
    local el = it.element ~= "none" and ("  [" .. Data.ELEMENT_BY_ID[it.element].name .. "]") or ""
    add(mark .. it.name .. (n > 0 and ("  x" .. n) or "") .. el, c)
    lines[#lines][3] = Dev.icons_for(it.id)
  end
  add(" ")
  for _, k in ipairs(KEYS) do add(k[1] .. "   " .. k[2], { 0.7, 0.75, 0.8 }) end
  add((now_ms - Dev.msg_t < 4000) and Dev.msg or " ", { 0.95, 0.9, 0.6 })
  for i, tb in ipairs(H.menu_lines) do
    local l = lines[i]
    if l then tb:SetText(FText(l[1])); color(tb, l[2]) else tb:SetText(FText("")) end
  end
  local icons = {}
  for i, l in ipairs(lines) do icons[i] = l[3] end
  Dev.menu_icons(H, icons)
end

function dev_action(key)
  if key == "F1" then Dev.open = not Dev.open; return end
  if not Dev.open then return end
  local srv = server()
  local pc = local_pc()
  if not srv or not valid(pc) then dev_msg("Only the host (or solo) can use the test menu"); return end
  local name = player_name(pc)
  local it = Data.ITEMS[Dev.sel]
  if key == "F2" then
    Dev.god = not Dev.god
    if not Dev.god and alive(pc.Pawn) then
      for _, set in ipairs(FindAllOf("ValAttributeSet") or {}) do
        if valid(set) and addr(set:GetOuter()) == addr(pc.Pawn) then set.TemporaryShield.BaseValue = 0; set.TemporaryShield.CurrentValue = 0 end
      end
    end
    dev_msg("God mode " .. (Dev.god and "ON" or "off"))
  elseif key == "F3" then Dev.sel = (Dev.sel - 2) % #Data.ITEMS + 1
  elseif key == "F4" then Dev.sel = Dev.sel % #Data.ITEMS + 1
  elseif key == "PGUP" then Dev.sel = math.max(1, Dev.sel - 10)
  elseif key == "PGDN" then Dev.sel = math.min(#Data.ITEMS, Dev.sel + 10)
  elseif key == "F5" then give(name, it.id, 1); dev_msg("Gave " .. it.name)
  elseif key == "F6" then take(name, it.id, 1); dev_msg("Removed " .. it.name)
  elseif key == "F7" then
    local st = pstate(name)
    for _, x in ipairs(Data.ITEMS) do st.items[x.id] = count(st, x.id) + 1 end
    apply_items(name)
    dev_msg("Gave one of every item (" .. #Data.ITEMS .. ")")
  elseif key == "F8" then take_all(name); dev_msg("Removed all RoR2 items")
  elseif key == "F9" then
    local ti = tier_index(Run.clock)
    local nxt = Data.DIFFICULTY_TIERS[ti + 1]
    Run.clock = nxt and (nxt.start_min * 60 + 1) or 0
    dev_msg("Clock -> " .. Data.DIFFICULTY_TIERS[tier_index(Run.clock)].name)
  elseif key == "F10" then
    local pawn = pc.Pawn
    if not alive(pawn) then return end
    local n = 0
    for _, b in ipairs(bots_near(pawn, 3000, nil)) do deal(pawn, b, b:GetHealth() + 1); n = n + 1 end
    dev_msg("Killed " .. n .. " enemies")
  elseif key == "END" then
    if Dev.ST.running then Dev.ST.stop = true; dev_msg("Stopping the self-test after this item..."); return end
    local only, n = {}, 0
    local f = io.open(MOD .. "selftest_failed.txt", "r")
    if f then for line in f:lines() do local id = line:match("^%s*(%S+)") ; if id and Data.ITEM_BY_ID[id] then only[id] = true; n = n + 1 end end; f:close() end
    if n == 0 then dev_msg("No failed items to re-test (run the full self-test with Home first)")
    else dev_msg("Re-testing " .. n .. " failed item(s): " .. tostring(Dev.ST.start(only))) end
  elseif key == "HOME" then
    if Dev.ST.running then Dev.ST.stop = true; dev_msg("Stopping the self-test after this item...")
    else dev_msg("Self-test: " .. tostring(Dev.ST.start(nil)) .. "  (results: selftest.txt)") end
  end
end
-- extra keys for moving through the item list (they map onto the F-key actions)
ALIAS = { UP_ARROW = "F3", DOWN_ARROW = "F4", RIGHT_ARROW = "F5", RETURN = "F5", LEFT_ARROW = "F6", BACKSPACE = "F6", PAGE_UP = "PGUP", PAGE_DOWN = "PGDN" }
for _, k in ipairs(Dev.enabled and { "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "HOME", "END", "UP_ARROW", "DOWN_ARROW", "RIGHT_ARROW", "LEFT_ARROW", "RETURN", "BACKSPACE", "PAGE_UP", "PAGE_DOWN" } or {}) do
  local ok, err = pcall(function()
    RegisterKeyBind(Key[k], function()
      ExecuteInGameThread(function()
        local act = ALIAS[k] or k
        if ALIAS[k] and not Dev.open then return end
        local ok2, err2 = pcall(dev_action, act)
        if not ok2 then log("test menu " .. k .. ": " .. tostring(err2)) end
      end)
    end)
  end)
  if not ok then log("keybind " .. k .. " failed: " .. tostring(err)) end
end

