class_name RGDInstancer
## RGD-owned instantiation (plan 4, "Core invariant"). Scenes are instantiated, then walked
## *before* add_child: nodes and scripts that don't belong on this side are removed, so
## their `_ready`, `_process` etc. never run here.
##
## A context is a Dictionary: {is_server, is_client, in_player_scene, is_owner}.

## Metadata on a node whose script was removed on this machine: the original script's path.
const META_STRIPPED := &"rgd_stripped_script"
## Metadata on a player scene's root: the peer id of the player it belongs to.
const META_CTX_OWNER := &"rgd_ctx_owner"


## A stripping context: which side this machine is, and for player scenes whether this
## machine owns the player.
static func make_ctx(is_server: bool, is_client: bool, in_player_scene := false, is_owner := false) -> Dictionary:
	return {is_server = is_server, is_client = is_client, in_player_scene = in_player_scene, is_owner = is_owner}


## Instantiates [param packed] and strips it for [param ctx].
static func instantiate(packed: PackedScene, ctx: Dictionary) -> Node:
	var root := packed.instantiate()
	if root == null:
		return null
	strip(root, ctx)
	return root


## Removes the nodes and scripts under [param root] that don't belong on [param ctx]'s side
## (a foreign player's `ui`, `local`/`server_only` branches, scripts per plan 6.5).
static func strip(root: Node, ctx: Dictionary) -> void:
	if ctx.in_player_scene:
		_strip_foreign_ui(root, ctx)
	_strip_node(root, root, ctx, &"")
	_drop_dead_connections(root, root)


## Signal connections made in the editor (Node ▸ Signals) to a method whose script doesn't run
## on this machine would fail with "method not found" when emitted. Remove them here: e.g. a
## RemoteEvent's on_server_event connected to the level script is only kept on the server.
static func _drop_dead_connections(n: Node, root: Node) -> void:
	for sig in n.get_signal_list():
		for c in n.get_signal_connection_list(sig.name):
			if not (c.flags & Object.CONNECT_PERSIST):
				continue
			var cb: Callable = c.callable
			var target := cb.get_object()
			if target is Node and (target == root or root.is_ancestor_of(target)) and not target.has_method(cb.get_method()):
				n.disconnect(sig.name, cb)
	for ch in n.get_children():
		_drop_dead_connections(ch, root)


## The player's `ui` subtree only exists on the owning client.
static func _strip_foreign_ui(root: Node, ctx: Dictionary) -> void:
	if ctx.is_client and ctx.is_owner:
		return
	var ui = root.get(&"ui")
	if ui is Node and is_instance_valid(ui) and ui != root:
		ui.get_parent().remove_child(ui)
		ui.free()
		root.set(&"ui", null)


static func _strip_node(n: Node, root: Node, ctx: Dictionary, inherited: StringName) -> void:
	var group := inherited
	if group == &"":
		if n.is_in_group(ScriptContext.GROUP_SERVER_ONLY):
			group = ScriptContext.GROUP_SERVER_ONLY
		elif n.is_in_group(ScriptContext.GROUP_LOCAL):
			group = ScriptContext.GROUP_LOCAL
	if n != root and _node_removed_here(group, ctx):
		n.get_parent().remove_child(n)
		n.free()
		return
	strip_script(n, ctx, group, false)
	for c in n.get_children():
		_strip_node(c, root, ctx, group)


static func _node_removed_here(group: StringName, ctx: Dictionary) -> bool:
	if group == ScriptContext.GROUP_SERVER_ONLY:
		return not ctx.is_server
	if group == ScriptContext.GROUP_LOCAL:
		return not ctx.is_client
	return false


## Replaces the node's script with the nearest base script that runs here (or none),
## keeping the values of properties the kept script declares. Returns true if it changed.
static func strip_script(n: Node, ctx: Dictionary, group: StringName, explicit_only: bool) -> bool:
	var s: Script = n.get_script()
	if s == null:
		return false
	var keep := ScriptContext.script_that_runs_here(s, ctx.in_player_scene, group, ctx.is_server, ctx.is_client, ctx.is_owner, explicit_only)
	if keep == s:
		return false
	var saved := {}
	if keep != null:
		for p in keep.get_script_property_list():
			if p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
				saved[p.name] = n.get(p.name)
	n.set_script(keep)
	for k in saved:
		n.set(k, saved[k])
	n.set_meta(META_STRIPPED, s.resource_path)
	return true
