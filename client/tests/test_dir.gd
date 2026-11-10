extends RefCounted
## One scratch folder per test run: user://test-runs/<process id>/. Godot names the user:// folder after the
## project, so every worktree shares it, and fixed file names there collide when tests run in parallel.
## Tests put their files and CDDA user dirs here (path / global); the entry scripts call clean() at the end,
## which also removes folders left by runs whose process is gone (a crash, a timeout).
## Use: const TestDir := preload("res://tests/test_dir.gd"), then TestDir.path("x.json").

const ROOT := "user://test-runs"

static var _dir := ""


## This run's folder as a user:// path, made on first use (emptied first: a dead run with the same id may
## have left one).
static func dir() -> String:
	if _dir.is_empty():
		_dir = ROOT.path_join(str(OS.get_process_id()))
		_remove_tree(_dir)
		DirAccess.make_dir_recursive_absolute(_dir)
	return _dir


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
				_dir = ROOT.path_join(id)
				return true
	return false


## Removes this run's folder and the folders of runs that are no longer running. A child run must not call it.
static func clean() -> void:
	if not _dir.is_empty():
		_remove_tree(_dir)
		_dir = ""
	if not DirAccess.dir_exists_absolute(ROOT):
		return
	for sub in DirAccess.get_directories_at(ROOT):
		if sub.is_valid_int() and not OS.is_process_running(int(sub)):
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
