class_name UserFiles
extends RefCounted
## Where the game's own files under user:// are read and written: settings, key bindings, bug reports, logs and
## CDDA's folder. In the game that is user:// itself. In a test run (Godot started with --script, so the main loop
## has a script) or a check run of the game (`-- --vr-check`, VrCheck's scenarios) it is that run's own folder,
## user://test-runs/run-<process id>/user/: such a run never reads or changes the player's files, and runs from
## several checkouts at once share none (Godot names user:// after the project, so every checkout has the same
## one). Code that opens such a file passes its path through at(). tests/test_dir.gd owns the run folders (stamps,
## cleaning; a check run's folder stays for a look and goes with the stale ones); a child run is pointed at its
## parent's folder with set_test_root.

const TEST_RUNS := "user://test-runs"

static var _root := ""        # a test run's folder for user files; "" = user:// itself
static var _decided := false


## `path` as it is opened: unchanged in the game, and for a path outside user:// or already under TEST_RUNS; in a
## test run the same name in the run's folder ("user://hud.cfg" -> "<run>/user/hud.cfg"). For the fixed names the
## game uses: in a test run a path with ".." gives "" (nothing opens), so nothing leaves the run's folder.
static func at(path: String) -> String:
	var root := test_root()
	if root.is_empty() or not path.begins_with("user://") or path == TEST_RUNS or path.begins_with(TEST_RUNS + "/"):
		return path
	if path.contains(".."):
		return ""
	DirAccess.make_dir_recursive_absolute(root)   # again each time: a test may have cleaned the run folder
	return root.path_join(path.trim_prefix("user://"))


## The folder user files go to in a test or check run, "" in the game.
static func test_root() -> String:
	if not _decided:
		var loop := Engine.get_main_loop()
		var by_args := script_run(OS.get_cmdline_args()) or check_run(OS.get_cmdline_user_args())
		if loop == null and not by_args:
			return ""   # too early to tell from the main loop, and the arguments don't say: asked again next time
		_decided = true
		if by_args or loop.get_script() != null:
			_root = TEST_RUNS.path_join("run-%d" % OS.get_process_id()).path_join("user")
	return _root


## Whether Godot's own arguments `args` start a script as the main loop (--script / -s): a test run, known before
## the main loop exists.
static func script_run(args: PackedStringArray) -> bool:
	return args.has("--script") or args.has("-s")


## Whether the game's own arguments `user_args` (those after "--") make it a check run: --vr-check or
## --vr-check=<names> (VrCheck's scenarios in a VR session, tools/vr/vr_check.sh).
static func check_run(user_args: PackedStringArray) -> bool:
	for a in user_args:
		if a == "--vr-check" or a.begins_with("--vr-check="):
			return true
	return false


## Points this test run's user files at `dir`, a folder under TEST_RUNS (a child run: its parent's). Anything else
## is ignored.
static func set_test_root(dir: String) -> void:
	if not dir.begins_with(TEST_RUNS + "/") or dir.contains(".."):
		return
	_decided = true
	_root = dir
