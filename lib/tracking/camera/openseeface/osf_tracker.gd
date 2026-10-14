extends "../camera_tracker.gd"

const OpenSeeData = preload("./osf_data.gd")
const UdpTracker = preload("res://lib/tracking/net/udp_tracker.gd")
const BundledProcess = preload("./bundled_process.gd")

const DEFAULT_PORT := 11573
const MIN_PORT := 1
const MAX_PORT := 65535
const MIN_CAMERA_INDEX := 0
const MAX_CAMERA_INDEX := 63
const MIN_FPS := 1
const MAX_FPS := 120
const EXTERNAL_TRACKER_GRACE_SECONDS := 0.5

signal data_received(data: OpenSeeData)
signal status_changed(message: String, is_error: bool)
signal settings_changed()

var blink_sync: bool = false
var auto_start: bool = true
var use_bundled: bool = true
var camera_index: int = 0
var port: int = DEFAULT_PORT
var capture_fps: int = 30

var server: UdpTracker
var process_controller
var status_message := "Disconnected"
var status_is_error := false
var has_valid_frame := false

var _start_generation := 0
var _start_pending := false
var _poll_elapsed := 0.0

func _init() -> void:
	# Preferences listens for persist nodes_added; this must be set before _ready.
	add_to_group("persist")
	process_controller = BundledProcess.new()

func _ready() -> void:
	super._ready()
	server = UdpTracker.new()
	server.name = "OSFSocket"
	server.connection_status.connect(_on_connection_status)
	server.packet_received.connect(_packet_received)
	data_received.connect(_data_received)
	add_child(server)

	if auto_start and not _is_headless():
		call_deferred("_run_automatic_start", _start_generation)

func _run_automatic_start(generation: int) -> bool:
	if generation != _start_generation:
		return false
	_start_tracking(true)
	return true

func _process(delta: float) -> void:
	if not _has_owned_process():
		return
	_poll_elapsed += delta
	if _poll_elapsed < 0.5:
		return
	_poll_elapsed = 0.0
	if not process_controller.is_running():
		process_controller.forget_exited_process()
		_start_generation += 1
		_start_pending = false
		if server != null:
			server.stop()
		has_valid_frame = false
		_set_status(
			"OpenSeeFace exited unexpectedly. Check the camera connection and tracker files, then reconnect.",
			true
		)

func create_config() -> Node:
	var panel = preload("./osf_config.tscn").instantiate()
	panel.tracker = self
	return panel

func load_settings(data: Dictionary) -> void:
	var trackers: Variant = data.get("trackers", {})
	if not trackers is Dictionary:
		trackers = {}
	var config: Variant = trackers.get("openseeface", {})
	if not config is Dictionary:
		config = {}

	var old_config := _current_config()
	auto_start = _as_bool(config.get("auto_start", true), true)
	use_bundled = _as_bool(config.get("use_bundled", true), true)
	camera_index = _bounded_int(config.get("camera_index", 0), 0, MIN_CAMERA_INDEX, MAX_CAMERA_INDEX)
	port = _bounded_int(config.get("port", DEFAULT_PORT), DEFAULT_PORT, MIN_PORT, MAX_PORT)
	capture_fps = _bounded_int(config.get("fps", 30), 30, MIN_FPS, MAX_FPS)
	blink_sync = _as_bool(config.get("blink_sync", false), false)
	settings_changed.emit()
	if not is_node_ready():
		return

	var next_config := _current_config()
	if old_config == next_config:
		return
	var runtime_changed: bool = (
		old_config.port != next_config.port
		or old_config.use_bundled != next_config.use_bundled
		or old_config.camera_index != next_config.camera_index
		or old_config.fps != next_config.fps
	)
	var was_listening := server != null and server.server != null and server.server.is_bound()
	var should_start_now: bool = not was_listening and not old_config.auto_start and auto_start
	if runtime_changed and was_listening:
		_start_generation += 1
		_start_pending = false
		_stop_owned_process()
		server.stop()
		_start_tracking(false)
	elif should_start_now and not _is_headless():
		call_deferred("_run_automatic_start", _start_generation)

func save_settings(data: Dictionary) -> void:
	var trackers: Variant = data.get("trackers", {})
	if not trackers is Dictionary:
		trackers = {}
	trackers["openseeface"] = _current_config()
	data["trackers"] = trackers

func set_auto_start(value: bool) -> void:
	auto_start = value

func set_use_bundled(value: bool) -> void:
	if use_bundled == value:
		return
	use_bundled = value
	_reconfigure_if_connected()

func set_camera_index(value: int) -> void:
	var next_value := clampi(value, MIN_CAMERA_INDEX, MAX_CAMERA_INDEX)
	if camera_index == next_value:
		return
	camera_index = next_value
	_reconfigure_if_connected()

func set_port(value: int) -> void:
	var next_value := clampi(value, MIN_PORT, MAX_PORT)
	if port == next_value:
		return
	port = next_value
	_reconfigure_if_connected()

func set_fps(value: int) -> void:
	var next_value := clampi(value, MIN_FPS, MAX_FPS)
	if capture_fps == next_value:
		return
	capture_fps = next_value
	_reconfigure_if_connected()

func set_blink_sync(value: bool) -> void:
	blink_sync = value

func connect_tracker() -> void:
	_start_tracking(false)

func disconnect_tracker() -> void:
	_start_generation += 1
	_start_pending = false
	_stop_owned_process()
	if server != null:
		server.stop()
	has_valid_frame = false
	_set_status("Disconnected")

func _exit_tree() -> void:
	_start_generation += 1
	_start_pending = false
	_stop_owned_process()
	if server != null:
		server.stop()
	has_valid_frame = false

func _start_tracking(is_automatic: bool) -> void:
	if server == null:
		return
	if is_automatic and (not auto_start or _is_headless() or not is_inside_tree()):
		return
	if _start_pending:
		return
	if server.server != null and server.server.is_bound():
		if _has_owned_process() and process_controller.is_running():
			_set_status("OpenSeeFace is running.")
			return
		if not use_bundled or not process_controller.is_available():
			_set_status("Listening for an external OpenSeeFace tracker on port %d." % port)
			return

	port = _bounded_int(port, DEFAULT_PORT, MIN_PORT, MAX_PORT)
	camera_index = _bounded_int(camera_index, 0, MIN_CAMERA_INDEX, MAX_CAMERA_INDEX)
	capture_fps = _bounded_int(capture_fps, 30, MIN_FPS, MAX_FPS)
	var can_launch_bundle: bool = use_bundled and process_controller.is_available()
	server.host = "127.0.0.1" if can_launch_bundle else "*"
	server.port = port
	if not server.start():
		_set_status("Could not listen on UDP port %d. Close another tracker or choose a different port." % port, true)
		return

	has_valid_frame = false
	if not can_launch_bundle:
		if use_bundled:
			_set_status("Listening on port %d. Bundled OpenSeeFace was not found; start it separately to connect." % port)
		else:
			_set_status("Listening for an external OpenSeeFace tracker on port %d." % port)
		return

	if _has_owned_process() and process_controller.is_running():
		_set_status("OpenSeeFace is running.")
		return

	_start_pending = true
	_start_generation += 1
	var generation := _start_generation
	_set_status("Waiting briefly for an existing tracker…")
	_run_start_after_grace(generation)

func _run_start_after_grace(generation: int) -> void:
	await get_tree().create_timer(EXTERNAL_TRACKER_GRACE_SECONDS).timeout
	if generation != _start_generation or not is_inside_tree():
		return
	_start_pending = false
	if has_valid_frame:
		_set_status("Connected to an existing OpenSeeFace tracker.")
		return
	if server == null or server.server == null or not server.server.is_bound():
		return
	if process_controller.start(camera_index, port, capture_fps):
		_set_status("Starting bundled OpenSeeFace on camera %d…" % camera_index)
	else:
		server.stop()
		has_valid_frame = false
		_set_status("Could not start bundled OpenSeeFace. Check the executable and camera index, then reconnect.", true)

func _packet_received(data: PackedByteArray) -> void:
	if data.size() != OpenSeeData.packetFrameSize:
		return
	has_valid_frame = true
	_set_status("Connected to OpenSeeFace.")
	var osf_data = OpenSeeData.new()
	osf_data.read_osf_data(data)
	data_received.emit(osf_data)

func _on_connection_status(status: int) -> void:
	match status:
		UdpTracker.ConnectionStatus.ON:
			if not has_valid_frame:
				_set_status("Receiving UDP data; waiting for a valid OpenSeeFace frame…")
		UdpTracker.ConnectionStatus.WAIT:
			_set_status("Listening on UDP port %d…" % port)
		UdpTracker.ConnectionStatus.OFF:
			if not _start_pending:
				_set_status("Disconnected")

func _reconfigure_if_connected() -> void:
	if server == null or server.server == null or not server.server.is_bound():
		return
	disconnect_tracker()
	_start_tracking(false)

func _stop_owned_process() -> void:
	if _has_owned_process():
		process_controller.stop()

func _has_owned_process() -> bool:
	return process_controller != null and process_controller.get_owned_process_id() > 0

func _set_status(message: String, is_error: bool = false) -> void:
	status_message = message
	status_is_error = is_error
	status_changed.emit(message, is_error)

func _is_headless() -> bool:
	return DisplayServer.get_name() == "headless"

func _current_config() -> Dictionary:
	return {
		"auto_start": auto_start,
		"use_bundled": use_bundled,
		"camera_index": camera_index,
		"port": port,
		"fps": capture_fps,
		"blink_sync": blink_sync,
	}

func _bounded_int(value: Variant, fallback: int, minimum: int, maximum: int) -> int:
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT and typeof(value) != TYPE_STRING:
		return fallback
	var parsed: int
	if typeof(value) == TYPE_STRING:
		if not value.is_valid_int():
			return fallback
		parsed = value.to_int()
	else:
		parsed = int(value)
	return clampi(parsed, minimum, maximum)

func _as_bool(value: Variant, fallback: bool) -> bool:
	if typeof(value) == TYPE_BOOL:
		return value
	return fallback

func _data_received(data: OpenSeeData) -> void:
	var eyeLeft = data.eyeLeftXY
	var eyeRight = data.eyeRightXY

	var leftOpen = data.leftEyeOpen
	var rightOpen = data.rightEyeOpen
	if blink_sync:
		leftOpen = rightOpen

	update({
		"FacePositionX": clampf(data.translation.x, -15, 15),
		"FacePositionY": clampf(data.translation.y, -15, 15),
		"FacePositionZ": clampf(data.translation.z, -10, 10),
		"FaceAngleX": clampf(data.rotation.y, -30, 30),
		"FaceAngleY": clampf(-data.rotation.x, -30, 30),
		"FaceAngleZ": clampf(data.rotation.z, -30, 30),
		"MouthOpen": clampf(data.mouthOpen, 0.0, 1.0),
		"MouthSmile": clampf(data.mouthWide, 0.0, 1.0),
		"EyeOpenLeft": leftOpen,
		"EyeOpenRight": rightOpen,
		"EyeLeftX": eyeLeft.x,
		"EyeLeftY": eyeLeft.y,
		"EyeRightX": eyeRight.x,
		"EyeRightY": eyeRight.y,
	})
