class_name ScriptContext
## Decides where a script runs (plan 6.5). One table, used by stripping, the export plugin and
## the editor's script icons.
##
## | Script            | World node          | Inside the player scene     |
## |-------------------|---------------------|-----------------------------|
## | name.gd           | server              | owning client               |
## | name.local.gd     | every client        | every client                |
## | name.server.gd    | server              | server                      |
## | name.shared.gd    | server + clients    | server + owning client      |
## | node in `local`   | every client        | every client                |
## | node in `server_only` | server          | server                      |
##
## A script that extends RGD's [RemoteEvent], [RemoteFunction] or [Player] (no suffix) runs
## on the server and every client: one script holds both sides of the remote or the player.

## Bits of a run mask.
const SERVER := 1
## Run-mask bit: the client of the player whose player scene holds the node.
const OWNER := 2
## Run-mask bit: every other client.
const OTHER_CLIENTS := 4
## Run mask: every client (owner and others).
const CLIENTS := OWNER | OTHER_CLIENTS
## Run mask: the server and every client.
const EVERYWHERE := SERVER | OWNER | OTHER_CLIENTS

## The `local` group: client-only nodes.
const GROUP_LOCAL := &"local"
## The `server_only` group: nodes that never leave the server.
const GROUP_SERVER_ONLY := &"server_only"

## Scripts under here (addons) run everywhere.
const ADDON_DIR := "res://addons/"
## RGD classes whose subclasses run on both sides by default, by script path.
const RGD_CLASSES := {
	"res://addons/rgd/runtime/player.gd": &"Player",
	"res://addons/rgd/runtime/remote_event.gd": &"RemoteEvent",
	"res://addons/rgd/runtime/remote_function.gd": &"RemoteFunction",
}

static var _rgd_base_cache := {}


## &"Player", &"RemoteEvent", &"RemoteFunction" if the script at [param path] extends one of
## them (directly or through other scripts), else &"".
static func rgd_base(path: String) -> StringName:
	if path == "" or path.begins_with(ADDON_DIR):
		return RGD_CLASSES.get(path, &"")
	if _rgd_base_cache.has(path):
		return _rgd_base_cache[path]
	var found := &""
	var s: Script = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	while s != null:
		if RGD_CLASSES.has(s.resource_path):
			found = RGD_CLASSES[s.resource_path]
			break
		s = s.get_base_script()
	_rgd_base_cache[path] = found
	return found


## Where a script runs, as a mask of [constant SERVER], [constant OWNER], [constant OTHER_CLIENTS].
## [param group] is [constant GROUP_LOCAL], [constant GROUP_SERVER_ONLY] or &"" (from the node or
## an ancestor). With [param explicit_only], an unsuffixed script runs wherever it was created
## (used for nodes the game instantiates itself at runtime).
static func run_mask(script_path: String, in_player_scene: bool, group: StringName = &"", explicit_only := false) -> int:
	if script_path.begins_with(ADDON_DIR):
		return EVERYWHERE
	if group == GROUP_SERVER_ONLY:
		return SERVER
	if group == GROUP_LOCAL:
		return CLIENTS
	match suffix_of(script_path):
		"server":
			return SERVER
		"local":
			return CLIENTS  # every client, in the world and in the player scene alike
		"shared":
			return (SERVER | OWNER) if in_player_scene else EVERYWHERE
	if explicit_only:
		return EVERYWHERE
	if rgd_base(script_path) != &"":
		return EVERYWHERE  # extends RemoteEvent / RemoteFunction / Player: both sides
	return OWNER if in_player_scene else SERVER


## True if the script should run in this process.
## [param is_owner]: this process is the client of the player whose player scene holds the node.
static func runs_here(script_path: String, in_player_scene: bool, group: StringName, is_server: bool, is_client: bool, is_owner: bool, explicit_only := false) -> bool:
	return mask_runs_here(run_mask(script_path, in_player_scene, group, explicit_only), in_player_scene, is_server, is_client, is_owner)


## True if a script with run mask [param mask] runs on this machine.
static func mask_runs_here(mask: int, in_player_scene: bool, is_server: bool, is_client: bool, is_owner: bool) -> bool:
	if is_server and mask & SERVER:
		return true
	if is_client:
		if in_player_scene:
			return bool(mask & (OWNER if is_owner else OTHER_CLIENTS))
		return bool(mask & CLIENTS)
	return false


## "server", "local", "shared" or "" for `door.server.gd` etc.
static func suffix_of(script_path: String) -> String:
	var file := script_path.get_file()
	var parts := file.split(".")
	if parts.size() >= 3:
		var s := parts[parts.size() - 2]
		if s in ["server", "local", "shared"]:
			return s
	return ""


## Human-readable "Runs on: ..." text for tooltips.
static func describe(mask: int, in_player_scene: bool) -> String:
	var where: PackedStringArray = []
	if mask & SERVER:
		where.append("server")
	if in_player_scene:
		if mask & OWNER:
			where.append("owning client")
		if mask & OTHER_CLIENTS:
			where.append("other clients")
	elif mask & CLIENTS:
		where.append("every client")
	return "Runs on: " + (", ".join(where) if where else "nowhere")


## The group that decides a node's context: the node's own or an ancestor's `local` /
## `server_only` group. Works on nodes outside the tree.
static func group_of(node: Node, stop_at: Node = null) -> StringName:
	var n := node
	while n != null and n != stop_at:
		if n.is_in_group(GROUP_SERVER_ONLY):
			return GROUP_SERVER_ONLY
		if n.is_in_group(GROUP_LOCAL):
			return GROUP_LOCAL
		n = n.get_parent()
	return &""


## The nearest script in [param script]'s inheritance chain that runs here, or null.
## A stripped `my_player.gd extends Player` falls back to RGD's `Player` script.
static func script_that_runs_here(script: Script, in_player_scene: bool, group: StringName, is_server: bool, is_client: bool, is_owner: bool, explicit_only := false) -> Script:
	var s := script
	while s != null:
		if runs_here(s.resource_path, in_player_scene, group, is_server, is_client, is_owner, explicit_only):
			return s
		s = s.get_base_script()
	return null
