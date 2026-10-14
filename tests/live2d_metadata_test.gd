extends SceneTree

var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)

func _run() -> void:
	# Load after autoloads initialize the model/tracker global dependencies.
	var loader_script = load("res://lib/model/formats/l2d/model_loader.gd")
	var model_script = load("res://lib/model/formats/l2d/model.gd")
	var directory := "user://metadata-test-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	DirAccess.make_dir_recursive_absolute(directory)
	var model_file := directory.path_join("Example.model3.json")
	var vts_file := directory.path_join("Example.vtube.json")
	var file := FileAccess.open(model_file, FileAccess.WRITE)
	file.store_string('{"Version":3,"FileReferences":{}}')
	file.close()
	var loader = loader_script.new()
	var metadata = loader.load_data(model_file)
	check(metadata.name == "Example" and metadata.id == "Example", "Models without a VTS sidecar must use filename metadata.")
	for data in [{"ArtMeshDetails": null, "FileReferences": null}, {"Name": null, "ModelID": 12}, {"Name": "", "ModelID": ""}]:
		loader.Files.write_json(vts_file, data)
		metadata = loader.load_data(model_file)
		check(metadata.name == "Example" and metadata.id == "Example", "Partial VTS metadata must not prevent model loading.")
		var model = model_script.new()
		model.modelmeta = metadata
		var settings: Dictionary = model._read_vts_settings()
		for section in ["FileReferences", "ArtMeshDetails", "ModelPositionMovement"]:
			check(settings[section] is Dictionary, "Null or missing VTS sections must become empty dictionaries.")
		model.free()
	loader.Files.write_json(vts_file, {"Name": "Custom model", "ModelID": "custom-id"})
	metadata = loader.load_data(model_file)
	check(metadata.name == "Custom model" and metadata.id == "custom-id", "Valid VTS name and ID must be preserved.")
	if failures.is_empty():
		print("Live2D metadata tests passed: missing/partial/null sidecars and preserved valid metadata.")
	quit(0 if failures.is_empty() else 1)
