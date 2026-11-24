# Godot features in RGD

How everyday Godot things behave in a replicated game. The short version is that **the server owns state and clients own presentation.** Replicate the *facts* (a number, a string, which animation, which material file). Let each machine produce the *look* (shaders, particles, sound, UI) locally from those facts.

What replicates on its own:
- nodes under the world and `Game.players`, plus their transforms
- public script variables of supported types
- the built-in properties listed in `addons/rgd/runtime/core/profiles.gd`

Everything else runs only on the machine where it happens.

## Autoloads

Autoloads (singletons) are **not replicated**. Every machine has its own copy with its own state, like Roblox's ModuleScripts.

| Autoload script | Runs on |
|---|---|
| `music.gd` | every machine (server, clients, host) |
| `save_system.server.gd` | the server only |
| `settings_menu.local.gd` | clients only |

Wrong-side `.server.gd` / `.local.gd` autoloads are freed. If the process starts with a role (Play Test, `--rgd-role`, a dedicated-server export), that happens before their `_ready`. Otherwise it happens as soon as `Game.host()` / `join()` decides the side. Keep autoload `_init` / `_enter_tree` free of side effects (plan 12.1).

**Sharing state:** an autoload's variables never reach other machines. For state everyone should see (round timer, scores, match phase), put a node in the world scene, e.g. a `Match` node with `match.gd`. Its public variables replicate, and clients read them with `Game.get_value(match, &"time_left")` or react with `Game.changed(match, &"phase")`. An autoload can still hold *helpers* for that state (`static func` utilities, constants, a reference to the `Match` node).

Calling the server from an autoload works through a `RemoteEvent` / `RemoteFunction` node in the world or player scene. The autoload can reference it (`get_tree().current_scene.get_node("Remotes/Buy")`).

## Shaders and materials

Shaders run on every machine that renders. A dedicated server is headless and renders nothing, so shader code never matters there.

| You do this on the server | Clients see it? |
|---|---|
| `mesh.material_override = preload("res://red.tres")` | **Yes.** The material is sent as a file reference; the client loads its own copy. |
| Swap to a material embedded in the same scene | **Yes**, resolved from the client's copy of the scene. |
| `mat.set_shader_parameter("tint", Color.RED)` | **Not by itself.** Changes *inside* a resource aren't diffed; call `Game.mark_dirty(mesh)` afterwards to resend it. |
| `material_override = base.duplicate()` / `StandardMaterial3D.new()` (runtime-created) | **Yes.** Materials, primitive meshes, shapes, gradients, curves, `StyleBoxFlat` and `LabelSettings` made at runtime are sent by value (their shader or textures by file). Identical ones are one object on the client. Other runtime resources arrive as null, and debug builds warn once. |
| `modulate` / `visible` on a CanvasItem or Node3D | **Yes** (built-in profile). |

For shader parameters, replicate the fact in a script variable and apply it on each machine:

```gdscript
# crystal.shared.gd: runs on server and clients
extends MeshInstance3D

var charge := 0.0:  # set by the server; replicates
	set(v):
		charge = v
		(material_override as ShaderMaterial).set_shader_parameter("glow", v)
```

The setter runs on clients when the server's value arrives. Give each instance its own material (*Local to Scene*) if instances glow differently. Animated shaders (`TIME`) run independently per machine. That's fine for visuals, but don't use them to drive gameplay.

## Animation

- `AnimationPlayer.current_animation` and `speed_scale` replicate. When the server plays `"open"`, clients start `"open"` from the beginning when the change arrives, so the playhead isn't synced. That's fine for door/attack/emote animations.
- **Inside your player scene, your machine drives them** (like Roblox's Animator): play `"walk"` on your own character in `controller.gd` and everyone sees it. The server's copy plays it too, so it can hit-test bones.
- Loop modes, blend times and the like live in the Animation resources, which every machine loads from the same files: set loops in the import settings (*Import ▸ Animation ▸ Loop Mode*), not in code on one machine.
- `BoneAttachment3D` transforms don't replicate: every machine computes them from its own skeleton.
- `AnimationTree` parameters don't replicate. Drive them on each machine from replicated facts: a character's velocity is already replicated through its transform, or replicate a `state` variable.
- An animation that moves a replicated node on the server (an `AnimationPlayer` on a moving platform) replicates through the transform stream, so clients don't need to play it.

Clients can still change these for looks (a death effect swapping `material_override`, a flash on `material_overlay`, instance shader uniforms): debug builds don't warn about `material_override`, `modulate`, light color/energy or animation playback changed on a client.

## Particles, sound, screen shake: one-off effects

Effects are presentation, so trigger them on clients:
- **From a state change:** `Game.changed(door, &"is_open").connect(func(open): $Creak.play())` in a `.local.gd` script.
- **From a moment that isn't state** (a hit, an explosion): `$Effects.fire_all_clients("explosion", position)` on a `RemoteEvent`, played by a client script.

`GPUParticles3D.emitting`, `AudioStreamPlayer.playing` and similar aren't in the default profiles. You can add them with `Game.register_profile` on every machine before the session starts, but an event is usually clearer.

## 2D

Everything works the same in 2D. The player scene's character is a `CharacterBody2D` (or any 2D body); right-click ▸ RGD ▸ **New Player Scene (2D)** makes one.

| | 2D | 3D |
|---|---|---|
| Transforms stream and interpolate | `Node2D` | `Node3D` |
| Owner simulates its character, server the rest | `CharacterBody2D`, `RigidBody2D` | `CharacterBody3D`, `RigidBody3D` |
| Your machine drives animations on your own character | `AnimatedSprite2D` (animation, speed, flips), `AnimationPlayer` | `AnimationPlayer`, `AnimatedSprite3D` |
| Children you move inside your character replicate | yes | yes |
| Built-in values that replicate | `visible`, `modulate`, `Sprite2D` texture/frame/flips, `AnimatedSprite2D`, `Polygon2D` color/texture, `Light2D` color/energy/enabled, `TileMapLayer` tiles, `CollisionShape2D`, `Label` | see the profiles |
| Lag compensation | `Game.rewind_raycast(player, PhysicsRayQueryParameters2D...)` | `...3D` |
| Streaming | `rgd/streaming/radius_2d` (pixels) | `rgd/streaming/radius` |
| Teleport threshold | `rgd/network/teleport_distance_2d` | `teleport_distance` |

**Tilemaps:** when the server edits a `TileMapLayer` (`set_cell`, `erase_cell`), clients get the change. The layer's whole tile data is resent, which is fine for occasional edits (a door, destructible tiles). For a level that changes every frame, use several small layers.

## Physics

- The server simulates. `RigidBody3D/2D` nodes are kinematic on clients and follow the stream.
- Each player's character is simulated by its owner and streamed to the server. `Game.ownership_validator` can reject impossible moves.
- `Game.set_network_owner(body, player)` hands any body to a player (e.g. a ball they're dribbling). If that player leaves, the server takes the body back and simulates it from where it was, with its last velocity. Physics callbacks (`body_entered`, `Area3D` overlaps) should run in server scripts, which is the default for world scripts.
- **Pausing** (`get_tree().paused = true`, a pause menu) pauses your nodes on that machine, not the network. A paused client stays connected, keeps receiving the server's changes and still sees the others move. A paused host still relays its players to each other. In single player (`Game.play_solo`) it's an ordinary pause.

## Input, cameras and UI

- Input exists only on clients. Scripts in the player scene run on the owning client, so put input handling there and send intents to the server with a `RemoteEvent`. Moving your own character doesn't need a remote, because you own it.
- Cameras live in the player scene. Make yours current from an owner script (the template's controller does `$Camera3D.current = true`). Other players' cameras exist on your machine, but their scripts don't run there, so once yours is current they stay inactive.
- UI goes in the player scene's `ui` (only on that player's machine), or in nodes in the `local` group.

## Signals, timers, tweens

- **Signals** are per machine and never cross the network. On clients, react to replicated changes with `Game.changed(node, prop)`. For moments, use `RemoteEvent`s.
- **Timers and tweens** on the server change replicated values or transforms, and those replicate. A tween on a client that changes a replicated property is overwritten by the next server value; debug builds warn about it. Use client tweens for presentation-only nodes (`local` group, UI).

## Data and resources in script variables

| Type in a replicated variable | Arrives as |
|---|---|
| numbers, bools, strings, vectors, colors, transforms, packed arrays | the value (NaN and infinity too) |
| `Array` / `Dictionary` of the above (nested is fine, up to 64 levels) | the value (the whole value is resent when anything inside changes) |
| typed `Array[int]`, `Dictionary[String, int]`... | the value, with its type (a variable declared typed on the client gets it converted) |
| a replicated `Node` | the same node on the client (null if the client doesn't have it, e.g. streamed out) |
| a `Resource` loaded from a file (`.tres`, `.png`, ...) | the client's copy of that file |
| a runtime-created `Resource`, any other `Object` | null (debug builds warn) |
| `Callable`, `Signal`, `RID` | not replicated (warned at startup) |

Prefix a variable with `_` to keep it on the server, or list it in `const RGD_NO_REPLICATE := ["name"]`.

## Scenes, saving, randomness

- **Several games in one project:** a level's root node can set `rgd_player_scene` and `rgd_menu_scene` metadata to use its own player scene and menu (the samples do this).
- **Changing levels:** `Game.change_scene(path)` on the server, not `get_tree().change_scene_to_file()`. It moves everyone and keeps players and characters.
- **Spawning:** `add_child` on the server spawns for everyone. A `PackedScene` instance arrives on clients as that scene, with client-side scripts intact.
- **Saving:** files on the server (`save.server.gd`). Client-side settings (volume, keybinds) in a `.local.gd` autoload.
- **Randomness:** roll on the server and replicate the result. Client-side randomness is fine for effects only.
