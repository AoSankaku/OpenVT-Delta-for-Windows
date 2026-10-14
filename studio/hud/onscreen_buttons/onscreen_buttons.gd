extends "res://ui/popout_panel.gd"

signal pressed(idx: int)

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	for btn in %Buttons.get_children():
		btn.text = str(btn.get_index() + 1)
		btn.tooltip_text = "Action button %d" % (btn.get_index() + 1)
		btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		btn.add_theme_font_size_override("font_size", 24)
		btn.pressed.connect(
			pressed.emit.bind(btn.get_index())
		)
