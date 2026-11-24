@tool
class_name RGDScriptUsage
## Where scripts are attached, from scanning scene files (no scripts run). Each attachment is
## (script path, inside the player scene?, `local`/`server_only` group, explicit only?).
## Instanced sub-scenes inherit the context they're instanced in.
##
## Contexts: the player scene; **world** scenes (full 6.5 table: plain scripts run on the
## server); every other scene is **neutral** (a menu, or something the game instantiates
## itself): only the explicit rules apply there (`.server.gd`, `.local.gd`, groups), because at
## runtime a plain script runs wherever its scene was created.

## script path -> Array of [in_player_scene: bool, group: StringName, explicit_only: bool]
var attachments := {}
## scene path -> true if it is (or is instanced inside) the player scene
var player_scenes := {}
## scene path -> true if it is (or is instanced inside) a world scene
var world_scenes := {}
## scene path -> true if it was visited as a neutral scene
var neutral_scenes := {}
var _visited := {}


## Scans the player scene, [param worlds], and [param scene_paths] (default: every scene in
## the project outside addons/) as neutral scenes.
static func scan(scene_paths: PackedStringArray = PackedStringArray(), worlds: PackedStringArray = PackedStringArray()) -> RGDScriptUsage:
	var u := RGDScriptUsage.new()
	if scene_paths.is_empty():
		scene_paths = find_scenes("res://")
	var player: String = ProjectSettings.get_setting(RGDSettings.PLAYER_SCENE, "")
	if player != "":
		u._visit(player, true, &"", false)
	for w in worlds:
		u._visit(w, false, &"", false)
	for p in scene_paths:
		if not u.player_scenes.has(p) and not u.world_scenes.has(p):
			u._visit(p, false, &"", true)
	return u


## A guess at which scenes are worlds (for editor hints only, never for stripping): scenes
## whose root is a Node3D/Node2D, other than the main scene and the menu scene.
static func guess_worlds(scene_paths: PackedStringArray) -> PackedStringArray:
	var out: PackedStringArray = []
	var skip := [ProjectSettings.get_setting("application/run/main_scene", ""),
		ProjectSettings.get_setting(RGDSettings.MENU_SCENE, ""),
		ProjectSettings.get_setting(RGDSettings.PLAYER_SCENE, "")]
	for p in scene_paths:
		if p in skip or not ResourceLoader.exists(p):
			continue
		var packed := load(p) as PackedScene
		if packed == null:
			continue
		var st := packed.get_state()
		if st.get_node_count() == 0:
			continue
		var t := st.get_node_type(0)
		if t == &"" and st.get_node_instance(0):
			continue  # inherited scene: skip the guess
		if ClassDB.is_parent_class(t, &"Node3D") or ClassDB.is_parent_class(t, &"Node2D"):
			out.append(p)
	return out


## Every .tscn/.scn under [param dir], recursively. Skips hidden folders and res://addons.
static func find_scenes(dir: String) -> PackedStringArray:
	var out: PackedStringArray = []
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".tscn") or f.ends_with(".scn"):
			out.append(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		if d.begins_with(".") or (dir == "res://" and d == "addons"):
			continue
		out.append_array(find_scenes(dir.path_join(d)))
	return out


## Run mask (ScriptContext bits) of [param script_path] over all its attachments; 0 if it
## isn't attached anywhere.
func mask_of(script_path: String) -> int:
	var m := 0
	for a in attachments.get(script_path, []):
		m |= ScriptContext.run_mask(script_path, a[0], a[1], a[2])
	return m


## True if any scene in the project attaches [param script_path] to a node.
func is_attached(script_path: String) -> bool:
	return attachments.has(script_path)


## True if the script runs on some client somewhere.
func runs_on_client(script_path: String) -> bool:
	return mask_of(script_path) & ScriptContext.CLIENTS != 0


## Mostly inside the player scene? (for icons/tooltips)
func mostly_player(script_path: String) -> bool:
	var a: Array = attachments.get(script_path, [])
	return not a.is_empty() and a.all(func(x): return x[0])


func _visit(scene_path: String, in_player: bool, group: StringName, explicit: bool) -> void:
	var key := "%s|%s|%s|%s" % [scene_path, in_player, group, explicit]
	if _visited.has(key) or not ResourceLoader.exists(scene_path):
		return
	_visited[key] = true
	if in_player:
		player_scenes[scene_path] = true
	elif explicit:
		neutral_scenes[scene_path] = true
	else:
		world_scenes[scene_path] = true
	var packed := load(scene_path) as PackedScene
	if packed == null:
		return
	var state := packed.get_state()
	var groups_by_path := {}
	for i in state.get_node_count():
		var path := String(state.get_node_path(i))
		var g := _parent_group(groups_by_path, path, group)
		for ng in state.get_node_groups(i):
			if ng == ScriptContext.GROUP_SERVER_ONLY:
				g = ScriptContext.GROUP_SERVER_ONLY
			elif ng == ScriptContext.GROUP_LOCAL and g == &"":
				g = ScriptContext.GROUP_LOCAL
		groups_by_path[path] = g
		for p in state.get_node_property_count(i):
			if state.get_node_property_name(i, p) == &"script":
				var s = state.get_node_property_value(i, p)
				if s is Script and s.resource_path != "":
					_add(s, in_player, g, explicit)
		var inst := state.get_node_instance(i)
		if inst:
			_visit(inst.resource_path, in_player, g, explicit)


func _add(s: Script, in_player: bool, g: StringName, explicit: bool) -> void:
	var list: Array = attachments.get_or_add(s.resource_path, [])
	var entry := [in_player, g, explicit and not in_player]
	if not list.has(entry):
		list.append(entry)


func _parent_group(groups_by_path: Dictionary, path: String, root_group: StringName) -> StringName:
	if path == ".":
		return root_group
	var slash := path.rfind("/")
	var parent := "." if slash < 0 else path.substr(0, slash)
	return groups_by_path.get(parent, root_group)
