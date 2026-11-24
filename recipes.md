# RGD recipes

Complete, small features you can copy into your game. Each one shows the scene layout, the server code, the client code, and one line on *why it works*. They build on the [guide](guide.md). Read sections 1–7 first if the terms are new.

Conventions used below:
- **Level** = your world scene (the one you Play Test). Its plain scripts run on the **server**.
- **Player scene** = `rgd/player_scene`. Its plain scripts run on **that player's machine**.
- Per-player data lives on **your Player class**: a script that extends `Player` on the player scene's root. It runs on the server and every client, and its public variables are the server's, so any machine reads `player.coins` directly:

```gdscript
# my_player.gd: on the player scene's root (Player node)
extends Player

var coins := 0
var kills := 0
var team := ""
```

- Remotes are handled in a script **on the remote itself** (`extends RemoteEvent` with `_on_server_event` / `_on_client_event`), or connected in the editor's Signals tab. Nothing to connect in code.

**Contents:** [Coins](#1-coins-to-collect) · [Scoreboard](#2-scoreboard) · [Chat](#3-chat) · [Round timer](#4-round-timer) · [Health and respawn](#5-health-damage-and-respawn) · [Shooting](#6-shooting) · [Teams and colors](#7-teams-and-colors) · [Teleporter](#8-teleporter-pad) · [Private messages](#9-private-messages) · [Kickable ball](#10-a-ball-players-can-push)

---

## 1. Coins to collect

**Scene** `coin.tscn`:

```
Coin        (Area3D + coin.gd)
├── Shape   (CollisionShape3D)
└── Mesh    (MeshInstance3D + coin_spin.local.gd)
```

```gdscript
# coin.gd: runs on the server (it's in the level, or spawned by the server)
extends Area3D

func _ready() -> void:
	body_entered.connect(_on_body_entered)

func _on_body_entered(body: Node3D) -> void:
	if is_queued_for_deletion():
		return                                  # two players touched it in the same frame
	var player := Game.players.get_player_from_character(body)
	if player == null:
		return                                  # something else touched it
	player.coins += 1                           # my_player.gd: replicates to everyone
	queue_free()                                # disappears for everyone
```

```gdscript
# coin_spin.local.gd: runs on every client (only looks, never affects the game)
extends MeshInstance3D

func _process(delta: float) -> void:
	rotate_y(delta * 3.0)
```

Show the count in the player's UI: give `coins` a setter in `my_player.gd`. It runs on every machine when the server's value arrives; only your own machine has your UI:

```gdscript
# my_player.gd
var coins := 0:
	set(v):
		coins = v
		if is_local() and ui:
			ui.get_node("Coins").text = "Coins: %d" % v
```

*Why it works:* the pickup is decided on the server, so nobody can fake it. `coins` is a public variable of a script that runs everywhere, so it replicates and its setter runs on clients. Placed coins can sit in the level; to spawn them, the server calls `add_child` (guide section 8).

---

## 2. Scoreboard

Everyone's coins, on everyone's screen. Add a `Label` named `Board` to the player's UI:

```gdscript
# scoreboard.gd: on a Label inside the player's UI
extends Label

func _process(_delta: float) -> void:
	var lines: PackedStringArray = []
	for p in Game.players.get_players():
		lines.append("%s — %d" % [p.display_name, p.coins])   # my_player.gd
	text = "\n".join(lines)
```

*Why it works:* every player's `Player` node, with your script, exists on every machine, and `coins` arrives from the server. (Rebuilding a few lines each frame is fine. For big lobbies, refresh on a timer.)

---

## 3. Chat

**Level:** a RemoteEvent named `Message` with this script. It runs on both sides: the server half cleans and broadcasts, the client half shows the line.

```gdscript
# message.gd, on the Message RemoteEvent
extends RemoteEvent

func _on_server_event(player: Player, text) -> void:       # on the server
	text = str(text).strip_edges().left(200)                 # never trust what a client sends
	if text != "":
		fire_all_clients(player.display_name, text)

func _on_client_event(who: String, text: String) -> void:  # on every client
	var ui := Game.players.local_player.ui
	if ui and ui.is_node_ready():
		ui.get_node("ChatBox").add_line(who, text)
```

**Player UI:** a `ChatBox` with a `LineEdit` named `Input` and a `RichTextLabel` named `Log`:

```gdscript
# chat_box.gd: in the player's UI, runs on this player's machine
extends Control

func _ready() -> void:
	$Input.text_submitted.connect(_on_submit)

func _on_submit(text: String) -> void:
	get_tree().current_scene.get_node("Message").fire_server(text)
	$Input.clear()

func add_line(who: String, text: String) -> void:
	$Log.add_text("%s: %s\n" % [who, text])                # add_text: no BBCode tricks from players
```

*Why it works:* clients only ever *ask* (`fire_server`). The server cleans the text and sends it to everyone (`fire_all_clients`). The sender's name comes from the server, so nobody can pretend to be someone else.

Messages from *before* a player joined (or before their chat box opened) don't replay. [Sample 2](../samples/chat/README.md) adds history for late joiners, whispers, typing indicators and more, built the same way.

---

## 4. Round timer

**Level:** a `Node` named `Round` with `round.gd`.

```gdscript
# round.gd: runs on the server
extends Node

var phase := "waiting"     # "waiting", "playing", "over": replicates
var time_left := 0         # whole seconds: replicates once per second

var _clock := 0.0          # private (starts with _): stays on the server

func _process(delta: float) -> void:
	if phase == "waiting" and Game.players.get_players().size() >= 2:
		phase = "playing"
		_clock = 90.0
	elif phase == "playing":
		_clock -= delta
		time_left = ceili(_clock)
		if _clock <= 0.0:
			_end_round()

func _end_round() -> void:
	phase = "over"
	await get_tree().create_timer(5.0).timeout
	Game.change_scene("res://levels/arena.tscn")   # fresh level, everyone moves
```

**Player UI:**

```gdscript
# round_label.gd: a Label in the player's UI
extends Label

func _ready() -> void:
	var round_node := get_tree().current_scene.get_node("Round")
	Game.changed(round_node, &"time_left").connect(func(t): text = "%d:%02d" % [t / 60, t % 60])
	Game.changed(round_node, &"phase").connect(func(p): if p == "over": text = "Round over!")
```

*Why it works:* only the server counts. `time_left` is a whole number, so it changes (and gets sent) once a second, not every frame. Late joiners get the current values immediately.

---

## 5. Health, damage and respawn

**Player scene:** give the character a health node and a label above its head.

```
Player
└── Character
    ├── Health        (Node + health.server.gd)
    └── HealthLabel   (Label3D, text "100 HP", position above the head)
```

```gdscript
# health.server.gd: runs on the server
extends Node

var hp := 100

func take_damage(amount: int) -> void:
	if hp <= 0:
		return
	hp = maxi(hp - amount, 0)
	$"../HealthLabel".text = "%d HP" % hp          # Label3D.text replicates: everyone sees it
	if hp == 0:
		var player := Game.players.get_player_from_character(get_parent())
		player.respawn()                             # fresh character (and fresh 100 HP)
```

**A kill zone** in the level (an `Area3D` under the map):

```gdscript
# kill_zone.gd: runs on the server
extends Area3D

func _ready() -> void:
	body_entered.connect(func(body: Node3D):
		var player := Game.players.get_player_from_character(body)
		if player:
			player.respawn())
```

*Why it works:* health lives in a `.server.gd` script, so only the server can change it. The floating label needs no client code at all, because `Label3D.text` replicates on its own. For a health bar in the owner's UI, read `Game.get_value(me.character.get_node("Health"), &"hp")`. Reconnect on `me.character_added` after a respawn, since it's a new character.

---

## 6. Shooting

**Level:**

```
Combat      (Node + combat.gd)
└── Shoot   (RemoteEvent)
```

**Scene** `bullet.tscn`: an `Area3D` with `bullet.gd`, a small `CollisionShape3D` and a `MeshInstance3D`.

The client only says *"I want to shoot in this direction"*:

```gdscript
# in the character's controller (player scene: runs on this player's machine)
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("shoot"):
		var aim := -$Camera3D.global_basis.z
		get_tree().current_scene.get_node("Combat/Shoot").fire_server(aim)
```

The server decides whether a shot happens and where it starts:

```gdscript
# combat.gd: runs on the server
extends Node

const BULLET := preload("res://bullet.tscn")
const COOLDOWN := 0.25

var _last_shot := {}   # user_id -> time

# Connected in the editor: Shoot ▸ Node ▸ Signals ▸ on_server_event ▸ Combat ▸ _on_shoot.
func _on_shoot(player: Player, aim) -> void:
	if not aim is Vector3 or player.character == null:
		return
	var now := Time.get_ticks_msec() / 1000.0
	if now - _last_shot.get(player.user_id, -10.0) < COOLDOWN:
		return                                         # too fast: ignore
	_last_shot[player.user_id] = now
	var bullet := BULLET.instantiate()
	bullet.shooter = player
	bullet.direction = (aim as Vector3).normalized()
	bullet.position = player.character.global_position + Vector3.UP * 1.5 + bullet.direction
	get_tree().current_scene.add_child(bullet)        # appears for everyone
```

```gdscript
# bullet.gd: spawned by the server, so it runs on the server
extends Area3D

const SPEED := 40.0

var direction := Vector3.FORWARD
var shooter: Player
var _life := 2.0

func _ready() -> void:
	body_entered.connect(_on_hit)

func _physics_process(delta: float) -> void:
	position += direction * SPEED * delta              # movement replicates
	_life -= delta
	if _life <= 0.0:
		queue_free()

func _on_hit(body: Node3D) -> void:
	var victim := Game.players.get_player_from_character(body)
	if victim == shooter:
		return                                         # don't hit yourself
	if victim:
		body.get_node("Health").take_damage(25)        # from recipe 5
	queue_free()
```

*Why it works:* the client never says "I hit someone". It only asks to shoot. The server checks the cooldown, spawns the bullet from the character's real position, and decides hits itself.

**Instant (hitscan) weapons** don't need a bullet scene. Test the ray on the server, against what the shooter saw (other players are shown slightly in the past on every screen):

```gdscript
# combat.gd: the same _on_shoot, hitscan version
func _on_shoot(player: Player, aim) -> void:
	if not aim is Vector3 or player.character == null:
		return
	# ... cooldown check as above ...
	var origin: Vector3 = player.character.global_position + Vector3.UP * 1.5
	var q := PhysicsRayQueryParameters3D.create(origin, origin + (aim as Vector3).normalized() * 100.0)
	q.exclude = [player.character.get_rid()]
	var hit := Game.rewind_raycast(player, q)          # lag compensation
	var victim := Game.players.get_player_from_character(hit.get("collider"))
	if victim and victim != player:
		victim.character.get_node("Health").take_damage(25)
```

`Game.rewind_raycast` puts moving bodies where they were on the shooter's screen for this one test, so a shot that looked like a hit is a hit. The full version, with effects, headshots and a kill feed, is `samples/shooter/match.gd`.

---

## 7. Teams and colors

Make two materials, `res://materials/red.tres` and `res://materials/blue.tres`. Then add a `Node` with `teams.gd` to the level:

```gdscript
# teams.gd: runs on the server
extends Node

const COLORS := {"red": preload("res://materials/red.tres"), "blue": preload("res://materials/blue.tres")}

func _ready() -> void:
	Game.players.player_added.connect(_on_player_added)
	for p in Game.players.get_players():        # players already here (e.g. after change_scene)
		_on_player_added(p)

func _on_player_added(player: Player) -> void:
	player.team = "red" if _count("red") <= _count("blue") else "blue"   # my_player.gd
	player.character_added.connect(func(ch: Node): _paint(ch, player.team))   # after respawns
	if player.character:
		_paint(player.character, player.team)

func _paint(character: Node, team: String) -> void:
	character.get_node("Mesh").material_override = COLORS[team]

func _count(team: String) -> int:
	return Game.players.get_players().filter(func(p): return p.team == team).size()
```

*Why it works:* `material_override` replicates as a *reference to the file*, so each client loads its own copy of `red.tres`. Swapping between saved materials always works. (Changing a shader parameter doesn't replicate; see [Godot features](godot_features.md#shaders-and-materials).)

---

## 8. Teleporter pad

**Level:** an `Area3D` with a collision shape, `teleporter.gd`, and a `Marker3D` somewhere as the destination.

```gdscript
# teleporter.gd: runs on the server
extends Area3D

@export var destination: Marker3D

func _ready() -> void:
	body_entered.connect(func(body: Node3D):
		if Game.players.get_player_from_character(body):
			Game.teleport(body, destination.global_transform))
```

*Why it works:* a player moves their own character, so setting its position on the server wouldn't stick. `Game.teleport` moves it everywhere and tells its owner. (Characters are direct children of the level, so a global transform is what you want here.)

---

## 9. Private messages

Some messages are for one player only: "you found a secret", "not enough coins". **One RemoteEvent in the level is enough**, like a Roblox RemoteEvent in ReplicatedStorage: `fire_client(player, ...)` reaches only that player, and on the server `on_server_event` always tells you which player sent it.

```
Level
└── Notify   (RemoteEvent)
```

```gdscript
# server, anywhere: e.g. in a secret area's script
func _on_body_entered(body: Node3D) -> void:
	var player := Game.players.get_player_from_character(body)
	if player:
		get_tree().current_scene.get_node("Notify").fire_client(player, "You found the secret room!")
```

```gdscript
# notify.gd, on the Notify RemoteEvent: show it as a toast. Only that player's machine gets it.
extends RemoteEvent

func _on_client_event(text: String) -> void:
	var toast: Label = Game.players.local_player.ui.get_node("Toast")
	toast.text = text
	toast.show()
	await get_tree().create_timer(3.0).timeout
	toast.hide()
```

*Why it works:* a RemoteEvent is one node shared by everyone, but each call names its target: `fire_client(player, ...)` goes to one machine, `fire_all_clients(...)` to all, and a client's `fire_server(...)` arrives with the sender as the first argument.

**Optional: one remote per player.** You can also put the RemoteEvent in the player scene (`Player ▸ Notify`), so every player has their own. That's only about organization: it keeps per-player things together (`player.get_node("Notify")` on the server, `get_parent().get_node("Notify")` in the player's UI) and survives level changes, since players are kept across `Game.change_scene`. A level remote's own script (`notify.gd`) comes with each new level, so it needs nothing either.

---

## 10. A ball players can push

Normally the server simulates rigid bodies, so a player pushing a ball would see it react a little late. Hand the ball to whoever touches it, and it reacts instantly for them:

```
Ball     (RigidBody3D + ball.gd)
├── Shape
├── Mesh
└── Near (Area3D, a bit bigger than the ball)
    └── Shape
```

```gdscript
# ball.gd: runs on the server
extends RigidBody3D

func _ready() -> void:
	$Near.body_entered.connect(_on_near)

func _on_near(body: Node3D) -> void:
	var player := Game.players.get_player_from_character(body)
	if player and Game.get_network_owner(self) != player:
		Game.set_network_owner(self, player)      # that player simulates the ball now
```

*Why it works:* the network owner simulates the body and streams it to everyone. On every other machine (including the server) it follows along. Hand it back with `Game.set_network_owner(self, null)`. If cheating matters, check owner updates with `Game.ownership_validator` (guide section 9).
