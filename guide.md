# The RGD guide

> Brand new? The [Beginner's Guide](beginners_guide.md) builds a complete small game first; come back here for the details.

RGD (**Replicated Godot**) turns a normal Godot game into a multiplayer one. Its design is heavily inspired by Roblox's multiplayer architecture. This guide goes from zero to a working multiplayer game, one idea at a time. Every example is small enough to copy and paste.

- New to RGD? Read sections 1–6 in order (about 20 minutes).
- Want working features? See [Recipes](recipes.md): coins, chat, health, shooting, shops, timers and more.
- Looking up a method? See the [API reference](api.md).
- Coming from Roblox? See [RGD for Roblox developers](roblox_guide.md).
- Want a whole working game to read? See [Sample 1: Flying Lobby](../samples/flying_lobby/README.md) (names, hosting, flying cubes, health tags, server-decided damage) and [Sample 2: Chat](../samples/chat/README.md) (no characters at all, plus a list of limitations and workarounds).
- Wondering how autoloads, shaders or animations behave? See [Godot features in RGD](godot_features.md).

---

## 1. The idea in one minute

```
            ┌──────────── SERVER ────────────┐
            │  owns the world                │
            │  runs the game rules           │
            │  decides what's true           │
            └──────┬──────────────────▲──────┘
   copies of the   │                  │  "please do X"
   world, updated  │                  │  (RemoteEvent)
   automatically   ▼                  │
            ┌──────────── CLIENTS ───────────┐
            │  show the world                │
            │  read input, play effects, UI  │
            │  move their own character      │
            └────────────────────────────────┘
```

Three rules cover almost everything:

1. **The server owns the world.** Doors, scores, enemies and pickups live on the server. Clients get a copy that updates by itself.
2. **Clients ask, the server decides.** A client can't open a door by itself. It sends a message (a `RemoteEvent`), and the server checks it and opens the door. Everyone then sees it open.
3. **Your own character is yours.** Each player moves their own character on their own machine, so movement feels instant. RGD sends it to everyone else.

You don't build special scenes, containers or "network nodes". You make a normal Godot game, and RGD works out what goes where.

---

## 2. Setup (5 minutes)

### Install

1. Copy `addons/rgd/` into your project.
2. *Project ▸ Project Settings ▸ Plugins* ▸ enable **RGD**. This adds an autoload called `Game`: everything RGD does goes through it.

### Make a player scene

The **player scene** is the one thing RGD needs from you. It's what each player gets when they join: a character, their UI, and their personal scripts.

Right-click in the Scene dock ▸ **RGD ▸ New Player Scene (3D)** (or **(2D)**). You get `res://player/player.tscn`:

```
Player            (Player node: the root, one per player)
├── Character     (CharacterBody3D + player_controller.gd: walk with WASD)
│   ├── Mesh
│   ├── Shape
│   └── Camera3D
└── UI            (CanvasLayer + player_hud.gd: only on this player's screen)
```

The **2D** version (`player_2d.tscn`) is the same shape with a top-down `CharacterBody2D`: a `Body` drawing that turns toward where you walk, a `Shape` and a `Camera2D`. There's no separate Player2D/Player3D class: the `Player` root doesn't care what its character is, so switching a game between 2D and 3D is just pointing `rgd/player_scene` at the other scene.

It's also set as *Project Settings ▸ rgd ▸ player_scene*. Change anything you like; the only rule is that the root is a `Player` with its `character` and `ui` properties pointing at your nodes.

### Press Play Test

Open your level (any scene with a floor), then pick **Play Test ▸ Server + 2** in the toolbar and press **Play Test**.

Two windows open, each with its own player. Walk around in one and watch the other. The Output panel shows every process, prefixed `[Server]`, `[Client 1]`, `[Client 2]`.

That's a multiplayer game. Everything from here on is about making things *happen* in it.

---

## 3. Where does my script run?

This is the most important idea in RGD. A script runs on the server or on clients depending on **where it is** and **what it's called**.

### The default rules

| Your script is... | It runs on... | Example |
|---|---|---|
| on a node in your level | **the server** | `door.gd`, `enemy.gd`, `coin.gd` |
| inside the player scene | **that player's machine** | `controller.gd`, `hud.gd` |

So game rules (in the level) run on the server, and things a player controls or sees (in the player scene) run on their machine. Most of the time you don't think about it at all.

### Changing the default with a name

| File name | Runs on |
|---|---|
| `name.gd` | the default above |
| `name.server.gd` | the server only, wherever it is |
| `name.local.gd` | every client (in a level and in the player scene alike), never the server |
| `name.shared.gd` | both the server and clients |

A script that **extends `RemoteEvent`, `RemoteFunction` or `Player`** runs on the server **and** every client by default (no suffix needed), because both sides of a remote or a player belong together. Sections 5–7 show what that gives you. A suffix still wins: `buy.server.gd extends RemoteEvent` runs on the server only.

### Changing the default with a group

Right-click a node ▸ **RGD**:

| Group | What happens |
|---|---|
| **Local** (`local`) | The node only exists on clients. The server never sees it. Good for decoration, client-only effects, a local camera rig. |
| **Server only** (`server_only`) | The node never leaves the server. Good for spawn logic, secret triggers, AI helpers. |

### `.local.gd` or the `local` group?

Both make code run on every client. The difference is the **node**:

- A **`.local.gd` script** is about the *code*. The node is still a normal, replicated node: it exists on the server too (with the script removed), and its built-in values (`visible`, its mesh, ...) come from the server. Use it for a script that reacts to things: an effect, a look that follows a replicated value. In the player scene it's how you say "every player's machine runs this for my character" (a plain script there runs only on that player's machine).
- The **`local` group** is about the *node*. The node (and its children) exists only on clients: it's never replicated, it's not on a dedicated server at all, and each client can change it freely. Use it for things that are purely this machine's business: a camera rig, a shield bubble whose `visible` each client sets itself, decoration, client-side particles.

Rule of thumb: start with `.local.gd`. Mark the node `local` when the client needs to *change the node itself* (show/hide it, move it), or when the server shouldn't have it at all.

Script icons in the editor are tinted **blue** (clients: local), **green** (server) or **teal** (both), so you can see this at a glance.

### Quick check

> *"I want an enemy that chases players."* The rules are in a level script, `enemy.gd`, so it runs on the server. Its position replicates to everyone.
>
> *"I want a health bar on my screen."* That's UI in the player scene, `hud.gd`, so it runs on my machine.
>
> *"I want sparks when the door opens."* That's a visual, so use `sparks.local.gd` on a child of the door. It runs on every client.
>
> *"I want the save system to only run on the server."* Use `save.server.gd`.

---

## 4. Replicated values: sharing state

**Every public variable in a script replicates automatically.** Change it on the server, and every client gets the new value.

```gdscript
# door.gd, on a door in your level: runs on the server
extends Node3D

var is_open := false        # public: every client gets this value
var _secret_code := 1234    # starts with _: stays on the server, nobody else sees it
```

The `_` prefix is GDScript's usual "private" marker, and RGD uses it the same way. **Anything starting with `_` never leaves the server.** Use it for answers, cooldowns and anything a cheater shouldn't see.

Supported types: numbers, bools, strings, vectors, colors, transforms, arrays and dictionaries of those, nodes, and resources loaded from files (`.tres`, `.png`, ...). Built-in properties replicate too: positions and rotations, `visible`, `Label3D.text`, `material_override` and more.

### Reading a value on a client

`door.gd` runs only on the server, so on a client the door has no script and no `is_open` variable. Ask RGD for the value instead:

```gdscript
var open: bool = Game.get_value(door, &"is_open", false)   # false = default if not arrived yet
```

### Reacting when a value changes

Usually you want to *do something* when a value changes, like playing an animation or updating a label. Connect to `Game.changed`:

```gdscript
# door_sound.local.gd, on a child of the door: runs on every client
extends AudioStreamPlayer3D

func _ready() -> void:
	Game.changed(get_parent(), &"is_open").connect(_on_is_open_changed)

func _on_is_open_changed(open: bool) -> void:
	play()   # creak!
```

**Pattern to remember:** the server changes a variable, and a `.local.gd` script reacts with `Game.changed`.

### One script for both sides

If you'd rather keep everything in one file, use `.shared.gd`. Then clients have the variable too, so **setters run on clients** when the value arrives:

```gdscript
# lamp.shared.gd: runs on server and clients
extends OmniLight3D

var on := true:
	set(value):
		on = value
		visible = value            # runs everywhere
		if Game.is_client():
			$Click.play()          # sound only where there's someone to hear it
```

Use `Game.is_server()` / `Game.is_client()` inside shared scripts to split the work. On a host (a player who is also the server), both are true.

### Clients can't change the world

If a client changes a replicated value (say, hides a node, or sets a variable of a `.shared.gd` script), only *its own copy* changes. Nobody else sees it, and the next time the server changes that value it's overwritten. Debug builds print a warning when this happens (not for things clients usually change on purpose for looks: `material_override`, `modulate`, light color/energy, animation playback). To change something, the client has to **ask the server**, which is the next section.

### Your own player scene: you author it

There's one exception, for your own player scene. Scripts in it run on your machine (section 3), and what they own goes out to everyone:

- **Public variables of your client scripts** (`controller.gd`; also `*.local.gd` in the player scene, whose copies on other machines then get your values and run their setters) replicate from you to the server and to everyone else. Others read them with `Game.get_value(node, &"name")` / `Game.changed(node, &"name")`. The server reads them the same way.
- **Your `AnimationPlayer`s** (`current_animation`, `speed_scale`): play an animation on your own character and everyone sees it, like Roblox's Animator.
- **Transforms of nodes inside your character** that you move: turn a `Model` child toward where you walk, tilt a head, and everyone sees it. Cameras, spring arms and `top_level` nodes (camera rigs) are left out, so your camera stays yours. Bone attachments follow each machine's own skeleton.

```gdscript
# controller.gd (player scene: runs on this player's machine)
var aim_pitch := 0.0     # everyone else gets it

func _physics_process(_delta):
	$Model/AnimationPlayer.play("walk" if velocity.length() > 0.1 else "idle")   # everyone sees it
```

```gdscript
# aim.gd: a node in the `local` group inside the character (every machine)
func _process(_delta):
	var pitch: float = Game.get_value(owner_character, &"aim_pitch", 0.0)
```

These are *looks and intent*, decided by a client. Don't base damage or scores on them without checking; `Game.owner_value_validator` can reject values on the server.

---

## 5. RemoteEvents: clients ask, server decides

A `RemoteEvent` is a node that carries a message between a client and the server. Add one anywhere (in your level or the player scene) like any other node: *Add Child Node ▸ RemoteEvent*.

Let's make a door that opens when a player presses E.

**Scene setup** (in your level):

```
Door        (Node3D + door.gd)
├── Panel   (MeshInstance3D)
└── Use     (RemoteEvent)
```

**The server listens.** Select `Use` ▸ *Node* dock ▸ *Signals* ▸ double-click `on_server_event` ▸ pick `Door` ▸ name the method `_on_use` ▸ *Connect*. Godot adds it to the door's script:

```gdscript
# door.gd: on a level node, so it runs on the server
extends Node3D

var is_open := false

func _on_use(player: Player) -> void:      # connected in the editor: no code to connect
	is_open = not is_open      # everyone sees the new value automatically
```

The first argument is always the **player who sent it**. RGD fills that in, and a client can't fake it.

**The client sends.** In the player's controller (player scene, so it runs on that player's machine):

```gdscript
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("use"):   # an action you add in Project Settings ▸ Input Map
		var door := get_tree().current_scene.get_node("Door")
		door.get_node("Use").fire_server()
```

**Everyone sees it.** Use a `.local.gd` child to animate, like in section 4.

### Three ways to handle an event

**1. Extend `RemoteEvent` (no boilerplate).** Put a script on the RemoteEvent node itself. It runs on both sides, and RGD calls these methods if you write them:

```gdscript
# open_door.gd, on the OpenDoor RemoteEvent node
extends RemoteEvent

func _on_server_event(player: Player) -> void:          # on the server
	var door := get_parent()
	if player.character.global_position.distance_to(door.global_position) < 3.0:
		door.is_open = not door.is_open

func _on_client_event(message: String) -> void:        # on the machine the server fired to
	print(message)
```

The client side just calls `$OpenDoor.fire_server()`. Nothing to connect, nothing to remember.

**2. The Signals tab.** Select the RemoteEvent ▸ *Node* dock ▸ *Signals* ▸ double-click `on_server_event` ▸ connect it to a node whose script runs on the server (your level script). Godot generates `func _on_open_door_on_server_event(player: Player)`; add your own arguments after `player`. Connect `on_client_event` to a client script (a `.local.gd`, or something in the player scene) the same way. Connections to a script that doesn't run on a machine are quietly removed there, so a server handler never errors on clients.

**3. In code**: `$OpenDoor.on_server_event.connect(_on_open)` in any server script. Handy when one script handles several remotes, or for remotes you create at runtime.

### Sending data

Pass any arguments you like. The server's handler receives them after `player`:

```gdscript
# client
$Chat.fire_server("hello everyone")
```

```gdscript
# chat.gd, on the Chat RemoteEvent (it runs on both sides; this method on the server)
extends RemoteEvent

func _on_server_event(player: Player, text: String) -> void:
	print(player.display_name, " says ", text)
```

### Server → clients

| Call (on the server) | Who gets it | The client handles it in |
|---|---|---|
| `remote.fire_client(player, args...)` | one player | `_on_client_event(args...)` (or the `on_client_event` signal) |
| `remote.fire_all_clients(args...)` | everyone | `_on_client_event(args...)` (or the `on_client_event` signal) |

```gdscript
# server
$Announce.fire_all_clients("Round starts in 10 seconds!")
```

```gdscript
# announce.gd, on the Announce RemoteEvent: on each client, show it on my screen
extends RemoteEvent

func _on_client_event(text: String) -> void:
	Game.players.local_player.ui.show_banner(text)
```

A remote in the level belongs to the level, and a remote's own script comes with it, so it keeps working after `Game.change_scene` with nothing to reconnect.

**When to use what:** for **state** (door open, score, time left), use a replicated variable. Late joiners get it too. For **moments** (an explosion, a chat line, "you got hit"), use a RemoteEvent.

### Events wait for a listener

If an event arrives while nothing handles it (no `_on_client_event` / `_on_server_event` in the remote's script and nothing connected to its signal), it waits in a queue. It's delivered the moment something connects, like in Roblox. This matters most when a player joins: their machine receives the world first and their own player scene a moment later. So a welcome `fire_client` sent from `player_added` would otherwise reach Bob before his UI exists. Now his UI still gets it when its `_ready` connects. (Up to 64 events wait per remote; debug builds warn if more pile up with nobody listening.)

A queue can't deliver what was sent *before* the player joined, though. For a backlog (chat history, a kill feed), **let the UI ask when it's ready**:

```gdscript
# say.gd, on the Say RemoteEvent: new messages go to my chat window once it's open
extends RemoteEvent

func _on_client_event(message: Dictionary) -> void:
	var ui := Game.players.local_player.ui
	if ui and ui.is_node_ready():
		ui.show_entry(message)
```

```gdscript
# chat window (player scene UI): when it opens, ask for what it missed
func _ready() -> void:
	for message in await room.get_node("History").invoke_server():
		show_entry(message)
```

Give each message an id and skip ids you've already shown. A message that arrives both queued and in the history then shows once, not twice. For plain *state*, use a replicated variable instead: late joiners always get those. [Sample 2](../samples/chat/README.md) does exactly this.

### Never trust the client

Anyone can modify their game. Treat every `fire_server` as a *request*, and check it:

```gdscript
func _on_use(player: Player) -> void:
	var ch := player.character as Node3D
	if ch == null or ch.global_position.distance_to(global_position) > 3.0:
		return                      # too far away: ignore
	is_open = not is_open
```

Check distances, cooldowns, money and permissions on the server. Every remote also has a `rate_limit` (default 60 calls per second per player) so nobody can flood your server. It's a flood guard: calls over it are dropped, with a warning in the server's log and, in debug builds, on the sending machine too. Players of a release build aren't told. For a friendly limit ("slow down!"), check timing in your handler and answer with `fire_client`.

**RGD checks the shape of what arrives.** Before your code sees anything a client sent, the server makes sure it's well formed. Values can't be absurdly nested or have lengths that don't fit. Text must be valid. Positions must be real numbers (no NaN or infinity). Handlers that declare parameter types only get calls that fit them: `func _on_buy(player: Player, item_id: int)` never receives a String. A call that doesn't fit is dropped with a warning in the server's log. Warnings are rate-limited, so a hacked client can't flood the log. A client that keeps sending malformed data is kicked with "sent invalid data". Lambdas don't tell Godot their parameter types, so for remotes that clients call, prefer named methods (or leave a lambda's parameters untyped and check them yourself). The *values* are still yours to check: a well-formed "buy 1,000,000 swords" is still a cheat.

**Positions are current when a remote arrives.** A player's own character moves on a fast, unreliable stream, while remotes travel on the reliable channel. So RGD sends the player's latest position *just ahead of* each remote they send. In your handler, `player.character.global_position` is where they were when they called it, so check it directly; don't trust a position they send you. [Sample 1](../samples/flying_lobby/README.md) checks wall bounces this way.

---

## 6. RemoteFunctions: ask and wait for an answer

A `RemoteFunction` is like a RemoteEvent, but the caller **waits for a reply**. Use it when the client needs an answer, as in "did my purchase work?"

```gdscript
# buy.gd, on the Buy RemoteFunction in your level (the answer is computed on the server)
extends RemoteFunction

const PRICES := {"sword": 50, "shield": 30}

func _on_server_invoke(player: Player, item: String) -> bool:
	if not PRICES.has(item) or player.coins < PRICES[item]:   # coins: see "Your own Player class"
		return false
	player.coins -= PRICES[item]
	return true
```

```gdscript
# shop_ui.gd: in the player's UI, runs on their machine
func _on_buy_sword_pressed() -> void:
	var ok: bool = await get_tree().current_scene.get_node("Buy").invoke_server("sword")
	$Message.text = "Bought!" if ok else "Not enough coins"
```

Don't forget the `await`. The server's handler may `await` too, for example to wait for a database. By default the caller waits until the answer comes, like Roblox. Set the node's `timeout` (seconds) to give up, in which case the call returns `null`. If the other side hasn't set its handler yet (a UI still loading), the call waits up to 10 seconds for it.

A call always finishes, so code after the `await` always runs. When no answer can come, it returns `null`: the player you asked left, you left the session, or the level changed and took the RemoteFunction with it. (In Roblox, `InvokeClient` to a player who leaves can hang the server script; here it returns `null`.)

**Extend it:** a script that `extends RemoteFunction` runs on both sides; write `_on_server_invoke(player, ...)` and return the answer. RGD uses it when `on_server_invoke` isn't set:

```gdscript
# get_price.gd, on the GetPrice RemoteFunction node
extends RemoteFunction

const PRICES := {"sword": 50, "shield": 30}

func _on_server_invoke(player: Player, item: String) -> int:
	return PRICES.get(item, 0)
```

---

## 7. Players

`Game.players` holds a `Player` node for everyone in the game, on every machine.

```gdscript
Game.players.get_players()          # everyone
Game.players.local_player           # me (null on a dedicated server)
Game.players.get_by_id(id)          # by peer id
Game.players.get_by_name("bob")     # by display name, ignoring case
Game.players.get_player_from_character(body)   # who does this body belong to?

Game.players.player_added.connect(func(p: Player): print(p.display_name, " joined"))
Game.players.player_removing.connect(func(p: Player): print(p.display_name, " left"))
```

Each `Player` has:

| | |
|---|---|
| `display_name` | the name they joined with, made unique on join (a second "Bob" becomes "Bob2"; turn off with *rgd ▸ players ▸ unique_names*). The server can change it (`player.display_name = "Robert"`) and everyone sees the change. The `Player` node's *name* doesn't follow, so identify players by `user_id` or the `Player` object. |
| `user_id` | their peer id (1 is the host's own player) |
| `character` | their character in the world (moved there at a spawn point) |
| `ui` | their UI (exists only on their own machine) |
| `respawn()` | server: give them a fresh character at a spawn point |
| `kick(reason)` | server: remove them from the game |

**Spawn points:** add any `Marker3D` (or `Marker2D`) to the group `spawn_point`. Characters spawn at them in turn.

### Your own Player class

Put a script that **`extends Player`** on the player scene's root. It runs on the server and every client, its public variables are the server's (they replicate, and setters run on clients), and RGD calls these if you write them:

| Method | Called on | When |
|---|---|---|
| `_server_ready()` | the server | the player joined and has a character |
| `_local_ready()` | this player's machine | once, when their game is ready |
| `_character_added(character)` | every machine | spawn and respawn |
| `_character_removing(character)` | every machine | before a character is replaced or removed |
| `_leaving()` | every machine | the player leaves |

```gdscript
# my_player.gd, on the player scene's root
extends Player

var coins := 0:
	set(v):
		coins = v
		if is_local():
			ui.get_node("Coins").text = "Coins: %d" % v    # only my own screen

func _server_ready() -> void:
	coins = 10                                             # the server decides

func _character_added(character: Node) -> void:
	character.get_node("NameTag").text = display_name
```

From any server script: `player.coins += 1`, and everyone sees it. The `character_added` / `character_removing` signals work from the Signals tab too.

### Per-player data (coins, kills, team)

Put it on your Player class (above): public variables of an `extends Player` script are the server's and every machine has them.

```gdscript
# my_player.gd, on the player scene's root
extends Player

var coins := 0
var kills := 0
var team := ""
```

The server changes them directly (`player.coins += 1`), and any machine reads them directly (`player.coins`), which is handy for scoreboards:

```gdscript
for p in Game.players.get_players():
	print(p.display_name, ": ", p.coins)
```

*Alternative:* a child node with a `.server.gd` script (`Player ▸ Stats`) works too. Its script exists only on the server, so clients read its values with `Game.get_value(player.get_node("Stats"), &"coins", 0)`. Use it when a script should stay off clients entirely.

---

## 8. Spawning things

**On the server, `add_child` is all you need.** Anything you add under the level appears on every client, and anything you free disappears everywhere.

```gdscript
# spawner.gd: in the level, runs on the server
extends Node3D

const COIN := preload("res://coin.tscn")

func spawn_coin(at: Vector3) -> void:
	var coin := COIN.instantiate()
	coin.position = at
	get_tree().current_scene.add_child(coin)    # appears for everyone

# later: coin.queue_free()   → disappears for everyone
```

The spawned scene's scripts follow the same rules as section 3. `coin.gd` runs on the server, and a `coin_spin.local.gd` inside it runs on clients.

To hide something from clients temporarily, move it into a `server_only` node. It disappears for clients and comes back when you move it out. Adding the node itself to the `server_only` group works too; after removing it from the group, call `Game.mark_dirty(node)` to bring it back.

---

## 9. Movement and physics

- **Characters** are moved by their owner (the player), so they feel instant. RGD streams the position to the server and everyone else, and smooths it out.
- **Everything else** is moved by the server: platforms, enemies, rolling boulders. Clients see a smooth copy.
- **Rigid bodies** are simulated by the server. On clients they just follow.
- **Animations** you play on your own character are seen by everyone (section 4). Animations the server plays (an enemy, a door) replicate too.

### Hitting moving targets (lag compensation)

Each player sees everyone else about 100 ms in the past (that's what makes movement smooth). If the server tests a shot against where targets are *now*, a player who aims perfectly at someone running sideways misses. In the shooter sample, a strafing player was hit by 7 of 31 well-aimed shots.

Test the shot against what the shooter saw instead:

```gdscript
# combat.gd (server)
func _on_shoot(player: Player, origin: Vector3, dir: Vector3) -> void:
	var q := PhysicsRayQueryParameters3D.create(origin, origin + dir * 100.0)
	q.exclude = [player.character.get_rid()]
	var hit := Game.rewind_raycast(player, q)   # 31 of 31 in the same test
```

Every remote a client sends carries the moment it was looking at; the server keeps a short history of moving bodies (`rgd/network/max_rewind`, 0.5 s by default) and tests the ray against each one where it was then. Static things are tested where they are. For the host's own player it's a plain raycast.

### Teleporting

Moving a character from the server needs `Game.teleport`, because the player owns their character:

```gdscript
Game.teleport(player.character, $Destination.global_transform)
```

### Giving a player control of an object

Want a player to push a ball without lag? Make them the **network owner**:

```gdscript
Game.set_network_owner($Ball, player)   # that player simulates the ball now
Game.set_network_owner($Ball, null)     # back to the server
```

### Stopping speed hacks

Owners send their own positions, so check them on the server if it matters:

```gdscript
# in any server script, e.g. a game manager's _ready()
Game.ownership_validator = func(player: Player, node: Node, state: Dictionary) -> bool:
	return node.global_position.distance_to(state.transform.origin) < 3.0   # max 3 m per tick
```

Return `false` to ignore that update.

---

## 10. Menus, hosting and joining

Play Test starts sessions for you. For a real game, add a menu, which is an ordinary scene (the "dedicated server" button is optional):

```gdscript
# main_menu.gd
extends Control

func _ready() -> void:
	Game.join_failed.connect(func(reason): $Status.text = "Couldn't join: " + reason)
	if Game.last_end_reason != "":   # back here after a game: "the host left", a kick...
		$Status.text = "Session ended: " + Game.last_end_reason

func _on_host_pressed() -> void:
	if Game.host(7777, "res://levels/arena.tscn", {name = $Name.text}) != OK:
		$Status.text = "Couldn't host: " + Game.last_error   # e.g. the port is in use

func _on_join_pressed() -> void:
	Game.join($Address.text, {name = $Name.text})   # "192.168.1.20" or "myserver.com:7777"
```

A join that fails leaves you on the menu, and `join_failed(reason)` says why: nobody answered, the server is full, a typo in the address. Pressing Host or Join again while a join is still trying cancels it, so players can change their mind.

To run a **dedicated server on this computer** from a menu (a separate headless process, like a server build):

```gdscript
func _on_dedicated_pressed() -> void:
	if Game.start_local_server(7777, "res://levels/arena.tscn") > 0:
		Game.join("127.0.0.1:7777", {name = $Name.text})   # waits until the server is up
	else:
		$Status.text = "Couldn't start a server: " + Game.last_error
```

The join connects as soon as the server is listening. In debug builds, what the server prints appears in your game's output as `[Local server] ...`. The server stops when you leave it, when your game quits (or crashes: within 3 seconds), when you host on its port, or with `Game.stop_local_server()`.

**Ports.** Pass `0` to use *Project Settings ▸ rgd ▸ network ▸ port* (7777); the `RGD_PORT` environment variable overrides it, and `Game.default_port()` returns the result. Only one game on a computer can host on a port: a second copy that presses Host gets an error, and `Game.last_error` tells the player to join instead. `Game.port_free(port)` checks first.

| Call | What it does |
|---|---|
| `Game.host(port, level, {name})` | You play **and** you're the server (a listen server). |
| `Game.start_server(port, level)` | A dedicated server with no player of its own. |
| `Game.start_local_server(port, level)` | A dedicated server in a separate process on this computer; join it at `127.0.0.1`. |
| `Game.join(address, {name})` | Join someone's game. |
| `Game.leave()` | Leave. If the host leaves, everyone gets "the host left". |
| `Game.change_scene(level)` | Server: move everyone to another level. Players and characters are kept. |

React to the session with signals: `Game.session_started`, `Game.session_ended(reason)` (left, kicked, host left) and `Game.scene_changed(path)`. Set *Project Settings ▸ rgd ▸ menu_scene* to go back to your menu automatically when a session ends.

Inside a session, `get_tree().current_scene` is the level on every machine.

**Several games in one project?** A level can pick its own player scene and menu with metadata on its root node (*Inspector ▸ Metadata ▸ Add*): `rgd_player_scene` and `rgd_menu_scene` (paths). They override the project settings while that level is loaded. The samples in `samples/` work this way.

---

## 11. Big worlds

By default every client gets everything. For big maps, turn on **streaming** in *Project Settings ▸ rgd ▸ streaming ▸ radius*, e.g. `200`. Each client then only receives the things near its character.

- "Things" are the top-level nodes of your level. Each one streams in and out as a whole, with its children.
- Large objects (a floor, terrain) count as near when any part of them is.
- Right-click ▸ **RGD ▸ Persistent** keeps a node on every client always (a skybox, a scoreboard, the goal flag).
- `player.replication_focus = some_node` (server) streams around something else, like a vehicle or a spectator camera.

There's also *rgd ▸ network ▸ bandwidth_limit_kb*: a per-player cap on movement updates. Nearby things update more often than far ones.

---

## 12. Testing and debugging

- **Play Test ▸ Server + N** is the best everyday test. **Host + N** makes the first window the host. Test in server mode regularly: on a host, the host sees the real world, so client-side mistakes can hide.
- Press **F9** in any game window (debug builds) for the network overlay: bytes per second, ping, the chattiest nodes and properties, and the server's tick time.
- Read the warnings. RGD tells you when:
  - a client changes a replicated value (it won't stick, so use a RemoteEvent)
  - a variable holds something that can't be sent (it arrives as `null`)
  - a remote handler has the wrong number of parameters
  - a player hits a remote's rate limit
- `Game.get_net_stats()` returns the overlay's numbers as a Dictionary.

---

## 13. Exporting and deploying

In *Project ▸ Export*, each preset gets an **RGD** section:

- **Client builds:** set *Role ▸ Client* and list your levels under *World Scenes*. Then run *Project ▸ Tools ▸ RGD: Update Client Export Filters*. Server-only scripts and `server_only` nodes are left out of the build, so players can't read your server code.
- **Dedicated server builds:** set *Role ▸ Server* and *Export Mode ▸ Export as dedicated server*. The build **starts a server by itself**: RGD sets `application/run/main_scene.dedicated_server` to its boot scene (a feature override only server builds see), so your menu never loads there. It loads the level in *Project Settings ▸ rgd ▸ server_scene* on port 7777.

### Running a server somewhere else

A dedicated build is an ordinary headless program, so it runs on a VPS, in Docker, or on a game-server host. Configure it with the command line or the environment (hosts usually prefer the environment):

| Setting | Command line | Environment |
|---|---|---|
| port | `-- --rgd-port=7000` (or `--rgd-address=:7000`) | `RGD_PORT=7000` |
| level | `-- --rgd-scene=res://levels/arena.tscn` | `RGD_SCENE=res://levels/arena.tscn` |
| stats in the log | `-- --rgd-netstats=10` | |

```
RGD_PORT=7000 ./server.x86_64 --headless
```

- It binds every network interface. Open the port in the firewall: UDP for ENet, TCP for WebSocket.
- **Stopping:** closing the window or calling `Game.leave()` tells every client "the server shut down". A plain `kill` / SIGTERM (what `docker stop` sends) ends the process at once, and Godot gives scripts no way to catch it. Clients then notice within *rgd ▸ network ▸ timeout* (8 s by default). For a clean stop, have the server call `Game.leave()` first, e.g. from an admin RemoteEvent or a `--shutdown-at` timer of your own.
- **Players turned away before they join:** `Game.join_validator` (below) can check a token from your backend.

### Transports: ENet, WebSocket, Steam, anything

RGD only needs a Godot `MultiplayerPeer`. *rgd ▸ network ▸ transport* picks what `Game.host` / `start_server` / `join` use:
- **`enet`** (default): UDP, the best choice for desktop games.
- **`websocket`**: TCP. Use it for **web exports** (browsers can't do UDP) and for hosts or proxies that only pass TCP. `Game.join("example.com:7000")` connects to `ws://example.com:7000`. For `wss://`, set up the peer yourself (below).

Anything else, such as **Steam** (GodotSteam's `SteamMultiplayerPeer`), WebRTC, or a relay service, is a peer you create and hand to RGD:

```gdscript
# Steam (GodotSteam) — lobby owner hosts, friends join through Steam's relay
func host_on_steam() -> void:
	var peer := SteamMultiplayerPeer.new()
	peer.create_host(0)
	Game.host_with_peer(peer, "res://levels/arena.tscn", {name = Steam.getPersonaName()})

func join_on_steam(owner_steam_id: int) -> void:
	var peer := SteamMultiplayerPeer.new()
	peer.create_client(owner_steam_id, 0)
	var ticket: Dictionary = Steam.getAuthSessionTicket()
	Game.join_with_peer(peer, {name = Steam.getPersonaName(),
		data = {steam_id = Steam.getSteamID(), ticket = ticket.buffer}})
```

`Game.start_server_with_peer(peer, level)` does the same for a dedicated server (e.g. a GodotSteam game server). Everything else (replication, remotes, ping via `Game.get_ping`, kicks, shutdown reasons) works the same on every transport. The integration tests run the same game over ENet and WebSocket.

### Checking who joins

`Game.join(address, {name = ..., data = {...}})` sends plain `data` along. On the server, `Game.join_validator` decides, and may `await` (a backend call, a Steam auth check). The data stays available as `player.join_data`, on the server only.

```gdscript
# server
Game.join_validator = func(peer: int, name: String, data: Dictionary) -> String:
	if not await Backend.verify(data.get("token", "")):
		return "please sign in again"      # the client gets join_failed("please sign in again")
	return ""                               # welcome
```

---

## 14. Escape hatches

RGD's defaults cover most games, and none of them lock you in. When you need lower-level control:

| You want | Use |
|---|---|
| To send your own data, your own format, reliable or not | `Game.send_message(peer, data, reliable)` and the `Game.message_received(from_peer, data)` signal. Clients send to `1`; the server sends to a peer, or `0` for everyone. |
| Godot's own RPCs | `@rpc` functions work as usual on nodes that have the same path on every machine (your level's nodes, players). RGD uses Godot's `SceneMultiplayer`, so `rpc()`, `rpc_id()` and `multiplayer.get_remote_sender_id()` are all there. |
| A node RGD shouldn't sync on its own | `Game.set_auto_sync(node, false)`, then `Game.sync(node)` (or `Game.sync(node, [&"hp"])`) whenever *you* decide. It still spawns and despawns everywhere. |
| One variable kept out of replication | Name it `_like_this`, or list it in `const RGD_NO_REPLICATE := ["name"]`. |
| A node that never replicates | The `local` (clients only) or `server_only` group. |
| A built-in property RGD doesn't send | `Game.register_profile(&"Class", [&"property"])` on every machine. |
| Your own transport, matchmaking, relay | `Game.host_with_peer` / `start_server_with_peer` / `join_with_peer` with any `MultiplayerPeer`. |
| The raw numbers | `Game.get_net_stats()`, `Game.get_ping(player)`. |

```gdscript
# Custom input streaming: the client sends its input 30 times a second, unreliable.
func _physics_process(_delta):
	Game.send_message(1, {move = _input, jump = _jump}, false)

# server
func _ready():
	Game.message_received.connect(func(from_peer: int, data):
		if data is Dictionary:
			_inputs[from_peer] = data)    # check what you receive: there's no rate limit
```

---

## 15. Common mistakes

| Symptom | Cause and fix |
|---|---|
| A client changes something but nobody else sees it | Clients can't change the world. Send a RemoteEvent and change it on the server. |
| My door script's `print` never shows in a client window | That's expected: a level script runs on the server. Check the `[Server]` output. |
| `get_value` returns null on a client | The value hasn't arrived yet (pass a default), or the variable starts with `_`. |
| A variable arrives as `null` | It holds a resource created in code or a non-Node object. Replicate plain data instead (see [Godot features](godot_features.md)). |
| My UI shows up for other players / is missing | Put UI under the player scene's `UI` node. It only exists on its owner's machine. |
| Input code runs but nothing happens | Input runs on clients. Make sure the script is in the player scene or is `.local.gd`, then send the action to the server. |
| Using `get_tree().change_scene_to_file()` breaks the game | Use `Game.change_scene()` on the server instead. |
| An autoload's variable is different on each machine | Autoloads aren't replicated. Keep shared state on a node in the level ([details](godot_features.md#autoloads)). |
| Works on the host, broken for joined players | The host sees the server's world. Test with Play Test ▸ Server + 2. |
| A new player misses messages sent before they joined | Events wait for a listener, but nothing replays the past. Let their UI ask for a backlog with a RemoteFunction when it's ready (section 5, *Events wait for a listener*). |
| Warning: "more than 64 events arrived with nothing connected" | Nobody ever connects `on_client_event` / `on_server_event` on that remote on this machine. Connect a listener, or stop sending it there. |
| A player's calls stop working when they click fast | They hit the remote's `rate_limit` (default 60/s). Debug builds warn on both machines. Raise it on the node, or limit in your own code and tell the player. |
| Other players don't see my character's animation / aim | Play it on an `AnimationPlayer` inside your player scene, keep aim in a public variable of `controller.gd` (section 4). Turning a child of the character works too, unless it's under a camera or a `top_level` node. |
| Shots miss running players that were under the crosshair | Use `Game.rewind_raycast(player, query)` on the server (section 9). |
| After `Game.change_scene`, a script's references to level nodes are broken | The level is a new instance. Look nodes up again, e.g. in `Game.scene_changed`. |
| Everything closes when the host quits | There's no host migration. For a room that should stay up, run a dedicated server (`Game.start_server` or a dedicated-server export). |
