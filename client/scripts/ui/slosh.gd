class_name Slosh
extends RefCounted
## Live item tiles, slice 2: a liquid's surface as a damped spring. push() gives it a shove (a camera turn, a step,
## a drag), step() moves it on; `tilt` -1..1 is how far the surface leans, back to 0 in a second or two.
## ItemTileView draws the fill's edge leaning by it.

const STIFF := 60.0       # pull back to level, per unit of tilt
const DAMP := 4.0         # how fast it calms
const MAX_VEL := 20.0
const REST := 0.002       # below this, tilt and speed count as still
const MAX_DT := 0.05      # a long frame doesn't fling it

var tilt := 0.0
var vel := 0.0


## A shove of `v` (tilt per second); NaN or infinite ones are ignored.
func push(v: float) -> void:
	if is_finite(v):
		vel = clampf(vel + v, -MAX_VEL, MAX_VEL)


## Moves it on by `dt` seconds; true while it still moves.
func step(dt: float) -> bool:
	if not is_finite(dt) or dt <= 0.0:
		return moving()
	dt = minf(dt, MAX_DT)
	vel += (-STIFF * tilt - DAMP * vel) * dt   # semi-implicit Euler: stable at these rates
	tilt = clampf(tilt + vel * dt, -1.0, 1.0)
	if not moving():
		tilt = 0.0
		vel = 0.0
	return moving()


func moving() -> bool:
	return absf(tilt) > REST or absf(vel) > REST
