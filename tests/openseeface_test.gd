extends SceneTree

const BundledProcess = preload("res://lib/tracking/camera/openseeface/bundled_process.gd")
const OsfConfig = preload("res://lib/tracking/camera/openseeface/osf_config.tscn")

var TrackerScript: Script

class FakeProcessController:
	extends RefCounted
	var available := true
	var running := false
	var owned_id := -1
	var starts: Array[Vector3i] = []
	var attempts := 0
	var fail_next_start := false
	var stop_count := 0

	func is_available() -> bool:
		return available

	func start(camera_index: int, port: int, fps: int) -> bool:
		attempts += 1
		if fail_next_start:
			fail_next_start = false
			return false
		starts.append(Vector3i(camera_index, port, fps))
		running = true
		owned_id = 42000 + starts.size()
		return true

	func stop() -> void:
		if owned_id > 0:
			stop_count += 1
		running = false
		owned_id = -1

	func is_running() -> bool:
		return running

	func get_owned_process_id() -> int:
		return owned_id

	func forget_exited_process() -> void:
		running = false
		owned_id = -1

var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)

func free_udp_port() -> int:
	var probe := PacketPeerUDP.new()
	var error := probe.bind(0, "127.0.0.1")
	if error != OK:
		return -1
	var result := probe.get_local_port()
	probe.close()
	return result

func wait_seconds(seconds: float) -> void:
	await create_timer(seconds).timeout
	await process_frame

func make_tracker(fake: FakeProcessController, settings: Dictionary = {}) -> Node:
	var tracker: Node = TrackerScript.new()
	tracker.process_controller = fake
	root.add_child(tracker)
	tracker.load_settings(settings)
	return tracker

func _run() -> void:
	root.get_node("Preferences")._data = {}
	TrackerScript = load("res://lib/tracking/camera/openseeface/osf_tracker.gd")
	check(TrackerScript != null, "OpenSeeFace tracker script must load.")
	if TrackerScript == null:
		quit(1)
		return
	var defaults: Node = TrackerScript.new()
	check(defaults.is_in_group("persist"), "The tracker must join persist before it enters the tree.")
	check(defaults.auto_start and defaults.use_bundled, "OpenSeeFace should default to automatic bundled tracking.")
	check(defaults.camera_index == 0 and defaults.capture_fps == 30 and defaults.port == 11573, "OpenSeeFace defaults should be camera 0, 30 FPS, and port 11573.")
	defaults.free()

	var bundle = BundledProcess.new()
	check(bundle.executable_path.is_absolute_path() and bundle.models_path.is_absolute_path(), "Bundled executable and model paths must be absolute.")
	var args: PackedStringArray = bundle.build_arguments(2, 12000, 45)
	check(args == PackedStringArray(["-i", "127.0.0.1", "-p", "12000", "-c", "2", "-F", "45", "-v", "0", "-s", "1", "--model-dir", bundle.models_path]), "OpenSeeFace must receive the configured camera, port, FPS, and model folder.")

	var fake := FakeProcessController.new()
	var tracker := make_tracker(fake, {"trackers": {"openseeface": {"auto_start": false}}})
	await process_frame
	check(not tracker.auto_start, "The test profile must explicitly disable automatic camera startup.")
	check(fake.starts.is_empty(), "Disabled auto-start must not start the camera helper.")
	var auto_fake := FakeProcessController.new()
	var deferred_tracker := make_tracker(auto_fake)
	var scheduled_generation: int = deferred_tracker._start_generation
	deferred_tracker.disconnect_tracker()
	check(not deferred_tracker._run_automatic_start(scheduled_generation), "Disconnect must invalidate a deferred automatic start.")
	await process_frame
	check(auto_fake.starts.is_empty() and (deferred_tracker.server.server == null or not deferred_tracker.server.server.is_bound()), "A cancelled deferred startup must neither launch a helper nor bind the receiver.")
	deferred_tracker.queue_free()
	await process_frame
	tracker.load_settings({"trackers": {"openseeface": {"auto_start": false, "camera_index": -5, "port": 70000, "fps": 0}}})
	check(tracker.camera_index == 0 and tracker.port == 65535 and tracker.capture_fps == 1, "Profile values must be validated and clamped.")
	tracker._packet_received(PackedByteArray([1, 2, 3]))
	check(not tracker.has_valid_frame, "Malformed OSF packet sizes must be ignored before parsing.")

	tracker.camera_index = 2
	tracker.port = free_udp_port()
	tracker.capture_fps = 45
	tracker.connect_tracker()
	await wait_seconds(0.65)
	check(fake.starts.size() == 1, "A manual connect should launch one bundled helper after the grace period.")
	if not fake.starts.is_empty():
		check(fake.starts[0] == Vector3i(2, tracker.port, 45), "The helper must receive the selected camera, port, and capture FPS.")
	tracker.connect_tracker()
	check(fake.starts.size() == 1, "Repeated Connect must not launch a second helper.")
	tracker.disconnect_tracker()
	check(fake.stop_count == 1 and fake.owned_id == -1, "Disconnect must stop only the owned helper process.")

	tracker.port = free_udp_port()
	tracker.connect_tracker()
	tracker.disconnect_tracker()
	await wait_seconds(0.65)
	check(fake.starts.size() == 1, "Disconnect must cancel a helper launch waiting on the external tracker grace period.")

	tracker.port = free_udp_port()
	tracker.connect_tracker()
	await wait_seconds(0.65)
	fake.running = false
	await wait_seconds(0.65)
	check(fake.owned_id == -1 and tracker.status_is_error, "An unexpected helper exit must clear owned state and report an actionable error.")
	check(tracker.server.server == null or not tracker.server.server.is_bound(), "An unexpected helper exit must stop the receiver.")

	fake.fail_next_start = true
	tracker.port = free_udp_port()
	tracker.connect_tracker()
	await wait_seconds(0.65)
	check(tracker.status_is_error and (tracker.server.server == null or not tracker.server.server.is_bound()), "A failed helper start must close the receiver so Connect can retry.")
	var failed_attempt_count := fake.attempts
	tracker.port = free_udp_port()
	tracker.connect_tracker()
	await wait_seconds(0.65)
	check(fake.attempts == failed_attempt_count + 1 and fake.running, "Connect must be available after a failed helper launch.")

	tracker.port = free_udp_port()
	tracker.connect_tracker()
	await wait_seconds(0.65)
	var stops_before_tree_exit := fake.stop_count
	tracker.queue_free()
	await process_frame
	check(fake.stop_count == stops_before_tree_exit + 1, "Leaving the scene must stop the tracker-owned helper.")

	var external_fake := FakeProcessController.new()
	external_fake.available = false
	var external_tracker := make_tracker(external_fake, {"trackers": {"openseeface": {"auto_start": false}}})
	await process_frame
	external_tracker.port = free_udp_port()
	external_tracker.connect_tracker()
	check(external_tracker.server.host == "*" and external_fake.starts.is_empty(), "Manual mode must listen for external trackers when no bundled executable is available.")
	external_tracker.disconnect_tracker()
	external_tracker.queue_free()
	await process_frame

	# UI controls are loaded from the same source script and remain attached across popout/reload.
	root.get_node("Preferences")._data = {"trackers": {"source": 0, "openseeface": {"auto_start": false}}}
	var studio = load("res://studio/studio.tscn").instantiate()
	root.add_child(studio)
	await process_frame
	await process_frame
	var system = get_first_node_in_group("system:tracking")
	var camera_panel = studio.get_node("Interface/HUD/Panels/CameraPanel")
	var active_tracker = system.get_node_or_null("FaceTracker")
	check(active_tracker != null and active_tracker.get_script() == TrackerScript, "Fresh profile source 0 should select OpenSeeFace.")
	if active_tracker != null and active_tracker.get_script() == TrackerScript:
		var panel_fake := FakeProcessController.new()
		active_tracker.process_controller = panel_fake
		var config = camera_panel.get_node("ScrollContainer/Accordion/Tracking/PanelContainer/FaceTracking/Config")
		check(config.scene_file_path == OsfConfig.resource_path, "OpenSeeFace should have a usable configuration panel.")
		var camera_spin: SpinBox = config.get_node("HBoxContainer3/CameraIndex")
		var port_spin: SpinBox = config.get_node("HBoxContainer2/Port")
		var fps_spin: SpinBox = config.get_node("HBoxContainer4/Fps")
		camera_spin.value = 4
		port_spin.value = 12001
		fps_spin.value = 24
		check(active_tracker.camera_index == 4 and active_tracker.port == 12001 and active_tracker.capture_fps == 24, "Camera, port, and capture FPS controls must update the tracker.")
		check(active_tracker.fps == 0.0, "Configuring capture FPS must preserve the measured incoming FPS counter.")
		config.get_node("AutoConnect").toggled.emit(false)
		config.get_node("UseBundled").toggled.emit(false)
		config.get_node("BlinkSync").toggled.emit(true)
		check(not active_tracker.auto_start and not active_tracker.use_bundled and active_tracker.blink_sync, "The startup, bundled helper, and blink controls must update tracker settings.")
		active_tracker.load_settings({"trackers": {"openseeface": {"auto_start": false, "use_bundled": true, "camera_index": 7, "port": 12002, "fps": 48, "blink_sync": false}}})
		check(camera_spin.value == 7 and port_spin.value == 12002 and fps_spin.value == 48, "Profile reload must refresh the existing configuration controls without emitting edits.")
		var load_data := {"trackers": {"source": 0, "openseeface": {"auto_start": false}}}
		camera_panel.load_settings(load_data)
		camera_panel.load_settings(load_data)
		await process_frame
		await process_frame
		check(system.get_node_or_null("FaceTracker") == active_tracker, "Reloading settings for the same source must preserve the live tracker instance.")
		var hud = studio.get_node("Interface/HUD")
		hud.popup_btn.pressed.emit()
		await process_frame
		await process_frame
		check(system.get_node_or_null("FaceTracker") == active_tracker, "Popping out the HUD must preserve the active tracker instance.")
		active_tracker.port = free_udp_port()
		active_tracker.connect_tracker()
		await wait_seconds(0.65)
		check(panel_fake.running, "The test process controller should own the helper before changing source.")
		system.activate_tracker(load("res://lib/tracking/camera/vts/vts_tracker.gd").new())
		await process_frame
		check(not panel_fake.running and panel_fake.owned_id == -1, "Switching tracking sources must stop the OpenSeeFace helper owned by the old tracker.")

	studio.queue_free()
	await process_frame
	if failures.is_empty():
		print("OpenSeeFace tests passed: defaults, helper lifecycle, packet validation, profile settings, UI controls, and HUD persistence.")
	quit(0 if failures.is_empty() else 1)
