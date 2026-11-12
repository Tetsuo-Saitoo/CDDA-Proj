class_name WeatherSound
extends Node
## Blocks C6 / I2: what the weather sounds like: rain, wind and thunder.
##
## No sound files: four short clips of filtered noise, made once on a worker thread (plain bytes; the streams and
## players are made on the main thread). Rain outdoors is a hiss; under a roof it is quieter and a duller patter
## joins it. The wind follows the wind on the player's square (calm indoors) with a little of the region's wind
## left. Thunder follows a lightning flash after a moment, and far rumbles come now and then during a thunderstorm.
## Not positional (the weather is everywhere), so the same on a flat screen and in VR. Loudness changes glide;
## nothing plays and nothing is processed in still, dry weather.

const RATE := 11025            # Hz, mono, 16 bit
const RAIN_S := 2.0
const WIND_S := 4.0
const THUNDER_S := 4.0
const FADE_PER_S := 1.2        # how fast a loudness glides (full range in under a second)
const RAIN_GAIN := 0.5         # loudness of heavy rain in the open (linear)
const INDOOR_RAIN := 0.15      # share of the outdoor hiss heard under a roof
const ROOF_GAIN := 0.45        # loudness of heavy rain on the roof
const WIND_GAIN := 0.6         # loudness of a gale
const WIND_FULL := 15.0        # m/s that counts as a gale
const INDOOR_WIND := 0.25      # share of the region's wind heard where the air is still
const THUNDER_GAIN := 0.9
const FAR_GAIN := 0.3          # a far rumble
const THUNDER_DELAY := Vector2(0.4, 2.5)    # seconds from flash to thunder
const RUMBLE_EVERY := Vector2(25.0, 70.0)   # seconds between far rumbles in a thunderstorm
const SILENT_DB := -60.0

var rain := AudioStreamPlayer.new()      # the hiss in the open
var roof := AudioStreamPlayer.new()      # the patter under a roof
var wind := AudioStreamPlayer.new()
var thunder := AudioStreamPlayer.new()
var targets := {}                        # player -> loudness wanted (linear 0..1)
var _gains := {}                         # player -> loudness now
var _thunder_in := -1.0                  # seconds until the next thunder, -1 none
var _thunder_gain := 0.0
var _rumble_in := -1.0                   # seconds until the next far rumble, -1 not a thunderstorm
var _rng := RandomNumberGenerator.new()
static var _task := -1                   # WorkerThreadPool task making the clips
static var _clips := {}                  # name -> PackedByteArray, filled by the task
static var _streams := {}                # name -> AudioStreamWAV, made from the clips on the main thread


func _init() -> void:
	for p: AudioStreamPlayer in [rain, roof, wind, thunder]:
		p.volume_db = SILENT_DB
		add_child(p)
		targets[p] = 0.0
		_gains[p] = 0.0
	thunder.max_polyphony = 2
	_rng.seed = 20261112
	prepare()


func _ready() -> void:
	_update_processing()   # a node with _process starts processing on its own


## Starts making the clips on a worker, once (they are ready well before the first rain).
static func prepare() -> void:
	if _task < 0 and _streams.is_empty():
		_task = WorkerThreadPool.add_task(_make_clips, false, "weather sounds")


## True once the clips are made; turns them into streams the first time (main thread).
static func ready_now(wait := false) -> bool:
	if not _streams.is_empty():
		return true
	if _task < 0:
		prepare()
	if not wait and not WorkerThreadPool.is_task_completed(_task):
		return false
	WorkerThreadPool.wait_for_task_completion(_task)
	_task = -1
	for name: String in _clips:
		var w := AudioStreamWAV.new()
		w.format = AudioStreamWAV.FORMAT_16_BITS
		w.mix_rate = RATE
		w.data = _clips[name]
		if name != "thunder":
			w.loop_mode = AudioStreamWAV.LOOP_FORWARD
			w.loop_begin = 0
			w.loop_end = (_clips[name] as PackedByteArray).size() / 2
		_streams[name] = w
	_clips.clear()
	return true


static func stream(name: String) -> AudioStreamWAV:
	return _streams.get(name)


static func _make_clips() -> void:
	var made := {"rain": clip("rain"), "roof": clip("roof"), "wind": clip("wind"), "thunder": clip("thunder")}
	_clips = made


## One clip as 16-bit samples: noise through simple filters. `rain` a bright hiss, `roof` a dull patter, `wind` a
## low rush that swells (whole swells per loop, so it repeats without a step), `thunder` a crack fading into a
## long rumble.
static func clip(name: String) -> PackedByteArray:
	var secs: float = {"rain": RAIN_S, "roof": RAIN_S, "wind": WIND_S, "thunder": THUNDER_S}[name]
	var n := int(RATE * secs)
	var data := PackedByteArray()
	data.resize(n * 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(name)
	var low := 0.0     # a low-passed copy of the noise
	var slow := 0.0    # a much slower one
	var v := 0.0
	match name:
		"rain":
			for i in n:
				var white := rng.randf_range(-1.0, 1.0)
				low += (white - low) * 0.25
				v = (white - low) * 0.45
				data.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 32000.0))
		"roof":
			for i in n:
				var white := rng.randf_range(-1.0, 1.0)
				low += (white - low) * 0.06
				slow += (absf(white) - slow) * 0.002
				v = low * 2.2 * (0.6 + 0.8 * slow)
				data.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 32000.0))
		"wind":
			for i in n:
				var t := float(i) / RATE
				low += (rng.randf_range(-1.0, 1.0) - low) * 0.035
				v = low * 3.0 * (0.65 + 0.25 * sin(TAU * t * 2.0 / WIND_S) + 0.1 * sin(TAU * t * 5.0 / WIND_S))
				data.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 32000.0))
		"thunder":
			for i in n:
				var t := float(i) / RATE
				var white := rng.randf_range(-1.0, 1.0)
				low += (white - low) * (0.5 * exp(-t * 9.0) + 0.03)
				slow += (white - slow) * 0.0015
				var env := minf(t * 60.0, 1.0) * exp(-t * 0.9) * (0.75 + 2.5 * absf(slow))
				v = low * 3.2 * env * minf((THUNDER_S - t) * 2.0, 1.0)
				data.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 32000.0))
	return data


## Sets what should be heard for `state` (thunderstorm: CDDA's sound category for the weather is thunder).
func apply(state: WeatherState) -> void:
	var strength := state.precip * state.precip if not state.snow else 0.0   # snow falls silently
	targets[rain] = strength * RAIN_GAIN * (INDOOR_RAIN if state.sheltered else 1.0)
	targets[roof] = strength * ROOF_GAIN if state.sheltered else 0.0
	var air := maxf(state.wind_here.length(), state.wind.length() * INDOOR_WIND)
	targets[wind] = clampf(air / WIND_FULL, 0.0, 1.0) * WIND_GAIN
	if not state.thunder:
		_rumble_in = -1.0
	elif _rumble_in < 0.0:
		_rumble_in = _rng.randf_range(RUMBLE_EVERY.x, RUMBLE_EVERY.y)
	_update_processing()


## Lightning struck: thunder follows after a moment (`near` 0..1: how close; 1 is overhead).
func strike(near := 1.0) -> void:
	_thunder_in = lerpf(THUNDER_DELAY.y, THUNDER_DELAY.x, clampf(near, 0.0, 1.0)) * _rng.randf_range(0.8, 1.2)
	_thunder_gain = THUNDER_GAIN * lerpf(0.5, 1.0, clampf(near, 0.0, 1.0))
	_update_processing()


func _process(delta: float) -> void:
	tick(delta)


## One step of the glides and timers (tests call it directly).
func tick(delta: float) -> void:
	var have := ready_now()
	for p: AudioStreamPlayer in [rain, roof, wind]:
		var want: float = targets[p]
		var now: float = move_toward(_gains[p], want, FADE_PER_S * delta)
		_gains[p] = now
		if now > 0.0 and have:
			if not p.playing:
				p.stream = stream(_name_of(p))
				p.play()
			p.volume_db = linear_to_db(now)
		elif p.playing:
			p.stop()
			p.volume_db = SILENT_DB
	if _thunder_in >= 0.0:
		_thunder_in -= delta
		if _thunder_in < 0.0 and have:
			_boom(_thunder_gain, 1.0)
	if _rumble_in >= 0.0:
		_rumble_in -= delta
		if _rumble_in < 0.0:
			_rumble_in = _rng.randf_range(RUMBLE_EVERY.x, RUMBLE_EVERY.y)
			if have:
				_boom(FAR_GAIN, 0.7)
	_update_processing()


func _boom(gain: float, pitch: float) -> void:
	thunder.stream = stream("thunder")
	thunder.volume_db = linear_to_db(gain)
	thunder.pitch_scale = pitch
	thunder.play()


func _name_of(p: AudioStreamPlayer) -> String:
	return "rain" if p == rain else ("roof" if p == roof else "wind")


## True while something is gliding, playing or due.
func busy() -> bool:
	for p: AudioStreamPlayer in [rain, roof, wind]:
		if _gains[p] > 0.0 or targets[p] > 0.0:
			return true
	return _thunder_in >= 0.0 or _rumble_in >= 0.0


func _update_processing() -> void:
	set_process(busy())
