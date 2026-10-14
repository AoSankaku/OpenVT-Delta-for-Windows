extends RefCounted

## Owns only the OpenSeeFace process started by this instance.
const BUNDLE_NAME := "openseeface"

var executable_path: String
var models_path: String
var _process_id: int = -1

func _init() -> void:
	var bundle_dir: String
	if Engine.is_editor_hint() or OS.has_feature("editor"):
		bundle_dir = ProjectSettings.globalize_path("res://bin").path_join(BUNDLE_NAME)
	else:
		bundle_dir = OS.get_executable_path().get_base_dir().path_join(BUNDLE_NAME)

	var binary_dir := bundle_dir.path_join("Binary")
	executable_path = binary_dir.path_join("facetracker.exe")
	models_path = bundle_dir.path_join("models")

func is_available() -> bool:
	return OS.get_name() == "Windows" \
		and FileAccess.file_exists(executable_path) \
		and DirAccess.dir_exists_absolute(models_path)

func start(camera_index: int, port: int, fps: int) -> bool:
	if is_running():
		return true
	_process_id = -1
	if not is_available():
		return false

	var args := build_arguments(camera_index, port, fps)
	_process_id = OS.create_process(executable_path, args, false)
	return _process_id > 0

func build_arguments(camera_index: int, port: int, fps: int) -> PackedStringArray:
	return PackedStringArray([
		"-i", "127.0.0.1",
		"-p", str(port),
		"-c", str(camera_index),
		"-F", str(fps),
		"-v", "0",
		"-s", "1",
		"--model-dir", models_path,
	])

func stop() -> void:
	if _process_id > 0 and OS.is_process_running(_process_id):
		OS.kill(_process_id)
	_process_id = -1

func is_running() -> bool:
	return _process_id > 0 and OS.is_process_running(_process_id)

func get_owned_process_id() -> int:
	return _process_id

## Clear the ID after observing an unexpected exit, without touching any other process.
func forget_exited_process() -> void:
	_process_id = -1
