extends SceneTree

var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)

func _run() -> void:
	var preferences = root.get_node("Preferences")
	var model_path: String = preload("res://tests/model_fixture.gd").prepare_copy("shutdown")
	if model_path.is_empty():
		quit(1)
		return
	preferences._data = {
		"active_model": model_path,
		"accepted_terms": "shutdown-verification",
		"trackers": {"openseeface": {"auto_start": false}},
	}
	var studio = load("res://studio/studio.tscn").instantiate()
	root.add_child(studio)
	var stage = get_first_node_in_group("system:stage")
	var deadline := Time.get_ticks_msec() + 10000
	while stage.active_model == null and Time.get_ticks_msec() < deadline:
		await process_frame
	if stage.active_model == null:
		push_error("The latest model did not finish loading.")
		quit(1)
		return
	var model = stage.active_model
	while model.blueprints.is_empty() and Time.get_ticks_msec() < deadline:
		await process_frame
	if model.blueprints.is_empty():
		push_error("The model's tracking graphs did not finish loading.")
		quit(1)
		return
	# Model switching removes the old model before its editor finishes closing.
	var detached_editor = load("res://studio/hud/blueprint_editor/editor.tscn").instantiate()
	detached_editor.active_model = model
	root.add_child(detached_editor)
	var model_parent: Node = model.get_parent()
	model_parent.remove_child(model)
	await process_frame
	check(not is_instance_valid(detached_editor), "A detached model's editor must close normally.")
	check(not preferences.Files.read_json(model.modelmeta.openvt_parameters).get("graphs", {}).is_empty(), "Detached model saving must preserve reattached graphs.")
	model_parent.add_child(model)
	var editor = load("res://studio/hud/blueprint_editor/editor.tscn").instantiate()
	editor.active_model = model
	root.add_child(editor)
	var graphs: Array = editor.get_node("%Profiles").get_children()
	if graphs.is_empty():
		push_error("The model must have a graph to verify unsaved editor changes.")
		quit(1)
		return
	graphs[0].name = "ShutdownBindingsTest"
	graphs[0].enabled = false
	await process_frame
	preferences.save_before_shutdown()
	var saved: Dictionary = preferences.Files.read_json(model.modelmeta.openvt_parameters)
	check(saved.get("graphs", {}).has("ShutdownBindingsTest"), "Open editor graphs must be included in the model snapshot.")
	check(saved.get("graphs", {}).get("ShutdownBindingsTest", {}).get("enabled") == false, "Unsaved editor changes must survive application close.")
	var saved_content := FileAccess.get_file_as_string(model.modelmeta.openvt_parameters)
	graphs[0].enabled = true
	editor.free()
	studio.free()
	check(FileAccess.get_file_as_string(model_path.replace(".model3.json", ".ovt.json")) == saved_content, "Editor and model teardown must not overwrite the final snapshot.")
	check(not preferences._dirty, "Teardown must not queue another profile save.")
	if failures.is_empty():
		print("Model shutdown passed: latest model loaded, editor changes preserved, no teardown rewrite.")
	quit(0 if failures.is_empty() else 1)
