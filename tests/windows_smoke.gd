extends SceneTree

const VtsConfig = preload("res://lib/tracking/camera/vts/vts_config.gd")

var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)

func _run() -> void:
	check(OS.has_feature("windows"), "Run this smoke test with the Windows Godot build.")
	check(VtsConfig._get_local_ipv4(PackedStringArray()) == "127.0.0.1", "VTS must tolerate missing network adapters.")
	check(VtsConfig._get_local_ipv4(PackedStringArray(["::1", "127.0.0.1", "10.0.0.2"])) == "10.0.0.2", "VTS must support 10.x networks.")
	check(VtsConfig._get_local_ipv4(PackedStringArray(["172.20.0.2"])) == "172.20.0.2", "VTS must support private 172.x networks.")
	check(Engine.has_singleton("GlobalInput"), "Windows global input DLL must register its singleton.")
	if Engine.has_singleton("GlobalInput"):
		var global_input = Engine.get_singleton("GlobalInput")
		for method in ["is_key_pressed", "is_key_just_pressed", "is_mouse_button_pressed", "get_mouse_position", "get_pen_pressure"]:
			check(global_input.has_method(method), "Missing Windows input API: " + method)
	var scene = load("res://studio/studio.tscn") as PackedScene
	check(scene != null, "The startup scene must load.")
	if scene != null:
		var studio = scene.instantiate()
		root.add_child(studio)
		for frame in 3:
			await process_frame
		check(get_first_node_in_group("system:stage") != null, "The stage must initialize.")
		check(get_first_node_in_group("output:v4l2") == null, "Windows must not instantiate the Linux virtual camera.")
		if Engine.has_singleton("GlobalInput"):
			var position: Vector2 = Engine.get_singleton("GlobalInput").get_mouse_position()
			print("Windows native cursor after frame: ", position)
			check(is_finite(position.x) and is_finite(position.y), "Global cursor position must remain finite.")
			check(position.x >= -1.0 and position.x <= 1.0 and position.y >= -1.0 and position.y <= 1.0, "Global cursor position must be normalized.")
		studio.queue_free()
		await process_frame
	if failures.is_empty():
		print("Windows smoke test passed: startup, optional camera, VTS networks, and native input APIs.")
	quit(0 if failures.is_empty() else 1)
