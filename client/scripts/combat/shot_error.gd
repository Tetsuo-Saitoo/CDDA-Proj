class_name ShotError
extends RefCounted
## CDDA's dispersion as angles for client-flown shots. CDDA rolls each projectile's error (arcmin) and a side
## (degrees, 0 = up on screen, 90 = right); the client turns its sight line by that much before flying the
## bullet. Also sizes the crosshair's spread circle. Inputs come from the bridge: non-finite values count as 0.

const MAX_ERROR_ARCMIN := 1800.0   # CDDA caps wild misses at 30 degrees


## `sight_dir` turned by `error_arcmin` toward the side `angle_deg` (0 up, 90 right, as seen along the sight).
## A zero or non-finite sight gives Vector3.ZERO.
static func apply(sight_dir: Vector3, error_arcmin: float, angle_deg: float) -> Vector3:
	if not sight_dir.is_finite() or sight_dir.length_squared() < 1e-12:
		return Vector3.ZERO
	var d := sight_dir.normalized()
	var err := clampf(error_arcmin, 0.0, MAX_ERROR_ARCMIN) if is_finite(error_arcmin) else 0.0
	var ang := deg_to_rad(fmod(angle_deg, 360.0)) if is_finite(angle_deg) else 0.0
	if err <= 0.0:
		return d
	var right := d.cross(Vector3.UP)
	if right.length_squared() < 1e-6:   # looking straight up or down
		right = d.cross(Vector3.FORWARD)
		if right.length_squared() < 1e-6:
			right = d.cross(Vector3.RIGHT)
	right = right.normalized()
	var up := right.cross(d)
	var off := up * cos(ang) + right * sin(ang)
	var e := deg_to_rad(err / 60.0)
	return (d * cos(e) + off * sin(e)).normalized()


## Radius in pixels of a cone of `arcmin` (half-angle) seen through a camera with vertical fov `fov_deg` on a
## view `viewport_h` pixels high. Clamped to 0 .. 0.45 * viewport_h; bad input gives 0.
static func spread_pixels(fov_deg: float, viewport_h: float, arcmin: float) -> float:
	if not (is_finite(fov_deg) and is_finite(viewport_h) and is_finite(arcmin)):
		return 0.0
	if fov_deg <= 0.0 or fov_deg >= 179.0 or viewport_h <= 0.0 or arcmin <= 0.0:
		return 0.0
	var cap := 0.45 * viewport_h
	var a := deg_to_rad(minf(arcmin / 60.0, 89.0))
	var px := tan(a) / tan(deg_to_rad(fov_deg) * 0.5) * viewport_h * 0.5
	return clampf(px, 0.0, cap) if is_finite(px) else cap
