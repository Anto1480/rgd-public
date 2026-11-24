@tool
extends Node
## Script icons by what the script extends, tinted by where it runs (plan 6.5): blue =
## clients (local), green = server, teal = both. A script that extends Player / RemoteEvent /
## RemoteFunction (directly or not) shows RGD's icon for it; any other script shows the icon
## of the Godot class it extends (CharacterBody2D, Node3D...), suffix or not. FileSystem dock: based on where the script is attached (scene scan).
## Scene dock: based on the node's actual context. Tooltips say "Runs on: ...".
## Best effort: it decorates the editor's own trees and quietly does nothing if their
## layout changes.

## Tint for scripts that run on the server only (green).
const SERVER_COLOR := Color(0.45, 0.95, 0.5)
## Tint for scripts that run on clients only (blue).
const CLIENT_COLOR := Color(0.45, 0.65, 1.0)
## Tint for scripts that run on both (teal).
const BOTH_COLOR := Color(0.4, 0.9, 0.9)

## Icons for scripts extending RGD's classes, by class name.
const RGD_ICONS := {
	&"Player": "res://addons/rgd/icons/player.svg",
	&"RemoteEvent": "res://addons/rgd/icons/remote_event.svg",
	&"RemoteFunction": "res://addons/rgd/icons/remote_function.svg",
}

# Untyped on purpose: when the editor hot-reloads this @tool script, an existing plugin
# instance keeps its old fields and new ones start as null (see icon_for).
var _icons = {}  # script path -> [modified time, Texture2D or null]
var _usage: RGDScriptUsage
var _usage_dirty := true
var _timer := 0.0


func _ready() -> void:
	var fs := EditorInterface.get_resource_filesystem()
	fs.filesystem_changed.connect(_mark_dirty)
	fs.resources_reimported.connect(_mark_dirty.unbind(1))


func _exit_tree() -> void:
	var fs := EditorInterface.get_resource_filesystem()
	if fs.filesystem_changed.is_connected(_mark_dirty):
		fs.filesystem_changed.disconnect(_mark_dirty)
	for c in fs.resources_reimported.get_connections():
		if c.callable.get_object() == self:
			fs.resources_reimported.disconnect(c.callable)


func _mark_dirty() -> void:
	_usage_dirty = true


func _process(delta: float) -> void:
	_timer += delta
	if _timer < 1.0:
		return
	_timer = 0.0
	if _usage_dirty:
		_usage_dirty = false
		var scenes := RGDScriptUsage.find_scenes("res://")
		_usage = RGDScriptUsage.scan(scenes, RGDScriptUsage.guess_worlds(scenes))
	_decorate_filesystem()
	_decorate_scene_tree()


## Icon tint for a run mask (see [ScriptContext]): server, clients, or both.
static func color_for(mask: int) -> Color:
	var server := mask & ScriptContext.SERVER != 0
	var client := mask & ScriptContext.CLIENTS != 0
	if server and client:
		return BOTH_COLOR
	if server:
		return SERVER_COLOR
	if client:
		return CLIENT_COLOR
	return Color.WHITE


## What a script's icon shows: an RGD class name (Player, RemoteEvent, RemoteFunction) or the
## Godot class it extends ("CharacterBody2D"), "" if unknown.
static func icon_name_for(path: String) -> StringName:
	var rgd := ScriptContext.rgd_base(path)
	if rgd != &"":
		return rgd
	var s: Script = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
	return s.get_instance_base_type() if s else &""


## The icon for a script file (cached until the file changes).
func icon_for(path: String) -> Texture2D:
	if not _icons is Dictionary:
		_icons = {}
	var mtime := FileAccess.get_modified_time(path)
	var hit: Array = _icons.get(path, [])
	if not hit.is_empty() and hit[0] == mtime:
		return hit[1]
	ScriptContext._rgd_base_cache.erase(path)
	var nm := icon_name_for(path)
	var tex: Texture2D = null
	if RGD_ICONS.has(nm):
		tex = load(RGD_ICONS[nm])
	elif nm != &"":
		var theme := EditorInterface.get_editor_theme()
		if theme.has_icon(nm, &"EditorIcons"):
			tex = theme.get_icon(nm, &"EditorIcons")
	_icons[path] = [mtime, tex]
	return tex


## Mask for a script file shown in the FileSystem dock.
func file_mask(path: String) -> int:
	if path.begins_with(ScriptContext.ADDON_DIR):
		return 0
	if _usage and _usage.is_attached(path):
		return _usage.mask_of(path)
	if ScriptContext.suffix_of(path) != "":
		return ScriptContext.run_mask(path, false)
	return 0  # unattached plain script: helper code, runs wherever it's called


func _decorate_filesystem() -> void:
	var dock := EditorInterface.get_file_system_dock()
	if dock == null:
		return
	for tree: Tree in dock.find_children("*", "Tree", true, false):
		var item := tree.get_root()
		while item:
			var meta = item.get_metadata(0)
			if meta is String and (meta as String).ends_with(".gd"):
				var icon := icon_for(meta)
				if icon and item.get_icon(0) != icon:
					item.set_icon(0, icon)
				_tint_item(item, file_mask(meta), _usage != null and _usage.mostly_player(meta))
			item = item.get_next_in_tree()
	for list: ItemList in dock.find_children("*", "ItemList", true, false):
		for i in list.item_count:
			var meta = list.get_item_metadata(i)
			if meta is String and (meta as String).ends_with(".gd"):
				var icon := icon_for(meta)
				if icon and list.get_item_icon(i) != icon:
					list.set_item_icon(i, icon)
				var mask := file_mask(meta)
				if mask != 0:
					list.set_item_icon_modulate(i, color_for(mask))
					list.set_item_tooltip(i, "%s\n%s" % [meta, ScriptContext.describe(mask, _usage.mostly_player(meta) if _usage else false)])


func _tint_item(item: TreeItem, mask: int, in_player: bool) -> void:
	if mask == 0:
		return
	item.set_icon_modulate(0, color_for(mask))
	var tip := ScriptContext.describe(mask, in_player)
	if not item.get_tooltip_text(0).ends_with(tip):
		item.set_tooltip_text(0, "%s\n%s" % [item.get_metadata(0), tip])


func _decorate_scene_tree() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return
	var in_player := root.scene_file_path == String(ProjectSettings.get_setting(RGDSettings.PLAYER_SCENE, "")) \
		or (_usage != null and _usage.player_scenes.has(root.scene_file_path))
	var dock := EditorInterface.get_base_control().find_child("Scene", true, false)
	if dock == null:
		return
	for tree: Tree in dock.find_children("*", "Tree", true, false):
		var item := tree.get_root()
		while item:
			var meta = item.get_metadata(0)
			if meta is NodePath:
				var node := root.get_node_or_null(meta) if String(meta) != "." else root
				if node == null:
					node = root.get_parent().get_node_or_null(meta) if root.get_parent() else null
				if node and node.get_script():
					var path: String = node.get_script().resource_path
					var mask := ScriptContext.run_mask(path, in_player, ScriptContext.group_of(node, root.get_parent()))
					# The node's own icon: RGD's for Player / RemoteEvent / RemoteFunction subclasses.
					var rgd := ScriptContext.rgd_base(path)
					if RGD_ICONS.has(rgd):
						var icon := icon_for(path)
						if icon and item.get_icon(0) != icon:
							item.set_icon(0, icon)
					for b in item.get_button_count(0):
						if item.get_button_tooltip_text(0, b).begins_with("Open Script"):
							item.set_button_color(0, b, color_for(mask))
							item.set_button_tooltip_text(0, b, "Open Script: %s\n%s" % [path, ScriptContext.describe(mask, in_player)])
			item = item.get_next_in_tree()
