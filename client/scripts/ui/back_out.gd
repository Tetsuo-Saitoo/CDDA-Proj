class_name BackOut
extends RefCounted
## Esc, and a pad's Start (user, 2026-11-17): each press backs out of one thing, the topmost first; with nothing
## open or in progress, the caller opens the game menu (the F1 menu: Options, Keys, Cheats, Save and quit, Close).
## The parts that read Esc themselves (a prompt, the F1 menu, the Tab view, the character screen) still get a real
## Esc first; main runs the steps on what reaches it, so Start works the same and nothing gets stuck behind a part
## that let Esc through. ORDER is the order, whatever order main adds the steps in.

const ORDER: PackedStringArray = [
	"keyboard",        # the on-screen keys of a text field (pad Y)
	"prompt",          # a game prompt or list, aiming (a target prompt), a wheel showing
	"teleport pick",   # the F1 cheat's "pick a square"
	"character",       # the character screen (P)
	"inventory",       # the Tab view: its selection first, then the view
	"tray",            # the items of a bag or pile laid out
	"carry",           # an item carried with the mouse
	"wheel",           # E's wheel, asked for and not shown yet
	"ascii",           # the ASCII view (F3)
	"look",            # the look panel and its line and marker
]

var _steps := {}   # name -> [open: Callable () -> bool, back: Callable () -> bool]


## Adds the step `what` (a name in ORDER): `open` says whether it is up now, `back` backs out of it (true when it
## did; false lets the next step go). False (nothing added) for a name not in ORDER.
func add(what: String, open: Callable, back: Callable) -> bool:
	if not what in ORDER:
		return false
	_steps[what] = [open, back]
	return true


## Backs out of the first open step (ORDER) whose back() worked: its name, or "" when nothing was (then the menu).
func step() -> String:
	for what: String in ORDER:
		var s: Array = _steps.get(what, [])
		if not s.is_empty() and (s[0] as Callable).call() == true and (s[1] as Callable).call() == true:
			return what
	return ""


## The steps open now, in ORDER (tests, the debug line).
func open_now() -> PackedStringArray:
	var out := PackedStringArray()
	for what: String in ORDER:
		var s: Array = _steps.get(what, [])
		if not s.is_empty() and (s[0] as Callable).call() == true:
			out.append(what)
	return out


## Esc pressed (not a repeat; any modifiers) or a pad's Start pressed.
static func is_back(event: InputEvent) -> bool:
	var k := event as InputEventKey
	if k != null:
		return k.pressed and not k.echo and (k.physical_keycode == KEY_ESCAPE or k.keycode == KEY_ESCAPE)
	var b := event as InputEventJoypadButton
	return b != null and b.pressed and b.button_index == InputActions.MENU_PAD


## A pressed Esc key, for the parts that read Esc themselves (Start goes to them as this).
static func esc() -> InputEventKey:
	var k := InputEventKey.new()
	k.keycode = KEY_ESCAPE
	k.physical_keycode = KEY_ESCAPE
	k.pressed = true
	return k
