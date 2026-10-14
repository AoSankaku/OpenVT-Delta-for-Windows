extends Control

const Serializers = preload("res://lib/utils/serializers.gd")

@export var title: String = ""

var is_floating: bool = false
var can_close: bool = true
var window: Window
var popup_position: Vector2
var _has_popup_position: bool = false

signal on_popout_requested
signal on_popout
signal on_restore_requested
signal on_restore

func restore() -> void:
	if not is_floating or not is_instance_valid(window):
		return
	can_close = true # force enable closing
	window.close_requested.emit()
	
func popout(persistent: bool = false) -> void:
	if is_floating:
		return
	
	can_close = not persistent
	on_popout_requested.emit()
	
	var position = self.position
	var source_window = get_window()
	
	var parent = self.get_parent()
	var index = self.get_index()
	window = Window.new()
	window.visible = false
	window.size = self.size
	window.min_size = Vector2i(get_combined_minimum_size().ceil())
	window.transient = true
	window.transparent = true
	window.title = title
	window.initial_position = Window.WINDOW_INITIAL_POSITION_ABSOLUTE
	if _has_popup_position:
		window.position = Vector2i(popup_position)
	else:
		window.position = source_window.position + (source_window.size - window.size) / 2
	
	get_tree().root.add_child(window)
	
	is_floating = true
	self.reparent(window, false)
	self.position = Vector2i.ZERO
	
	on_popout.emit()
	
	window.close_requested.connect(
		func ():
			if not can_close:
				return
			on_restore_requested.emit()
			popup_position = window.position
			_has_popup_position = true
			var closing_window = window
			window = null
			is_floating = false
			self.reparent(parent)
			parent.move_child(self, index)
			
			self.set_position(position, false)
			
			closing_window.queue_free()
			on_restore.emit()
	)
	window.show()
	_fit_window_on_screen()

func _fit_window_on_screen() -> void:
	var usable_rect = DisplayServer.screen_get_usable_rect(window.current_screen)
	if usable_rect.size.x <= 0 or usable_rect.size.y <= 0:
		return # Headless display servers don't have a monitor work area.

	# Window.position is the client origin, so allow room for the native title bar.
	var decorations = window.get_size_with_decorations() - window.size
	window.size = window.size.min((usable_rect.size - decorations).max(Vector2i.ONE))
	var frame_position = window.get_position_with_decorations()
	var client_offset = window.position - frame_position
	var last_position = usable_rect.end - window.get_size_with_decorations()
	window.position = Vector2i(
		clampi(frame_position.x, usable_rect.position.x, maxi(usable_rect.position.x, last_position.x)),
		clampi(frame_position.y, usable_rect.position.y, maxi(usable_rect.position.y, last_position.y)),
	) + client_offset

func load_settings(settings: Dictionary):
	var windows: Dictionary = settings.get("window_positions", {})
	_has_popup_position = windows.has(self.name)
	var self_pos: Vector2 = Serializers.Vec2Serializer.from_json(windows.get(self.name, {"x": 0, "y": 0}))
	
	popup_position = self_pos
	
func save_settings(settings: Dictionary):
	if is_instance_valid(window):
		popup_position = window.position
		_has_popup_position = true
		
	var windows: Dictionary = settings.get("window_positions", {})
	if _has_popup_position:
		windows[self.name] = Serializers.Vec2Serializer.to_json(popup_position)
	
	settings["window_positions"] = windows
	
