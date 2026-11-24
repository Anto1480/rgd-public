# Game

**Inherits:** Node < Object

**Where you find it:** The `Game` autoload (always there once the RGD plugin is enabled). Script: `addons/rgd/runtime/game.gd`.

The RGD runtime, registered as the `Game` autoload.

## Description

The RGD runtime, registered as the `Game` autoload. It is the whole pipeline:
sessions, `Game.players`, replication and remotes. No scene structure is required.

```gdscript
func _on_host_pressed(): Game.host(7777, "res://levels/map.tscn")
func _on_join_pressed(): Game.join($Address.text, {name = $Name.text})
```

## Tutorials

- [The RGD guide](../guide.md)
- [Beginner's Guide](../beginners_guide.md)
- [Deploying](../guide.md#13-exporting-and-deploying)
- [Escape hatches](../guide.md#14-escape-hatches)

## Properties

| Type | Name | Default |
|---|---|---|
| RGDPlayers | [players](#players) |  |
| Callable | [ownership_validator](#ownership_validator) |  |
| Callable | [owner_value_validator](#owner_value_validator) |  |
| Callable | [join_validator](#join_validator) |  |
| String | [last_end_reason](#last_end_reason) | `""` |
| String | [last_error](#last_error) | `""` |

## Methods

| Returns | Method |
|---|---|
| Error | [start_server](#start_server)(port: int = 0, scene: String = "") |
| int | [start_local_server](#start_local_server)(port: int = 0, scene: String = "") |
| void | [stop_local_server](#stop_local_server)(port: int = 0, wait: bool = false) |
| int | [default_port](#default_port)() |
| bool | [port_free](#port_free)(port: int) static |
| Dictionary | [rewind_raycast](#rewind_raycast)(player: Player, query: Object) |
| Error | [host](#host)(port: int = 0, scene: String = "", opts: Dictionary = {}) |
| Error | [play_solo](#play_solo)(scene: String = "", opts: Dictionary = {}) |
| bool | [is_solo](#is_solo)() |
| Error | [host_with_peer](#host_with_peer)(peer: MultiplayerPeer, scene: String = "", opts: Dictionary = {}) |
| Error | [start_server_with_peer](#start_server_with_peer)(peer: MultiplayerPeer, scene: String = "") |
| Error | [join](#join)(address: String, opts: Dictionary = {}) |
| Error | [join_with_peer](#join_with_peer)(peer: MultiplayerPeer, opts: Dictionary = {}) |
| void | [leave](#leave)() |
| void | [kick](#kick)(player: Player, reason: String = "kicked") |
| bool | [is_server](#is_server)() |
| bool | [is_client](#is_client)() |
| bool | [is_host](#is_host)() |
| bool | [is_session_active](#is_session_active)() |
| int | [local_peer_id](#local_peer_id)() |
| Variant | [get_value](#get_value)(node: Node, prop: StringName, default: Variant = null) |
| Signal | [changed](#changed)(node: Node, prop: StringName) |
| void | [mark_dirty](#mark_dirty)(node: Node) |
| void | [teleport](#teleport)(node: Node, xform: Variant) |
| void | [set_network_owner](#set_network_owner)(node: Node, player: Player) |
| Player | [get_network_owner](#get_network_owner)(node: Node) |
| bool | [is_network_owner](#is_network_owner)(node: Node) |
| int | [get_ping](#get_ping)(player: Player = null) |
| void | [send_message](#send_message)(to_peer: int, data: Variant, reliable: bool = true) |
| void | [set_auto_sync](#set_auto_sync)(node: Node, enabled: bool) |
| void | [sync](#sync)(node: Node, props: Array = []) |
| Error | [change_scene](#change_scene)(path: String) |
| void | [register_profile](#register_profile)(cls: StringName, props: Array) |
| Dictionary | [get_net_stats](#get_net_stats)() |
| void | [show_net_stats](#show_net_stats)(visible: bool) |
| int | [net_id](#net_id)(node: Node) |

## Signals

**session_started**()

The session is running: the world is loaded (and on clients, the initial state arrived).

**session_ended**(reason: String)

The session ended: left, server closed, or kicked.

```gdscript
Game.session_ended.connect(func(reason: String):
    $Menu/Status.text = "Disconnected: " + reason)
```

**join_failed**(reason: String)

A join attempt failed (couldn't connect, rejected, different builds...).

```gdscript
Game.join_failed.connect(func(reason: String): $Status.text = "Couldn't join: " + reason)
```

**scene_changed**(path: String)

Everyone moved to a new world (Game.change_scene). Emitted on every machine.

**message_received**(from_peer: int, data: Variant)

A raw message from Game.send_message (the escape hatch). `from_peer` is 1 for the server; on the server it's the sender's peer id (`Game.players.get_by_id(from_peer)`).

## Constants

- **Msg** = `RGDProtocol.Msg` — Message types (see `RGDProtocol`).
- **DEFAULT_PORT** = `7777` — The port used when none is given: 7777.
- **HANDSHAKE_TIMEOUT** = `10.0` — Seconds a new connection has to say hello before the server drops it.
- **META_PLAYER_SCENE** = `&"rgd_player_scene"` — Metadata on a level's root node that overrides `rgd/player_scene` for that level.
- **META_MENU_SCENE** = `&"rgd_menu_scene"` — Metadata on a level's root node that overrides `rgd/menu_scene` for that level.
- **BOOT_SCENE** = `"res://addons/rgd/runtime/boot.tscn"` — RGD's empty scene, used to start processes without the project's main scene.
- **BAD_INPUT_LIMIT** = `50` — A client that sends this many malformed messages (or positions that aren't numbers) is kicked with "sent invalid data": a working client never sends one.

## Property Descriptions

### players

`RGDPlayers players`

Every connected player (Roblox's `Players`).

### ownership_validator

`Callable ownership_validator`

Optional server-side check of owner-sent states: `func(player, node, state: Dictionary) -> bool`.

```gdscript
# Reject characters moving faster than they could run.
Game.ownership_validator = func(player: Player, node: Node, state: Dictionary) -> bool:
    return node.global_position.distance_to(state.transform.origin) < 3.0
```

### owner_value_validator

`Callable owner_value_validator`

Optional server-side check of values a player's own machine sets in its player scene (public variables of its client scripts, its AnimationPlayers): `func(player, node, prop: StringName, value) -> bool`. Return false to ignore the value.

```gdscript
Game.owner_value_validator = func(player: Player, node: Node, prop: StringName, value) -> bool:
    return prop != &"aim_pitch" or absf(value) <= 1.5
```

### join_validator

`Callable join_validator`

Optional server-side check of a joining client: `func(peer: int, name: String, data: Dictionary) -> String`. Return "" to let them in, or a reason to turn them away (they get join_failed(reason)). May `await` (e.g. ask your backend, or check a Steam auth ticket).

```gdscript
Game.join_validator = func(peer: int, name: String, data: Dictionary) -> String:
    var ok: bool = await Backend.check_token(data.get("token", ""))
    return "" if ok else "not signed in"
```

### last_end_reason

`String last_end_reason = ""`

Why the last session ended, when it wasn't your own choice: "the host left", "kicked", "the server shut down"... ("" otherwise). A menu can show it when the game returns to it.

```gdscript
func _ready() -> void:   # menu.gd
    if Game.last_end_reason != "":
        $Status.text = "Session ended: " + Game.last_end_reason
```

### last_error

`String last_error = ""`

Why the last host / start_server / join / start_local_server call failed, in words a player understands ("port 7777 is already in use: ..."). "" after a success.

```gdscript
if Game.host(Game.default_port(), LEVEL) != OK:
    $Status.text = Game.last_error
```

## Method Descriptions

### start_server

`Error start_server(port: int = 0, scene: String = "")`

Starts a dedicated server (no local player). `scene`: the world; defaults to the current scene. `port` 0 means `default_port`; a port in use fails like `host`.

```gdscript
# A "Start dedicated server" button in a tools menu:
func _on_server_pressed() -> void:
    Game.start_server(7777, "res://levels/arena.tscn")
```

A dedicated-server export doesn't need this call: it starts a server by itself, loading `rgd/server_scene` (or `--rgd-scene=...`, port from `--rgd-address=:7777`).

```gdscript
# Command line for a server build:
# ./server.x86_64 --headless -- --rgd-scene=res://levels/arena.tscn
```

### start_local_server

`int start_local_server(port: int = 0, scene: String = "")`

Starts a dedicated server for this game on this computer, in a separate headless process, and returns its process id (-1 on failure, with the reason in `last_error`). Join it with `Game.join("127.0.0.1")` right away: the join waits until the server is up.

```gdscript
func _on_dedicated_pressed() -> void:
    if Game.start_local_server(0, "res://levels/arena.tscn") > 0:
        Game.join("127.0.0.1", {name = $Name.text})
    else:
        $Status.text = Game.last_error
```

The server stops when you leave a session on it, when this game quits (or crashes), when you host on its port, or with `stop_local_server`. Calling this again while it runs returns the same server. Works from the editor and from exported builds.

### stop_local_server

`void stop_local_server(port: int = 0, wait: bool = false)`

Stops the dedicated server this game started on `port` with `start_local_server` (0 = all of them). Its players get "the server shut down". With `wait`, returns once the port is free again (at most 2 seconds).

```gdscript
func _on_stop_server_pressed() -> void:
    Game.stop_local_server()
```

### default_port

`int default_port()`

The port this game uses when you don't give one: `rgd/network/port` (7777 by default), or the RGD_PORT environment variable when it's set.

```gdscript
Game.host(Game.default_port(), "res://levels/arena.tscn", {name = $Name.text})
```

### port_free

`static bool port_free(port: int)`

True if nothing on this computer is listening on `port` for this game's transport (UDP for ENet, TCP for WebSocket), so Game.host / start_server can use it.

```gdscript
if not Game.port_free(7777):
    $Status.text = "Someone on this computer is already hosting: join them!"
```

### rewind_raycast

`Dictionary rewind_raycast(player: Player, query: Object)`

Server, lag compensation: casts the ray `query` against the world as `player` saw it when they sent the remote being handled. Other players' characters, drones and any other moving body are tested where they were on that player's screen, so a shot that looked like a hit is a hit. Returns the same Dictionary as `intersect_ray` ({} = no hit).

```gdscript
func _on_shoot(player: Player, origin: Vector3, dir: Vector3) -> void:
    var q := PhysicsRayQueryParameters3D.create(origin, origin + dir * 100.0)
    q.exclude = [player.character.get_rid()]
    var hit := Game.rewind_raycast(player, q)
    if hit and Game.players.get_player_from_character(hit.collider):
        ...
```

Works in 2D too: pass a PhysicsRayQueryParameters2D. Goes back at most `rgd/network/max_rewind` seconds. For the host's own player (who sees the present) it's a plain raycast.

### host

`Error host(port: int = 0, scene: String = "", opts: Dictionary = {})`

Starts a server with a local player (listen server, peer id 1). `port` 0 means `default_port`. If another game on this computer already uses the port, returns an error and `last_error` says so (a local server this game started there is stopped first: you're hosting there now).

```gdscript
func _on_host_pressed() -> void:
    if Game.host(7777, "res://levels/arena.tscn", {name = $Name.text}) != OK:
        $Status.text = "Couldn't host: " + Game.last_error   # e.g. the port is in use
```

### play_solo

`Error play_solo(scene: String = "", opts: Dictionary = {})`

Starts a single-player game: you're the host and nobody can join (nothing is opened on the network). The same game code runs as in multiplayer: world scripts on the "server" (this machine), your player scene, remotes (delivered locally). One code path for both modes.

```gdscript
func _on_single_player_pressed() -> void:
    Game.play_solo("res://levels/level_1.tscn", {name = "Player"})
```

### is_solo

`bool is_solo()`

True in a single-player game started with `play_solo`.

### host_with_peer

`Error host_with_peer(peer: MultiplayerPeer, scene: String = "", opts: Dictionary = {})`

Hosts using any MultiplayerPeer (already set up as a server): ENet, WebSocket, WebRTC, Steam (GodotSteam's SteamMultiplayerPeer)... RGD only needs `send_bytes` and peer ids.

```gdscript
var peer := SteamMultiplayerPeer.new()
peer.create_host(0)
Game.host_with_peer(peer, "res://levels/arena.tscn", {name = Steam.getPersonaName()})
```

### start_server_with_peer

`Error start_server_with_peer(peer: MultiplayerPeer, scene: String = "")`

Starts a dedicated server (no local player) on any MultiplayerPeer already set up as a server. See `host_with_peer`.

### join

`Error join(address: String, opts: Dictionary = {})`

Joins a server at `host:port` (without a port: `default_port`). `opts`: `{name = "...", data = {...}}`. `data` (plain values) reaches the server's `join_validator` and `player.join_data`: use it for a login token, a Steam id or auth ticket, a chosen skin.

```gdscript
func _on_join_pressed() -> void:
    Game.join($Address.text, {name = $Name.text})  # "192.168.1.20", "myserver.com:7777"
```

### join_with_peer

`Error join_with_peer(peer: MultiplayerPeer, opts: Dictionary = {})`

Joins using any MultiplayerPeer (already set up as a client).

### leave

`void leave()`

Leaves the session (or stops the server). Goes to `rgd/menu_scene` if set. When the server or host leaves, clients get session_ended with "the host left".

```gdscript
func _on_quit_pressed() -> void:
    Game.leave()
```

### kick

`void kick(player: Player, reason: String = "kicked")`

Server: disconnects `player` with a reason they'll see in session_ended.

```gdscript
Game.kick(player, "AFK for too long")
```

### is_server

`bool is_server()`

True on the server and on the host.

### is_client

`bool is_client()`

True on clients and on the host (the host is both).

### is_host

`bool is_host()`

True on a listen server: the server with a local player.

### is_session_active

`bool is_session_active()`

True while in a session (hosting, serving, or joined and the initial state arrived).

### local_peer_id

`int local_peer_id()`

This process's peer id (1 on the server/host, 0 when not in a session).

### get_value

`Variant get_value(node: Node, prop: StringName, default: Variant = null)`

A replicated value: the script variable `prop` if this machine's node has it, otherwise the value the server sent (for variables of server-only scripts).

```gdscript
# door.gd runs on the server only, so clients don't have its variables.
# They still get the values:
var open: bool = Game.get_value($Door, &"is_open", false)
```

### changed

`Signal changed(node: Node, prop: StringName)`

A Signal emitted with the new value whenever `prop` of `node` changes (on clients when the server's value arrives, on the server when the change is detected).

```gdscript
# coin_counter.local.gd: update a label whenever the server changes `coins`.
func _ready() -> void:
    Game.changed(stats, &"coins").connect(func(value): $Label.text = str(value))
```

### mark_dirty

`void mark_dirty(node: Node)`

Server: wakes a node's change detection right away (otherwise idle nodes are polled less often). Also starts replicating a node that just left the `local`/`server_only` group.

```gdscript
lamp.remove_from_group(&"server_only")
Game.mark_dirty(lamp)  # clients get it now
```

### teleport

`void teleport(node: Node, xform: Variant)`

Server: moves a node (Node3D or Node2D) without interpolation, and corrects its owner if a player owns it.

```gdscript
Game.teleport(player.character, Transform3D(Basis(), Vector3(0, 2, 0)))
```

### set_network_owner

`void set_network_owner(node: Node, player: Player)`

Server: gives simulation of `node` to `player` (null = the server).

```gdscript
# The player who picks up the ball simulates it (no lag for them).
func _on_pickup(player: Player) -> void:
    Game.set_network_owner($Ball, player)

func _on_drop() -> void:
    Game.set_network_owner($Ball, null)  # back to the server
```

### get_network_owner

`Player get_network_owner(node: Node)`

The player who simulates `node`, or null if the server does.

### is_network_owner

`bool is_network_owner(node: Node)`

True if this machine simulates `node` (its own character, on a client or the host).

### get_ping

`int get_ping(player: Player = null)`

Round-trip time to `player` in milliseconds (server), or to the server when `player` is null (client). Measured by RGD itself, so it works on any transport.

### send_message

`void send_message(to_peer: int, data: Variant, reliable: bool = true)`

The escape hatch for anything RGD doesn't model: sends `data` (plain values, and replicated nodes as references) straight to `to_peer`. Arrives as `message_received` on that machine. A client can only send to the server (1). On the server, 0 sends to every client. Unreliable messages may be dropped or arrive out of order. No rate limit: check what you receive. Godot's own `@rpc` works too, on nodes that have the same path everywhere (your level's nodes, players).

```gdscript
# client: stream a custom input state, unreliable
Game.send_message(1, {move = input, t = Time.get_ticks_msec()}, false)
# server
Game.message_received.connect(func(from_peer: int, data): _inputs[from_peer] = data)
```

### set_auto_sync

`void set_auto_sync(node: Node, enabled: bool)`

Server, the other escape hatch: `enabled` false stops RGD from sending `node`'s values and transform on its own. It still exists everywhere and spawns/despawns as usual; you decide when clients get its state with `sync`.

```gdscript
Game.set_auto_sync($Scoreboard, false)
# ...change it as much as you like, then once:
Game.sync($Scoreboard)
```

### sync

`void sync(node: Node, props: Array = [])`

Server: sends `node`'s current values now (all its replicated properties and its transform, or only `props`). Works for any node, auto-synced or not.

### change_scene

`Error change_scene(path: String)`

Server: moves everyone to a new world. Players and their characters are kept; characters are placed at the new world's spawn points.

```gdscript
# round_manager.gd (server): next map when the round ends.
func _on_round_over() -> void:
    Game.change_scene("res://levels/map2.tscn")
```

### register_profile

`void register_profile(cls: StringName, props: Array)`

Adds built-in properties that replicate for `cls` (and classes inheriting it), e.g. `Game.register_profile(&"OmniLight3D", [&"omni_range"])`. Call it on every machine before hosting or joining (an autoload's `_ready` is a good place): profiles are part of the handshake, so a client with different profiles is rejected as a different build.

### get_net_stats

`Dictionary get_net_stats()`

Network numbers for the last couple of seconds. Keys: `role`, `replicated_nodes`, `bytes_out_per_sec` / `bytes_in_per_sec` (per peer), `ping_msec`, `top_nodes`, `top_props`, `remote_calls_per_sec`, `interpolating`, `owned`. Server: `tick_usec_avg` / `tick_usec_max` (replication tick cost), `streamed_units` (per peer, "in/total") and `stream_waiting` (entries held back by the bandwidth limit). Client: `parked` (streamed-out world parts kept for later).

### show_net_stats

`void show_net_stats(visible: bool)`

Shows or hides the in-game network overlay (also F9 in debug builds).

### net_id

`int net_id(node: Node)`

The replicated id of `node` (0 if it doesn't replicate). Mostly for debugging.

[Back to the API reference](../api.md)
