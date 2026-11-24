extends RemoteEvent
## The Say remote. Clients send what they type (fire_server); the room script answers, connected
## in room.tscn (Node ▸ Signals: on_server_event ▸ room.gd's _on_say). Messages the server sends
## back arrive here, in _on_client_event, on the receiving player's machine, and go to their
## chat window. Extending RemoteEvent makes this script run on both sides; nothing to connect.


func _on_client_event(entry: Dictionary) -> void:
	var me := Game.players.local_player
	# A message that arrives before the window is ready isn't lost: the window pulls the
	# history when it opens (message ids skip duplicates).
	if me and me.ui and me.ui.is_node_ready():
		me.ui.show_entry(entry)
