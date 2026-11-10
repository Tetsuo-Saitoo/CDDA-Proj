extends RefCounted
## One scratch folder per test run: user://test-runs/run-<process id>/. Godot names the user:// folder after the
## project, so every worktree shares it, and fixed file names there collide when tests run in parallel.
## Tests put their files and CDDA user dirs here (path / global); the entry scripts call clean() at the end,
## which also removes stale folders left by runs that crashed or timed out.
## Use: const TestDir := preload("res://tests/test_dir.gd"), then TestDir.path("x.json").
## Another run's folder counts as stale only by the age of its STAMP file: OS.is_process_running only knows this
## process's own children, so a pid check deleted parallel runs' folders while they ran.

const ROOT := "user://test-runs"
const PREFIX := "run-"               # folders are run-<pid>; older code deletes bare-number folders as dead runs
const STAMP := ".started"            # written when a run makes its folder
const STALE_S := 12 * 3600           # another run's folder that started longer ago than this is removed

static var _dir := ""


## This run's folder as a user:// path, made on first use (emptied first: a dead run with the same id may
## have left one).
static func dir() -> String:
	if _dir.is_empty():
		_dir = ROOT.path_join(PREFIX + str(OS.get_process_id()))
		_remove_tree(_dir)
		DirAccess.make_dir_recursive_absolute(_dir)
		stamp(_dir)
	return _dir


## Marks folder `user_path` as started at unix time `at` (default now).
static func stamp(user_path: String, at := -1) -> void:
	var f := FileAccess.open(user_path.path_join(STAMP), FileAccess.WRITE)
	if f != null:
		f.store_string(str(at if at >= 0 else int(Time.get_unix_time_from_system())))


## When the run using folder `user_path` started: its stamp, else (being made, or older code) the folder's own time.
static func _started(user_path: String) -> int:
	var s := user_path.path_join(STAMP)
	if FileAccess.file_exists(s):
		var t := FileAccess.get_file_as_string(s).strip_edges()
		if t.is_valid_int():
			return int(t)
	return FileAccess.get_modified_time(user_path)


## A file or folder name in this run's folder, as a user:// path.
static func path(name: String) -> String:
	return dir().path_join(name)


## The same as an absolute OS path (the bridge and CDDA take those).
static func global(name: String) -> String:
	return ProjectSettings.globalize_path(path(name))


## The argument that hands this run's folder to a child Godot run (live_test.gd's load run).
static func child_arg() -> String:
	dir()
	return "--test-run=%d" % OS.get_process_id()


## In a child run: uses the parent's folder named by `--test-run=<id>` in `args`. False if there is none.
static func use_parent(args: PackedStringArray) -> bool:
	for a in args:
		if a.begins_with("--test-run="):
			var id := a.trim_prefix("--test-run=")
			if id.is_valid_int() and int(id) > 0 and str(int(id)) == id:
				_dir = ROOT.path_join(PREFIX + id)
				return true
	return false


## Removes this run's folder and stale folders of other runs (started more than STALE_S ago). Folders of runs
## still going in other checkouts are kept. A child run must not call it.
static func clean() -> void:
	if not _dir.is_empty():
		_remove_tree(_dir)
		_dir = ""
	if not DirAccess.dir_exists_absolute(ROOT):
		return
	var now := int(Time.get_unix_time_from_system())
	for sub in DirAccess.get_directories_at(ROOT):
		if not sub.begins_with(PREFIX) or not sub.trim_prefix(PREFIX).is_valid_int():
			continue
		if now - _started(ROOT.path_join(sub)) > STALE_S:
			_remove_tree(ROOT.path_join(sub))


## Deletes a folder under ROOT with everything in it. Links are removed, never followed.
static func _remove_tree(user_path: String) -> void:
	if not user_path.begins_with(ROOT + "/") or user_path.contains("..") or not DirAccess.dir_exists_absolute(user_path):
		return
	var d := DirAccess.open(user_path)
	if d == null:
		return
	d.include_hidden = true
	for f in d.get_files():
		d.remove(f)
	for sub in d.get_directories():
		if d.is_link(sub):
			d.remove(sub)
		else:
			_remove_tree(user_path.path_join(sub))
	DirAccess.remove_absolute(user_path)
