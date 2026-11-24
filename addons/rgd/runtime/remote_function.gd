@icon("res://addons/rgd/icons/remote_function.svg")
class_name RemoteFunction
extends Node
## Request/response between a client and the server, exactly like Roblox's RemoteFunction.
##
## [codeblock]
## # server
## $BuyItem.on_server_invoke = func(player: Player, item_id: int) -> bool:
##     return await shop.try_buy(player, item_id)
## # client
## var ok = await $BuyItem.invoke_server(42)
## [/codeblock]
## [b]Handle calls without boilerplate:[/b] in a script that `extends RemoteFunction` (it runs
## on the server and on clients), write `_on_server_invoke(player, ...)` (and, rarely,
## `_on_client_invoke(...)`); RGD uses them when no handler Callable is set.
## [codeblock]
## # get_price.gd, on a RemoteFunction node in your level
## extends RemoteFunction
##
## func _on_server_invoke(player: Player, item: String) -> int:
##     return Shop.price_for(player, item)
## [/codeblock]
## Waits forever by default (like Roblox); set [member timeout] to give up. If the other side
## hasn't set its handler yet, the call waits up to [constant HANDLER_WAIT] seconds for it. A
## call always finishes: a timeout, a missing handler, a disconnect, a wrong argument count,
## the session ending or this node being freed (a scene change) resolve it to null, so code
## awaiting it never hangs.

## Server handler: func(player: Player, ...args) -> Variant. May await.
var on_server_invoke: Callable
## Client handler for invoke_client: func(...args) -> Variant. May await.
## (Risky in Roblox terms: the server waits on a client that might never answer.)
var on_client_invoke: Callable

## Seconds to wait for an answer. 0 = wait forever.
@export var timeout := 0.0
## Max calls per second per player (server side). Extra calls are dropped.
@export var rate_limit := 60

## Handlers and settings that stay on each machine (not replicated).
const RGD_NO_REPLICATE := ["on_server_invoke", "on_client_invoke", "timeout", "rate_limit"]
## Seconds a call waits for the other side to set its handler (e.g. a UI that isn't ready yet).
const HANDLER_WAIT := 10.0

var _next_request := 1


## A call waiting for its answer. [Game] keeps it (not a coroutine of this node, which may be
## freed while waiting) and emits [signal finished] once: with the answer, or with null.
class Call extends RefCounted:
	signal finished(value: Variant)
	var remote_id := 0
	var remote_name := ""
	var req := 0
	## Who answers: 1 (the server) for invoke_server, the player's id for invoke_client.
	var peer := 0
	var deadline := 0  # Time.get_ticks_msec() to give up at; 0 = never
	var timeout := 0.0
	var done := false
	var value: Variant


## Client → server. Use with await: `var r = await remote.invoke_server(...)`.
## [codeblock]
## var price: int = await $GetPrice.invoke_server("sword")
## [/codeblock]
func invoke_server(...args: Array) -> Variant:
	if not Game.is_client():
		push_error("RGD: %s.invoke_server() called on the server. Call the function directly, or use invoke_client." % name)
		return null
	Game._check_client_rate(self)
	var call := _new_call(1)
	if Game.is_host():
		_answer_here(call, on_server_invoke, [Game.players.local_player] + args, "on_server_invoke")
	elif not Game._send_remote_msg(1, self, RGDProtocol.Msg.INVOKE, call.req, args):
		Game._calls.erase(call)
		push_error("RGD: %s.invoke_server(): this RemoteFunction isn't replicated." % name)
		return null
	return call.finished  # what `await` waits for


## Server → client. Use with await.
## [codeblock]
## # Ask one player's game which language it uses.
## var lang = await $GetLanguage.invoke_client(player)
## [/codeblock]
func invoke_client(player: Player, ...args: Array) -> Variant:
	if not Game.is_server():
		push_error("RGD: %s.invoke_client() called on a client. Clients call invoke_server()." % name)
		return null
	if player == null or not is_instance_valid(player):
		push_warning("RGD: %s.invoke_client(): player is gone." % name)
		return null
	var call := _new_call(player.user_id)
	if player.user_id == Game.local_peer_id() and Game.is_host():
		_answer_here(call, on_client_invoke, args, "on_client_invoke")
	else:
		Game._send_remote_msg(player.user_id, self, RGDProtocol.Msg.INVOKE, call.req, args)
	return call.finished  # what `await` waits for


func _new_call(peer: int) -> Call:
	var c := Call.new()
	c.remote_id = get_instance_id()
	c.remote_name = name
	c.req = _next_request
	_next_request += 1
	c.peer = peer
	c.timeout = timeout
	c.deadline = Time.get_ticks_msec() + int(timeout * 1000.0) if timeout > 0.0 else 0
	Game._calls.append(c)
	return c


## The host calling its own handler: run it here and finish the call with its result.
func _answer_here(call: Call, handler: Callable, args: Array, handler_name: String) -> void:
	var r := await _call_handler(handler, args, handler_name)
	_finish(call, r)


## Records the answer ([ok, value_or_error]); Game emits it on the next frame (the caller may
## not be awaiting yet if the handler answered at once).
func _finish(call: Call, result: Array) -> void:
	if call.done:
		return
	call.done = true
	if result.size() == 2 and bool(result[0]):
		call.value = result[1]
	else:
		push_warning("RGD: %s: %s" % [name, result[1] if result.size() == 2 else "a malformed answer"])


## Runs a handler (which may be a coroutine) with spread arguments. Returns [ok, value_or_error].
func _call_handler(handler: Callable, args: Array, handler_name: String) -> Array:
	if not handler.is_valid() and has_method("_" + handler_name):
		handler = Callable(self, "_" + handler_name)  # the subclass's _on_server_invoke
	if not handler.is_valid():
		handler = await _wait_for_handler(handler_name)
	if not handler.is_valid():
		return [false, "no %s handler is set on the other side" % handler_name]
	var why := Game._call_mismatch(handler, args)
	if why != "":
		var msg := "%s.%s %s" % [name, handler_name, why]
		Game._warn_limited("%d:%s" % [get_instance_id(), handler_name], "RGD: dropped a call: " + msg,
			handler_name == "on_client_invoke")
		return [false, msg]
	var value = await handler.callv(args)
	return [true, value]


## Waits up to HANDLER_WAIT seconds for [param handler_name] to be set.
func _wait_for_handler(handler_name: String) -> Callable:
	var tree := Engine.get_main_loop() as SceneTree
	var end := Time.get_ticks_msec() + int(HANDLER_WAIT * 1000.0)
	while tree != null and Time.get_ticks_msec() < end and is_instance_valid(self):
		var h: Callable = get(handler_name)
		if h.is_valid():
			return h
		await tree.process_frame
	return get(handler_name) if is_instance_valid(self) else Callable()


# Called by Game when messages arrive.

func _server_invoke(player: Player, req: int, args: Array) -> void:
	var r := await _call_handler(on_server_invoke, [player] + args, "on_server_invoke")
	if is_instance_valid(player) and Game.is_server():
		Game._send_remote_msg(player.user_id, self, RGDProtocol.Msg.INVOKE_RESULT, req, r)


func _client_invoke(req: int, args: Array) -> void:
	var r := await _call_handler(on_client_invoke, args, "on_client_invoke")
	if Game.is_session_active():
		Game._send_remote_msg(1, self, RGDProtocol.Msg.INVOKE_RESULT, req, r)


## An answer arrived from [param from_peer] (only the peer that was asked can answer).
func _resolve(req: int, result: Array, from_peer: int) -> void:
	for c in Game._calls:
		if c.remote_id == get_instance_id() and c.req == req and c.peer == from_peer:
			_finish(c, result)
			return
