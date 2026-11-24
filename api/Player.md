# Player

**Inherits:** Node < Object

**Where you find it:** The root node of your player scene (`rgd/player_scene`); one per connected player, under `Game.players`. Script: `addons/rgd/runtime/player.gd`.

Root of the player scene (`rgd/player_scene`).

## Description

Root of the player scene (`rgd/player_scene`). One per connected player, under
`Game.players` on every machine.

`character` is moved into the world at a spawn point and owned by this player.
`ui` only exists on this player's own machine.

[b]Your own player class:[/b] put a script that `extends Player` on the player scene's root.
It runs on the server and on every client (no suffix needed); its public variables are the
server's and replicate to everyone, with setters running on clients. RGD calls these if you
write them, so there's nothing to connect:
- `_server_ready()`: on the server, once the player has joined and has a character.
- `_local_ready()`: on this player's own machine, once.
- `_character_added(character)` / `_character_removing(character)`: on every machine, on
spawn and respawn.
- `_leaving()`: on every machine, when the player leaves.
```gdscript
# my_player.gd, on the player scene's root
extends Player

var coins := 0:                       # the server's value, replicated to everyone
    set(v):
        coins = v
        if is_local() and ui:
            ui.get_node("Coins").text = str(v)   # runs on this player's machine

func _server_ready() -> void:
    coins = 10                        # starting money, decided by the server

func _local_ready() -> void:
    ui.get_node("Welcome").text = "Hi " + display_name
```
The signals (`character_added`, ...) work from the Signals tab as well.

## Tutorials

- [Make a player scene](../guide.md#make-a-player-scene)
- [Players](../guide.md#7-players)

## Properties

| Type | Name | Default |
|---|---|---|
| Node | [character](#character) |  |
| Node | [ui](#ui) |  |
| Node | [replication_focus](#replication_focus) |  |
| int | [user_id](#user_id) | `0` |
| String | [display_name](#display_name) | `""` |
| Dictionary | [join_data](#join_data) | `{}` |

## Methods

| Returns | Method |
|---|---|
| bool | [is_local](#is_local)() |
| void | [respawn](#respawn)() |
| void | [kick](#kick)(reason: String = "kicked") |

## Signals

**character_added**(character: Node)

A character was assigned (spawn or respawn), on every machine. Also calls `_character_added(character)` if the script defines it.

**character_removing**(character: Node)

The current character is being replaced or removed.

## Property Descriptions

### character

`@export Node character`

The player's character (any physics body). Can be empty for games without an avatar.

### ui

`@export Node ui`

The player's UI (CanvasLayer or Control). Only exists on this player's own machine.

### replication_focus

`Node replication_focus`

Server, with streaming on (`rgd/streaming/radius`): the world streams in around this node instead of `character` (Roblox's `ReplicationFocus`). E.g. a camera or a vehicle.

```gdscript
# Stream the world around the car the player is driving.
player.replication_focus = car
```

### user_id

`int user_id = 0`

The player's peer id (1 for the host's own player).

### display_name

`String display_name = ""`

The name shown for this player (from `Game.join(address, {name = ...})`).

### join_data

`Dictionary join_data = {}`

Server: what the client sent with `Game.join(address, {data = {...}})`: an auth token, a platform id (Steam), a chosen skin... Plain data only. Never sent to other players.

## Method Descriptions

### is_local

`bool is_local()`

True on this player's own machine.

### respawn

`void respawn()`

Server: replaces the character with a fresh one from the player scene at a spawn point.

```gdscript
# kill_zone.gd (server): anyone who falls in starts over.
func _on_body_entered(body: Node3D) -> void:
    var player := Game.players.get_player_from_character(body)
    if player:
        player.respawn()
```

### kick

`void kick(reason: String = "kicked")`

Server: disconnects this player; they get session_ended(reason).

[Back to the API reference](../api.md)
