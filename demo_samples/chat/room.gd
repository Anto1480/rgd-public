extends Node
## The chat room's rules. A plain script on the level, so it runs on the server (or the host).
##
## Messages come in through the Say RemoteEvent and go out to everyone through the same
## remote. `_on_say` and `_on_typing` are connected in room.tscn (Node ▸ Signals), so there's
## no connecting code here. The server keeps the last messages in `_history` (private), and a
## player's chat window asks for them through the History RemoteFunction (history.gd).

const MAX_LENGTH := 300
const HISTORY_SIZE := 50
## Per-player gap between messages. RemoteEvent's own rate_limit (60/s) is a flood guard;
## chat wants a stricter, friendlier limit.
const MIN_GAP_MSEC := 300
const MAX_NAME_LENGTH := 20

## The room's topic. Public, so it replicates: late joiners see it right away.
var topic := "Welcome! Type /help for commands."

var _history: Array = []
var _next_id := 1
var _last_message := {}  # user_id -> msec


func _ready() -> void:
	Game.players.player_added.connect(_on_player_added)
	Game.players.player_removing.connect(_on_player_removing)


func _on_player_added(p: Player) -> void:
	# RGD already makes names unique, but they may contain spaces, which /w can't handle.
	# Replacing spaces can create a duplicate ("Bob Ross" vs "Bob_Ross"), so check again.
	var base := p.display_name.replace(" ", "_").left(MAX_NAME_LENGTH)
	var chosen := base
	var i := 2
	while _find_player(chosen, p) != null:
		chosen = "%s%d" % [base, i]
		i += 1
	p.display_name = chosen
	_post({kind = "system", text = "%s joined" % chosen})


func _on_player_removing(p: Player) -> void:
	_last_message.erase(p.user_id)
	_post({kind = "system", text = "%s left" % p.display_name})


func _on_say(player: Player, text) -> void:
	# Never trust the client: any type, any length, any rate.
	text = str(text).strip_edges().left(MAX_LENGTH)
	if text == "":
		return
	var now := Time.get_ticks_msec()
	if now - _last_message.get(player.user_id, -100000) < MIN_GAP_MSEC:
		_tell(player, "Slow down a little.")
		return
	_last_message[player.user_id] = now
	_set_typing(player, false)
	if text.begins_with("/"):
		_command(player, text)
	else:
		_post({kind = "say", from = player.display_name, text = text})


func _command(player: Player, text: String) -> void:
	var command := text.get_slice(" ", 0).to_lower()
	var rest := text.substr(command.length()).strip_edges()
	match command:
		"/me":
			if rest != "":
				_post({kind = "me", from = player.display_name, text = rest})
		"/w", "/whisper":
			var target_name := rest.get_slice(" ", 0)
			var message := rest.substr(target_name.length()).strip_edges()
			var target := _find_player(target_name)
			if target == null or message == "":
				_tell(player, "Usage: /w <name> <message> (names are case-insensitive)")
				return
			var entry := _entry({kind = "whisper", from = player.display_name, to = target.display_name, text = message})
			$Say.fire_client(target, entry)
			if target != player:
				$Say.fire_client(player, entry)
		"/name":
			var new_name := rest.left(MAX_NAME_LENGTH)
			if new_name == "" or new_name.contains(" "):
				_tell(player, "Usage: /name <new name> (no spaces, up to %d characters)" % MAX_NAME_LENGTH)
			elif _find_player(new_name) != null:
				_tell(player, "Someone is already called %s." % new_name)
			else:
				var old := player.display_name
				player.display_name = new_name  # Player.display_name replicates to everyone
				_post({kind = "system", text = "%s is now %s" % [old, new_name]})
		"/topic":
			if not _is_host_player(player):
				_tell(player, "Only the host can change the topic.")
			elif rest != "":
				topic = rest
				_post({kind = "system", text = "%s changed the topic" % player.display_name})
		"/help":
			_tell(player, "Commands: /me <action> · /w <name> <message> · /name <new name> · /topic <text> (host) · /leave · /help")
		_:
			_tell(player, "Unknown command %s. Try /help." % command)


func _on_typing(player: Player, typing) -> void:
	_set_typing(player, bool(typing))


func _set_typing(player: Player, typing: bool) -> void:
	player.typing = typing  # chat_player.gd: replicates to everyone


## The messages kept for late joiners (History remote).
func history() -> Array:
	return _history


## Adds a message to the history and sends it to everyone.
func _post(fields: Dictionary) -> void:
	var entry := _entry(fields)
	_history.append(entry)
	if _history.size() > HISTORY_SIZE:
		_history.pop_front()
	$Say.fire_all_clients(entry)


## A message only [param player] sees (not kept in the history).
func _tell(player: Player, text: String) -> void:
	$Say.fire_client(player, _entry({kind = "system", text = text}))


## Every message gets an id (clients use it to skip duplicates) and the server's clock time.
func _entry(fields: Dictionary) -> Dictionary:
	fields.id = _next_id
	_next_id += 1
	fields.time = Time.get_time_string_from_system().left(5)
	return fields


## The player called [param display_name] (case-insensitive), ignoring [param except].
func _find_player(display_name: String, except: Player = null) -> Player:
	for p in Game.players.get_players():
		if p != except and p.display_name.to_lower() == display_name.to_lower():
			return p
	return null


## The host's own player has peer id 1. A dedicated server has no player, so nobody is host.
func _is_host_player(player: Player) -> bool:
	return Game.is_host() and player.user_id == 1
