extends "../model_loader.gd"

func model_directory() -> String:
	return "user://Live2DModels"

func model_format() -> StringName:
	return "Live2D/Ayagami"
	
func supported_extension() -> Array[String]:
	return [".model3.json", ".moc3"]

func strategy() -> Script:
	return preload("./model.gd")

func load_data(path: String) -> ModelMeta:
	var meta = ModelMeta.new()
	
	var base_dir = path.get_base_dir()
	var base_name = path.get_file()
	# always prefer using model3 for loading
	for ext in supported_extension():
		base_name = base_name.trim_suffix(ext)
	var filepath = path
	if not path.ends_with(".model3.json"):
		filepath = base_dir.path_join("%s.model3.json" % base_name)
	var vt_file = base_dir.path_join("%s.vtube.json" % base_name)
	var ovt_file = base_dir.path_join("%s.ovt.json" % base_name)

	meta.name = base_name
	meta.id = base_name
	meta.model = filepath

	if FileAccess.file_exists(vt_file):
		var vtube_data = Files.read_json(vt_file)
		var model_name: Variant = vtube_data.get("Name")
		var model_id: Variant = vtube_data.get("ModelID")
		if model_name is String and not model_name.is_empty():
			meta.name = model_name
		if model_id is String and not model_id.is_empty():
			meta.id = model_id
	
	var model_data = Files.read_json(filepath)
	meta.path = path.get_base_dir()
	meta.format = model_format()
	meta.studio_parameters = vt_file
	meta.openvt_parameters = ovt_file
	
	return meta
