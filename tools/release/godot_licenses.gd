extends SceneTree
## Writes the licence notices of the Godot engine this runs on (its own MIT licence and every third-party part
## it contains) to the file named after `--`. tools/build/appimage.sh runs it with the Godot that matches the
## export template:  godot --headless --path client --script <this file> -- <out.txt>


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1:
		push_error("usage: godot --headless --script godot_licenses.gd -- <out.txt>")
		quit(1)
		return
	var out := PackedStringArray()
	out.append("Godot Engine %s\n\n%s" % [Engine.get_version_info()["string"], Engine.get_license_text()])
	out.append("Third-party parts of Godot Engine:")
	for c: Dictionary in Engine.get_copyright_info():
		for p: Dictionary in c["parts"]:
			out.append("- %s\n  Files: %s\n  Copyright: %s\n  License: %s" % [c["name"],
					", ".join(p["files"]), "\n             ".join(p["copyright"]), p["license"]])
	var lic := Engine.get_license_info()
	for k: String in lic.keys():
		out.append("License %s:\n\n%s" % [k, lic[k]])
	var f := FileAccess.open(args[0], FileAccess.WRITE)
	if f == null:
		push_error("cannot write " + args[0])
		quit(1)
		return
	f.store_string("\n\n".join(out) + "\n")
	f.close()
	quit(0)
