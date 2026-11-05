class_name VrPerf
extends Node
## Frame-time log for VR tests (L1, later L6). Every 10 s it prints a line and appends it to
## user://vr_perf.log: frame interval (average, worst), frames that missed the headset's refresh, CPU and
## GPU render time, draw calls. Numbers and the GPU's name only, so testers can send the file as is.

const PERIOD_S := 10.0
const LOG_PATH := "user://vr_perf.log"
const MAX_LOG_BYTES := 1 << 20   # start over past this

var xr: XRInterface
var last_line := ""
var _vp: RID
var _t := 0.0
var _n := 0
var _sum := 0.0
var _worst := 0.0
var _late := 0
var _cpu := 0.0
var _gpu := 0.0
var _draws := 0.0


func _init(interface: XRInterface) -> void:
	xr = interface
	name = "VrPerf"


func _ready() -> void:
	_vp = get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_vp, true)
	_write("--- %s  %s (%s)" % [Time.get_datetime_string_from_system(), RenderingServer.get_video_adapter_name(),
			RenderingServer.get_current_rendering_driver_name()])


func refresh_hz() -> float:
	var hz := 0.0
	if xr != null and xr.has_method("get_display_refresh_rate"):
		hz = float(xr.call("get_display_refresh_rate"))
	return hz if hz > 1.0 else 90.0


func _process(delta: float) -> void:
	_n += 1
	_sum += delta
	_worst = maxf(_worst, delta)
	if delta > 1.5 / refresh_hz():
		_late += 1
	_cpu += RenderingServer.viewport_get_measured_render_time_cpu(_vp) + RenderingServer.get_frame_setup_time_cpu()
	_gpu += RenderingServer.viewport_get_measured_render_time_gpu(_vp)
	_draws += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	_t += delta
	if _t >= PERIOD_S:
		_report()


func _report() -> void:
	last_line = "%.0f Hz: frame avg %.1f ms, worst %.1f ms, %d of %d late; render cpu %.1f ms, gpu %.1f ms; %d draw calls" % [
			refresh_hz(), 1000.0 * _sum / _n, 1000.0 * _worst, _late, _n, _cpu / _n, _gpu / _n, int(_draws / _n)]
	print("vr perf: " + last_line)
	_write(last_line)
	_t = 0.0
	_n = 0
	_sum = 0.0
	_worst = 0.0
	_late = 0
	_cpu = 0.0
	_gpu = 0.0
	_draws = 0.0


static func _write(line: String) -> void:
	var f := FileAccess.open(LOG_PATH, FileAccess.READ_WRITE)
	if f == null or f.get_length() > MAX_LOG_BYTES:
		f = FileAccess.open(LOG_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.seek_end()
	f.store_line(line)
