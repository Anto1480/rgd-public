# Coin Run scripts

The scripts of the 2D platformer sample (`samples/2d platformer/scripts/`), documented like a class reference. They're game code, not part of RGD: use them as examples of how the pieces fit. See the sample's [README](../../samples/2d%20platformer/README.md) and the [Beginner's Guide](../beginners_guide.md), which builds the game step by step.

Contents: [level.gd](#levelgd), [platformer_player.gd](#platformer_playergd), [fx_event.gd](#fx_eventgd), [push_event.gd](#push_eventgd), [controller.gd](#controllergd), [touch_area.gd](#touch_areagd), [slime.gd](#slimegd), [platform.gd](#platformgd), [health.server.gd](#healthservergd), [hud.gd](#hudgd), [sfx.gd](#sfxgd), [menu.gd](#menugd), [rules.gd](#rulesgd)

## level.gd

**Inherits:** Node2D < CanvasItem < Node < Object · **Runs on:** the server (in single player: your machine)

The level's rules.

### Description

The level's rules. A plain script on the level's root, so it runs on the server: a
dedicated server, the host, or your own machine in single player (Game.play_solo), with
the same code every time. Coins, hits, stomps, springs, checkpoints and the finish all go
through here; the things in the level only report what touched them.

### Properties

| Type | Name | Default |
|---|---|---|
| String | [phase](#phase) | `"playing"` |
| float | [elapsed](#elapsed) | `0.0` |
| float | [results_left](#results_left) | `0.0` |

### Methods

| Returns | Method |
|---|---|
| void | [collect_coin](#collect_coin)(p: Player, coin: Node2D) |
| void | [hurt](#hurt)(p: Player, from: Vector2) |
| void | [spring](#spring)(p: Player, spring_node: Node2D) |
| void | [slime_touched](#slime_touched)(p: Player, slime: Node2D) |
| void | [checkpoint](#checkpoint)(p: Player, flag: Node2D) |
| void | [finish](#finish)(p: Player) |

### Property Descriptions

#### phase

`String phase = "playing"`

"playing", then "results" once everyone reached the flag. Public, so it replicates.

#### elapsed

`float elapsed = 0.0`

Seconds since the level started (tenths), for the HUD and finish times.

#### results_left

`float results_left = 0.0`

Seconds until the next run starts (during "results").

### Method Descriptions

#### collect_coin

`void collect_coin(p: Player, coin: Node2D)`

Server: `p` took `coin`: +1 coin, a sound for everyone, the coin disappears everywhere.

#### hurt

`void hurt(p: Player, from: Vector2)`

Server: costs `p` a heart (unless they're blinking from a recent hit) and knocks them away from `from`. Out of hearts: back to the checkpoint.

#### spring

`void spring(p: Player, spring_node: Node2D)`

Server: launches `p` upward (asks their machine with Push, since they own their character).

#### slime_touched

`void slime_touched(p: Player, slime: Node2D)`

A character touched a slime: from above while falling is a stomp, anything else hurts.

#### checkpoint

`void checkpoint(p: Player, flag: Node2D)`

Server: `p` reached `flag`; that's where they come back from now on.

#### finish

`void finish(p: Player)`

Server: `p` reached the goal. Records their time; when everyone has, shows the results and restarts the level.

## platformer_player.gd

**Inherits:** Player · **Runs on:** the server and every client (extends Player)

A Coin Run player: the player scene's root.

### Description

A Coin Run player: the player scene's root. Because it extends Player, this script runs on
the server and on every client, and its public variables are the server's: the HUD and the
results read `coins`, `finish_time`... directly on any machine.

### Properties

| Type | Name | Default |
|---|---|---|
| int | [skin](#skin) | `0` |
| float | [finish_time](#finish_time) | `-1.0` |

### Methods

| Returns | Method |
|---|---|
| void | [reset](#reset)() |

### Property Descriptions

#### skin

`int skin = 0`

Which color this player wears (an index into Rules.SKINS).

#### finish_time

`float finish_time = -1.0`

Seconds it took to reach the flag (-1 = not yet).

### Method Descriptions

#### reset

`void reset()`

Server: a new run (after a restart).

## fx_event.gd

**Inherits:** RemoteEvent · **Runs on:** both sides (extends RemoteEvent); `_on_client_event` on clients

The level's Fx remote: the server says what happened ("coin", "hurt", "stomp"...) and where, with fire_all_clients.

### Description

The level's Fx remote: the server says what happened ("coin", "hurt", "stomp"...) and where,
with fire_all_clients. Extending RemoteEvent, this script runs on every machine, and RGD calls
_on_client_event on each client: it plays the sound there. Nothing to connect.

## push_event.gd

**Inherits:** RemoteEvent · **Runs on:** both sides (extends RemoteEvent); `_on_client_event` on clients

The level's Push remote: the server asks one player's machine to move that player's own character (springs, stomps, knockback).

### Description

The level's Push remote: the server asks one player's machine to move that player's own
character (springs, stomps, knockback). Each player simulates their own character, so the
server can't move it directly. RGD calls _on_client_event on that player's machine.

## controller.gd

**Inherits:** CharacterBody2D < PhysicsBody2D < CollisionObject2D < Node2D < CanvasItem < Node < Object · **Runs on:** the player's own machine (player scene)

Running and jumping.

### Description

Running and jumping. It's in the player scene, so it runs only on this player's machine:
the character belongs to its player, so it moves instantly here and RGD sends the position
to everyone. The animation (Sprite's `animation`, `flip_h`) is played here too, and RGD
sends that as well (your machine drives your own character's AnimatedSprite2D).

←/→ or A/D run · Space/W/↑ jump (hold for higher) · Esc back to the menu

### Methods

| Returns | Method |
|---|---|
| void | [push](#push)(v: Vector2, absolute_y: bool) |

### Method Descriptions

#### push

`void push(v: Vector2, absolute_y: bool)`

The server asked us to move our own character (springs, stomps, hits), through the level's Push remote (push_event.gd). Only we can move it: it's ours.

## touch_area.gd

**Inherits:** Area2D < CollisionObject2D < Node2D < CanvasItem < Node < Object · **Runs on:** the server (in single player: your machine)

Coins, spikes, springs, checkpoints and the flag: a level node, so this runs on the server.

### Description

Coins, spikes, springs, checkpoints and the flag: a level node, so this runs on the
server. It tells the level which player touched it; the level decides what happens.

### Properties

| Type | Name | Default |
|---|---|---|
| Variant | [kind](#kind) | `Kind.COIN` |

### Constants

- **Kind** = `{ COIN, SPIKES, SPRING, CHECKPOINT, GOAL }`

### Property Descriptions

#### kind

`@export Variant kind = Kind.COIN`

What this area is: a coin, spikes, a spring, a checkpoint or the goal.

## slime.gd

**Inherits:** CharacterBody2D < PhysicsBody2D < CollisionObject2D < Node2D < CanvasItem < Node < Object · **Runs on:** the server (in single player: your machine)

A slime walking back and forth.

### Description

A slime walking back and forth. A level node: this runs on the server, and clients get its
position (transform stream) and animation (AnimatedSprite2D.animation replicates).

### Methods

| Returns | Method |
|---|---|
| void | [squash](#squash)() |

### Method Descriptions

#### squash

`void squash()`

Server: the slime was stomped. Flattens it, turns off its collisions, and removes it a second later (for everyone).

## platform.gd

**Inherits:** AnimatableBody2D < StaticBody2D < PhysicsBody2D < CollisionObject2D < Node2D < CanvasItem < Node < Object · **Runs on:** the server (in single player: your machine)

A platform moving back and forth, moved by the server.

### Description

A platform moving back and forth, moved by the server. Players riding it are moved by their
own machines (they simulate their characters) on top of its replicated copy.

### Properties

| Type | Name | Default |
|---|---|---|
| Vector2 | [travel](#travel) | `Vector2(384, 0)` |
| float | [period](#period) | `4.0` |

### Property Descriptions

#### travel

`@export Vector2 travel = Vector2(384, 0)`

How far the platform moves from its start (pixels).

#### period

`@export float period = 4.0`

Seconds for a full trip there and back.

## health.server.gd

**Inherits:** Node < Object · **Runs on:** the server (in single player: your machine)

Hearts.

### Description

Hearts. A .server.gd script: only the server changes them. `hearts` and `hurt_left` are
public, so every machine gets them (the HUD shows hearts, everyone sees the hit blink).

### Properties

| Type | Name | Default |
|---|---|---|
| float | [hurt_left](#hurt_left) | `0.0` |

### Methods

| Returns | Method |
|---|---|
| bool | [hurt](#hurt)() |
| void | [reset](#reset)() |

### Property Descriptions

#### hurt_left

`float hurt_left = 0.0`

Seconds of invulnerability left after a hit.

### Method Descriptions

#### hurt

`bool hurt()`

Returns true if the hit counted.

#### reset

`void reset()`

Back to full hearts, with a short blink of invulnerability.

## hud.gd

**Inherits:** CanvasLayer < Node < Object · **Runs on:** the player's own machine (player scene)

This player's screen: hearts, coins, time, and the results.

### Description

This player's screen: hearts, coins, time, and the results. The player scene's UI exists
only on its own player's machine. Built in code to keep the sample small.

### Methods

| Returns | Method |
|---|---|
| String | [results_text](#results_text)() |

### Method Descriptions

#### results_text

`String results_text()`

One line per player: name, coins, time.

## sfx.gd

**Inherits:** Node2D < CanvasItem < Node < Object · **Runs on:** every client (`local` group)

Sounds and little effects.

### Description

Sounds and little effects. This node is in the `local` group: it exists on every player's
machine and never on a dedicated server. The server says what happened through the Fx
remote, whose script (fx_event.gd) calls play_at here.

### Properties

| Type | Name | Default |
|---|---|---|
| Array[StringName] | [heard](#heard) | `[]` |

### Methods

| Returns | Method |
|---|---|
| void | [play_at](#play_at)(sound: StringName, at: Vector2) |

### Property Descriptions

#### heard

`Array[StringName] heard = []`

Everything heard, for tests.

### Method Descriptions

#### play_at

`void play_at(sound: StringName, at: Vector2)`

Plays `sound` at `at` on this machine (and records it in `heard`).

## menu.gd

**Inherits:** Control < CanvasItem < Node < Object · **Runs on:** each player (a menu, outside any session)

Start screen: single player, or multiplayer (host, join, or a dedicated server on this computer).

### Description

Start screen: single player, or multiplayer (host, join, or a dedicated server on this
computer). Single player is the same game: Game.play_solo runs the level with you as the
only player and nothing opened on the network.

## rules.gd

**Inherits:** RefCounted < Object · **Runs on:** both (not attached to a node)

Platformer rules shared by the server and the clients (not attached to a node).

### Description

Platformer rules shared by the server and the clients (not attached to a node).

### Methods

| Returns | Method |
|---|---|
| SpriteFrames | [skin_frames](#skin_frames)(index: int) static |
| float | [results_time](#results_time)() static |

### Constants

- **COYOTE_TIME** = `0.1` — Grace after leaving a ledge, and how early a jump press still counts before landing.
- **INVULNERABLE_TIME** = `1.2` — Seconds of blinking after a hit, during which nothing hurts.
- **KILL_Y** = `1200.0` — Below this y you fell out of the level.
- **RESULTS_TIME** = `6.0` — Seconds the results stay up before the level restarts.

### Method Descriptions

#### skin_frames

`static SpriteFrames skin_frames(index: int)`

The SpriteFrames of skin number `index` (wraps around the list).

#### results_time

`static float results_time()`

Seconds the results stay up (the tests shorten it with `platformer/results_time`).

[Back to the API reference](../api.md)
