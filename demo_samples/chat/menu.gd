extends Control
## Start screen: enter a name, then host (you chat and you're the server) or join.

const ROOM := "res://samples/chat/room.tscn"

@onready var _name: LineEdit = %Name
@onready var _address: LineEdit = %Address
@onready var _status: Label = %Status


func _ready() -> void:
	%Host.pressed.connect(_on_host)
	%Join.pressed.connect(_on_join)
	Game.join_failed.connect(func(reason: String): _status.text = "Couldn't join: " + reason)
	if Game.last_end_reason != "":
		_status.text = "Session ended: " + Game.last_end_reason  # "the host left", a kick...
	_name.grab_focus()


func _on_host() -> void:
	if Game.host(Game.default_port(), ROOM, {name = _chat_name()}) != OK:
		_status.text = "Couldn't host: " + Game.last_error


func _on_join() -> void:
	var address := _address.text.strip_edges()
	if address == "":
		address = "127.0.0.1"
	_status.text = "Joining %s..." % address
	Game.join(address, {name = _chat_name()})


## Names have no spaces so /w works with them.
func _chat_name() -> String:
	var n := _name.text.strip_edges().replace(" ", "_")
	return n if n != "" else "Guest%d" % (randi() % 1000)
