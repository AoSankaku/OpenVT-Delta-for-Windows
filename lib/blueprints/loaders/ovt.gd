extends "./blueprint_loader.gd"

const Serializers = preload("res://lib/utils/serializers.gd")

const PLACEHOLDER_GRAPH_KEYS := ["bindings", "enabled", "name", "nodes"]
const PLACEHOLDER_NODE_KEYS := ["id", "parameters", "position", "type"]

func id() -> StringName:
	return "ovt"
	
func load_graph(model: VtModel, path: String = model.modelmeta.openvt_parameters) -> Array:
	var data: Dictionary = Files.read_json(path)
	if data.is_empty():
		return []
		
	var valid_graphs = []
	if "graphs" in data: # model data may hold multiple graphs
		var graphs: Variant = data.get("graphs")
		if not graphs is Dictionary:
			return []
		var migrate_vts_placeholder := _is_safe_vts_placeholder_map(graphs)
		for profile in graphs:
			if migrate_vts_placeholder and profile in ["VTS_Parameters", "VTS_Hotkeys"]:
				continue
			var graph: Blueprint = BlueprintTemplate.instantiate()
			graph.name = profile
			add_child(graph)
			await _deserialize(graph, model, graphs[profile])
			if graph.get_child_count() > 0:
				valid_graphs.append(graph)
			remove_child(graph)
			if graph.get_child_count() == 0:
				graph.queue_free()
	else: # assume the file itself is a single blueprint
		var graph: Blueprint = BlueprintTemplate.instantiate()
		graph.name = data.get("name", "Blueprint")
		add_child(graph)
		await _deserialize(graph, model, data)
		if graph.get_child_count() > 0:
			valid_graphs.append(graph)
		remove_child(graph)
		if graph.get_child_count() == 0:
			graph.queue_free()
		
	return valid_graphs

func _is_safe_vts_placeholder_map(graphs: Dictionary) -> bool:
	if graphs.size() == 1:
		if not graphs.has("VTS_Parameters"):
			return false
	elif graphs.size() == 2:
		if not graphs.has("VTS_Parameters") or not graphs.has("VTS_Hotkeys"):
			return false
		if not _is_safe_empty_vts_hotkeys(graphs["VTS_Hotkeys"]):
			return false
	else:
		return false
	return _is_safe_vts_parameter_placeholder(graphs["VTS_Parameters"])

func _is_safe_empty_vts_hotkeys(data: Variant) -> bool:
	return data is Dictionary \
		and _has_exact_keys(data, PLACEHOLDER_GRAPH_KEYS) \
		and data.get("name") == "VTS_Hotkeys" \
		and data.get("enabled") == true \
		and data.get("bindings") is Array \
		and data.bindings.is_empty() \
		and data.get("nodes") is Array \
		and data.nodes.is_empty()

func _is_safe_vts_parameter_placeholder(data: Variant) -> bool:
	if not data is Dictionary:
		return false
	if not _has_exact_keys(data, PLACEHOLDER_GRAPH_KEYS):
		return false
	if data.get("name") != "VTS_Parameters" or data.get("enabled") != true:
		return false
	if not data.get("bindings") is Array or not data.bindings.is_empty():
		return false
	var nodes: Variant = data.get("nodes")
	if not nodes is Array or nodes.size() != 1:
		return false
	var node: Variant = nodes[0]
	if not node is Dictionary or not _has_exact_keys(node, PLACEHOLDER_NODE_KEYS):
		return false
	if node.get("type") != "model_output" or not node.get("id") is String or node.id.is_empty():
		return false
	if not node.get("parameters") is Dictionary or not node.parameters.is_empty():
		return false
	var position: Variant = node.get("position")
	if not position is Dictionary or not _has_exact_keys(position, ["x", "y"]):
		return false
	for axis in ["x", "y"]:
		if typeof(position[axis]) != TYPE_INT and typeof(position[axis]) != TYPE_FLOAT:
			return false
		if not is_finite(float(position[axis])):
			return false
	return true

func _has_exact_keys(value: Dictionary, expected: Array) -> bool:
	if value.size() != expected.size():
		return false
	for key in expected:
		if not value.has(key):
			return false
	return true

func _deserialize(graph: Blueprint, model: VtModel, data: Dictionary):
	graph.enabled = data.get("enabled", true)
	graph.process_mode = PROCESS_MODE_INHERIT if graph.enabled else PROCESS_MODE_DISABLED
	
	for i in data.get("nodes", []):
		var id = i.get("id", "")
		if id.is_empty():
			continue
		var n = graph.create_action(StringName(i.type))
		
		if n != null:
			n.id = id
			n.model = model
			n.deserialize(i.get("parameters", {}))
			n = graph.spawn_action(n, model)
		
		if n == null:
			push_error("invalid action type (%s), clearing graph" % i.type)
			graph.clear_connections()
			for c in graph.get_children():
				c.queue_free()
			return
		
		n.position_offset = Serializers.Vec2Serializer.from_json(i.get("position"), Vector2.ZERO)
		
	# delay connecting until all blueprints have been loaded
	# this is necessary for some nodes that require dynamically building slots
	# as well as for nodes that rely on cross-blueprint state
	await get_tree().process_frame
	for node in graph.get_children():
		if node is VtAction:
			node.build_slots()
		
	for i in data.get("bindings", []):
		if i.src in graph.graph_elements and i.dst in graph.graph_elements:
			var from_node: VtAction = graph.graph_elements[i.src]
			var to_node: VtAction = graph.graph_elements[i.dst]
			if from_node == null or to_node == null:
				continue
			var src_slot = "{0}".format([i.src_slot])
			var dst_slot = "{0}".format([i.dst_slot])
			var src_port = from_node.get_output_port_by_name(src_slot)
			var dst_port = to_node.get_input_port_by_name(dst_slot)
			if src_port == -1:
				push_error("invalid slot in graph connection (node: {0}, src: {1})".format([from_node.name, src_slot]))
				continue
			if dst_port == -1:
				push_error("invalid slot in graph connection (node: {0}, dst: {1})".format([to_node.name, dst_slot]))
				continue
			graph._on_connection_request.call_deferred(
				from_node.name, src_port,
				to_node.name, dst_port
			)
			
