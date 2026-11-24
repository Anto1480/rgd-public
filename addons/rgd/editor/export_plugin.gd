@tool
extends EditorExportPlugin
## Export options `rgd/role` and `rgd/world_scenes` (plan 6.8). For a **client** export:
## - scenes are rewritten without `server_only` nodes and without scripts that only run on
##   the server: `.server.gd` everywhere, plus plain scripts in the player scene's server
##   parts... and in the scenes listed in `rgd/world_scenes` (plain world scripts run on the
##   server; elsewhere a plain script runs wherever its scene is created, so it's kept),
## - script files that only ever run on the server are left out (unless another kept script
##   could still need them: a base class, a class_name or a path mentioned in kept code).
##   Godot's GDScript exporter handles `.gd` files before any plugin can skip them, so this
##   goes through the preset's exclude filter: Project ▸ Tools ▸ RGD: Update Client Export
##   Filters writes the list (kept in the `rgd/excluded_scripts` option). The export warns
##   when the list is out of date.
## - a report of what was stripped is printed at the end.
## For a **server** export use Godot's "Dedicated Server" export mode as well.

## What an export preset builds: Both (default: everything), Client (server parts left out), Server.
enum Role { BOTH, CLIENT, SERVER }

var _role := Role.BOTH
var _usage: RGDScriptUsage
var _drop := {}  # script path -> true
var _rewritten: PackedStringArray = []
var _dropped: PackedStringArray = []
var _tmp_dir := ""


func _get_name() -> String:
	return "RGD"


func _get_export_options(_platform: EditorExportPlatform) -> Array[Dictionary]:
	return [{
		option = {name = "rgd/role", type = TYPE_INT, hint = PROPERTY_HINT_ENUM, hint_string = "Both,Client,Server"},
		default_value = Role.BOTH,
	}, {
		option = {name = "rgd/world_scenes", type = TYPE_PACKED_STRING_ARRAY, hint = PROPERTY_HINT_TYPE_STRING,
			hint_string = "%d/%d:*.tscn,*.scn" % [TYPE_STRING, PROPERTY_HINT_FILE]},
		default_value = PackedStringArray(),
	}, {
		option = {name = "rgd/excluded_scripts", type = TYPE_PACKED_STRING_ARRAY, usage = PROPERTY_USAGE_STORAGE},
		default_value = PackedStringArray(),
	}]


func _get_export_option_warning(_platform: EditorExportPlatform, option: String) -> String:
	if option == "rgd/role" and get_option("rgd/role") == Role.SERVER:
		return "Also set Resources ▸ Export Mode to \"Export as dedicated server\" to strip visuals."
	if option == "rgd/world_scenes" and get_option("rgd/role") == Role.CLIENT and (get_option("rgd/world_scenes") as PackedStringArray).is_empty():
		return "List your level scenes so plain (server) scripts on world nodes are left out of the client build. Without it only .server.gd scripts and server_only nodes are stripped."
	return ""


func _export_begin(_features: PackedStringArray, _is_debug: bool, _path: String, _flags: int) -> void:
	_role = get_option("rgd/role")
	_rewritten.clear()
	_dropped.clear()
	_drop.clear()
	if _role != Role.CLIENT:
		return
	_tmp_dir = OS.get_cache_dir().path_join("rgd_export_%d" % Time.get_ticks_msec())
	DirAccess.make_dir_recursive_absolute(_tmp_dir)
	_usage = RGDScriptUsage.scan(PackedStringArray(), get_option("rgd/world_scenes"))
	_drop = server_only_scripts(_usage)
	var listed := get_option("rgd/excluded_scripts") as PackedStringArray
	var missing := _drop.keys().filter(func(p): return not listed.has(p))
	if not missing.is_empty():
		push_warning("RGD client export: %d server-only script(s) aren't in this preset's exclude filter yet, so they'll still be packed (unreferenced): %s. Run Project ▸ Tools ▸ RGD: Update Client Export Filters." % [missing.size(), ", ".join(missing)])


## Scripts that are attached somewhere, never run on a client, and that no kept code refers to.
## [param search_dir]: where to look for kept code that might reference a candidate.
static func server_only_scripts(usage: RGDScriptUsage, search_dir := "res://") -> Dictionary:
	var candidates := {}
	for path in usage.attachments:
		if path.begins_with(ScriptContext.ADDON_DIR):
			continue
		if not usage.runs_on_client(path):
			candidates[path] = true
	# Keep anything a kept script could still reference.
	var kept_sources: PackedStringArray = []
	for path in _all_scripts(search_dir):
		if not candidates.has(path):
			kept_sources.append(FileAccess.get_file_as_string(path))
	var kept_text := "\n".join(kept_sources)
	for path in candidates.keys():
		var s := load(path) as Script
		var cls := s.get_global_name() if s else &""
		if path in kept_text or (cls != &"" and String(cls) in kept_text):
			candidates.erase(path)
	return candidates


static func _all_scripts(dir: String) -> PackedStringArray:
	var out: PackedStringArray = []
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".gd"):
			out.append(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		if not d.begins_with("."):
			out.append_array(_all_scripts(dir.path_join(d)))
	return out


func _export_file(path: String, _type: String, _features: PackedStringArray) -> void:
	if _role != Role.CLIENT:
		return
	if _drop.has(path):
		# Only reached when Godot's script exporter didn't handle the file first (e.g. text mode).
		_dropped.append(path)
		skip()
		return
	if (path.ends_with(".tscn") or path.ends_with(".scn")) and not path.begins_with("res://addons/") \
			and (_usage.player_scenes.has(path) or _usage.world_scenes.has(path) or _usage.neutral_scenes.has(path)):
		var bytes := rewrite_scene_for_client(path, _usage, _tmp_dir)
		if not bytes.is_empty():
			_rewritten.append(path)
			add_file(path, bytes, false)
			skip()


## Returns the client version of a scene file, or empty if nothing needed stripping.
static func rewrite_scene_for_client(path: String, usage: RGDScriptUsage, tmp_dir: String) -> PackedByteArray:
	var packed := load(path) as PackedScene
	if packed == null:
		return PackedByteArray()
	var root := packed.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	if root == null:
		return PackedByteArray()
	var in_player: bool = usage != null and usage.player_scenes.has(path)
	# A scene also used as a neutral scene keeps its plain scripts (explicit rules only).
	var explicit: bool = not in_player and (usage == null or usage.neutral_scenes.has(path) or not usage.world_scenes.has(path))
	var ctx := RGDInstancer.make_ctx(false, true, in_player, true)
	var changed := _strip_owned(root, root, ctx, &"", explicit)
	var out := PackedByteArray()
	if changed:
		var repacked := PackedScene.new()
		if repacked.pack(root) == OK:
			var tmp := tmp_dir.path_join(path.get_file())
			if ResourceSaver.save(repacked, tmp) == OK:
				out = FileAccess.get_file_as_bytes(tmp)
	root.free()
	return out


## Strips nodes saved in this scene file (not the internals of instanced sub-scenes; those are
## handled in their own files). Returns true if anything changed.
static func _strip_owned(n: Node, root: Node, ctx: Dictionary, inherited: StringName, explicit: bool) -> bool:
	var changed := false
	var group := inherited
	if group == &"":
		if n.is_in_group(ScriptContext.GROUP_SERVER_ONLY):
			group = ScriptContext.GROUP_SERVER_ONLY
		elif n.is_in_group(ScriptContext.GROUP_LOCAL):
			group = ScriptContext.GROUP_LOCAL
	if n != root and group == ScriptContext.GROUP_SERVER_ONLY and n.owner == root:
		n.get_parent().remove_child(n)
		n.free()
		return true
	if n == root or n.owner == root:
		if RGDInstancer.strip_script(n, ctx, group, explicit):
			n.remove_meta(RGDInstancer.META_STRIPPED)
			changed = true
	for c in n.get_children():
		changed = _strip_owned(c, root, ctx, group, explicit) or changed
	return changed


func _export_end() -> void:
	if _role != Role.CLIENT:
		return
	var excluded := (get_option("rgd/excluded_scripts") as PackedStringArray).size()
	print_rich("[color=#8ef]RGD client export:[/color] rewrote %d scene(s); %d server-only script(s) excluded by the preset filter." % [_rewritten.size(), maxi(excluded, _dropped.size())])
	if (get_option("rgd/world_scenes") as PackedStringArray).is_empty():
		print("  (rgd/world_scenes is empty: plain world scripts were kept. List your levels to leave them out.)")
	for p in _rewritten:
		print("  scene  ", p)
	for p in _dropped:
		print("  -      ", p)
	if _tmp_dir != "":
		for f in DirAccess.get_files_at(_tmp_dir):
			DirAccess.remove_absolute(_tmp_dir.path_join(f))
		DirAccess.remove_absolute(_tmp_dir)


## Project ▸ Tools ▸ RGD: Update Client Export Filters. For every preset with rgd/role =
## Client, puts the server-only scripts in its exclude filter (replacing the previous RGD
## list, keeping the user's own patterns). Returns the number of presets updated.
static func update_client_export_filters(presets_path := "res://export_presets.cfg", search_dir := "res://") -> int:
	var cfg := ConfigFile.new()
	if cfg.load(presets_path) != OK:
		push_warning("RGD: no export presets yet (%s). Add a preset, set RGD ▸ Role to Client, then run this again." % presets_path)
		return 0
	var updated := 0
	for section in cfg.get_sections():
		if not section.ends_with(".options") or int(cfg.get_value(section, "rgd/role", 0)) != Role.CLIENT:
			continue
		var preset := section.trim_suffix(".options")
		var worlds: PackedStringArray = cfg.get_value(section, "rgd/world_scenes", PackedStringArray())
		var drop := server_only_scripts(RGDScriptUsage.scan(PackedStringArray(), worlds), search_dir).keys()
		drop.sort()
		var old: PackedStringArray = cfg.get_value(section, "rgd/excluded_scripts", PackedStringArray())
		var user_patterns: PackedStringArray = []
		for pat in String(cfg.get_value(preset, "exclude_filter", "")).split(",", false):
			var t := pat.strip_edges()
			if t != "" and not old.has(t) and not old.has("res://" + t.trim_prefix("res://")):
				user_patterns.append(t)
		var patterns := user_patterns.duplicate()
		for d in drop:
			patterns.append(d)
		cfg.set_value(preset, "exclude_filter", ", ".join(patterns))
		cfg.set_value(section, "rgd/excluded_scripts", PackedStringArray(drop))
		updated += 1
		print_rich("[color=#8ef]RGD:[/color] preset \"%s\": %d server-only script(s) in the exclude filter." % [cfg.get_value(preset, "name", preset), drop.size()])
	if updated > 0:
		cfg.save(presets_path)
	else:
		push_warning("RGD: no export preset has RGD ▸ Role = Client.")
	return updated
