extends RefCounted
## For the live tests' delta checks (live_test.gd, range_ui_live_test.gd): is a snapshot that was read from the
## bridge's delta call the plain snapshot of the same moment?


## "" when `a` (read from the delta call's answer, on the snapshot held) and `b` (the plain snapshot of the same
## moment) are the same: seq, turn, the player's square, the bubble's origin, and every submap's revisions, terrain,
## furniture, traps, items and what is known of them, fields, flags, vis, light, lights and heat; else what differs
## first.
static func diff(a: Snapshot, b: Snapshot) -> String:
	if a.seq != b.seq or a.turn != b.turn or a.player_pos != b.player_pos or a.bubble_origin != b.bubble_origin:
		return "seq %d / %d, turn %d / %d, player %s / %s, origin %s / %s" % [a.seq, b.seq, a.turn, b.turn,
				a.player_pos, b.player_pos, a.bubble_origin, b.bubble_origin]
	if a.submaps.size() != b.submaps.size():
		return "%d submaps, the plain one has %d" % [a.submaps.size(), b.submaps.size()]
	for p: Vector3i in b.submaps:
		var x: Snapshot.Submap = a.submaps.get(p)
		var y: Snapshot.Submap = b.submaps[p]
		if x == null:
			return "no submap %s" % p
		if x.revision != y.revision or x.detail_revision != y.detail_revision:
			return "submap %s: revisions %d.%d / %d.%d" % [p, x.revision, x.detail_revision, y.revision, y.detail_revision]
		for f: String in ["ter", "furn", "trap", "items", "handles", "fields", "flags", "vis", "light", "poses",
				"shelves", "more", "inside", "inside_more", "lights", "lights_sent", "heat"]:
			if y.get(f) == null:
				return "a submap has no %s to compare" % f
			if x.get(f) != y.get(f):
				return "submap %s: %s differs" % [p, f]
		if x.cookware.size() != y.cookware.size():
			return "submap %s: %d / %d cookware" % [p, x.cookware.size(), y.cookware.size()]
	return ""
