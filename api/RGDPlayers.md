# RGDPlayers

**Inherits:** Node < Object

**Where you find it:** `Game.players` (one per machine). Script: `addons/rgd/runtime/players.gd`.

`Game.players`: every connected `Player`, on every machine (Roblox's `Players`).

## Description

`Game.players`: every connected `Player`, on every machine (Roblox's `Players`).

## Tutorials

- [Players](../guide.md#7-players)

## Properties

| Type | Name | Default |
|---|---|---|
| Player | [local_player](#local_player) |  |

## Methods

| Returns | Method |
|---|---|
| Array[Player] | [get_players](#get_players)() |
| Player | [get_by_id](#get_by_id)(user_id: int) |
| Player | [get_by_name](#get_by_name)(display_name: String) |
| Player | [get_player_from_character](#get_player_from_character)(node: Node) |

## Signals

**player_added**(player: Player)

A player joined (on every machine; on a late joiner, once per player already there).

```gdscript
# scoreboard.local.gd
func _ready() -> void:
    Game.players.player_added.connect(func(p: Player): _add_row(p.display_name))
```

**player_removing**(player: Player)

A player is leaving. Their Player node is still valid during the signal.

## Property Descriptions

### local_player

`Player local_player`

This machine's own player (null on a dedicated server).

## Method Descriptions

### get_players

`Array[Player] get_players()`

Every connected player, in join order.

### get_by_id

`Player get_by_id(user_id: int)`

The player with peer id `user_id`, or null.

### get_by_name

`Player get_by_name(display_name: String)`

The player whose `Player.display_name` is `display_name` (ignoring case), or null.

```gdscript
var target := Game.players.get_by_name("bob")   # finds "Bob"
```

### get_player_from_character

`Player get_player_from_character(node: Node)`

The player whose character is `node` or contains it (Roblox's `GetPlayerFromCharacter`), or null. Handy in collision callbacks, where you get the body or one of its parts:

```gdscript
func _on_body_entered(body: Node3D) -> void:
    var player := Game.players.get_player_from_character(body)
    if player:
        player.respawn()
```

[Back to the API reference](../api.md)
