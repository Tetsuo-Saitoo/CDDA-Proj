extends Logger
## Collects engine and script errors (not warnings) while tests run, so a run that printed a SCRIPT ERROR
## (a cast of a freed object, a call on null, ...) fails instead of saying "all passed". GDScript stops the
## function that hits a runtime error, so the checks after it never ran.
## Used by tests/run_tests.gd: OS.add_logger(catch) at the start, take() at the end.
## Logger calls come from any thread, so everything is behind the mutex. Nothing here may print or raise an
## error itself: that would call back into the logger.

const MAX_KEPT := 100

## Errors whose message starts with one of these are expected (negative tests feed bad text to parsers).
## Set it before OS.add_logger.
var allowed := PackedStringArray()

var _lock := Mutex.new()
var _kept := PackedStringArray()
var _dropped := 0


func _log_error(function: String, file: String, line: int, code: String, rationale: String,
		_editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
	if error_type == ERROR_TYPE_WARNING:
		return
	var text := rationale if not rationale.is_empty() else code
	for a in allowed:
		if text.begins_with(a):
			return
	var kind := "SCRIPT ERROR" if error_type == ERROR_TYPE_SCRIPT else (
			"SHADER ERROR" if error_type == ERROR_TYPE_SHADER else "ERROR")
	_lock.lock()
	if _kept.size() < MAX_KEPT:
		_kept.append("%s: %s (%s, %s:%d)" % [kind, text, function, file, line])
	else:
		_dropped += 1
	_lock.unlock()


## Removes the kept errors whose line contains `part`; returns how many there were.
func take_matching(part: String) -> int:
	_lock.lock()
	var rest := PackedStringArray()
	for e in _kept:
		if not e.contains(part):
			rest.append(e)
	var n := _kept.size() - rest.size()
	_kept = rest
	_lock.unlock()
	return n


## Every error seen since the last take, and empties the list.
func take() -> PackedStringArray:
	_lock.lock()
	var out := _kept
	if _dropped > 0:
		out.append("... and %d more" % _dropped)
	_kept = PackedStringArray()
	_dropped = 0
	_lock.unlock()
	return out
