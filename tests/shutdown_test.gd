extends SceneTree

class PersistedState:
	extends Node
	var writes := {"count": 0}
	var value := "initial"

	func _init() -> void:
		add_to_group("persist")

	func load_settings(_data: Dictionary) -> void:
		pass

	func save_settings(data: Dictionary) -> void:
		writes.count += 1
		data[str(name)] = value

var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)

func _run() -> void:
	var preferences = root.get_node("Preferences")
	preferences.active_file = "user://shutdown-test.json"
	preferences._data = {}
	var ordinary := PersistedState.new()
	ordinary.name = "ordinary"
	root.add_child(ordinary)
	var ordinary_writes := ordinary.writes
	ordinary.free()
	check(ordinary_writes.count == 1, "Removing a node during normal use must still capture its state.")
	var state := PersistedState.new()
	state.name = "edited_state"
	root.add_child(state)
	state.value = "latest edit"
	var shutdown_writes := state.writes
	preferences.save_before_shutdown()
	preferences.save_before_shutdown()
	check(shutdown_writes.count == 1, "Repeated close requests must capture settings only once.")
	var saved: Dictionary = preferences.Files.read_json(preferences.active_file)
	check(saved.get("edited_state") == "latest edit", "The final edit must be written before teardown.")
	state.value = "teardown state"
	state.free()
	check(shutdown_writes.count == 1, "Teardown must not serialize the same settings again.")
	check(not preferences._dirty, "Teardown must not queue a second profile write.")
	if failures.is_empty():
		print("Shutdown tests passed: normal removal, one final save, repeated close, and teardown.")
	quit(0 if failures.is_empty() else 1)
