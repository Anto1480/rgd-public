@tool
extends EditorContextMenuPlugin
## Right-click ▸ RGD in the Scene dock: mark nodes `local` / `server_only` (plain Godot
## groups, plan D18) and create the player scene from a template.

## Menu id: put the selection in the `local` group.
const ID_LOCAL := 0
## Menu id: put the selection in the `server_only` group.
const ID_SERVER_ONLY := 1
## Menu id: back to replicated (no RGD group).
const ID_CLEAR := 2
## Menu id: toggle the `persistent` group.
const ID_PERSISTENT := 3
## Menu id: New Player Scene (3D).
const ID_NEW_PLAYER := 10
## Menu id: New Player Scene (2D).
const ID_NEW_PLAYER_2D := 11

## The editor's undo/redo, so group changes can be undone.
var undo: EditorUndoRedoManager


func _popup_menu(_paths: PackedStringArray) -> void:
	var menu := PopupMenu.new()
	var nodes := EditorInterface.get_selection().get_selected_nodes()
	var all_local := not nodes.is_empty() and nodes.all(func(n): return n.is_in_group(ScriptContext.GROUP_LOCAL))
	var all_server := not nodes.is_empty() and nodes.all(func(n): return n.is_in_group(ScriptContext.GROUP_SERVER_ONLY))
	menu.add_check_item("Local (clients only, never replicated)", ID_LOCAL)
	menu.set_item_checked(menu.get_item_index(ID_LOCAL), all_local)
	menu.set_item_tooltip(menu.get_item_index(ID_LOCAL), "Adds the node to the `local` group: it and its children exist only on clients and the server ignores them.")
	menu.add_check_item("Server only (never sent to clients)", ID_SERVER_ONLY)
	menu.set_item_checked(menu.get_item_index(ID_SERVER_ONLY), all_server)
	menu.set_item_tooltip(menu.get_item_index(ID_SERVER_ONLY), "Adds the node to the `server_only` group: never sent to clients and removed from client exports.")
	menu.add_item("Replicated (default)", ID_CLEAR)
	var all_persistent := not nodes.is_empty() and nodes.all(func(n): return n.is_in_group(RGDReplicator.GROUP_PERSISTENT))
	menu.add_check_item("Persistent (never streams out)", ID_PERSISTENT)
	menu.set_item_checked(menu.get_item_index(ID_PERSISTENT), all_persistent)
	menu.set_item_tooltip(menu.get_item_index(ID_PERSISTENT), "Adds the node to the `persistent` group: with streaming on (rgd/streaming/radius), a top-level world node in this group is always sent to every client.")
	menu.add_separator()
	menu.add_item("New Player Scene (3D)...", ID_NEW_PLAYER)
	menu.add_item("New Player Scene (2D)...", ID_NEW_PLAYER_2D)
	menu.id_pressed.connect(_on_id.bind(nodes))
	add_context_submenu_item("RGD", menu, EditorInterface.get_editor_theme().get_icon(&"MultiplayerSpawner", &"EditorIcons"))


func _on_id(id: int, nodes: Array) -> void:
	match id:
		ID_LOCAL:
			_set_group(nodes, ScriptContext.GROUP_LOCAL)
		ID_SERVER_ONLY:
			_set_group(nodes, ScriptContext.GROUP_SERVER_ONLY)
		ID_CLEAR:
			_set_group(nodes, &"")
		ID_PERSISTENT:
			_toggle_group(nodes, RGDReplicator.GROUP_PERSISTENT)
		ID_NEW_PLAYER:
			RGDPlayerTemplate.create_and_open(RGDPlayerTemplate.Kind.PLAYER_3D)
		ID_NEW_PLAYER_2D:
			RGDPlayerTemplate.create_and_open(RGDPlayerTemplate.Kind.PLAYER_2D)


## Puts [param nodes] in exactly one of the RGD groups (or none), with undo.
func _set_group(nodes: Array, group: StringName) -> void:
	if nodes.is_empty() or undo == null:
		return
	undo.create_action("RGD: mark %s" % (group if group != &"" else "replicated"))
	for n: Node in nodes:
		for g in [ScriptContext.GROUP_LOCAL, ScriptContext.GROUP_SERVER_ONLY]:
			var has: bool = n.is_in_group(g)
			var want: bool = g == group
			if has and not want:
				undo.add_do_method(n, &"remove_from_group", g)
				undo.add_undo_method(n, &"add_to_group", g, true)
			elif want and not has:
				undo.add_do_method(n, &"add_to_group", g, true)
				undo.add_undo_method(n, &"remove_from_group", g)
	undo.add_do_method(EditorInterface, &"mark_scene_as_unsaved")
	undo.add_undo_method(EditorInterface, &"mark_scene_as_unsaved")
	undo.commit_action()


## Adds [param group] to every node in [param nodes], or removes it if they all have it.
func _toggle_group(nodes: Array, group: StringName) -> void:
	if nodes.is_empty() or undo == null:
		return
	var remove := nodes.all(func(n): return n.is_in_group(group))
	undo.create_action("RGD: %s %s" % ["unmark" if remove else "mark", group])
	for n: Node in nodes:
		if remove:
			undo.add_do_method(n, &"remove_from_group", group)
			undo.add_undo_method(n, &"add_to_group", group, true)
		elif not n.is_in_group(group):
			undo.add_do_method(n, &"add_to_group", group, true)
			undo.add_undo_method(n, &"remove_from_group", group)
	undo.add_do_method(EditorInterface, &"mark_scene_as_unsaved")
	undo.add_undo_method(EditorInterface, &"mark_scene_as_unsaved")
	undo.commit_action()
