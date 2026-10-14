extends SceneTree

class FakeProcess:
	extends RefCounted
	var running := false
	var owned_id := -1
	var starts := 0
	var stops := 0
	var last_camera := -1

	func is_available() -> bool:
		return true

	func start(camera_index: int, _port: int, _fps: int) -> bool:
		starts += 1
		last_camera = camera_index
		running = true
		owned_id = 50000 + starts
		return true

	func stop() -> void:
		if owned_id > 0:
			stops += 1
		running = false
		owned_id = -1

	func is_running() -> bool:
		return running

	func get_owned_process_id() -> int:
		return owned_id

	func forget_exited_process() -> void:
		owned_id = -1

var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)

func wait_for_start() -> void:
	await create_timer(0.65).timeout
	await process_frame

func _run() -> void:
	var probe := PacketPeerUDP.new()
	if probe.bind(0, "127.0.0.1") != OK:
		push_error("Could not allocate a test UDP port.")
		quit(1)
		return
	var port := probe.get_local_port()
	probe.close()
	root.get_node("Preferences")._data = {
		"accepted_terms": "toggle-test",
		"trackers": {"source": 0, "openseeface": {"auto_start": false, "camera_index": 3, "port": port}},
	}
	var osf_script = load("res://lib/tracking/camera/openseeface/osf_tracker.gd")
	var studio = load("res://studio/studio.tscn").instantiate()
	root.add_child(studio)
	await process_frame
	await process_frame
	var system = get_first_node_in_group("system:tracking")
	var tracker = system.get_node("FaceTracker")
	var fake := FakeProcess.new()
	tracker.process_controller = fake
	var control = studio.get_node("Interface/CameraToggle")
	var button: Button = control.get_node("%Toggle")
	var status: Label = control.get_node("%Status")
	check(control.is_visible_in_tree() and not button.disabled, "The initial screen must expose an enabled camera button.")
	check(not button.button_pressed and button.text.contains("ON"), "The inactive camera must offer ON.")
	button.button_pressed = not button.button_pressed
	check(button.button_pressed and button.text.contains("OFF"), "Enabling the camera must immediately offer OFF while starting.")
	check(not status.text.contains("顔を追跡中"), "A listening socket must not imply valid face tracking.")
	button.button_pressed = not button.button_pressed
	await wait_for_start()
	check(fake.starts == 0 and not button.button_pressed, "Turning OFF during startup must cancel the pending helper.")
	button.button_pressed = not button.button_pressed
	await wait_for_start()
	check(fake.starts == 1 and fake.running, "ON must start exactly one helper.")
	check(fake.last_camera == 3 and not tracker.auto_start, "The quick button must preserve camera and startup preferences.")
	var valid_frame := PackedByteArray()
	valid_frame.resize(tracker.OpenSeeData.packetFrameSize)
	tracker._packet_received(valid_frame)
	check(status.text.contains("顔を追跡中"), "A valid frame must update the visible tracking state.")
	var config = studio.get_node("Interface/HUD/Panels/CameraPanel/ScrollContainer/Accordion/Tracking/PanelContainer/FaceTracking/Config")
	config.get_node("%Disconnect").pressed.emit()
	check(not button.button_pressed and fake.stops == 1, "Disconnect in settings must synchronize the main-screen button.")
	config.get_node("%Connect").pressed.emit()
	await wait_for_start()
	check(button.button_pressed and fake.starts == 2, "Connect in settings must synchronize the main-screen button.")
	system.activate_tracker(load("res://lib/tracking/camera/vts/vts_tracker.gd").new())
	await process_frame
	var source: OptionButton = studio.get_node("Interface/HUD/Panels/CameraPanel/%TrackingSource")
	check(source.get_selected_metadata() != osf_script and not button.button_pressed and not fake.running, "Changing source must stop the old helper and reset the button.")
	studio.get_node("Interface/HUD/Panels/CameraPanel").load_settings({"trackers": {"source": source.selected}})
	button.button_pressed = not button.button_pressed
	tracker = system.get_node("FaceTracker")
	# Replace before the 0.5s grace expires, so the real camera is never opened.
	var switched_fake := FakeProcess.new()
	tracker.process_controller = switched_fake
	check(tracker.get_script() == osf_script and source.get_selected_metadata() == osf_script, "ON must select the webcam source and synchronize settings.")
	await wait_for_start()
	check(switched_fake.starts == 1 and switched_fake.last_camera == 3, "Source switching must keep the configured camera.")
	switched_fake.running = false
	await wait_for_start()
	check(status.text.contains("エラー") and not button.button_pressed and not button.disabled, "Unexpected helper exit must show an error and allow retry.")
	button.button_pressed = not button.button_pressed
	await wait_for_start()
	check(switched_fake.starts == 2 and button.button_pressed, "The initial-screen button must retry after an error.")
	var hud = studio.get_node("Interface/HUD")
	hud.popup_btn.pressed.emit()
	await process_frame
	await process_frame
	check(control.get_window() == root and control.is_visible_in_tree(), "The camera button must remain in the main window when controls pop out.")
	check(system.get_node("FaceTracker") == tracker and switched_fake.starts == 2, "Popping out controls must preserve the running tracker.")
	button.button_pressed = not button.button_pressed
	check(not switched_fake.running and not button.button_pressed, "OFF must stop the owned helper after popout.")
	hud.restore()
	await process_frame
	studio.queue_free()
	await process_frame
	if failures.is_empty():
		print("Camera toggle tests passed: main-screen ON/OFF, startup cancel, settings sync, source switch, error retry, and popout.")
	quit(0 if failures.is_empty() else 1)
