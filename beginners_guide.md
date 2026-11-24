# Beginner's Guide: build a 2D platformer you can play alone or together

This guide takes you from nothing to **Coin Run**: a 2D platformer that works in **single player** and in **multiplayer** (host, join, or a dedicated server), built with Godot and RGD. Then it shows how to **build (export)** the game and **put it on GitHub**.

You don't need to know networking. You should know a little Godot (scenes, nodes, attaching a script) and a little GDScript. If you've never used Godot, do the official *Your first 2D game* tutorial first; it takes an hour.

The finished game is in this repository at [`samples/2d platformer/`](../samples/2d%20platformer/README.md). Keep it open next to this guide: every step below matches a file there.

![Coin Run](images/platformer.png)

**Contents**
1. [Get the project](#1-get-the-project)
2. [Play the finished game](#2-play-the-finished-game)
3. [Five ideas you need](#3-five-ideas-you-need)
4. [Build it, step by step](#4-build-it-step-by-step)
5. [Test it](#5-test-it)
6. [Build (export) the game](#6-build-export-the-game)
7. [Put it on GitHub](#7-put-it-on-github)
8. [Where next](#8-where-next)

---

## 1. Get the project

You need **Godot 4.5 or newer** (the project is developed on 4.7.2). Download it from [godotengine.org](https://godotengine.org/download). The standard version is enough; you don't need .NET.

**Get the code**, either way:
- With git: `git clone https://github.com/Anto1480/rgd.git`
- Or on GitHub: **Code ▸ Download ZIP**, then unzip it.

**Open it:** start Godot ▸ **Import** ▸ pick the `project.godot` file in the folder ▸ **Import & Edit**. The first time, Godot imports all the images and sounds; give it a minute.

The RGD plugin is already enabled in this project. In *your own* project later, you copy the `addons/rgd/` folder in and enable **RGD** in *Project ▸ Project Settings ▸ Plugins*. That adds an autoload called `Game`, which is the whole multiplayer system.

---

## 2. Play the finished game

1. In the FileSystem dock, open `samples/2d platformer/scenes/menu.tscn`.
2. Press **F6** (*Run Current Scene*).
3. Type a name and press **Single player**.

Run with **←/→** (or A/D), jump with **Space** (hold it for a higher jump), land on slimes to stomp them, and reach the yellow flag.

**Now with two players on one computer:**
1. *Debug ▸ Customize Run Instances…* ▸ tick **Enable Multiple Instances** ▸ set it to **2** ▸ OK.
2. Press **F6** again: two windows open.
3. Window 1: **Host**. Window 2: **Join** (leave the address empty: it means "this computer").

Both of you play the same level. Coins one player takes disappear for the other, and you see each other run.

There's a faster way you'll use while developing: open `scenes/level.tscn` and press **Play Test** in the toolbar (next to Godot's play buttons). It starts a server and as many players as you pick in its dropdown, already in the level, with no menu.

---

## 3. Five ideas you need

### 1. One machine is in charge: the server
In a multiplayer game, one copy of the game decides what's true: who has how many coins, where the slimes are, who reached the flag. That's the **server**. Everyone else (the **clients**) shows a copy of that world and sends requests.

The server can be a player (**host**), a separate program with no player (a **dedicated server**), or, in single player, simply your own game (**solo**). Your code doesn't change between these.

### 2. The world copies itself
Anything in your level scene exists on every machine. When the server moves a slime, changes a sprite's texture, deletes a coin or changes a **public variable** in a script, RGD sends the change to everyone. You don't write any networking code for that.

Variables starting with `_` (`var _secret := 3`) are private: they stay on the server.

### 3. Where your script runs depends on where it is
| The script is... | It runs on... |
|---|---|
| on a node in your **level** (`level.gd`, `slime.gd`) | the **server** (rules, enemies, pickups) |
| in your **player scene** (`controller.gd`, `hud.gd`) | **that player's own machine** (input, camera, UI) |
| named `something.server.gd` | the server only |
| named `something.local.gd` | every player's machine (effects, sounds), never the server |
| on a node in the `local` group | every player's machine, and the node itself only exists there |
| `extends RemoteEvent`, `RemoteFunction` or `Player` | the server **and** every player's machine (both sides of it in one script) |

So the slime's AI runs on the server, and your controls run on your computer. In the editor, script icons are tinted **green** (server), **blue** (clients) or **teal** (both).

### 4. The player scene
Every player who joins gets a copy of one scene, the **player scene**: their character, their UI, their personal scripts. Your character belongs to you: you move it on your own machine (no delay), and RGD sends its position, its animation and the direction it faces to everyone.

### 5. Clients ask, the server decides
A client can't change the world directly (it would only change its own copy). It **asks** with a `RemoteEvent`, and the server decides. Put a script on the RemoteEvent node itself: it runs on both sides, and RGD calls the right method on each. There's nothing to connect:

```gdscript
# buy.gd, on a RemoteEvent node named Buy
extends RemoteEvent

func _on_server_event(player: Player, item: String) -> void:   # runs on the server
	print(player.display_name, " wants a ", item)

# any client script:  get_tree().current_scene.get_node("Buy").fire_server("sword")
```

The server answers with `fire_client(player, ...)` or `fire_all_clients(...)`, which arrive in `_on_client_event(...)`. You can also connect the remote's signals in the editor's Signals tab. See [the guide](guide.md#three-ways-to-handle-an-event).

In Coin Run you'll barely need this: touching a coin is detected *on the server* (it has everyone's positions), so clients never even have to ask.

---

## 4. Build it, step by step

Make a folder for your version, e.g. `my_platformer/`, with `scenes/` and `scripts/` inside. The art is already in `samples/2d platformer/assets/` (Kenney's *New Platformer Pack*); use it from there.

> Following along exactly isn't required. You can read each step and look at the finished file. The point is to understand *why* each piece is where it is.

### 4.1 A tileset from the spritesheet

1. Create a scene with a **Node2D** root named `Level`, and save it as `my_platformer/scenes/level.tscn`.
2. Add a **TileMapLayer** child named `Tiles`. In the Inspector: *Tile Set ▸ New TileSet*.
3. Open the **TileSet** panel (bottom of the editor). Drag `assets/kenney_new-platformer-pack-1/Spritesheets/spritesheet-tiles-default.png` into it. When Godot asks to create tiles automatically, say **No**.
4. With the atlas selected, set **Texture Region Size** to `64 × 64` and **Separation** to `1 × 1` (the sheet has a 1-pixel gap between tiles). Now create the tiles you want by clicking them.
5. Give the ground collision: in the TileSet's Inspector, *Physics Layers ▸ Add Element*. Then select the grass blocks, go to the **Paint** tab ▸ *Physics Layer 0*, and paint a full square on each.
6. For **one-way platforms** (the floating grass strips you can jump up through), paint their collision and tick *One Way*.
7. Paint your level in the **TileMap** tab.

The finished sample's tileset is `scenes/tileset.tres`, if you'd rather reuse it.

### 4.2 Spawn points and the level's settings

1. Add a few **Marker2D** nodes where players should appear, and put them in the group `spawn_point` (*Node ▸ Groups*). RGD places each new player at one of them.
2. Add a **Marker2D** named `Start` too: we'll send players back there.
3. Tell RGD which player scene and menu this level uses. Either set *Project Settings ▸ Rgd ▸ Player Scene* (one game per project), or, as the samples do, select `Level` ▸ *Inspector ▸ Add Metadata*:
   - `rgd_player_scene` = `res://my_platformer/scenes/player.tscn`
   - `rgd_menu_scene` = `res://my_platformer/scenes/menu.tscn` (where everyone goes when they leave)

### 4.3 The player scene

Right-click in the Scene dock ▸ **RGD ▸ New Player Scene (2D)**. You get:

```
Player          (Player: the root, one per player)
├── Character   (CharacterBody2D + controller: moves with WASD)
│   ├── Body, Shape, Camera2D
└── UI          (CanvasLayer: only exists on this player's screen)
```

Make it a platformer character:
1. Replace `Body` with an **AnimatedSprite2D** named `Sprite`. In *Sprite Frames ▸ New SpriteFrames*, add the animations `idle`, `walk`, `jump` and `hit` using `Sprites/Characters/Default/character_green_*.png`. Tick *Loop* on `walk`.
2. Make the `Shape` a rectangle around the body, with the feet at the node's origin.
3. Replace the controller script with a side-view one:

```gdscript
# scripts/controller.gd: in the player scene, so it runs on this player's machine
extends CharacterBody2D

const SPEED := 420.0
const JUMP := -980.0
const GRAVITY := 2400.0

@onready var _sprite: AnimatedSprite2D = $Sprite


func _ready() -> void:
	$Camera2D.make_current()


func _physics_process(delta: float) -> void:
	var axis := Input.get_axis(&"ui_left", &"ui_right")
	velocity.x = axis * SPEED
	velocity.y += GRAVITY * delta
	if is_on_floor() and Input.is_action_just_pressed(&"ui_accept"):
		velocity.y = JUMP
	move_and_slide()

	# Animation and facing: your machine plays them, RGD shows them to everyone.
	if not is_on_floor():
		_sprite.play(&"jump")
	elif axis != 0.0:
		_sprite.play(&"walk")
	else:
		_sprite.play(&"idle")
	if axis != 0.0:
		_sprite.flip_h = axis < 0.0
```

Notice what's **not** there: nothing about the network. The character is yours, so moving it, playing its animation and flipping its sprite on your machine is all it takes. The finished `controller.gd` adds coyote time (a jump still works a moment after leaving a ledge), a jump buffer, and short jumps when you let go early.

4. Save as `my_platformer/scenes/player.tscn`.

### 4.4 First test

Open `level.tscn` ▸ **Play Test** dropdown ▸ *Host + clients*, **2** ▸ **Play Test**. Two windows, two characters, each controlled in its own window, each seeing the other run. You've made a multiplayer game.

### 4.5 Coins and a score

**Per-player data** lives on the `Player`, so it survives when the character respawns. Give the player scene's root (`Player`) your own script that extends `Player`:

```gdscript
# scripts/platformer_player.gd: on the Player root. Runs on the server and every client.
extends Player

var coins := 0          # public: the server's value, every machine gets it (HUD, scoreboard)
```

A script that extends `Player` runs everywhere, and its public variables belong to the server: only the server changes them, and every machine reads them directly (`player.coins`).

A **coin** is a small scene: an **Area2D** (collision mask: the players' layer) with a `CollisionShape2D` and a `Sprite2D` (`coin_gold.png`):

```gdscript
# scripts/coin.gd: on a level node, so it runs on the server
extends Area2D

func _ready() -> void:
	body_entered.connect(func(body: Node2D):
		var player := Game.players.get_player_from_character(body)
		if player and not is_queued_for_deletion():
			player.coins += 1
			queue_free())               # gone for everyone
```

Why does this work for everyone? The **server** has every player's position (each player sends theirs), so the server's coin sees whoever touches it. It adds the coin to the player, and RGD sends the new `coins` value and the coin's removal to all players.

Show it in the player's UI. Put a `Label` named `Coins` under `UI`:

```gdscript
# scripts/hud.gd: on the UI, so it runs on this player's machine
extends CanvasLayer

@onready var _me: Player = get_parent()   # my own Player (platformer_player.gd)

func _process(_delta: float) -> void:
	$Coins.text = "Coins: %d" % _me.coins
```

### 4.6 Sounds: telling everyone that something happened

A coin's sound is an *effect*: every player should hear it, but it isn't state. Use a **RemoteEvent**:

1. Add a **RemoteEvent** to the level (Add Node ▸ search "RemoteEvent") and name it `Fx`.
2. In `coin.gd`, before `queue_free()`: `get_parent().get_node("Fx").fire_all_clients("coin", global_position)`.
3. Give `Fx` a script (right-click ▸ *Extend Script*). It extends RemoteEvent, so it runs on every machine, and RGD calls `_on_client_event` on each client:

```gdscript
# scripts/fx_event.gd, on the Fx RemoteEvent
extends RemoteEvent

func _on_client_event(kind: String, at: Vector2) -> void:
	if kind == "coin":
		var p := AudioStreamPlayer2D.new()
		p.stream = preload("res://samples/2d platformer/assets/kenney_new-platformer-pack-1/Sounds/sfx_coin.ogg")
		add_child(p)
		p.global_position = at
		p.play()
```

A dedicated server never plays sounds: `_on_client_event` only runs on players' machines. (The finished sample hands the sound to an `Sfx` node in the **`local`** group, which only exists on players' machines, and keeps all its sounds there.)

### 4.7 Hearts, spikes and checkpoints

Add a **Node** named `Health` to the character, with `health.server.gd`:

```gdscript
extends Node

var hearts := 3
var hurt_left := 0.0      # a moment of blinking after a hit

func _physics_process(delta: float) -> void:
	hurt_left = maxf(hurt_left - delta, 0.0)

func hurt() -> bool:
	if hurt_left > 0.0 or hearts <= 0:
		return false
	hearts -= 1
	hurt_left = 1.2
	return true
```

Spikes are an `Area2D` over the spike tiles that calls the level's `hurt(player, ...)`. Here's the one thing that's different in multiplayer: **the server can't move your character**, because it's yours. To knock a player back, the server *asks their machine* with a second RemoteEvent, `Push`:

```gdscript
# level.gd (server)
$Push.fire_client(player, Vector2(500, -600), true)
```

```gdscript
# scripts/push_event.gd, on the Push RemoteEvent: runs on that player's machine
extends RemoteEvent

func _on_client_event(v: Vector2, _absolute_y: bool) -> void:
	Game.players.local_player.character.velocity = v     # my own character: I may move it
```

Springs and stomp bounces use the same `Push`. To put a player back at a checkpoint, the server uses **`Game.teleport(character, transform)`**, the one call that moves someone else's character for real.

The finished `level.gd` keeps each player's last checkpoint in `player._checkpoint` (a private variable of `platformer_player.gd`: it stays on the server) and sends players back there when they lose all hearts or fall below the level.

### 4.8 Slimes

A slime is a **CharacterBody2D** in the level with an `AnimatedSprite2D` and an `Area2D` hitbox. Its script runs on the server, because it's a level node:

```gdscript
# scripts/slime.gd (server)
extends CharacterBody2D

var _dir := -1.0

func _physics_process(delta: float) -> void:
	velocity.y += 2400.0 * delta
	velocity.x = _dir * 90.0
	move_and_slide()
	if is_on_wall():
		_dir = -_dir
	$Sprite.flip_h = _dir > 0.0
```

Its position and animation reach every player automatically. When a player touches the hitbox, the level decides: falling onto it from above is a **stomp** (the slime is squashed, the player bounces with `Push`), anything else **hurts**. The server knows each player's velocity, because players send it with their position.

### 4.9 Finish line and restart

The flag is one more `Area2D`. When a player touches it, `level.gd` stores their time in `player.finish_time`. When *everyone* has finished, it shows the results for a few seconds, then restarts the level for everyone:

```gdscript
Game.change_scene(scene_file_path)    # server: everyone moves to a fresh copy of the level
```

Players (with their `coins` and `finish_time`) are kept across `change_scene`, so `level.gd` resets the score in its `_ready`. The new level's `Fx` and `Push` bring their scripts along, so nothing needs reconnecting.

### 4.10 The menu: single player or multiplayer

The menu is an ordinary scene (it's not part of any session). Each button is one line:

```gdscript
# scripts/menu.gd
const LEVEL := "res://my_platformer/scenes/level.tscn"

func _on_single_player() -> void:
	Game.play_solo(LEVEL, {name = $Name.text})        # just you, nothing on the network

func _on_host() -> void:
	Game.host(7777, LEVEL, {name = $Name.text})       # you play, friends join you

func _on_join() -> void:
	Game.join($Address.text, {name = $Name.text})     # "192.168.1.20", or "" for this computer

func _on_dedicated() -> void:
	Game.start_local_server(7777, LEVEL)              # a separate, invisible server program
	Game.join("127.0.0.1:7777", {name = $Name.text})  # connects as soon as it's up
```

Things go wrong, and the menu should say so. Add a `Label` named `Status`:

```gdscript
func _ready() -> void:
	Game.join_failed.connect(func(reason): $Status.text = "Couldn't join: " + reason)
	if Game.last_end_reason != "":                    # back from a game: "the host left"...
		$Status.text = "Session ended: " + Game.last_end_reason
```

and in `_on_host`, `if Game.host(...) != OK: $Status.text = Game.last_error`. The usual reason is two copies of the game on one computer both pressing Host: only one can use the port, so the other should press Join. The dedicated server stops when you leave it or quit the game.

**Single player is not a special mode in your game code.** `Game.play_solo` runs the same level with you as the server and the only player, so the rules, the slimes and the coins work exactly as online. If you need to know, `Game.is_solo()` tells you (the HUD uses it to hide the multiplayer scoreboard).

Make the menu the game's first scene: *Project Settings ▸ Application ▸ Run ▸ Main Scene*.

---

## 5. Test it

- **Play Test** (toolbar) with *Server + 2* is the most honest test: a separate server like a real online game. *Host + 1* is quicker but can hide bugs, because the host sees the real world directly.
- **F6 on the menu** tests what players will actually do, including single player.
- **Read the Output panel.** Each window's lines are prefixed (`[Server]`, `[Client 1]`). RGD warns when a client changes something that won't replicate, or when a value can't be sent.
- Press **F9** in any game window to see the network overlay (traffic, ping, the busiest nodes).
- Common surprises:
  - *"My `print` in `slime.gd` doesn't show in the game window"*: it runs on the server; look for `[Server]`.
  - *"My character's change doesn't show for others"*: change it in a script in the player scene (you own it), or ask the server with a RemoteEvent.
  - *"The server can't move my character"*: it's yours; use `Push` (ask the owner) or `Game.teleport`.

This repo also has automated tests that play the game headless: `godot --headless --path . -s res://tests/integration/run.gd -- --only=sample_platformer,sample_platformer_solo`.

---

## 6. Build (export) the game

"Building" a Godot game means **exporting** it: Godot packs your project into a program for each platform.

### 6.1 One-time setup

1. *Editor ▸ Manage Export Templates ▸ Download and Install* (once per Godot version).
2. *Project ▸ Export… ▸ Add…* and pick your platform (Windows Desktop, macOS, Linux, Web). Each one is a **preset**.

### 6.2 The game players download

Add a preset for each platform you want, then in each preset's **RGD** section:
- **Role:** `Client` (or leave it at `Both` if players should also be able to host or play single player, which is what Coin Run needs: keep **Both**).
- **World Scenes:** list your level (`res://my_platformer/scenes/level.tscn`).

Press **Export Project**, pick a file name (e.g. `build/windows/CoinRun.exe`), and untick *Export With Debug* for a release.

With *Role = Client*, server-only scripts (`*.server.gd`, level scripts) and `server_only` nodes are left out of the build, so players can't read them. Then you need a dedicated server to play online, and single player won't work (no server code). Use *Both* when players host or play alone, and *Client* for a game that's only played on your servers.

### 6.3 A dedicated server

1. Add a preset for the server's platform (usually **Linux**).
2. *Resources ▸ Export Mode ▸* **Export as dedicated server**.
3. **RGD ▸ Role:** `Server`.
4. *Project Settings ▸ Rgd ▸ Server Scene:* your level.
5. Export, e.g. `build/server/coinrun_server.x86_64`.

Run it on any computer or rented server:

```
./coinrun_server.x86_64 --headless
# other port or level:  RGD_PORT=7000 ./coinrun_server.x86_64 --headless
```

It starts by itself (no menu), listens on port **7777 (UDP)**, and players connect with **Join** and the server's address. Open that port in the server's firewall. To play over the internet with **Host** from home, your router must forward the port to your computer; a rented server avoids that.

### 6.4 A web version

Browsers can't use the default UDP networking. Set *Project Settings ▸ Rgd ▸ Network ▸ Transport* to **websocket** (in both the web build and the server), export with the **Web** preset, and serve the folder with any web server. Single player works in the browser as is.

### 6.5 Exporting from the command line

Useful for scripts and CI (Godot must be on your PATH; names are your preset names):

```
godot --headless --path . --export-release "Windows Desktop" build/windows/CoinRun.exe
godot --headless --path . --export-release "Linux Server" build/server/coinrun_server.x86_64
```

---

## 7. Put it on GitHub

### 7.1 The repository

The project is a normal folder of text and image files. Commit everything **except** Godot's cache:

```gitignore
# .gitignore
.godot/
build/
*.tmp
```

`export_presets.cfg` holds your export settings. Commit it, unless you put passwords in it (for example Android signing keys).

```
git init
git add .
git commit -m "Coin Run: first version"
git branch -M main
git remote add origin https://github.com/<you>/coin-run.git
git push -u origin main
```

Put a `README.md` at the top with a screenshot, the controls, and how to run it. GitHub shows it on the repository's front page.

### 7.2 Releases (downloads for players)

Don't commit the exported programs. Instead, on GitHub: **Releases ▸ Draft a new release** ▸ tag (e.g. `v1.0`) ▸ attach the zipped builds from `build/` ▸ **Publish**. Players download them from there.

### 7.3 Automatic builds (optional)

GitHub can export the game every time you push a version tag. Save this as `.github/workflows/export.yml`. It uses the community *godot-ci* image; match the Godot version to yours:

```yaml
name: Export
on:
  push:
	tags: ["v*"]
jobs:
  export:
	runs-on: ubuntu-latest
	container: barichello/godot-ci:4.5
	steps:
	  - uses: actions/checkout@v4
	  - name: Export
		run: |
		  mkdir -p build/windows build/linux
		  godot --headless --path . --export-release "Windows Desktop" build/windows/CoinRun.exe
		  godot --headless --path . --export-release "Linux Server" build/linux/coinrun_server.x86_64
	  - uses: softprops/action-gh-release@v2
		with:
		  files: build/**/*
```

The presets you use must exist in the committed `export_presets.cfg`.

---

## 8. Where next

- [The RGD guide](guide.md): every concept in more depth (remote functions, ownership, big worlds, deploying, escape hatches).
- [Recipes](recipes.md): copy-paste features (scoreboard, chat, round timer, teams, shooting…).
- [API reference](api.md): every class, property, method and signal.
- The other samples: [a chat with no characters](../samples/chat/README.md), [flying cubes](../samples/flying_lobby/README.md), [a 3D shooter on a dedicated server](../samples/shooter/README.md).

Ideas for your Coin Run:
- A second level: `Game.change_scene("res://my_platformer/scenes/level_2.tscn")` when everyone finishes.
- Blocks you hit from below to release a coin (the `block_coin` tiles): a `StaticBody2D` whose server script notices a player's head.
- A ghost of your best run in single player: record your positions in `controller.gd` and replay them with a `local` node.
