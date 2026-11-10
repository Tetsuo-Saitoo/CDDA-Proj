extends RefCounted
## One scratch folder per test run: user://test-runs/<process id>/. Godot names the user:// folder after the
## project, so every worktree shares it, and fixed file names there collide when tests run in parallel.
## Tests put their files and CDDA user dirs here (path / global); the entry scripts call clean() at the end,
## which also removes folders that runs left behind (a crash, a timeout) once they are STALE_S old.
## Use: const TestDir := preload("res://tests/test_dir.gd"), then TestDir.path("x.json").

const ROOT := "user://test-runs"
## Each folder's start mark: the unix time its run began.
const MARK := ".run"
## Another run's folder goes only when it started longer ago than this. Whether its process still runs
## can't be asked: OS.is_process_running only knows Godot's own child processes (others read as gone).
const STALE_S := 6 * 3600

static var _dir := ""


## This run's folder as a user:// path, made on first use with its start mark (emptied first: no live
## process has this id, so a folder with it was left by a dead run).
static func dir() -> String:
	if _dir.is_empty():
		_dir = ROOT.path_join(str(OS.get_process_id()))
		_remove_tree(_dir)
		DirAccess.make_dir_recursive_absolute(_dir)
		var f := FileAccess.open(_dir.path_join(MARK), FileAccess.WRITE)
		if f != null:
			f.store_string(str(int(Time.get_unix_time_from_system())))
			f.close()
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


## Removes this run's folder and folders whose run started over STALE_S ago. A child run must not call it.
static func clean() -> void:
	if not _dir.is_empty():
		_remove_tree(_dir)
		_dir = ""
	if not DirAccess.dir_exists_absolute(ROOT):
		return
	var now := int(Time.get_unix_time_from_system())
	for sub in DirAccess.get_directories_at(ROOT):
		var t := started(ROOT.path_join(sub))
		if sub.is_valid_int() and t > 0 and now - t > STALE_S:
			_remove_tree(ROOT.path_join(sub))


## When the run owning `folder` began: its start mark, else the folder's own time; 0 if neither is known
## (such a folder is left alone).
static func started(folder: String) -> int:
	var mark := folder.path_join(MARK)
	if FileAccess.file_exists(mark):
		var f := FileAccess.open(mark, FileAccess.READ)
		if f != null and f.get_length() <= 32:
			var t := f.get_as_text().strip_edges()
			if t.is_valid_int():
				return int(t)
	return FileAccess.get_modified_time(folder) if DirAccess.dir_exists_absolute(folder) else 0


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
