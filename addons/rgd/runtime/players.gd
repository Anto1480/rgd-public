class_name RGDPlayers
extends Node
## [code]Game.players[/code]: every connected [Player], on every machine (Roblox's `Players`).

## A player joined (on every machine; on a late joiner, once per player already there).
## [codeblock]
## # scoreboard.local.gd
## func _ready() -> void:
##     Game.players.player_added.connect(func(p: Player): _add_row(p.display_name))
## [/codeblock]
signal player_added(player: Player)
## A player is leaving. Their Player node is still valid during the signal.
signal player_removing(player: Player)

## This machine's own player (null on a dedicated server).
var local_player: Player

## Each machine has its own local player; never replicated.
const RGD_NO_REPLICATE := ["local_player"]


func _init() -> void:
	name = "Players"
	child_entered_tree.connect(_on_child_entered)
	child_exiting_tree.connect(_on_child_exiting)


## Every connected player, in join order.
func get_players() -> Array[Player]:
	var out: Array[Player] = []
	for c in get_children():
		if c is Player:
			out.append(c)
	return out


## The player with peer id [param user_id], or null.
func get_by_id(user_id: int) -> Player:
	for c in get_children():
		if c is Player and c.user_id == user_id:
			return c
	return null


## The player whose [member Player.display_name] is [param display_name] (ignoring case), or null.
## [codeblock]
## var target := Game.players.get_by_name("bob")   # finds "Bob"
## [/codeblock]
func get_by_name(display_name: String) -> Player:
	for p in get_players():
		if p.display_name.to_lower() == display_name.to_lower():
			return p
	return null


## The player whose character is [param node] or contains it (Roblox's
## `GetPlayerFromCharacter`), or null. Handy in collision callbacks, where you get the body
## or one of its parts:
## [codeblock]
## func _on_body_entered(body: Node3D) -> void:
##     var player := Game.players.get_player_from_character(body)
##     if player:
##         player.respawn()
## [/codeblock]
func get_player_from_character(node: Node) -> Player:
	if node == null:
		return null
	for p in get_players():
		var ch := p.character
		if ch != null and is_instance_valid(ch) and (ch == node or ch.is_ancestor_of(node)):
			return p
	# Server: a character that is still being placed knows its player.
	var c := node
	while c != null:
		var p = c.get_meta(&"rgd_player") if c.has_meta(&"rgd_player") else null
		if p is Player and is_instance_valid(p):
			return p
		c = c.get_parent()
	return null


func _on_child_entered(n: Node) -> void:
	if not n is Player:
		return
	if int(n.get_meta(RGDInstancer.META_CTX_OWNER, 0)) == Game.local_peer_id() and Game.is_client():
		local_player = n
	player_added.emit(n)


func _on_child_exiting(n: Node) -> void:
	if not n is Player:
		return
	player_removing.emit(n)
	if n.has_method(&"_leaving"):
		n.call(&"_leaving")
	if local_player == n:
		local_player = null
