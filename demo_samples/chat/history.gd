extends RemoteFunction
## The History remote: a chat window asks for the messages from before it opened. Extending
## RemoteFunction, this runs on both sides and RGD calls _on_server_invoke on the server.


func _on_server_invoke(_player: Player) -> Array:
	return get_parent().history()
