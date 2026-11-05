class_name CddaPalette
extends RefCounted
## Colours for placeholder art: CDDA colour names (id tables) and registry material names.
##
## CDDA's terminal colours are loud (wood floors are cyan), so each name maps to a muted albedo that
## keeps CDDA's meaning: cyan reads as metal or glass, brown as wood, and so on.

const NAMED := {
	"black": Color(0.13, 0.13, 0.14), "white": Color(0.86, 0.85, 0.82),
	"light_gray": Color(0.64, 0.64, 0.62), "dark_gray": Color(0.33, 0.33, 0.35),
	"red": Color(0.6, 0.2, 0.17), "green": Color(0.27, 0.47, 0.22), "blue": Color(0.25, 0.34, 0.6),
	"cyan": Color(0.42, 0.53, 0.57), "magenta": Color(0.55, 0.28, 0.55), "brown": Color(0.47, 0.33, 0.2),
	"light_red": Color(0.8, 0.45, 0.4), "light_green": Color(0.45, 0.66, 0.34),
	"light_blue": Color(0.45, 0.6, 0.82), "light_cyan": Color(0.62, 0.74, 0.77),
	"pink": Color(0.86, 0.6, 0.7), "yellow": Color(0.84, 0.74, 0.32),
}
## Longest first, so "light_gray" wins over a shorter name.
const NAMES := ["light_green", "light_blue", "light_cyan", "light_gray", "light_red", "dark_gray",
		"magenta", "yellow", "black", "white", "brown", "green", "pink", "blue", "cyan", "red"]

## Registry `material` names (assets/materials doesn't exist yet: these are the placeholders).
const MATERIALS := {
	"soil": Color(0.42, 0.32, 0.22), "grass": Color(0.33, 0.52, 0.22),
	"asphalt": Color(0.2, 0.2, 0.22), "concrete": Color(0.58, 0.58, 0.56),
	"wood_floor": Color(0.6, 0.45, 0.28), "wood_floor_waxed": Color(0.66, 0.44, 0.27),
	"plaster_white": Color(0.88, 0.86, 0.82), "brick": Color(0.58, 0.27, 0.2),
	"roof_tar": Color(0.24, 0.23, 0.25), "wood_plank": Color(0.52, 0.37, 0.23),
	"wood": Color(0.56, 0.4, 0.25), "wood_dark": Color(0.36, 0.25, 0.16), "wood_pale": Color(0.72, 0.6, 0.43),
	"metal": Color(0.6, 0.62, 0.64), "metal_dark": Color(0.3, 0.31, 0.33), "enamel": Color(0.9, 0.9, 0.88),
	"stone": Color(0.55, 0.54, 0.5), "foliage": Color(0.24, 0.43, 0.19), "cardboard": Color(0.66, 0.52, 0.34),
	"canvas": Color(0.45, 0.5, 0.38), "ceramic": Color(0.92, 0.92, 0.9), "plastic_green": Color(0.2, 0.42, 0.25),
}

const DEFAULT := Color(0.6, 0.6, 0.6)
const GLASS := Color(0.6, 0.8, 0.9, 0.35)


## Foreground colour of a CDDA colour name: "c_light_blue_green" -> light blue, "i_white" -> white.
## Unknown or empty names give `fallback`.
static func fg(cdda: String, fallback := DEFAULT) -> Color:
	var parts := _split(cdda)
	return NAMED[parts[0]] if not parts[0].is_empty() else fallback


## Background colour ("c_light_blue_green" -> green), or the foreground when there is none. Plants
## carry their leaves in the background and their berries or flowers in the foreground.
static func bg(cdda: String, fallback := DEFAULT) -> Color:
	var parts := _split(cdda)
	if not parts[1].is_empty():
		return NAMED[parts[1]]
	return NAMED[parts[0]] if not parts[0].is_empty() else fallback


static func material(name: String, fallback := DEFAULT) -> Color:
	return MATERIALS.get(name, fallback)


## [fg, bg] base names, "" where unknown.
static func _split(cdda: String) -> PackedStringArray:
	var out := PackedStringArray(["", ""])
	if cdda.length() < 3 or cdda.length() > 48 or cdda[1] != "_":
		return out
	var rest := cdda.substr(2)
	for n: String in NAMES:
		if rest == n:
			out[0] = n
			return out
		if rest.begins_with(n + "_"):
			out[0] = n
			var b := rest.substr(n.length() + 1)
			if NAMED.has(b):
				out[1] = b
			return out
	return out
