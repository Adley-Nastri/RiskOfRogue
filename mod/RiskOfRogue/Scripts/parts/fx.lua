-- Risk of Rogue: fx.lua
-- Deadzone visual effects for RoR2 procs.
-- Runs in the shared mod environment set up by main.lua (see docs/DEVELOPMENT.md).

---------------------------------------------------------------------------
-- Deadzone effects for RoR2 procs (host spawns and tells clients)
---------------------------------------------------------------------------
FX_BY_ID = {}
for _, f in ipairs(Data.FX) do FX_BY_ID[f.id] = f end
NS_CACHE = {}
function ns_asset(path)
  local a = NS_CACHE[path]
  if valid(a) then return a end
  a = StaticFindObject(path)
  if not valid(a) then pcall(function() a = LoadAsset(path) end) end
  NS_CACHE[path] = a
  return a
end
spawn_fx_local = function(id, x, y, z)
  local f = FX_BY_ID[id]
  if not f then return end
  local ns = ns_asset(f.system)
  local pc = local_pc()
  if not valid(ns) or not valid(pc) then return end
  pcall(function()
    cls("/Script/Niagara.Default__NiagaraFunctionLibrary"):SpawnSystemAtLocation(pc, ns, { X = x, Y = y, Z = z },
      { Pitch = 0, Yaw = 0, Roll = 0 }, { X = f.scale, Y = f.scale, Z = f.scale }, true, true, 0, true)
  end)
end
fx = function(id, x, y, z)
  spawn_fx_local(id, x, y, z)
  for _, pc in ipairs(FindAllOf("ValPlayerController") or {}) do
    send(pc, string.format("f|%s|%d|%d|%d", id, math.floor(x), math.floor(y), math.floor(z)))
  end
end
fx_at = function(id, actor)
  if valid(actor) then local x, y, z = loc(actor); fx(id, x, y, z) end
end

