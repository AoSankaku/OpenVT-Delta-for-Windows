extends VBoxContainer
class_name Accordion

enum Mode {
	SINGLE,
	MULTI
}

@export var select_mode = Mode.SINGLE
@export var allow_deselect = true

var button_group = ButtonGroup.new()
var _fold_buttons: Dictionary = {}

func _ready() -> void:
	button_group.allow_unpress = allow_deselect
	
	for i in get_children():
		add_fold(i)
		
	child_entered_tree.connect(
		func (node):
			if node.get_parent() != self:
				return
			# only allow collapsing nodes with children
			if node.get_child_count() > 0:
				add_fold.call_deferred(node)
	)
	
func add_fold(section: Node):
	if not is_instance_valid(section) or section.get_parent() != self:
		return
	var section_id = section.get_instance_id()
	if _fold_buttons.has(section_id):
		return
	var btn = preload("./accordion_button.tscn").instantiate()
	_fold_buttons[section_id] = btn
	btn.text = section.name
	btn.button_pressed = section.visible
	if select_mode == Mode.MULTI:
		btn.button_group = button_group
	btn.link = section
	var remove_fold = _remove_fold.bind(section_id)
	if not section.tree_exiting.is_connected(remove_fold):
		section.tree_exiting.connect(remove_fold, CONNECT_DEFERRED)
	
	# add sibling before
	add_child(btn)
	move_child(btn, section.get_index())
	
func _remove_fold(section_id: int) -> void:
	var section = instance_from_id(section_id)
	# Reparenting the whole controls panel leaves its sections in this accordion.
	if is_instance_valid(section) and section.get_parent() == self:
		return
	var btn = _fold_buttons.get(section_id)
	if is_instance_valid(btn):
		btn.queue_free()
	_fold_buttons.erase(section_id)
