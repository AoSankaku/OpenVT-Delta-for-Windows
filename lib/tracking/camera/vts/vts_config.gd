extends Control

const SocketTracker = preload("res://lib/tracking/net/socket_tracker.gd")

var tracker: SocketTracker

func _ready() -> void:
	%Hostname.text = _get_local_ipv4(IP.get_local_addresses())
	tracker.connection_status.connect(
		func (status):
			match status:
				SocketTracker.ConnectionStatus.OFF:
					%ActiveIndicator.text = "Off"
					%ActiveIndicator.modulate = Color.RED
				SocketTracker.ConnectionStatus.ON:
					%ActiveIndicator.text = "On"
					%ActiveIndicator.modulate = Color.WHITE
				SocketTracker.ConnectionStatus.WAIT:
					%ActiveIndicator.text = "Waiting..."
					%ActiveIndicator.modulate = Color.WHITE
	)
	
static func _get_local_ipv4(addresses: PackedStringArray) -> String:
	var fallback = "127.0.0.1"
	for address in addresses:
		if address.contains(":") or not address.is_valid_ip_address():
			continue
		if address.begins_with("127.") or address == "0.0.0.0":
			continue
		if fallback == "127.0.0.1":
			fallback = address
		var second_octet = address.get_slice(".", 1).to_int()
		if address.begins_with("192.168.") or address.begins_with("10."):
			return address
		if address.begins_with("172.") and second_octet >= 16 and second_octet <= 31:
			return address
	return fallback

func _on_connect_pressed() -> void:
	tracker.host = "*"
	tracker.port = %Port.value
	tracker.start()
	
func _on_disconnect_pressed() -> void:
	tracker.stop()
