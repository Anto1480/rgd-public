class_name RGDSettings
## Project settings used by RGD. All of them live under `rgd/` in Project Settings.

## The player scene: root is a [Player] with a `character` and a `ui` (plan 6.2). A level can
## use its own with `rgd_player_scene` metadata on its root node.
const PLAYER_SCENE := "rgd/player_scene"
## The world a dedicated server loads when it starts by itself (a dedicated-server export, or
## `--rgd-role=server` without `--rgd-scene`). Empty = the main scene.
const SERVER_SCENE := "rgd/server_scene"
## Scene to return to when a session ends (empty = stay). A level can override it with
## `rgd_menu_scene` metadata on its root node.
const MENU_SCENE := "rgd/menu_scene"
## Make display names unique when players join: a second "Bob" becomes "Bob2".
const UNIQUE_NAMES := "rgd/players/unique_names"
## Spawn a Player for everyone who joins. Off: call it yourself.
const AUTO_SPAWN := "rgd/players/auto_spawn"
## Network ticks per second (property diffs and transform streams).
const TICK_RATE := "rgd/network/tick_rate"
## Seconds clients stay behind the server's stream so movement interpolates smoothly.
const INTERPOLATION_DELAY := "rgd/network/interpolation_delay"
## The game's port: what Game.host / start_server / join / start_local_server use when you
## don't give one (port 0, or an address without ":port"). The RGD_PORT environment variable
## overrides it.
const PORT := "rgd/network/port"
## Players allowed at once; more are rejected with "server is full".
const MAX_PLAYERS := "rgd/network/max_players"
## A jump larger than this (3D units) snaps instead of interpolating.
const TELEPORT_DISTANCE := "rgd/network/teleport_distance"
## A jump larger than this (pixels) snaps instead of interpolating.
const TELEPORT_DISTANCE_2D := "rgd/network/teleport_distance_2d"
## Streaming (plan 6.10): radius around each player's character; 0 = off (send everything).
const STREAMING_RADIUS := "rgd/streaming/radius"
## Streaming radius for 2D worlds (pixels); 0 = off.
const STREAMING_RADIUS_2D := "rgd/streaming/radius_2d"
## KB/s per client for the transform stream; 0 = unlimited.
const BANDWIDTH_LIMIT := "rgd/network/bandwidth_limit_kb"
## Transport for Game.host / start_server / join: "enet" (UDP, default) or "websocket"
## (TCP; works in web exports and through HTTP proxies). Any other MultiplayerPeer (Steam,
## WebRTC) goes through Game.host_with_peer / start_server_with_peer / join_with_peer.
const TRANSPORT := "rgd/network/transport"
## Seconds without hearing from the other side before a connection counts as lost (ENet). A
## server killed without a goodbye (SIGTERM, a crash) is noticed by clients this fast, and a
## join that gets no answer gives up after this long.
const TIMEOUT := "rgd/network/timeout"
## Game.rewind_raycast() goes back at most this many seconds (lag compensation).
const MAX_REWIND := "rgd/network/max_rewind"

const _DEFS := [
	[PLAYER_SCENE, "", TYPE_STRING, PROPERTY_HINT_FILE, "*.tscn,*.scn"],
	[SERVER_SCENE, "", TYPE_STRING, PROPERTY_HINT_FILE, "*.tscn,*.scn"],
	[MENU_SCENE, "", TYPE_STRING, PROPERTY_HINT_FILE, "*.tscn,*.scn"],
	[AUTO_SPAWN, true, TYPE_BOOL, PROPERTY_HINT_NONE, ""],
	[UNIQUE_NAMES, true, TYPE_BOOL, PROPERTY_HINT_NONE, ""],
	[PORT, 7777, TYPE_INT, PROPERTY_HINT_RANGE, "1,65535"],
	[TICK_RATE, 30, TYPE_INT, PROPERTY_HINT_RANGE, "1,128"],
	[INTERPOLATION_DELAY, 0.1, TYPE_FLOAT, PROPERTY_HINT_RANGE, "0,1,0.01"],
	[MAX_PLAYERS, 32, TYPE_INT, PROPERTY_HINT_RANGE, "1,4095"],
	[TELEPORT_DISTANCE, 8.0, TYPE_FLOAT, PROPERTY_HINT_RANGE, "0,1000,0.1"],
	[TELEPORT_DISTANCE_2D, 256.0, TYPE_FLOAT, PROPERTY_HINT_RANGE, "0,100000,1"],
	[STREAMING_RADIUS, 0.0, TYPE_FLOAT, PROPERTY_HINT_RANGE, "0,10000,1,or_greater"],
	[STREAMING_RADIUS_2D, 0.0, TYPE_FLOAT, PROPERTY_HINT_RANGE, "0,1000000,1,or_greater"],
	[BANDWIDTH_LIMIT, 0, TYPE_INT, PROPERTY_HINT_RANGE, "0,100000,1,or_greater,suffix:KB/s"],
	[MAX_REWIND, 0.5, TYPE_FLOAT, PROPERTY_HINT_RANGE, "0,2,0.01,suffix:s"],
	[TRANSPORT, "enet", TYPE_STRING, PROPERTY_HINT_ENUM, "enet,websocket"],
	[TIMEOUT, 8.0, TYPE_FLOAT, PROPERTY_HINT_RANGE, "1,60,0.5,suffix:s"],
]


## Adds every RGD setting (with its default) so it shows up in Project Settings.
static func register() -> void:
	for d in _DEFS:
		if not ProjectSettings.has_setting(d[0]):
			ProjectSettings.set_setting(d[0], d[1])
		ProjectSettings.set_initial_value(d[0], d[1])
		ProjectSettings.add_property_info({name = d[0], type = d[2], hint = d[3], hint_string = d[4]})
		ProjectSettings.set_as_basic(d[0], true)


## The value of an RGD setting, or its default if the project doesn't set it.
static func get_value(key: String) -> Variant:
	for d in _DEFS:
		if d[0] == key:
			return ProjectSettings.get_setting(key, d[1])
	return ProjectSettings.get_setting(key)
