extends PanelContainer

const OpenSeeFaceTracker = preload("res://lib/tracking/camera/openseeface/osf_tracker.gd")

const ENABLE_TEXT := "カメラ ONにする"
const DISABLE_TEXT := "カメラ OFFにする"

var _tracking_system: Node
var _tracker: Node

func _ready() -> void:
	if not OS.has_feature("openseeface") and not OS.is_debug_build():
		hide()
		return

	_tracking_system = get_tree().get_first_node_in_group("system:tracking")
	if _tracking_system != null:
		_tracking_system.tracker_changed.connect(_on_tracker_changed)
		_on_tracker_changed(_tracking_system.get_node_or_null("FaceTracker"))
	else:
		_refresh_state()

func _exit_tree() -> void:
	if is_instance_valid(_tracking_system) and _tracking_system.tracker_changed.is_connected(_on_tracker_changed):
		_tracking_system.tracker_changed.disconnect(_on_tracker_changed)
	_unbind_tracker()

func _on_tracker_changed(new_tracker: Node) -> void:
	_unbind_tracker()
	if new_tracker != null and new_tracker.get_script() == OpenSeeFaceTracker:
		_tracker = new_tracker
		if not _tracker.status_changed.is_connected(_on_tracker_status_changed):
			_tracker.status_changed.connect(_on_tracker_status_changed)
	_refresh_state()

func _on_tracker_status_changed(_message: String, _is_error: bool) -> void:
	_refresh_state()

func _unbind_tracker() -> void:
	if is_instance_valid(_tracker) and _tracker.status_changed.is_connected(_on_tracker_status_changed):
		_tracker.status_changed.disconnect(_on_tracker_status_changed)
	_tracker = null

func _on_toggle_toggled(toggled_on: bool) -> void:
	if not is_instance_valid(_tracking_system):
		_tracking_system = get_tree().get_first_node_in_group("system:tracking")
	if not is_instance_valid(_tracking_system):
		%Toggle.set_pressed_no_signal(false)
		_refresh_state()
		return

	var active_tracker = _tracking_system.get_node_or_null("FaceTracker")
	if toggled_on:
		if active_tracker == null or active_tracker.get_script() != OpenSeeFaceTracker:
			_tracking_system.activate_tracker(OpenSeeFaceTracker.new())
			active_tracker = _tracking_system.get_node_or_null("FaceTracker")
		if active_tracker != null and active_tracker.get_script() == OpenSeeFaceTracker:
			active_tracker.connect_tracker()
	else:
		if active_tracker != null and active_tracker.get_script() == OpenSeeFaceTracker:
			active_tracker.disconnect_tracker()
	_refresh_state()

func _refresh_state() -> void:
	var listening := _is_listening()
	%Toggle.set_pressed_no_signal(listening)
	%Toggle.text = DISABLE_TEXT if listening else ENABLE_TEXT

	if not is_instance_valid(_tracker):
		%Status.text = "停止中"
		%Status.tooltip_text = "カメラで顔・表情のトラッキングを開始します。"
		%Toggle.tooltip_text = %Status.tooltip_text
		return

	if _tracker.has_valid_frame:
		%Status.text = "顔を追跡中"
	elif _tracker.status_is_error:
		%Status.text = "エラー（再試行できます）"
	elif listening:
		%Status.text = "起動中・接続待ち"
	else:
		%Status.text = "停止中"

	%Status.tooltip_text = _tracker.status_message
	%Toggle.tooltip_text = _tracker.status_message

func _is_listening() -> bool:
	return (
		is_instance_valid(_tracker)
		and _tracker.server != null
		and _tracker.server.server != null
		and _tracker.server.server.is_bound()
	)
