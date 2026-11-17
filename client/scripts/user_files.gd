class_name UserFiles
extends RefCounted
## Where the game's own files under user:// are read and written: settings, key bindings, bug reports, logs and
## CDDA's folder. In the game that is user:// itself. In a test run (Godot started with --script, so the main loop
## has a script) it is that run's own folder, user://test-runs/run-<process id>/user/: a test never reads or
## changes the player's files, and runs from several checkouts at once share none (Godot names user:// after the
## project, so every checkout has the same one). Code that opens such a file passes its path through at().
## tests/test_dir.gd owns the run folders (stamps, cleaning); a child run is pointed at its parent's folder with
## set_test_root.

const TEST_RUNS := "user://test-runs"

static var _root := ""        # a test run's folder for user files; "" = user:// itself
static var _decided := false


## `path` as it is opened: unchanged in the game, and for a path outside user:// or already under TEST_RUNS; in a
## test run the same name in the run's folder ("user://hud.cfg" -> "<run>/user/hud.cfg").
static func at(path: String) -> String:
	var root := test_root()
	if root.is_empty() or not path.begins_with("user://") or path == TEST_RUNS or path.begins_with(TEST_RUNS + "/"):
		return path
	DirAccess.make_dir_recursive_absolute(root)   # again each time: a test may have cleaned the run folder
	return root.path_join(path.trim_prefix("user://"))


## The folder user files go to in a test run, "" in the game.
static func test_root() -> String:
	if not _decided:
		var loop := Engine.get_main_loop()
		if loop == null:
			return ""   # too early to tell: asked again on the next call
		_decided = true
		if loop.get_script() != null:
			_root = TEST_RUNS.path_join("run-%d" % OS.get_process_id()).path_join("user")
	return _root


## Points this test run's user files at `dir`, a folder under TEST_RUNS (a child run: its parent's). Anything else
## is ignored.
static func set_test_root(dir: String) -> void:
	if not dir.begins_with(TEST_RUNS + "/") or dir.contains(".."):
		return
	_decided = true
	_root = dir
