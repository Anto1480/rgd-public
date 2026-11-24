@tool
extends EditorPlugin
## RGD editor plugin: registers the `Game` autoload and the editor tools (Play Test, the
## right-click RGD menu, script icon tints, the export plugin).

## Name of the autoload the plugin registers: `Game`.
const AUTOLOAD_NAME := "Game"
## Script of the `Game` autoload.
const AUTOLOAD_PATH := "res://addons/rgd/runtime/game.gd"
## The Play Test toolbar control.
const PlayTest := preload("res://addons/rgd/editor/play_test.gd")
## The Scene dock's right-click ▸ RGD menu.
const ContextMenu := preload("res://addons/rgd/editor/rgd_context_menu.gd")
## Script icons and tints in the FileSystem and Scene docks.
const ScriptIcons := preload("res://addons/rgd/editor/script_icons.gd")
## The RGD section of export presets.
const ExportPlugin := preload("res://addons/rgd/editor/export_plugin.gd")
## Descriptions under the RGD settings in Project Settings.
const SettingsHelp := preload("res://addons/rgd/editor/settings_help.gd")
## Project ▸ Tools item: New Player Scene (3D).
const TOOL_NEW_PLAYER := "RGD: New Player Scene (3D)"
## Project ▸ Tools item: New Player Scene (2D).
const TOOL_NEW_PLAYER_2D := "RGD: New Player Scene (2D)"
## Project ▸ Tools item: Update Client Export Filters.
const TOOL_EXPORT_FILTERS := "RGD: Update Client Export Filters"

var _play_test: Control
var _context_menu: EditorContextMenuPlugin
var _script_icons: Node
var _export: EditorExportPlugin
var _settings_help: EditorInspectorPlugin


func _enable_plugin() -> void:
	add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)
	_move_game_autoload_first()


func _disable_plugin() -> void:
	remove_autoload_singleton(AUTOLOAD_NAME)


func _enter_tree() -> void:
	RGDSettings.register()
	_set_server_main_scene()
	_play_test = PlayTest.new()
	add_control_to_container(CONTAINER_TOOLBAR, _play_test)
	_context_menu = ContextMenu.new()
	_context_menu.undo = get_undo_redo()
	add_context_menu_plugin(EditorContextMenuPlugin.CONTEXT_SLOT_SCENE_TREE, _context_menu)
	_script_icons = ScriptIcons.new()
	add_child(_script_icons)
	_export = ExportPlugin.new()
	add_export_plugin(_export)
	_settings_help = SettingsHelp.new()
	add_inspector_plugin(_settings_help)
	add_tool_menu_item(TOOL_NEW_PLAYER, RGDPlayerTemplate.create_and_open.bind(RGDPlayerTemplate.Kind.PLAYER_3D))
	add_tool_menu_item(TOOL_NEW_PLAYER_2D, RGDPlayerTemplate.create_and_open.bind(RGDPlayerTemplate.Kind.PLAYER_2D))
	add_tool_menu_item(TOOL_EXPORT_FILTERS, func(): ExportPlugin.update_client_export_filters())


func _exit_tree() -> void:
	remove_tool_menu_item(TOOL_NEW_PLAYER)
	remove_tool_menu_item(TOOL_NEW_PLAYER_2D)
	remove_tool_menu_item(TOOL_EXPORT_FILTERS)
	if _export:
		remove_export_plugin(_export)
		_export = null
	if _settings_help:
		remove_inspector_plugin(_settings_help)
		_settings_help = null
	if _script_icons:
		_script_icons.queue_free()
		_script_icons = null
	if _context_menu:
		remove_context_menu_plugin(_context_menu)
		_context_menu = null
	if _play_test:
		_play_test.stop()
		remove_control_from_container(CONTAINER_TOOLBAR, _play_test)
		_play_test.queue_free()
		_play_test = null


## Dedicated-server builds start in RGD's empty boot scene (which starts the server), not the
## game's main scene, which is usually a menu, and may not even be set. A feature override:
## only builds with the `dedicated_server` feature see it.
func _set_server_main_scene() -> void:
	const KEY := "application/run/main_scene.dedicated_server"
	if not ProjectSettings.has_setting(KEY):
		ProjectSettings.set_setting(KEY, "res://addons/rgd/runtime/boot.tscn")
		ProjectSettings.save()


## `Game` must load before user autoloads so it can strip `*.server.gd` / `*.local.gd`
## autoloads on the wrong side before their `_ready` (plan 6.5).
func _move_game_autoload_first() -> void:
	var lowest := 0
	for p in ProjectSettings.get_property_list():
		var n: String = p.name
		if n.begins_with("autoload/") and n != "autoload/" + AUTOLOAD_NAME:
			lowest = mini(lowest, ProjectSettings.get_order(n))
	ProjectSettings.set_order("autoload/" + AUTOLOAD_NAME, lowest - 1)
	ProjectSettings.save()
