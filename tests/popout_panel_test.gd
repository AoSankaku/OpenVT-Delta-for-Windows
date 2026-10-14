extends SceneTree

var failures: Array[String] = []
var native_windows: bool

func _initialize() -> void:
	_run.call_deferred()

func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)

func check_visible_frame(window: Window, message: String) -> void:
	if not native_windows:
		return
	var usable_rect = DisplayServer.screen_get_usable_rect(window.current_screen)
	var frame = Rect2i(window.get_position_with_decorations(), window.get_size_with_decorations())
	check(usable_rect.encloses(frame), message + ": " + str(frame) + " in " + str(usable_rect))
	check(frame.position.y < window.position.y, "The native title bar must be included in the placement check.")

func _run() -> void:
	native_windows = DisplayServer.get_name() == "Windows"
	# Native window tests should not activate an actual webcam.
	root.get_node("Preferences")._data = {"trackers": {"openseeface": {"auto_start": false}}}
	var studio = load("res://studio/studio.tscn").instantiate()
	root.add_child(studio)
	await process_frame
	var hud = studio.get_node("Interface/HUD")
	var original_parent = hud.get_parent()
	var buttons = hud.onscreen_buttons
	var accordion = hud.get_node("Panels/CameraPanel/ScrollContainer/Accordion")
	var accordion_child_count: int = accordion.get_child_count()
	hud.load_settings({})
	buttons.load_settings({})
	# Exercise the same signal as the user's popout button, including the action window.
	hud.popup_btn.pressed.emit()
	await process_frame
	check(hud.is_floating and buttons.is_floating, "Both control panels must pop out.")
	check(not hud.window.unresizable and not hud.window.borderless, "Controls must have a native, resizable title bar.")
	check_visible_frame(hud.window, "A new control window must fit the monitor work area")
	check_visible_frame(buttons.window, "A new action window must fit the monitor work area")
	var first_position: Vector2i = hud.window.position
	check(first_position != Vector2i.ZERO, "A new popout must not default to the desktop origin.")
	if native_windows:
		var normal_size: Vector2i = hud.window.size
		hud.window.mode = Window.MODE_MAXIMIZED
		await process_frame
		check(hud.window.mode == Window.MODE_MAXIMIZED, "The controls must support native maximization.")
		hud.window.mode = Window.MODE_WINDOWED
		await process_frame
		check(hud.window.mode == Window.MODE_WINDOWED, "The controls must return to normal mode.")
		check(hud.window.size == normal_size, "Restoring must recover the normal window size.")
		hud.window.position += Vector2i(24, 24)
		await process_frame
		check(hud.window.position == first_position + Vector2i(24, 24), "The restored window must be movable.")
	var saved_position: Vector2i = hud.window.position
	hud.restore()
	await process_frame
	check(hud.get_parent() == original_parent and not hud.is_floating, "Closing must dock the controls again.")
	check(not buttons.is_floating, "Docking must also restore the action window.")
	check(accordion.get_child_count() == accordion_child_count, "Docking must preserve settings section controls.")
	# Saving after queue_free used to access a freed Window on the next frame.
	var settings: Dictionary = {}
	hud.save_settings(settings)
	check(Vector2(saved_position) == Vector2(settings.window_positions.HUD.x, settings.window_positions.HUD.y), "Docked settings must retain the last popup position.")
	hud.load_settings(settings)
	hud.popout()
	await process_frame
	check(hud.window.position == saved_position, "A valid saved position must be restored.")
	hud.restore()
	await process_frame
	# Recover profiles saved by the old version, and positions from disconnected monitors.
	for position in [Vector2i.ZERO, Vector2i(-100000, -100000), Vector2i(100000, 100000)]:
		hud.load_settings({"window_positions": {"HUD": {"x": position.x, "y": position.y}}})
		hud.popout()
		await process_frame
		check_visible_frame(hud.window, "An invalid saved position must be recovered")
		hud.restore()
		await process_frame
	# Tracker/configuration sections can also be added, removed, and added again.
	var section = VBoxContainer.new()
	section.name = "TemporarySettings"
	section.add_child(Button.new())
	accordion.add_child(section)
	await process_frame
	await process_frame
	check(accordion.get_child_count() == accordion_child_count + 2, "Adding a settings section must create one fold button.")
	accordion.remove_child(section)
	await process_frame
	await process_frame
	check(accordion.get_child_count() == accordion_child_count, "Removing a section must remove its fold button.")
	accordion.add_child(section)
	await process_frame
	await process_frame
	check(accordion.get_child_count() == accordion_child_count + 2, "Re-adding a section must restore one fold button.")
	section.queue_free()
	await process_frame
	await process_frame
	check(accordion.get_child_count() == accordion_child_count, "Freeing a section must remove its fold button.")
	studio.queue_free()
	await process_frame
	if failures.is_empty():
		print("Popout tests passed: initial placement, saved positions, docking, and ", "native maximize/restore." if native_windows else "headless lifecycle.")
	quit(0 if failures.is_empty() else 1)
