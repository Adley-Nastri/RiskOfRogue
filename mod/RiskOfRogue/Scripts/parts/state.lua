-- Risk of Rogue: state.lua
-- Run state (authoritative on the host), messages to clients, giving and taking items.
-- Runs in the shared mod environment set up by main.lua (see docs/DEVELOPMENT.md).

---------------------------------------------------------------------------
-- run state (authoritative on the host)
---------------------------------------------------------------------------
Run = {}
function reset_run()
  Run = {
    players = {},        -- name -> {items={}, handles={}, pawn=addr, base_jump=nil, infusion=0}
    clock = 0.0,         -- seconds of run time
    last_world_t = nil,
    buffed = {},         -- bot addr -> time the clock buff was applied
    killed = {},         -- bot addr -> time of death (dedupe kill hooks)
  }
end
reset_run()

function pstate(name)
  local st = Run.players[name]
  if not st then st = { items = {}, handles = {}, pawn = 0, infusion = 0 }; Run.players[name] = st end
  return st
end
function count(st, id) return st.items[id] or 0 end

-- view = what the local HUD draws (host fills it directly, clients from messages)
View = { clock = 0, items = {}, banners = {}, ticker = {}, buffs = {}, bcount = {}, in_run = false }
BUFF_BY_ID = {}
for _, b in ipairs(Data.BUFFS) do BUFF_BY_ID[b.id] = b end
-- RoR2 buff row states and proc messages for the sheet-driven items (filled in below the engine)
Procs = { hits = 0 }
function ticker(text)
  table.insert(View.ticker, 1, { text = text, t = now_ms })
  while #View.ticker > 4 do table.remove(View.ticker) end
end

-- message helpers ---------------------------------------------------------
function send(pc, msg)
  if valid(pc) and not pc:IsLocalController() then
    pcall(function() pc:ClientMessage(TAG .. msg, FName("None"), 0.0) end)
  end
end
function pc_of(name)
  for _, pc in ipairs(FindAllOf("ValPlayerController") or {}) do
    if valid(pc) and player_name(pc) == name then return pc end
  end
end
function notify(name, kind, payload)
  local pc = pc_of(name)
  if not valid(pc) then return end
  if pc:IsLocalController() then
    if kind == "p" then table.insert(View.banners, { id = payload, t = now_ms })
    elseif kind == "b" then local b = BUFF_BY_ID[payload]; if b then View.buffs[payload] = now_ms + b.duration_ms; View.bcount[payload] = 1 end
    elseif kind == "B" then
      local id, ms, c = payload:match("^([^|]+)|(%d+)|?(%d*)$")
      if id and BUFF_BY_ID[id] then View.buffs[id] = now_ms + tonumber(ms); View.bcount[id] = tonumber(c) or 1 end
    elseif kind == "t" then ticker(payload) end
  else
    send(pc, kind .. "|" .. payload)
  end
end

---------------------------------------------------------------------------
-- items
---------------------------------------------------------------------------
function apply_items(name)
  local st = pstate(name)
  local pc = pc_of(name)
  if not valid(pc) then return end
  local pawn = pc.Pawn
  if not alive(pawn) then return end
  for _, it in ipairs(Data.ITEMS) do
    local n = count(st, it.id)
    if it.kind == "stat" or it.kind == "growth" then
      remove_effect(pawn, st.handles[it.id]); st.handles[it.id] = nil
      local mag = 0
      if it.kind == "stat" and n > 0 then mag = stack_mag(it, n) end
      if it.kind == "growth" and n > 0 then mag = math.min(st.infusion, it.dmg * n) end
      if n > 0 and mag ~= 0 then st.handles[it.id] = apply_magnitude(pawn, it.ge, mag) end
    end
    if it.kind == "stat" and it.ge2 ~= "" then
      remove_effect(pawn, st.handles[it.id .. "#2"]); st.handles[it.id .. "#2"] = nil
      local mag2 = it.op2 == "mult" and (1 + it.k2 * n) or (it.k2 * n)
      if n > 0 then st.handles[it.id .. "#2"] = apply_magnitude(pawn, it.ge2, mag2) end
    end
    if it.pge ~= "" then
      remove_effect(pawn, st.handles[it.id .. "#p"]); st.handles[it.id .. "#p"] = nil
      local magp = it.pop == "mult" and (1 + it.pk * n) or (it.pk * n)
      if n > 0 then st.handles[it.id .. "#p"] = apply_magnitude(pawn, it.pge, magp) end
    end
    if it.kind == "jump" then
      if not st.base_jump then st.base_jump = pawn.JumpMaxCount end
      pawn.JumpMaxCount = st.base_jump + math.floor(it.k * n)
      send(pc, "j|" .. tostring(pawn.JumpMaxCount))
    end
  end
end

function give(name, id, n)
  local it = Data.ITEM_BY_ID[id]
  if not it then return end
  local st = pstate(name)
  st.items[id] = count(st, id) + (n or 1)
  log(name .. " picked up " .. it.name .. " (x" .. st.items[id] .. ")")
  apply_items(name)
  notify(name, "p", id)
end

function take(name, id, n)
  local it = Data.ITEM_BY_ID[id]
  if not it then return end
  local st = pstate(name)
  st.items[id] = math.max(0, count(st, id) - (n or 1))
  if id == "Infusion" and st.items[id] == 0 then st.infusion = 0 end
  log(name .. " lost " .. it.name .. " (x" .. st.items[id] .. ")")
  apply_items(name)
end
function take_all(name)
  local st = pstate(name)
  st.items = {}
  st.infusion = 0
  apply_items(name)
end

function roll_rarity(weight_key)
  local total = 0
  for _, r in ipairs(Data.RARITIES) do total = total + r[weight_key] end
  local x = math.random() * total
  for _, r in ipairs(Data.RARITIES) do x = x - r[weight_key]; if x <= 0 then return r.id end end
  return Data.RARITIES[1].id
end
function roll_item(rarity)
  local pool = {}
  for _, it in ipairs(Data.ITEMS) do if it.rarity == rarity then pool[#pool + 1] = it.id end end
  return pool[math.random(#pool)]
end

