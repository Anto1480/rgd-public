# RGD API reference

Every class, property, method and signal of RGD, laid out like Godot's class reference. Generated from the doc comments by `tools/gen_api_docs.gd` (don't edit by hand); the same text shows up in Godot's built-in help (F1). New to RGD? Start with the [Beginner's Guide](beginners_guide.md) or [the guide](guide.md).

## How it fits together

- **[Game](api/Game.md)** is the whole system: an autoload you call to host, join, play solo, change levels, and reach everything else.
- **[RGDPlayers](api/RGDPlayers.md)** (`Game.players`) lists the connected players and tells you when they come and go.
- **[Player](api/Player.md)** is the root of your player scene: one per player, with their `character` and `ui`.
- **[RemoteEvent](api/RemoteEvent.md)** and **[RemoteFunction](api/RemoteFunction.md)** are nodes for messages between clients and the server.
- Everything else is configuration: [project settings](#project-settings), [groups](#groups), [script names](#where-scripts-run), the [command line](#command-line-and-environment).

## Classes

| Class | Inherits | Summary |
|---|---|---|
| [Game](api/Game.md) | Node | The RGD runtime, registered as the `Game` autoload. |
| [RGDPlayers](api/RGDPlayers.md) | Node | `Game.players`: every connected `Player`, on every machine (Roblox's `Players`). |
| [Player](api/Player.md) | Node | Root of the player scene (`rgd/player_scene`). |
| [RemoteEvent](api/RemoteEvent.md) | Node | One-way messages between clients and the server, exactly like Roblox's RemoteEvent. |
| [RemoteFunction](api/RemoteFunction.md) | Node | Request/response between a client and the server, exactly like Roblox's RemoteFunction. |

The sample game's scripts are documented the same way in [Coin Run scripts](api/coin_run.md).

## Project settings

*Project Settings ▸ rgd* (turn on *Advanced Settings* to see them all).

| Setting | Default | Meaning |
|---|---|---|
| `rgd/player_scene` | `""` | The player scene: root is a `Player` with a `character` and a `ui`. A level can use its own with `rgd_player_scene` metadata on its root node. |
| `rgd/server_scene` | `""` | The world a dedicated server loads when it starts by itself (a dedicated-server export, or `--rgd-role=server` without `--rgd-scene`). Empty = the main scene. |
| `rgd/menu_scene` | `""` | Scene to return to when a session ends (empty = stay). A level can override it with `rgd_menu_scene` metadata on its root node. |
| `rgd/players/unique_names` | `true` | Make display names unique when players join: a second "Bob" becomes "Bob2". |
| `rgd/players/auto_spawn` | `true` | Spawn a Player for everyone who joins. Off: call it yourself. |
| `rgd/network/tick_rate` | `30` | Network ticks per second (property diffs and transform streams). |
| `rgd/network/interpolation_delay` | `0.1` | Seconds clients stay behind the server's stream so movement interpolates smoothly. |
| `rgd/network/port` | `7777` | The game's port: what Game.host / start_server / join / start_local_server use when you don't give one (port 0, or an address without ":port"). The RGD_PORT environment variable overrides it. |
| `rgd/network/max_players` | `32` | Players allowed at once; more are rejected with "server is full". |
| `rgd/network/teleport_distance` | `8.0` | A jump larger than this (3D units) snaps instead of interpolating. |
| `rgd/network/teleport_distance_2d` | `256.0` | A jump larger than this (pixels) snaps instead of interpolating. |
| `rgd/streaming/radius` | `0.0` | Streaming: radius around each player's character; 0 = off (send everything). |
| `rgd/streaming/radius_2d` | `0.0` | Streaming radius for 2D worlds (pixels); 0 = off. |
| `rgd/network/bandwidth_limit_kb` | `0` | KB/s per client for the transform stream; 0 = unlimited. |
| `rgd/network/transport` | `enet` | Transport for Game.host / start_server / join: "enet" (UDP, default) or "websocket" (TCP; works in web exports and through HTTP proxies). Any other MultiplayerPeer (Steam, WebRTC) goes through Game.host_with_peer / start_server_with_peer / join_with_peer. |
| `rgd/network/timeout` | `8.0` | Seconds without hearing from the other side before a connection counts as lost (ENet). A server killed without a goodbye (SIGTERM, a crash) is noticed by clients this fast, and a join that gets no answer gives up after this long. |
| `rgd/network/max_rewind` | `0.5` | Game.rewind_raycast() goes back at most this many seconds (lag compensation). |

## Groups

Plain Godot groups; add them from right-click ▸ RGD in the Scene dock or the Groups tab.

| Group | Effect |
|---|---|
| `local` | The node and its children exist only on clients (every client); never replicated, never on a dedicated server. Their scripts run on clients. |
| `server_only` | Never sent to clients; removed from client exports. Their scripts run on the server. |
| `persistent` | With streaming on, a top-level world node in this group is always sent to every client. |
| `spawn_point` | Characters spawn at these nodes (Node3D or Node2D), round-robin. |

## Where scripts run

| Script | On a level node | Inside the player scene |
|---|---|---|
| `name.gd` | server | that player's machine |
| `name.local.gd` | every client | every client |
| `name.server.gd` | server | server |
| `name.shared.gd` | server + every client | server + that player's machine |
| `extends RemoteEvent`, `RemoteFunction` or `Player` (no suffix) | server + every client | server + every client |

A host (and single player) is both server and client, so both kinds run there. Scripts on nodes your own code instantiates run where they were created (only the suffixes and groups apply).

## Level metadata

| Metadata on the level's root | Overrides |
|---|---|
| `rgd_player_scene` | `rgd/player_scene` while this level is loaded |
| `rgd_menu_scene` | `rgd/menu_scene` while this level is loaded |

## Script constants

| Constant in a script | Effect |
|---|---|
| `const RGD_NO_REPLICATE := ["name", ...]` | Those public variables don't replicate. |

## Command line and environment

Arguments go after `--` (they're your game's arguments, not Godot's): `godot --headless --path . res://addons/rgd/runtime/boot.tscn -- --rgd-role=server`.

| Argument | Environment | Meaning |
|---|---|---|
| `--rgd-role=server\|host\|client\|solo` | | Start a session at launch (dedicated-server exports default to `server`). |
| `--rgd-address=host:port` | | Where to connect (client) or which port to use (server: `:7000`). |
| `--rgd-port=7000` | `RGD_PORT` | The port (otherwise `rgd/network/port`, 7777). |
| `--rgd-scene=res://...` | `RGD_SCENE` | The level (otherwise `rgd/server_scene`, then the main scene). |
| `--rgd-name=Name` | | Display name when joining. |
| `--rgd-data={"token":"..."}` | | Join data (JSON), see `Game.join`. |
| `--rgd-netstats[=seconds]` | | Print network stats to the log. |
| `--rgd-parent-beat=<file>` | | Set by `Game.start_local_server`: shut down when the game that started this server deletes that file or stops updating it (it quit or crashed). |
