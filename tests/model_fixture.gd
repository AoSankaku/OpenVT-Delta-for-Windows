extends RefCounted
## Optional model tests always work on an ignored copy, never the supplied model.

static func prepare_copy(test_name: String) -> String:
	var source_file := OS.get_environment("OPENVT_TEST_MODEL")
	if source_file.is_empty():
		var fallback := DirAccess.open("res://bin/visual-model-v3")
		if fallback != null:
			for file_name in fallback.get_files():
				if file_name.ends_with(".model3.json"):
					source_file = "res://bin/visual-model-v3".path_join(file_name)
					break
	source_file = ProjectSettings.globalize_path(source_file)
	if not source_file.ends_with(".model3.json") or not FileAccess.file_exists(source_file):
		push_error("Set OPENVT_TEST_MODEL to a Live2D .model3.json file. Test models are not distributed.")
		return ""
	var destination := ProjectSettings.globalize_path("res://bin/model-fixtures".path_join(test_name))
	if not _copy_directory(source_file.get_base_dir(), destination):
		return ""
	return destination.path_join(source_file.get_file())

static func _copy_directory(source: String, destination: String) -> bool:
	if DirAccess.make_dir_recursive_absolute(destination) != OK:
		return false
	var directory := DirAccess.open(source)
	if directory == null:
		return false
	for file_name in directory.get_files():
		if DirAccess.copy_absolute(source.path_join(file_name), destination.path_join(file_name)) != OK:
			return false
	for folder_name in directory.get_directories():
		if not _copy_directory(source.path_join(folder_name), destination.path_join(folder_name)):
			return false
	return true
