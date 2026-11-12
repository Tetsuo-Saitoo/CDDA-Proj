class_name PanelFit
extends RefCounted
## L4: draws a screen menu `k` times larger while it still fills its parent, for the VR panel (1 logical pixel is
## about 1.1 mm at the panel's distance: 16 px text wants to be 20 px or more). The menu lays out as on a screen
## 1 / k the size and is scaled up from its top-left corner; the margins it had on the screen (its offsets) stay
## the same on the panel. Done with anchors alone, so it follows the parent's size by itself.
## Only for a Control anchored to its parent's full rect (the menus are); anything else is left as it is.

## Meta on a fitted Control: the margins it had before, [left, top, right, bottom].
const META := &"panel_fit"
const MIN_SCALE := 0.5
const MAX_SCALE := 3.0


## Fits `c` at scale `k` (MIN_SCALE..MAX_SCALE; not a number: 1). Again with another `k` changes it; 1 puts the
## full-rect anchors and its margins back. False when `c` isn't a full-rect Control.
static func apply(c: Control, k: float) -> bool:
	if not is_instance_valid(c):
		return false
	if not c.has_meta(META):
		if not (c.anchor_left == 0.0 and c.anchor_top == 0.0 and c.anchor_right == 1.0 and c.anchor_bottom == 1.0):
			return false
		c.set_meta(META, [c.offset_left, c.offset_top, -c.offset_right, -c.offset_bottom])
	var m: Array = c.get_meta(META)
	var s := clampf(k, MIN_SCALE, MAX_SCALE) if is_finite(k) else 1.0
	c.anchor_right = 1.0 / s
	c.anchor_bottom = 1.0 / s
	c.offset_left = m[0]
	c.offset_top = m[1]
	c.offset_right = m[0] - (m[0] + m[2]) / s
	c.offset_bottom = m[1] - (m[1] + m[3]) / s
	c.pivot_offset = Vector2.ZERO
	c.scale = Vector2(s, s)
	if is_equal_approx(s, 1.0):
		c.remove_meta(META)
	return true
