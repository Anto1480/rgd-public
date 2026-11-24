@icon("res://addons/rgd/icons/remote_event.svg")
class_name RemoteEvent
extends Node
## One-way messages between clients and the server, exactly like Roblox's RemoteEvent.
##
## [codeblock]
## # client
## $OpenDoor.fire_server()
## # server
## $OpenDoor.on_server_event.connect(func(player: Player): is_open = not is_open)
## [/codeblock]
## Arguments can be plain data (numbers, strings, vectors, arrays, dictionaries...), replicated
## nodes, and file-backed resources. Other objects arrive as null.
##
## Like Roblox, events that arrive while nobody is connected wait in a queue (up to
## [constant QUEUE_LIMIT] per side) and are delivered as soon as a listener connects. So a
## player's UI still gets an event the server sent the moment they joined.
##
## [b]Three ways to handle events[/b], use whichever you like:
## - [b]Extend it.[/b] A script that `extends RemoteEvent` runs on the server and on clients
## (no suffix needed), and RGD calls its `_on_server_event(player, ...)` and
## `_on_client_event(...)` if you write them. No connecting, no boilerplate:
## [codeblock]
## # buy.gd, on a RemoteEvent node in your level
## extends RemoteEvent
##
## func _on_server_event(player: Player, item: String) -> void:   # on the server
##     if Shop.can_afford(player, item):
##         Shop.give(player, item)
##         fire_client(player, "bought", item)
##
## func _on_client_event(what: String, item: String) -> void:     # on that player's machine
##     print("You %s a %s" % [what, item])
## [/codeblock]
## - [b]The Signals tab.[/b] Select the node ▸ Node ▸ Signals ▸ `on_server_event` ▸ Connect,
## pick a node whose script runs on the server (a level script), and add your arguments after
## `player` in the generated method. `on_client_event` goes to a client script.
## - [b]In code.[/b] `$Buy.on_server_event.connect(func(player: Player, item: String): ...)`.

## Server: a client fired this event. Handlers get the sending [Player], then the arguments
## spread out: `func(player: Player, item: String, amount: int)`.
signal on_server_event(player: Player)
## Client: the server fired this event to this machine. Handlers get the arguments spread out:
## `func(message: String, amount: int)`.
signal on_client_event

## Max fire_server calls per second per player (server side). Extra calls are dropped.
@export var rate_limit := 60

## Settings that stay on each machine (not replicated).
const RGD_NO_REPLICATE := ["rate_limit"]
## Events kept per side while nobody listens. Older ones are dropped beyond this.
const QUEUE_LIMIT := 64

var _queue_server: Array = []  # [player, args...] arrays waiting for on_server_event listeners
var _queue_client: Array = []  # args arrays waiting for on_client_event listeners
var _queue_warned := false


# A notification, not _ready: a script extending RemoteEvent may define its own _ready.
func _notification(what: int) -> void:
	if what == NOTIFICATION_READY:
		set_process(not (_queue_server.is_empty() and _queue_client.is_empty()))


## Delivers queued events once someone listens.
func _process(_delta: float) -> void:
	if not _queue_server.is_empty() and _has_server_listener():
		var q := _queue_server
		_queue_server = []
		for e in q:
			if is_instance_valid(e[0]):  # the sender may have left meanwhile
				_dispatch(&"on_server_event", &"_on_server_event", e)
	if not _queue_client.is_empty() and _has_client_listener():
		var q := _queue_client
		_queue_client = []
		for e in q:
			_dispatch(&"on_client_event", &"_on_client_event", e)
	if _queue_server.is_empty() and _queue_client.is_empty():
		set_process(false)


## Client → server.
## [codeblock]
## # In the player scene (runs on this player's machine):
## get_tree().current_scene.get_node("Chat").fire_server("hello!")
## [/codeblock]
func fire_server(...args: Array) -> void:
	if not Game.is_client():
		push_error("RGD: %s.fire_server() called on the server. Use fire_client / fire_all_clients, or connect on_server_event." % name)
		return
	Game._check_client_rate(self)
	if Game.is_host():
		_deliver_server.call_deferred(Game.players.local_player, args)
		return
	if not Game._send_remote(1, self, args):
		push_error("RGD: %s.fire_server(): this RemoteEvent isn't replicated (is it inside the world or the player scene?)." % name)


## Server → one client.
## [codeblock]
## # Only this player hears it.
## $Notify.fire_client(player, "You found a secret!")
## [/codeblock]
func fire_client(player: Player, ...args: Array) -> void:
	if not Game.is_server():
		push_error("RGD: %s.fire_client() called on a client. Clients talk to the server with fire_server()." % name)
		return
	if player == null:
		push_error("RGD: %s.fire_client(): player is null." % name)
		return
	if player.user_id == Game.local_peer_id() and Game.is_host():
		_deliver_client.call_deferred(args)
	else:
		Game._send_remote(player.user_id, self, args)


## Server → every client.
## [codeblock]
## $Announce.fire_all_clients("%s won the round" % player.display_name)
## [/codeblock]
func fire_all_clients(...args: Array) -> void:
	if not Game.is_server():
		push_error("RGD: %s.fire_all_clients() called on a client." % name)
		return
	for peer in Game._ready_peers():
		Game._send_remote(peer, self, args)
	if Game.is_host():
		_deliver_client.call_deferred(args)


func _deliver_server(player: Player, args: Array) -> void:
	if not _has_server_listener():
		_enqueue(_queue_server, [player] + args)
	else:
		_dispatch(&"on_server_event", &"_on_server_event", [player] + args)


func _deliver_client(args: Array) -> void:
	if not _has_client_listener():
		_enqueue(_queue_client, args)
	else:
		_dispatch(&"on_client_event", &"_on_client_event", args)


func _has_server_listener() -> bool:
	return has_method(&"_on_server_event") or not on_server_event.get_connections().is_empty()


func _has_client_listener() -> bool:
	return has_method(&"_on_client_event") or not on_client_event.get_connections().is_empty()


## Calls the subclass's virtual handler (if it has one), then the signal's listeners.
## A call that a handler can't take (the wrong number of arguments, or the wrong types for a
## handler that declares them) is dropped with a warning, before anything runs: from a client
## it may be a cheat; from the server it's a bug (then it's an error).
func _dispatch(sig: StringName, virtual: StringName, args: Array) -> void:
	var handlers: Array[Callable] = []
	if has_method(virtual):
		handlers.append(Callable(self, virtual))
	for c in get_signal_connection_list(sig):
		handlers.append(c.callable)
	for h in handlers:
		var why := Game._call_mismatch(h, args)
		if why != "":
			var from := ""
			if sig == &"on_server_event" and not args.is_empty() and args[0] is Player:
				from = " from " + (args[0] as Player).display_name
			var handler := "%s()" % h.get_method() if h.get_object() != null and h.get_object().has_method(h.get_method()) else "a lambda handler"
			Game._warn_limited("%d:%s" % [get_instance_id(), sig], "RGD: %s: dropped a call%s: %s %s." % [
				name, from, handler, why], sig == &"on_client_event")
			return
	if has_method(virtual):
		Callable(self, virtual).callv(args)
	if not get(sig).get_connections().is_empty():
		emit_signal.callv([sig] + args)


func _enqueue(queue: Array, entry: Array) -> void:
	if queue.size() >= QUEUE_LIMIT:
		queue.pop_front()
		if not _queue_warned:
			_queue_warned = true
			push_warning("RGD: %s: more than %d events arrived with nothing connected to receive them; dropping the oldest. Connect on_server_event / on_client_event." % [name, QUEUE_LIMIT])
	queue.append(entry)
	set_process(true)
