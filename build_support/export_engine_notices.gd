extends SceneTree

func _initialize() -> void:
	var directory := ProjectSettings.globalize_path("res://license")
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--output="):
			directory = argument.trim_prefix("--output=")
	if DirAccess.make_dir_recursive_absolute(directory) != OK:
		push_error("Cannot create the engine license directory.")
		quit(1)
		return
	var license_file := FileAccess.open(directory.path_join("GODOT_LICENSE.txt"), FileAccess.WRITE)
	if license_file == null:
		quit(1)
		return
	license_file.store_string(Engine.get_license_text())
	license_file.close()
	var notices := "Godot Engine %s\n\n" % Engine.get_version_info().get("string", "")
	for component in Engine.get_copyright_info():
		notices += "%s\n" % component["name"]
		for part in component["parts"]:
			notices += "Files:\n" + "\n".join(part["files"]) + "\n"
			notices += "Copyright:\n" + "\n".join(part["copyright"]) + "\n"
			notices += "License: %s\n\n" % part["license"]
	var license_info := Engine.get_license_info()
	var names := license_info.keys()
	names.sort()
	for name in names:
		notices += "\n===== %s =====\n%s\n" % [name, license_info[name]]
	var notices_file := FileAccess.open(directory.path_join("GODOT_THIRDPARTY_NOTICES.txt"), FileAccess.WRITE)
	if notices_file == null:
		quit(1)
		return
	notices_file.store_string(notices)
	notices_file.close()
	print("Godot license and third-party notices exported from the build engine.")
	quit(0)
