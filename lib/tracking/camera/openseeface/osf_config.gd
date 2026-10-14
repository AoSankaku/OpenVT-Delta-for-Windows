extends Control

const SocketTracker = preload("res://lib/tracking/net/socket_tracker.gd")

var tracker

func _ready() -> void:
	if not is_instance_valid(tracker):
		return
	if not tracker.data_received.is_connected(%PointPreview._on_data_received):
		tracker.data_received.connect(%PointPreview._on_data_received)
	if not tracker.status_changed.is_connected(_on_status_changed):
		tracker.status_changed.connect(_on_status_changed)
	if not tracker.settings_changed.is_connected(_sync_from_tracker):
		tracker.settings_changed.connect(_sync_from_tracker)
	if not tracker.server.connection_status.is_connected(_on_connection_status):
		tracker.server.connection_status.connect(_on_connection_status)
	_sync_from_tracker()
	_on_status_changed(tracker.status_message, tracker.status_is_error)
	_on_connection_status(SocketTracker.ConnectionStatus.ON if tracker.server.server != null and tracker.server.server.is_bound() else SocketTracker.ConnectionStatus.OFF)

func _sync_from_tracker() -> void:
	%BlinkSync.set_pressed_no_signal(tracker.blink_sync)
	%AutoConnect.set_pressed_no_signal(tracker.auto_start)
	%UseBundled.set_pressed_no_signal(tracker.use_bundled)
	%CameraIndex.set_value_no_signal(tracker.camera_index)
	%Port.set_value_no_signal(tracker.port)
	%Fps.set_value_no_signal(tracker.capture_fps)

func _process(_delta: float) -> void:
	if is_instance_valid(tracker):
		%FpsCounter.text = "FPS: %d" % max(0, tracker.fps)

func _on_blink_sync_toggled(toggled_on: bool) -> void:
	tracker.set_blink_sync(toggled_on)

func _on_auto_connect_toggled(toggled_on: bool) -> void:
	tracker.set_auto_start(toggled_on)

func _on_use_bundled_toggled(toggled_on: bool) -> void:
	tracker.set_use_bundled(toggled_on)

func _on_camera_index_value_changed(value: float) -> void:
	tracker.set_camera_index(int(value))

func _on_port_value_changed(value: float) -> void:
	tracker.set_port(int(value))

func _on_fps_value_changed(value: float) -> void:
	tracker.set_fps(int(value))

func _on_connect_pressed() -> void:
	tracker.connect_tracker()

func _on_disconnect_pressed() -> void:
	tracker.disconnect_tracker()

func _on_status_changed(message: String, is_error: bool) -> void:
	%Status.text = message
	%Status.modulate = Color(1.0, 0.45, 0.4) if is_error else Color.WHITE
	_sync_buttons()

func _on_connection_status(status: int) -> void:
	var connected: bool = status == SocketTracker.ConnectionStatus.ON and tracker.has_valid_frame
	%ActiveIndicator.text = "On" if connected else "Off"
	%ActiveIndicator.modulate = Color.RED if connected else Color.WHITE
	_sync_buttons()

func _sync_buttons() -> void:
	var listening: bool = tracker.server.server != null and tracker.server.server.is_bound()
	%Connect.disabled = listening
	%Disconnect.disabled = not listening
	var connected: bool = tracker.has_valid_frame
	%ActiveIndicator.text = "On" if connected else "Off"
	%ActiveIndicator.modulate = Color.RED if connected else Color.WHITE
