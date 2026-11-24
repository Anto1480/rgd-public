@icon("res://addons/rgd/icons/player.svg")
class_name Player
extends Node
## Root of the player scene (`rgd/player_scene`, plan 6.2). One per connected player, under
## [code]Game.players[/code] on every machine.
##
## [member character] is moved into the world at a spawn point and owned by this player.
## [member ui] only exists on this player's own machine.
##
## [b]Your own player class:[/b] put a script that `extends Player` on the player scene's root.
## It runs on the server and on every client (no suffix needed); its public variables are the
## server's and replicate to everyone, with setters running on clients. RGD calls these if you
## write them, so there's nothing to connect:
## - `_server_ready()`: on the server, once the player has joined and has a character.
## - `_local_ready()`: on this player's own machine, once.
## - `_character_added(character)` / `_character_removing(character)`: on every machine, on
## spawn and respawn.
## - `_leaving()`: on every machine, when the player leaves.
## [codeblock]
## # my_player.gd, on the player scene's root
## extends Player
##
## var coins := 0:                       # the server's value, replicated to everyone
##     set(v):
##         coins = v
##         if is_local() and ui:
##             ui.get_node("Coins").text = str(v)   # runs on this player's machine
##
## func _server_ready() -> void:
##     coins = 10                        # starting money, decided by the server
##
## func _local_ready() -> void:
##     ui.get_node("Welcome").text = "Hi " + display_name
## [/codeblock]
## The signals ([signal character_added], ...) work from the Signals tab as well.

## A character was assigned (spawn or respawn), on every machine. Also calls
## `_character_added(character)` if the script defines it.
signal character_added(character: Node)
## The current character is being replaced or removed.
signal character_removing(character: Node)

## Kept on each machine; never replicated.
const RGD_NO_REPLICATE := ["ui", "replication_focus", "join_data"]

## The player's character (any physics body). Can be empty for games without an avatar.
@export var character: Node:
	set(v):
		if v == character:
			return
		if character != null and is_instance_valid(character):
			character_removing.emit(character)
			if has_method(&"_character_removing"):
				call_deferred(&"_character_removing", character)
		character = v
		if v != null:
			character_added.emit(v)
			if has_method(&"_character_added"):
				call_deferred(&"_character_added", v)  # once it's placed in the world

## The player's UI (CanvasLayer or Control). Only exists on this player's own machine.
@export var ui: Node

## Server, with streaming on (`rgd/streaming/radius`): the world streams in around this node
## instead of [member character] (Roblox's `ReplicationFocus`). E.g. a camera or a vehicle.
## [codeblock]
## # Stream the world around the car the player is driving.
## player.replication_focus = car
## [/codeblock]
var replication_focus: Node

## The player's peer id (1 for the host's own player).
var user_id := 0
## The name shown for this player (from `Game.join(address, {name = ...})`).
var display_name := ""
## Server: what the client sent with `Game.join(address, {data = {...}})`: an auth token,
## a platform id (Steam), a chosen skin... Plain data only. Never sent to other players.
var join_data := {}


# A notification, not _ready: a script extending Player may define its own _ready.
func _notification(what: int) -> void:
	if what == NOTIFICATION_READY:
		_call_lifecycle.call_deferred()  # after the character is placed in the world


func _call_lifecycle() -> void:
	if not is_inside_tree():
		return
	if Game.is_server() and has_method(&"_server_ready"):
		call(&"_server_ready")
	if is_local() and has_method(&"_local_ready"):
		call(&"_local_ready")


## True on this player's own machine.
func is_local() -> bool:
	return Game.players.local_player == self


## Server: replaces the character with a fresh one from the player scene at a spawn point.
## [codeblock]
## # kill_zone.gd (server): anyone who falls in starts over.
## func _on_body_entered(body: Node3D) -> void:
##     var player := Game.players.get_player_from_character(body)
##     if player:
##         player.respawn()
## [/codeblock]
func respawn() -> void:
	Game._respawn(self)


## Server: disconnects this player; they get session_ended(reason).
func kick(reason: String = "kicked") -> void:
	Game.kick(self, reason)
