-- Risk of Rogue: hud_widgets.lua
-- HUD building blocks: widget constructors and layout helpers.
-- Runs in the shared mod environment set up by main.lua (see docs/DEVELOPMENT.md).

---------------------------------------------------------------------------
-- HUD
---------------------------------------------------------------------------
HUD = nil
function new(classpath, outer, name) return StaticConstructObject(cls(classpath), outer, FName(name)) end
function text(wt, canvas, name, size)
  local tb = new("/Script/UMG.TextBlock", wt, name)
  local f = tb.Font; f.Size = size; tb:SetFont(f)
  tb:SetShadowOffset({ X = 1.5, Y = 1.5 })
  tb:SetShadowColorAndOpacity({ R = 0, G = 0, B = 0, A = 0.85 })
  local slot = canvas:AddChildToCanvas(tb)
  slot:SetAutoSize(true)
  return tb, slot
end
function image(wt, canvas, name)
  local img = new("/Script/UMG.Image", wt, name)
  local slot = canvas:AddChildToCanvas(img)
  return img, slot
end
function color(tb, c, a) tb:SetColorAndOpacity({ SpecifiedColor = { R = c[1], G = c[2], B = c[3], A = a or 1 }, ColorUseRule = 0 }) end
function anchor(slot, ax, ay, px, py, sx, sy, alx, aly)
  slot:SetAnchors({ Minimum = { X = ax, Y = ay }, Maximum = { X = ax, Y = ay } })
  slot:SetAlignment({ X = alx or 0, Y = aly or 0 })
  slot:SetPosition({ X = px, Y = py })
  if sx then slot:SetSize({ X = sx, Y = sy }) end
end

