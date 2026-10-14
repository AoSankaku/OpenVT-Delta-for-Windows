extends SceneTree

const FILES = preload("res://lib/utils/files.gd")

var failures: Array[String] = []
var model: Node
var test_directory: String

func _initialize() -> void:
	_run.call_deferred()

func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)

func _run() -> void:
	# Load project scripts only after autoloads have initialized Registry and Preferences.
	root.get_node("Preferences")._data = {
		"trackers": {"openseeface": {"auto_start": false, "use_bundled": false}}
	}
	var copied_model := _prepare_workspace_model_copy()
	check(not copied_model.is_empty(), "The v3 workspace model should be copied for isolated sidecar tests.")
	if copied_model.is_empty():
		quit(1)
		return

	var studio = load("res://studio/studio.tscn").instantiate()
	root.add_child(studio)
	await process_frame
	var stage = studio.get_node("Stage")
	model = root.get_node("ModelManager").make_model(copied_model)
	check(model != null, "The copied v3 Live2D model should load through ModelManager.")
	if model == null:
		quit(1)
		return
	stage.canvas.add_child(model)
	await model.loaded
	for _frame in range(300):
		if not model.blueprints.is_empty():
			break
		await process_frame
	await process_frame

	check(model.is_initialized(), "The workspace v3 model must initialize successfully.")
	var standard_graph = _find_graph(model.blueprints, "L2D Standard")
	check(standard_graph != null, "The placeholder OVT graph and missing VTS mappings should load L2D Standard defaults.")
	if standard_graph != null:
		check(standard_graph.get_connection_list().size() >= 10, "L2D Standard should contain parameter connections for the v3 model.")
		_test_mouth_rangemap(standard_graph, false)
		_test_interpolated_tracker_timestamp_guard()
		await _test_synthetic_osf_updates(studio)
		await _test_saved_graph_reload(standard_graph)

	await _test_ovt_migration()
	await _test_vts_defaults()

	if failures.is_empty():
		print("Live2D tracking tests passed: v3 defaults, OSF-driven parameters, OVT migration safety, VTS fallbacks, explicit mappings, and saved graph reload.")
	else:
		push_error("Live2D tracking tests failed: %d assertion(s)." % failures.size())
	quit(0 if failures.is_empty() else 1)

func _prepare_workspace_model_copy() -> String:
	var model_path: String = preload("res://tests/model_fixture.gd").prepare_copy("tracking")
	if model_path.is_empty():
		return ""
	test_directory = model_path.get_base_dir()
	var model_stem := model_path.trim_suffix(".model3.json")
	var vtube_path := model_stem + ".vtube.json"
	var ovt_path := model_stem + ".ovt.json"
	var vtube_data: Dictionary = FILES.read_json(vtube_path) if FileAccess.file_exists(vtube_path) else {}
	vtube_data.erase("ParameterSettings")
	vtube_data.erase("Hotkeys")
	FILES.write_json(vtube_path, vtube_data)
	var ovt_data: Dictionary = FILES.read_json(ovt_path) if FileAccess.file_exists(ovt_path) else {}
	ovt_data["graphs"] = {
		"VTS_Hotkeys": _empty_graph_data("VTS_Hotkeys"),
		"VTS_Parameters": _empty_parameter_graph_data(),
	}
	FILES.write_json(ovt_path, ovt_data)
	return model_path

func _test_synthetic_osf_updates(studio: Node) -> void:
	var tracker_script: Script = load("res://lib/tracking/camera/openseeface/osf_tracker.gd")
	var data_script: Script = load("res://lib/tracking/camera/openseeface/osf_data.gd")
	var tracker: Node = tracker_script.new()
	tracker.name = "SyntheticOpenSeeFace"
	tracker.smoothing = 0.0
	studio.get_node("TrackerSystem").add_child(tracker)
	var data = data_script.new()
	data.rotation = Vector3(0.0, 18.0, 0.0)
	data.translation = Vector3.ZERO
	data.leftEyeOpen = 0.2
	data.rightEyeOpen = 0.75
	data.leftGaze = Quaternion(Vector3.UP, 0.3)
	data.rightGaze = Quaternion(Vector3.UP, 0.5)
	data.mouthOpen = 0.8
	data.mouthWide = 0.6
	tracker._data_received(data)
	for _frame in range(45):
		await process_frame
	check(absf(float(model.get("parameters/ParamAngleX")) - 18.0) < 2.0, "Synthetic OSF face angle should reach ParamAngleX through L2D Standard.")
	check(absf(float(model.get("parameters/ParamEyeLOpen")) - 0.2) < 0.15, "Synthetic OSF left-eye openness should update the v3 model.")
	check(absf(float(model.get("parameters/ParamEyeROpen")) - 0.75) < 0.15, "Synthetic OSF right-eye openness should update the v3 model.")
	check(absf(float(model.get("parameters/ParamEyeBallX"))) > 0.1, "Synthetic OSF gaze should move the v3 eyeball parameter.")
	check(float(model.get("parameters/ParamMouthOpenY")) > 0.45, "Synthetic OSF mouth openness should drive ParamMouthOpenY within its supported range.")
	tracker.queue_free()

func _test_interpolated_tracker_timestamp_guard() -> void:
	var tracker: Node = load("res://lib/tracking/interpolated_tracker.gd").new()
	tracker._previous = {"FaceAngleX": -12.0}
	tracker._parameters = {"FaceAngleX": 21.0}
	tracker._previous_msec = 42.0
	tracker._latest_msec = 42.0
	var values: Dictionary = tracker.parameters(42.0)
	check(is_finite(float(values.get("FaceAngleX", NAN))) and values["FaceAngleX"] == 21.0, "Same-timestamp tracker samples should return the latest finite value instead of NaN.")
	tracker.free()

func _test_saved_graph_reload(_graph: GraphEdit) -> void:
	model.save_settings()
	var ovt_path: String = model.modelmeta.openvt_parameters
	var saved_data: Dictionary = FILES.read_json(ovt_path)
	var saved_graphs: Dictionary = saved_data.get("graphs", {})
	var saved_standard: Dictionary = saved_graphs.get("L2D Standard", {})
	check(saved_standard is Dictionary and saved_standard.get("bindings", []).size() > 0, "Saving the model should persist standard graph connections in the copied OVT sidecar.")
	var ovt_loader: Node = load("res://lib/blueprints/loaders/ovt.gd").new()
	root.add_child(ovt_loader)
	var reloaded_graphs: Array = await ovt_loader.load_graph(model, ovt_path)
	await process_frame
	var reloaded_standard = _find_graph(reloaded_graphs, "L2D Standard")
	check(reloaded_standard != null, "The saved L2D Standard graph should reload from its OVT sidecar.")
	if reloaded_standard != null:
		check(reloaded_standard.get_connection_list().size() >= 10, "Reloaded L2D Standard should keep its parameter connections.")
		_test_mouth_rangemap(reloaded_standard, true)
	ovt_loader.queue_free()

func _test_mouth_rangemap(graph: GraphEdit, is_reloaded: bool) -> void:
	var mouth_range: Node
	for connection in graph.get_connection_list():
		var output: Node = graph.get_node(NodePath(connection.to_node))
		if not output.has_method("get_type") or output.get_type() != &"model_output":
			continue
		var output_slot: int = output.get_input_slot_by_port(connection.to_port)
		if output_slot < 0 or output.get_input_slot_name(output_slot) != &"ParamMouthOpenY":
			continue
		var source: Node = graph.get_node(NodePath(connection.from_node))
		if source.has_method("get_type") and source.get_type() == &"rangemap":
			mouth_range = source
			break
	check(mouth_range != null, "The default ParamMouthOpenY binding should use a range map.")
	if mouth_range == null:
		return
	check(mouth_range.b_clamp, "The default mouth range map should clamp output to the model's supported range.")
	var mouth_mapping: Dictionary = mouth_range.serialize()
	check(mouth_mapping.get("b_clamp", false), "The saved mouth range map should serialize its output clamp.")
	mouth_range.update_value(mouth_range.get_input_port_by_name("value"), mouth_range.b.y + 10.0)
	var output_value: float = mouth_range.get_value(0)
	check(is_finite(output_value) and output_value <= mouth_range.b.y, "An out-of-range mouth value must remain within the model parameter's upper limit.")
	if is_reloaded:
		check(mouth_mapping.has("b_clamp") and mouth_mapping["b_clamp"] == true, "The mouth output clamp should persist across graph save and reload.")
		var previous_a: Vector2 = mouth_range.a
		var previous_b: Vector2 = mouth_range.b
		var previous_input: float = mouth_range.input_value
		var previous_a_clamp: bool = mouth_range.a_clamp
		var previous_b_clamp: bool = mouth_range.b_clamp
		mouth_range.a = Vector2(0.0, 1.0)
		mouth_range.b = Vector2(30.0, -30.0)
		mouth_range.b_clamp = true
		mouth_range.update_value(mouth_range.get_input_port_by_name("value"), 0.5)
		var reversed_midpoint: float = mouth_range.get_value(0)
		check(is_equal_approx(reversed_midpoint, 0.0), "A reversed output range should preserve its endpoint order during remapping.")
		mouth_range.update_value(mouth_range.get_input_port_by_name("value"), 2.0)
		var reversed_output: float = mouth_range.get_value(0)
		check(is_equal_approx(reversed_output, -30.0), "Clamped reversed output should reach the normalized lower bound for an out-of-range value.")
		mouth_range.a = Vector2(1.0, 0.0)
		mouth_range.b = Vector2(0.0, 1.0)
		mouth_range.a_clamp = true
		mouth_range.b_clamp = false
		mouth_range.update_value(mouth_range.get_input_port_by_name("value"), 0.25)
		check(is_equal_approx(mouth_range.get_value(0), 0.75), "A reversed input range should preserve its endpoint order during remapping.")
		mouth_range.update_value(mouth_range.get_input_port_by_name("value"), -1.0)
		check(is_equal_approx(mouth_range.get_value(0), 1.0), "Clamped reversed input should reach the normalized endpoint for an out-of-range value.")
		mouth_range.a = previous_a
		mouth_range.b = previous_b
		mouth_range.a_clamp = previous_a_clamp
		mouth_range.b_clamp = previous_b_clamp
		mouth_range.update_value(mouth_range.get_input_port_by_name("value"), previous_input)

func _test_ovt_migration() -> void:
	var loader: Node = load("res://lib/blueprints/loaders/ovt.gd").new()
	root.add_child(loader)
	var path := _fixture_path("ovt-safe-placeholder")
	var safe_graphs := {
		"VTS_Hotkeys": _empty_graph_data("VTS_Hotkeys"),
		"VTS_Parameters": _empty_parameter_graph_data(),
	}
	FILES.write_json(path, {"graphs": safe_graphs})
	var migrated: Array = await loader.load_graph(model, path)
	check(migrated.is_empty(), "The exact inert VTS graph pair should be skipped so the VTS defaults loader can run.")

	var disabled_data := _empty_parameter_graph_data()
	disabled_data["enabled"] = false
	path = _fixture_path("ovt-disabled-placeholder")
	FILES.write_json(path, {"graphs": {"VTS_Parameters": disabled_data}})
	var disabled_graphs: Array = await loader.load_graph(model, path)
	check(disabled_graphs.size() == 1 and disabled_graphs[0].name == "VTS_Parameters", "A disabled VTS graph must be preserved rather than migrated.")
	if disabled_graphs.size() == 1:
		check(not disabled_graphs[0].enabled, "The disabled flag must survive OVT deserialization.")
		var has_model_output := false
		for child in disabled_graphs[0].get_children():
			if child.has_method("get_type") and child.get_type() == &"model_output":
				has_model_output = true
		check(has_model_output, "The disabled placeholder's model output node must survive OVT deserialization.")

	var custom_graph := _empty_graph_data("CustomGraph")
	custom_graph["nodes"] = [{"id": "custom-node", "parameters": {}, "position": {"x": 30.0, "y": 0.0}, "type": "model_output"}]
	path = _fixture_path("ovt-custom-sibling")
	var custom_map := {
		"VTS_Hotkeys": _empty_graph_data("VTS_Hotkeys"),
		"VTS_Parameters": _empty_parameter_graph_data(),
		"CustomGraph": custom_graph,
	}
	FILES.write_json(path, {"graphs": custom_map})
	var preserved_graphs: Array = await loader.load_graph(model, path)
	check(_find_graph(preserved_graphs, "VTS_Parameters") != null, "A custom graph sibling must prevent migration of the placeholder graph.")
	check(_find_graph(preserved_graphs, "CustomGraph") != null, "A valid custom sibling graph must be preserved.")
	var original_json: Dictionary = FILES.read_json(path)
	check(original_json.get("graphs", {}).keys().size() == 3, "OVT migration must leave the saved custom graph map intact on disk.")
	loader.queue_free()

func _test_vts_defaults() -> void:
	var loader: Node = load("res://lib/blueprints/loaders/vts.gd").new()
	root.add_child(loader)
	var variants: Array[Dictionary] = [
		{"Name": "No settings"},
		{"ParameterSettings": null, "Hotkeys": null},
		{"ParameterSettings": [], "Hotkeys": []},
	]
	for index in variants.size():
		var path := _fixture_path("vts-defaults-%d" % index)
		FILES.write_json(path, variants[index])
		var graphs: Array = await loader.load_graph(model, path)
		check(_find_graph(graphs, "L2D Standard") != null, "Missing, null, or empty VTS mappings should create L2D Standard defaults.")

	var missing_path := _fixture_path("missing-vtube-sidecar")
	var missing_graphs: Array = await loader.load_graph(model, missing_path)
	check(_find_graph(missing_graphs, "L2D Standard") != null, "A missing VTube Studio sidecar should use L2D Standard defaults.")

	var explicit_path := _fixture_path("vts-explicit-mapping")
	FILES.write_json(explicit_path, {
		"ParameterSettings": [{"Input": "FaceAngleX", "OutputLive2D": "ParamAngleX"}],
		"Hotkeys": null,
	})
	var explicit_graphs: Array = await loader.load_graph(model, explicit_path)
	var parameter_graph = _find_graph(explicit_graphs, "VTS_Parameters")
	check(parameter_graph != null, "A valid VTS parameter mapping should remain authoritative.")
	check(_find_graph(explicit_graphs, "L2D Standard") == null, "Valid VTS mappings must not be overridden by the standard defaults graph.")
	if parameter_graph != null:
		var explicit_targets := _connection_targets(parameter_graph)
		check(explicit_targets == ["ParamAngleX"], "Explicit VTS mappings should connect only their chosen Live2D parameter.")

	var hotkeys_path := _fixture_path("vts-hotkeys-only")
	FILES.write_json(hotkeys_path, {
		"Hotkeys": [{
			"Triggers": {"Trigger1": "K", "Trigger2": "", "Trigger3": "", "ScreenButton": 0},
			"Action": "RemoveAllExpressions",
			"File": "",
			"FadeSecondsAmount": 0.25,
			"DeactivateAfterKeyUp": false,
			"OnScreenHotkeyColor": {"r": 1.0, "g": 1.0, "b": 1.0, "a": 1.0},
		}],
	})
	var hotkeys_and_defaults: Array = await loader.load_graph(model, hotkeys_path)
	var hotkeys_graph = _find_graph(hotkeys_and_defaults, "VTS_Hotkeys")
	check(hotkeys_graph != null and hotkeys_graph.get_connection_list().size() > 0, "Usable hotkeys should be retained when VTS parameter mappings are absent.")
	check(_find_graph(hotkeys_and_defaults, "L2D Standard") != null, "Hotkeys-only VTS data should also receive standard parameter defaults.")
	loader.queue_free()

func _connection_targets(graph: GraphEdit) -> Array[String]:
	var targets: Array[String] = []
	for connection in graph.get_connection_list():
		var output: Node = graph.get_node(NodePath(connection.to_node))
		if output.get_type() == &"model_output":
			targets.append(output.get_input_slot_name(output.get_input_slot_by_port(connection.to_port)))
	return targets

func _find_graph(graphs: Array, graph_name: String) -> GraphEdit:
	for graph in graphs:
		if is_instance_valid(graph) and graph.name == graph_name:
			return graph
	return null

func _fixture_path(name: String) -> String:
	var directory := ProjectSettings.globalize_path("res://bin/live2d-tracking-test/cases")
	DirAccess.make_dir_recursive_absolute(directory)
	return directory.path_join("%s.json" % name)

func _empty_graph_data(graph_name: String) -> Dictionary:
	return {"bindings": [], "enabled": true, "name": graph_name, "nodes": []}

func _empty_parameter_graph_data() -> Dictionary:
	return {
		"bindings": [],
		"enabled": true,
		"name": "VTS_Parameters",
		"nodes": [{"id": "13122", "parameters": {}, "position": {"x": 488.0, "y": 0.0}, "type": "model_output"}],
	}
