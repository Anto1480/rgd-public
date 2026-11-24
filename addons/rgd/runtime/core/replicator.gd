class_name RGDReplicator
extends Node
## Replication core (plan 6.3, 6.6). `Game` talks to it through a narrow set of methods so it
## can move to a GDExtension later (D2) without changing the user-facing API.
##
## Server: assigns net ids, polls replicated properties at the network tick, sends spawns,
## placements, despawns, property diffs and transform streams.
## Client: mirrors the server's tree, applies diffs, interpolates transforms, and streams the
## transforms of nodes it owns back to the server.

## Client: the initial state (or the one after change_scene) is fully applied.
signal snapshot_finished
## Client: a node replicated from the server was spawned (still outside the tree).
signal node_spawned(node: Node, ctx_owner: int)

## Message types (see [RGDProtocol]).
const Msg := RGDProtocol.Msg
## Message writer (see [RGDWire]).
const W := RGDWire.Writer
## Message reader (see [RGDWire]).
const R := RGDWire.Reader

## Metadata holding replicated values a node's script doesn't declare (read with Game.get_value).
const META_VALUES := &"rgd_values"
## Metadata that keeps a node (and its children) out of replication, like the player's UI.
const META_NO_REPLICATE := &"rgd_no_replicate"
## Metadata with the peer id that simulates a node (0 = the server).
const META_OWNER := &"rgd_owner"
## [scene_path, sub_path, ctx_owner]: this node is the part at sub_path of a fresh instance.
const META_SPAWN_SCENE := &"rgd_spawn_scene"
## Prefix of the user signals behind Game.changed(node, prop).
const CHANGED_PREFIX := "rgd_changed:"

## Ticks a node must be unchanged before it's polled less often (see the benchmark, 12.4).
const SLEEP_AFTER := 30
## A sleeping node is checked every this many ticks.
const SLEEP_EVERY := 5
## Ticks a moving node must be still before its final transform is sent reliably.
const SETTLE_TICKS := 3

## Streaming (plan 6.10): a top-level node of the world in this group never streams out.
const GROUP_PERSISTENT := &"persistent"
## A unit streams in within the radius and out beyond radius × this (hysteresis).
const STREAM_OUT_FACTOR := 1.25
## Each unit's relevance is re-checked every this many ticks, a slice of the units per tick
## (all of them right after spawns).
const RELEVANCE_EVERY := 5
## Under a bandwidth limit, the transform stream always gets at least this many bytes a tick.
const MIN_STREAM_BYTES := 128
## Built-in properties a player's own machine drives inside its player scene (like Roblox's
## Animator: animations played on your own character replicate).
const OWNER_PROFILE := {&"AnimationPlayer": [&"current_animation", &"speed_scale"],
	&"AnimatedSprite2D": [&"animation", &"speed_scale", &"flip_h", &"flip_v"],
	&"AnimatedSprite3D": [&"animation", &"speed_scale", &"flip_h", &"flip_v"]}
## Properties clients often change on purpose for looks, or that change by themselves
## (an animation ending): no "client changed X" warning for these.
const WRITE_CHECK_EXEMPT := {&"material_override": true, &"modulate": true, &"light_color": true,
	&"light_energy": true, &"current_animation": true, &"speed_scale": true, &"animation": true,
	&"energy": true, &"color": true}


class Rec:
	## The node's net id (the same on every machine).
	var id: int
	## The replicated node.
	var node: Node
	## Parent net id the clients currently use. 0 = not placed yet, -1 = anchor (never placed).
	var parent_id := 0
	## The name clients currently use for it.
	var name: StringName
	## Property names that replicate for this node (profile + public script variables).
	var props: Array = []
	## The last value sent for each property.
	var last := {}
	## 3 = Node3D, 2 = Node2D, 0 = no transform.
	var xkind := 0
	## True once the first transform was sent.
	var xform_init := false
	## The last transform sent.
	var last_xform: Variant
	## Ticks left before the final transform goes out reliably after moving.
	var settle := 0
	## Ticks without changes (sleeping nodes are checked less often).
	var idle := 0
	## The next transform snaps instead of interpolating (Game.teleport).
	var teleport := false
	## The peer that simulates this node (0 = the server).
	var owner_peer := 0
	## The owner changed and clients haven't been told yet.
	var owner_dirty := false
	## Set on spawn roots: what clients need to recreate the node.
	var spawn := {}
	## Set on world-scene nodes: path relative to the world root in the scene file.
	var world_path := ""
	## Streaming unit this node belongs to (its top-level world ancestor), 0 = always sent.
	var unit := 0
	## Unit roots: rough radius of the unit's content around its origin (-1 = not measured).
	var bound := -1.0
	## The streaming unit must be recomputed (it moved).
	var unit_dirty := true
	## Set by tree signals (moved, renamed, leaving): sleeping nodes skip all work until then.
	var struct_dirty := true
	## Marks the record dirty when the node enters/leaves the tree or is renamed.
	var on_struct: Callable
	## Values sent by the player whose player scene holds this node (owner-authored), and
	## which of them changed since the last tick.
	var owner_vals := {}
	## Owner-authored values that changed this tick, to relay.
	var owner_dirty_vals := {}
	## Peer that authors owner_vals (never gets them back).
	var owner_author := 0
	## Owner-authored props this node also has (AnimationPlayer): not polled on the server.
	var owner_set := {}
	## Lag compensation: [server tick, global transform] while the node moves, newest last.
	var hist: Array = []
	## Peer that moves this node: a child of its owned character (never gets it back).
	var xform_author := 0
	## Game.set_auto_sync(node, false): values and transform only go out with Game.sync.
	var manual := false


## True on the server and the host.
var is_server := false
## True on clients and the host.
var is_client := false
## This process's peer id (1 on server/host).
var local_peer := 0
## Network ticks per second (`rgd/network/tick_rate`).
var tick_rate := 30
## Seconds clients stay behind the stream (`rgd/network/interpolation_delay`).
var interpolation_delay := 0.1
## A 3D jump larger than this snaps (`rgd/network/teleport_distance`).
var teleport_distance := 8.0
## A 2D jump larger than this snaps (`rgd/network/teleport_distance_2d`).
var teleport_distance_2d := 256.0
## Streaming radius (3D units / 2D pixels), 0 = streaming off for that dimension.
var streaming_radius := 0.0
## Streaming radius for 2D worlds in pixels, 0 = off.
var streaming_radius_2d := 0.0
## Bytes per second per client for the transform stream (0 = unlimited).
var bandwidth_limit := 0
## The SceneMultiplayer RGD sends through.
var mp: SceneMultiplayer
## The `Game` autoload.
var game: Node

var _anchors := {}  # Node -> true (world root, Players)
var _world: Node
var _players_anchor: Node

# Shared registry
var _nodes := {}  # id -> Node
var _ids := {}  # instance id -> id

# Server
var _next_id := 1
var _recs := {}  # id -> Rec (insertion order = registration order)
var _spawn_queue: Array[int] = []
var _ready_peers := {}  # peer id -> true
var _strings := {}  # StringName -> id
var _string_list: Array[StringName] = []
var _new_strings: Array[int] = []
var _tick := 0
var _acc := 0.0
var _warned_scripts := {}
var _units := {}  # unit root id -> true
var _unit_slices: Array[Dictionary] = [{}, {}, {}, {}, {}]  # by id % RELEVANCE_EVERY
var _peer_units := {}  # peer -> {unit id: true} units this peer currently has
var _relevance_due := false
var _pending_stream := {}  # peer -> {id: [xform, snap, priority]} (bandwidth limit)
var _tick_bytes := {}  # peer -> bytes sent this tick
var _owned_tick := {}  # peer -> newest client tick of an applied OWNED_STATE
var _owner_dirty := {}  # rec id -> true: owner-authored values to relay this tick
var _owner_allowed := {}  # script path -> Array[StringName] the owner may author
var _owner_types := {}  # class|script path -> {prop: [type, class name]} (owner value checks)
var _view_tick := {}  # peer -> server tick the peer was showing when it sent its last remote
var _hist_ids := {}  # rec id -> true: nodes with a transform history (lag compensation)
## Seconds Game.rewind_raycast goes back at most (`rgd/network/max_rewind`).
var max_rewind := 0.5

# Client
var _limbo := {}  # id -> Node spawned but not placed yet
var _client_strings := {}  # id -> StringName
var _owned := {}  # id -> true (nodes this client simulates)
var _owned_last := {}  # id -> Transform3D last sent
var _interp := {}  # id -> Array of [tick, Transform3D, snap]
var _latest_tick := -1.0
var _play_tick := 0.0
var _in_snapshot := false
var _applied := {}  # id -> {prop: value} last value the server sent (debug: client-write warnings)
var _write_warned := {}
var _write_check_frame := 0
var _parked := {}  # world path -> streamed-out world node (outside the tree)
var _parked_ids := {}  # net id -> world path of the parked node
var _owner_props := {}  # id -> Array[StringName]: values this client authors (its player scene)
var _owner_last := {}  # id -> {prop: value last sent}
var _owner_xform := {}  # id -> true: child nodes of my character whose transforms I author
var _rtt := {}  # peer -> round-trip msec measured with PING/PONG (any transport)
var _ping_timer := 0.0


func _init() -> void:
	name = "Replicator"


# ---------------------------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------------------------

## Starts replicating for a session on [param p_mp], as server and/or client.
func setup(p_game: Node, p_mp: SceneMultiplayer, p_is_server: bool, p_is_client: bool) -> void:
	game = p_game
	mp = p_mp
	is_server = p_is_server
	is_client = p_is_client
	local_peer = mp.get_unique_id() if mp.has_multiplayer_peer() else 1
	tick_rate = RGDSettings.get_value(RGDSettings.TICK_RATE)
	interpolation_delay = RGDSettings.get_value(RGDSettings.INTERPOLATION_DELAY)
	teleport_distance = RGDSettings.get_value(RGDSettings.TELEPORT_DISTANCE)
	teleport_distance_2d = RGDSettings.get_value(RGDSettings.TELEPORT_DISTANCE_2D)
	streaming_radius = RGDSettings.get_value(RGDSettings.STREAMING_RADIUS)
	streaming_radius_2d = RGDSettings.get_value(RGDSettings.STREAMING_RADIUS_2D)
	bandwidth_limit = int(RGDSettings.get_value(RGDSettings.BANDWIDTH_LIMIT)) * 1024
	max_rewind = float(RGDSettings.get_value(RGDSettings.MAX_REWIND))
	if is_server:
		get_tree().node_added.connect(_on_node_added)


## Forgets everything (session ended). Frees spawned nodes still in limbo or parked.
func clear() -> void:
	if get_tree() and get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.disconnect(_on_node_added)
	for id in _limbo:
		var n: Node = _limbo[id]
		if is_instance_valid(n) and n.get_parent() == null:
			n.free()
	_limbo.clear()
	_free_parked()
	RGDWire._inline_cache.clear()
	_units.clear()
	for d in _unit_slices:
		d.clear()
	_peer_units.clear()
	_pending_stream.clear()
	_tick_bytes.clear()
	_owned_tick.clear()
	_owner_dirty.clear()
	_owner_allowed.clear()
	_owner_types.clear()
	_view_tick.clear()
	_hist_ids.clear()
	_owner_props.clear()
	_owner_last.clear()
	_owner_xform.clear()
	_rtt.clear()
	_relevance_due = false
	# Nodes that outlive the session (the Players container) keep their signals otherwise, and
	# the next session's record with the same id would connect the same callable again.
	for r in _recs.values():
		_disconnect_rec(r)
	_nodes.clear()
	_ids.clear()
	_recs.clear()
	_spawn_queue.clear()
	_ready_peers.clear()
	_strings.clear()
	_string_list.clear()
	_new_strings.clear()
	_client_strings.clear()
	_owned.clear()
	_owned_last.clear()
	_interp.clear()
	_applied.clear()
	_write_warned.clear()
	_stats_last = {}
	_stats_window_start = 0
	_anchors.clear()
	_world = null
	_players_anchor = null
	_next_id = 1
	_tick = 0
	_latest_tick = -1.0
	is_server = false
	is_client = false


## The net id of [param n], 0 if it isn't replicated.
func id_of(n: Node) -> int:
	if n == null or not is_instance_valid(n):
		return 0
	return _ids.get(n.get_instance_id(), 0)


## The node with net id [param id], or null.
func node_of(id: int) -> Node:
	var n = _nodes.get(id)
	if n != null and is_instance_valid(n):
		return n
	return null


func _bind(id: int, n: Node) -> void:
	_nodes[id] = n
	_ids[n.get_instance_id()] = id
	if not is_server and _is_rigid(n):
		# The server simulates it; the client only shows the streamed transform.
		_set_simulated(n, false)


func _unbind(id: int) -> void:
	var n = _nodes.get(id)
	if n != null and is_instance_valid(n):
		_ids.erase(n.get_instance_id())
	_nodes.erase(id)


# ---------------------------------------------------------------------------------------------
# Server: registration
# ---------------------------------------------------------------------------------------------

## Registers the world (before it enters the tree) and the Players anchor.
func server_set_world(world: Node, players_anchor: Node) -> void:
	_world = world
	_players_anchor = players_anchor
	_anchors[world] = true
	_anchors[players_anchor] = true
	if id_of(players_anchor) == 0:
		var pr := _new_rec(players_anchor)
		pr.parent_id = -1
	var wr := _new_rec(world)
	wr.parent_id = -1
	wr.world_path = "."
	_register_internals(world, world, wr, true)


## Server, change_scene: forgets every node inside [param old_world] (clients rebuild their
## world from a fresh snapshot). Players and detached characters keep their ids.
## Returns the kept ids.
func server_reset_world(old_world: Node) -> Array:
	var kept: Array = []
	for id in _recs.keys():
		var r: Rec = _recs[id]
		if not is_instance_valid(r.node) or r.node == old_world or old_world.is_ancestor_of(r.node):
			_unregister(id)
		else:
			kept.append(id)
	_anchors.erase(old_world)
	_spawn_queue = _spawn_queue.filter(func(id): return _recs.has(id))
	return kept


## Client, change_scene: keeps [param kept] ids (moving those inside the old world to limbo)
## and forgets the rest.
func client_reset_world(old_world: Node, kept: Array) -> void:
	var keep := {}
	for id in kept:
		keep[id] = true
	# Detach the top-most kept nodes that live inside the old world (the characters).
	for id in kept:
		var n := node_of(id)
		if n == null or old_world == null or not old_world.is_ancestor_of(n):
			continue
		var parent := n.get_parent()
		if keep.has(id_of(parent)) and parent != old_world:
			continue
		parent.remove_child(n)
		_limbo[id] = n
	for id in _nodes.keys():
		if not keep.has(id):
			_unbind(id)
	for id in _owned.keys():
		if not keep.has(id):
			_owned.erase(id)
	_interp.clear()
	_latest_tick = -1.0
	_free_parked()


func _free_parked() -> void:
	for path in _parked:
		var n: Node = _parked[path]
		if is_instance_valid(n):
			n.free()
	_parked.clear()
	_parked_ids.clear()


## Net id of [code]Game.players[/code].
func players_anchor_id() -> int:
	return id_of(_players_anchor)


func _new_rec(n: Node) -> Rec:
	var r := Rec.new()
	r.id = _next_id
	_next_id += 1
	r.node = n
	r.name = n.name
	r.xkind = 3 if n is Node3D else (2 if n is Node2D else 0)
	if n is BoneAttachment3D and not n.override_pose:
		r.xkind = 0  # follows its skeleton on every machine; streaming it would fight that
	r.props = _props_for(n)
	# A method bound to the id, not a lambda capturing `r`: that would be a reference cycle
	# (r -> callable -> r), so records and every value they hold leaked at exit.
	r.on_struct = _mark_struct.bind(r.id)
	for sig in [n.tree_entered, n.tree_exiting, n.renamed]:
		if not sig.is_connected(r.on_struct):
			sig.connect(r.on_struct)
	_recs[r.id] = r
	_bind(r.id, n)
	return r


func _disconnect_rec(r: Rec) -> void:
	if is_instance_valid(r.node) and r.on_struct.is_valid():
		for sig in [r.node.tree_entered, r.node.tree_exiting, r.node.renamed]:
			if sig.is_connected(r.on_struct):
				sig.disconnect(r.on_struct)


## False for a transform that would break physics: NaN or infinite numbers, or a basis that
## squashes everything flat (scale 0).
static func _sane_xform(xf: Variant) -> bool:
	if xf is Transform3D:
		return xf.is_finite() and absf((xf as Transform3D).basis.determinant()) > 1e-9
	if xf is Transform2D:
		return xf.is_finite() and absf((xf as Transform2D).determinant()) > 1e-9
	return false


func _mark_struct(id: int) -> void:
	var r: Rec = _recs.get(id)
	if r != null:
		r.struct_dirty = true


## True if [param n] (inside or outside the tree) should replicate: under an anchor, not in a
## `local`/`server_only` branch, not marked no-replicate.
func _replicable(n: Node) -> bool:
	var c := n
	while c != null:
		if _anchors.has(c):
			return true
		if c.is_in_group(ScriptContext.GROUP_LOCAL) or c.is_in_group(ScriptContext.GROUP_SERVER_ONLY) or c.has_meta(META_NO_REPLICATE):
			return false
		c = c.get_parent()
	return false


func _excluded_branch(n: Node) -> bool:
	return n.is_in_group(ScriptContext.GROUP_LOCAL) or n.is_in_group(ScriptContext.GROUP_SERVER_ONLY) or n.has_meta(META_NO_REPLICATE)


func _on_node_added(n: Node) -> void:
	if not is_server or id_of(n) != 0 or _anchors.has(n):
		return
	if not _replicable(n):
		return
	register_now(n)


## Registers [param root] and its replicable descendants right away and queues their spawn.
func register_now(root: Node) -> void:
	if id_of(root) != 0 or not _replicable(root):
		return
	var r := _new_rec(root)
	if root.has_meta(META_SPAWN_SCENE):
		var m: Array = root.get_meta(META_SPAWN_SCENE)
		r.spawn = {kind = Msg.SPAWN_SCENE, scene = m[0], sub = m[1], ctx_owner = m[2], internals = []}
		_register_all_descendants(root, root, r)
	elif root.scene_file_path != "":
		r.spawn = {kind = Msg.SPAWN_SCENE, scene = root.scene_file_path, sub = "",
			ctx_owner = int(root.get_meta(RGDInstancer.META_CTX_OWNER, 0)), internals = []}
		_register_internals(root, root, r, false)
	else:
		var s: Script = root.get_script()
		var sp: String = root.get_meta(RGDInstancer.META_STRIPPED, s.resource_path if s else "")
		r.spawn = {kind = Msg.SPAWN_NODE, cls = root.get_class(), script = sp,
			ctx_owner = int(root.get_meta(RGDInstancer.META_CTX_OWNER, 0))}
		for c in root.get_children():
			if not _excluded_branch(c):
				register_now(c)
	_spawn_queue.append(r.id)


## Registers the nodes that came from [param scene_root]'s scene file as internals of [param rec].
func _register_internals(scene_root: Node, n: Node, rec: Rec, is_world: bool) -> void:
	for c in n.get_children():
		if _excluded_branch(c):
			continue
		if _is_internal(c, scene_root):
			var cr := _new_rec(c)
			cr.parent_id = id_of(n)
			var rel := _rel_path(scene_root, c)
			if is_world:
				cr.world_path = rel
			else:
				rec.spawn.internals.append([rel, cr.id])
			_register_internals(scene_root, c, rec, is_world)
		elif id_of(c) == 0:
			register_now(c)


func _register_all_descendants(scene_root: Node, n: Node, rec: Rec) -> void:
	for c in n.get_children():
		if _excluded_branch(c) or id_of(c) != 0:
			continue
		var cr := _new_rec(c)
		cr.parent_id = id_of(n)
		rec.spawn.internals.append([_rel_path(scene_root, c), cr.id])
		_register_all_descendants(scene_root, c, rec)


func _rel_path(from: Node, to: Node) -> String:
	var parts: PackedStringArray = []
	var c := to
	while c != null and c != from:
		parts.insert(0, String(c.name))
		c = c.get_parent()
	return "/".join(parts)


## A node belongs to a scene file if the scene root is in its owner chain.
func _is_internal(n: Node, scene_root: Node) -> bool:
	var o := n.owner
	while o != null:
		if o == scene_root:
			return true
		o = o.owner
	return false


func _props_for(n: Node) -> Array:
	var s: Script = n.get_script()
	var key := str(n.get_class()) + "|" + (s.resource_path if s else "")
	if _prop_cache.has(key):
		return _prop_cache[key]
	var out: Array = []
	for p in RGDProfiles.props_for(StringName(n.get_class())):
		if p in n:
			out.append(p)
	if s != null:
		var no_rep: Array = []
		var b := s
		while b != null:
			no_rep.append_array(b.get_script_constant_map().get("RGD_NO_REPLICATE", []))
			b = b.get_base_script()
		var skipped: PackedStringArray = []
		for p in s.get_script_property_list():
			if not (p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE):
				continue
			var nm: String = p.name
			if nm.begins_with("_") or nm in no_rep or StringName(nm) in out:
				continue
			if p.type in [TYPE_CALLABLE, TYPE_SIGNAL, TYPE_RID]:
				skipped.append(nm)
				continue
			out.append(StringName(nm))
		if skipped and OS.is_debug_build() and not _warned_scripts.has(s.resource_path):
			_warned_scripts[s.resource_path] = true
			push_warning("RGD: %s: not replicating %s (unsupported type). Prefix with _ to silence." % [s.resource_path, ", ".join(skipped)])
	_prop_cache[key] = out
	return out

var _prop_cache := {}


func _string_id(s: StringName) -> int:
	if _strings.has(s):
		return _strings[s]
	var id := _string_list.size()
	_strings[s] = id
	_string_list.append(s)
	_new_strings.append(id)
	return id


# ---------------------------------------------------------------------------------------------
# Server: tick
# ---------------------------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if not is_server and not is_client:
		return
	_roll_stats()
	_ping_timer += delta
	if _ping_timer >= 1.0:
		_ping_timer = 0.0
		var ping := W.new(Msg.PING).f64(Time.get_ticks_usec() / 1000.0).bytes()
		for peer in (_ready_peers.keys() if is_server else ([1] if is_client and _world != null else [])):
			if not (is_server and peer == local_peer):
				_send(ping, peer, MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED, RGDProtocol.CH_STREAM)
	_acc += delta
	var step := 1.0 / tick_rate
	if _acc < step:
		return
	_acc = fmod(_acc, step)
	if _acc > step:
		_acc = 0.0
	if is_server:
		var t0 := Time.get_ticks_usec()
		_server_tick()
		var dt := Time.get_ticks_usec() - t0
		_stats_tick_usec += dt
		_stats_tick_max = maxi(_stats_tick_max, dt)
		_stats_ticks += 1
	elif is_client and not _in_snapshot:
		_client_tick()


func _server_tick() -> void:
	_tick += 1
	_tick_bytes.clear()
	var stream_on := streaming()
	# Every message is tagged with the streaming unit it belongs to ([unit, bytes]); a peer only
	# gets messages for units it currently has (unit 0 = everyone).
	var spawns: Array = []
	for id in _spawn_queue:
		var r: Rec = _recs.get(id)
		if r != null and is_instance_valid(r.node):
			if stream_on:
				_set_unit(r, _unit_of(r.node))
				r.unit_dirty = false
				if r.unit == r.id:
					_relevance_due = true
			spawns.append([r.unit, _msg_spawn(r)])
	_spawn_queue.clear()

	var props: Array = []
	var places: Array = []
	var despawns: Array[PackedByteArray] = []
	var owners: Array = []
	var moves := {}  # peer -> Array[PackedByteArray] (nodes that changed streaming unit)
	var stream: Array = []  # [id, xform, snap, owner_peer, unit]
	var changed_signals: Array = []

	for id in _recs.keys():
		var r: Rec = _recs.get(id)
		if r == null:
			continue
		var asleep: bool = r.idle > SLEEP_AFTER and (_tick + id) % SLEEP_EVERY != 0
		if asleep and not r.struct_dirty and not r.owner_dirty:
			continue
		r.struct_dirty = false
		var n := r.node
		if not is_instance_valid(n) or not n.is_inside_tree():
			despawns.append(_msg_id(Msg.DESPAWN, id))
			_unregister(id)
			continue
		if r.parent_id != -1 and _excluded_branch(n):
			# Put in the `local` / `server_only` group at runtime: clients lose it.
			despawns.append(_msg_id(Msg.DESPAWN, id))
			_unregister_subtree(n)
			continue
		var unit := r.unit
		if stream_on and r.unit_dirty:
			r.unit_dirty = false
			unit = _unit_of(n)
		elif not stream_on:
			unit = 0
		if r.parent_id != -1:
			var pid := id_of(n.get_parent())
			if pid != r.parent_id or n.name != r.name:
				if pid == 0 or not _replicable(n):
					despawns.append(_msg_id(Msg.DESPAWN, id))
					_unregister_subtree(n)
					continue
				r.parent_id = pid
				r.name = n.name
				var place := W.new(Msg.PLACE).varint(id).varint(pid).string(n.name).bytes()
				if stream_on:
					unit = _unit_of(n)
					_mark_units_dirty(n)
				if unit == r.unit:
					places.append([unit, place])
				else:
					_move_between_units(r, unit, place, moves)
		_set_unit(r, unit)
		if r.owner_dirty:
			r.owner_dirty = false
			owners.append([r.unit, W.new(Msg.OWNER).varint(id).varint(r.owner_peer).bytes()])
		if asleep or r.manual:
			continue
		var changed: Array = []
		for p in r.props:
			if r.owner_set.has(p):
				continue  # its player's machine drives it (OWNER_PROFILE)
			var v = n.get(p)
			if not r.last.has(p) or not _same(r.last[p], v):
				r.last[p] = _copy(v)
				changed.append(p)
		var send_xform := false
		var snap := false
		if r.xkind != 0:
			var cur: Variant = n.transform
			if not r.xform_init:
				r.xform_init = true
				r.last_xform = cur
				send_xform = true
			elif cur != r.last_xform:
				var limit := teleport_distance if r.xkind == 3 else teleport_distance_2d
				snap = r.teleport or cur.origin.distance_to(r.last_xform.origin) > limit
				var prev: Variant = r.last_xform
				r.teleport = false
				r.last_xform = cur
				r.settle = SETTLE_TICKS
				_record_history(r, snap, prev)
				stream.append([id, cur, snap, r.owner_peer if r.owner_peer != 0 else r.xform_author, r.unit])
				_stat_node(id, 31 * _ready_peers.size())
				r.idle = 0
			elif r.settle > 0:
				r.settle -= 1
				if r.settle == 0:
					send_xform = true
		if changed or send_xform:
			r.idle = 0
			props.append([r.unit, _msg_props(r, changed, send_xform, snap)])
			for p in changed:
				changed_signals.append([n, p, n.get(p)])
		else:
			r.idle += 1

	# Streaming: units entering / leaving each peer's radius.
	var streamed := {}  # peer -> Array[PackedByteArray]
	var fresh := {}  # peer -> {unit: true} streamed in this tick (they get the full state)
	if stream_on and _ready_peers:
		var slice := -1 if _relevance_due else _tick % RELEVANCE_EVERY
		_relevance_due = false
		_relevance_pass(slice, streamed, fresh)

	# Values players sent for their own player scene: to everyone else.
	var owner_msgs: Array = []  # [unit, author, bytes]
	for id in _owner_dirty:
		var r: Rec = _recs.get(id)
		if r == null or not is_instance_valid(r.node) or r.owner_dirty_vals.is_empty():
			continue
		owner_msgs.append([r.unit, r.owner_author, _msg_owner_props(r, r.owner_dirty_vals.keys())])
		r.owner_dirty_vals.clear()
	_owner_dirty.clear()

	# Strings first: everything above may have added some.
	var defs: Array[PackedByteArray] = []
	for sid in _new_strings:
		defs.append(W.new(Msg.STRING_DEF).varint(sid).string(_string_list[sid]).bytes())
	_new_strings.clear()
	# Places go last-registered first, so new subtrees are assembled in limbo and enter the
	# client's tree once, in their final shape (a character lands in the world, not first under
	# its Player).
	places.reverse()
	var tagged: Array = spawns + props + places + owners
	for peer in _ready_peers:
		var units: Dictionary = _peer_units.get(peer, {})
		var f: Dictionary = fresh.get(peer, {})
		for b in defs:
			_send(b, peer, MultiplayerPeer.TRANSFER_MODE_RELIABLE, RGDProtocol.CH_RELIABLE)
		for e in tagged:
			if e[0] == 0 or (units.has(e[0]) and not f.has(e[0])):
				_send(e[1], peer, MultiplayerPeer.TRANSFER_MODE_RELIABLE, RGDProtocol.CH_RELIABLE)
		for e in owner_msgs:
			if e[1] != peer and (e[0] == 0 or (units.has(e[0]) and not f.has(e[0]))):
				_send(e[2], peer, MultiplayerPeer.TRANSFER_MODE_RELIABLE, RGDProtocol.CH_RELIABLE)
		for b in despawns:
			_send(b, peer, MultiplayerPeer.TRANSFER_MODE_RELIABLE, RGDProtocol.CH_RELIABLE)
		for b in moves.get(peer, []):
			_send(b, peer, MultiplayerPeer.TRANSFER_MODE_RELIABLE, RGDProtocol.CH_RELIABLE)
		for b in streamed.get(peer, []):
			_send(b, peer, MultiplayerPeer.TRANSFER_MODE_RELIABLE, RGDProtocol.CH_RELIABLE)
	for peer in _ready_peers:
		_send_stream(peer, stream)
	for c in changed_signals:
		emit_changed(c[0], c[1], c[2])


## Sends this tick's transform stream to [param peer]. Under a bandwidth limit, entries that
## don't fit wait, gaining priority each tick (faster for nodes near the peer's focus).
func _send_stream(peer: int, stream: Array) -> void:
	var units: Dictionary = _peer_units.get(peer, {})
	var entries: Array = []
	for e in stream:
		if e[3] != peer and (e[4] == 0 or units.has(e[4])):
			entries.append(e)
	if bandwidth_limit > 0:
		entries = _budget_stream(peer, entries)
	if entries.is_empty():
		return
	var w := W.new(Msg.XFORM_BATCH).varint(_tick)
	w.varint(entries.size())
	for e in entries:
		w.varint(e[0]).u8((1 if e[2] else 0) | (2 if e[1] is Transform2D else 0)).xform(e[1])
	_send(w.bytes(), peer, MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED, RGDProtocol.CH_STREAM)


func _budget_stream(peer: int, entries: Array) -> Array:
	var pend: Dictionary = _pending_stream.get_or_add(peer, {})
	var units: Dictionary = _peer_units.get(peer, {})
	for e in entries:
		var old: Array = pend.get(e[0], [null, false, 0.0])
		pend[e[0]] = [e[1], e[2] or old[1], old[2]]
	var focus := _focus_of(peer)
	var order: Array = []
	for id in pend.keys():
		var n := node_of(id)
		var r: Rec = _recs.get(id)
		if n == null or not n.is_inside_tree() or r == null or (r.unit != 0 and not units.has(r.unit)):
			pend.erase(id)  # gone, or streamed out of this peer's range
			continue
		var pe: Array = pend[id]
		pe[2] += _stream_weight(focus, n)
		order.append([pe[2], id])
	order.sort_custom(func(a, b): return a[0] > b[0])
	var budget := maxi(int(bandwidth_limit / float(tick_rate)) - int(_tick_bytes.get(peer, 0)), MIN_STREAM_BYTES)
	var used := 8
	var out: Array = []
	for o in order:
		var pe: Array = pend[o[1]]
		var size := 3 + (13 if pe[0] is Transform2D else 29)
		if used + size > budget and not out.is_empty():
			break
		used += size
		out.append([o[1], pe[0], pe[1]])
		pend.erase(o[1])
	return out


## Priority gained per tick while waiting: 1 at the focus, falling off with distance.
func _stream_weight(focus: Node, n: Node) -> float:
	var d := -1.0
	var ref := 1.0
	if focus is Node3D and n is Node3D:
		d = focus.global_position.distance_to(n.global_position)
		ref = streaming_radius if streaming_radius > 0.0 else 32.0
	elif focus is Node2D and n is Node2D:
		d = focus.global_position.distance_to(n.global_position)
		ref = streaming_radius_2d if streaming_radius_2d > 0.0 else 512.0
	if d < 0.0:
		return 1.0
	return 1.0 / (1.0 + d / ref)


# ---------------------------------------------------------------------------------------------
# Server: streaming (plan 6.10)
# ---------------------------------------------------------------------------------------------

## True if streaming is on for either dimension.
func streaming() -> bool:
	return streaming_radius > 0.0 or streaming_radius_2d > 0.0


## The streaming unit of [param n]: its top-level ancestor under the world, if that's a
## Node3D/Node2D with streaming on for its dimension, not `persistent` and not a character.
func _unit_of(n: Node) -> int:
	if _world == null:
		return 0
	var c := n
	while c != null:
		var p := c.get_parent()
		if p == _world:
			if not ((c is Node3D and streaming_radius > 0.0) or (c is Node2D and streaming_radius_2d > 0.0)):
				return 0
			if c.is_in_group(GROUP_PERSISTENT) or c.has_meta(&"rgd_player"):
				return 0
			return id_of(c)
		c = p
	return 0


## A node moved: its descendants may belong to another unit now.
func _mark_units_dirty(n: Node) -> void:
	for c in n.get_children():
		var cr: Rec = _recs.get(id_of(c))
		if cr != null:
			cr.unit_dirty = true
			cr.struct_dirty = true
		_mark_units_dirty(c)


func _set_unit(r: Rec, unit: int) -> void:
	if r.unit == r.id and unit != r.id:
		_units.erase(r.id)
		_unit_slices[r.id % RELEVANCE_EVERY].erase(r.id)
	r.unit = unit
	if unit == r.id:
		_units[r.id] = true
		_unit_slices[r.id % RELEVANCE_EVERY][r.id] = true


## [param r] was placed under a parent in another streaming unit. Peers that have both units
## get the PLACE; peers that only had the old one lose the node; peers that only have the new
## one get the whole subtree.
func _move_between_units(r: Rec, unit: int, place: PackedByteArray, moves: Dictionary) -> void:
	var old := r.unit
	for peer in _ready_peers:
		var units: Dictionary = _peer_units.get_or_add(peer, {})
		var had := old == 0 or units.has(old)
		var has := unit == 0 or units.has(unit)
		if unit == r.id and had:
			# Became a top-level unit of its own: peers that saw it keep it.
			units[r.id] = true
			has = true
		var list: Array = moves.get_or_add(peer, [])
		if had and has:
			list.append(place)
		elif had:
			list.append(_msg_id(Msg.DESPAWN, r.id))
		elif has:
			list.append_array(_subtree_msgs(r.node))
	if old == r.id:
		for peer in _peer_units:
			_peer_units[peer].erase(r.id)


func _focus_of(peer: int) -> Node:
	var p: Player = game.players.get_by_id(peer) if game and game.players else null
	if p == null:
		return null
	var f: Node = p.replication_focus if is_instance_valid(p.replication_focus) else null
	if f == null and is_instance_valid(p.character):
		f = p.character
	if f != null and (f is Node3D or f is Node2D) and f.is_inside_tree():
		return f
	return null


## True if [param peer] should have unit [param r]. No focus (no character yet, or a game
## without one) means everything.
func _wants_unit(peer: int, focus: Node, r: Rec, has: bool) -> bool:
	if focus == null or r.owner_peer == peer:
		return true
	var n := r.node
	var d := -1.0
	if focus is Node3D and n is Node3D:
		d = focus.global_position.distance_to(n.global_position)
	elif focus is Node2D and n is Node2D:
		d = focus.global_position.distance_to(n.global_position)
	if d < 0.0:
		return true
	if r.bound < 0.0:
		r.bound = _bound_of(n)
	var radius := streaming_radius if n is Node3D else streaming_radius_2d
	return d - r.bound <= (radius * STREAM_OUT_FACTOR if has else radius)


## Streams units in/out for every ready peer. Fills [param streamed] (peer -> messages) and
## [param fresh] (peer -> units streamed in). [param slice]: only that slice of the units
## (-1 = all). Positions are read once per unit, foci once per peer.
func _relevance_pass(slice: int, streamed: Dictionary, fresh: Dictionary) -> void:
	var peers: Array = []  # [peer, units, focus, focus position, out, fresh]
	for peer in _ready_peers:
		var units: Dictionary = _peer_units.get_or_add(peer, {})
		if slice <= 0:
			for uid in units.keys():
				if not _units.has(uid):
					units.erase(uid)
		var focus := _focus_of(peer)
		var out: Array[PackedByteArray] = []
		var f := {}
		streamed[peer] = out
		fresh[peer] = f
		peers.append([peer, units, focus, focus.global_position if focus else null, out, f])
	var src: Dictionary = _units if slice < 0 else _unit_slices[slice]
	for uid in src:
		var r: Rec = _recs.get(uid)
		if r == null or not is_instance_valid(r.node) or not r.node.is_inside_tree():
			continue
		var n := r.node
		var is_3d := n is Node3D
		var pos: Variant = n.global_position
		if r.bound < 0.0:
			r.bound = _bound_of(n)
		var radius := streaming_radius if is_3d else streaming_radius_2d
		for pe in peers:
			var units: Dictionary = pe[1]
			var has := units.has(uid)
			var want := true
			if pe[2] != null and r.owner_peer != pe[0] and (pe[2] is Node3D) == is_3d:
				var d: float = pos.distance_to(pe[3]) - r.bound
				want = d <= (radius * STREAM_OUT_FACTOR if has else radius)
			if want and not has:
				units[uid] = true
				pe[5][uid] = true
				pe[4].append_array(_subtree_msgs(n))
			elif has and not want:
				units.erase(uid)
				var park := r.world_path if r.spawn.is_empty() else ""
				pe[4].append(W.new(Msg.STREAM_OUT).varint(uid).string(park).bytes())


## Everything a client needs to build [param root]'s subtree from scratch: spawns, props,
## places (bottom-up), owners.
func _subtree_msgs(root: Node) -> Array[PackedByteArray]:
	var spawns: Array[PackedByteArray] = []
	var props: Array[PackedByteArray] = []
	var places: Array[PackedByteArray] = []
	var owners: Array[PackedByteArray] = []
	_collect_subtree(root, root, {}, spawns, props, places, owners)
	places.reverse()
	var out: Array[PackedByteArray] = []
	out.append_array(spawns)
	out.append_array(props)
	out.append_array(places)
	out.append_array(owners)
	return out


func _collect_subtree(n: Node, root: Node, covered: Dictionary, spawns: Array[PackedByteArray],
		props: Array[PackedByteArray], places: Array[PackedByteArray], owners: Array[PackedByteArray]) -> void:
	var id := id_of(n)
	var r: Rec = _recs.get(id)
	if r == null:
		return
	if not covered.has(id):
		if not r.spawn.is_empty():
			spawns.append(_msg_spawn(r, n))
			for e in r.spawn.internals:
				covered[e[1]] = true
		elif r.world_path != "" and r.world_path != ".":
			# A part of the world scene: the client re-creates it from its own copy.
			var sp := {kind = Msg.SPAWN_SCENE, scene = game._world_path, sub = r.world_path, ctx_owner = 0, internals = []}
			_world_internals(n, r.world_path + "/", sp.internals, covered)
			spawns.append(_msg_spawn_raw(id, n.name, sp, n))
		else:
			# No recipe (e.g. a scene's internal node moved elsewhere): a bare node of its class.
			var s: Script = n.get_script()
			spawns.append(_msg_spawn_raw(id, n.name, {kind = Msg.SPAWN_NODE, cls = n.get_class(),
				script = n.get_meta(RGDInstancer.META_STRIPPED, s.resource_path if s else ""),
				ctx_owner = int(n.get_meta(RGDInstancer.META_CTX_OWNER, 0))}))
	props.append(_msg_props(r, r.props, r.xkind != 0, true))
	if not r.owner_vals.is_empty():
		props.append(_msg_owner_props(r, r.owner_vals.keys()))
	places.append(W.new(Msg.PLACE).varint(id).varint(id_of(n.get_parent())).string(n.name).bytes())
	if r.owner_peer != 0:
		owners.append(W.new(Msg.OWNER).varint(id).varint(r.owner_peer).bytes())
	for c in n.get_children():
		_collect_subtree(c, root, covered, spawns, props, places, owners)


func _world_internals(n: Node, prefix: String, out: Array, covered: Dictionary) -> void:
	for c in n.get_children():
		var cid := id_of(c)
		var cr: Rec = _recs.get(cid)
		if cr != null and cr.spawn.is_empty() and cr.world_path.begins_with(prefix):
			out.append([cr.world_path.substr(prefix.length()), cid])
			covered[cid] = true
		_world_internals(c, prefix, out, covered)


## Rough radius of [param n]'s visible/collision content around its origin, so big things
## (a floor, terrain) count as near when any part of them is.
func _bound_of(n: Node) -> float:
	var acc := [0.0, 0]
	if n is Node3D:
		_bound3(n, Transform3D.IDENTITY, acc)
	elif n is Node2D:
		_bound2(n, Transform2D.IDENTITY, acc)
	return acc[0]


func _bound3(n: Node3D, xf: Transform3D, acc: Array) -> void:
	acc[1] += 1
	if acc[1] > 512:
		return
	var box: Variant = null
	if n is VisualInstance3D:
		box = (n as VisualInstance3D).get_aabb()
	elif n is CollisionShape3D and n.shape != null:
		var m: Mesh = n.shape.get_debug_mesh()
		if m:
			box = m.get_aabb()
	if box is AABB:
		for i in 8:
			acc[0] = maxf(acc[0], (xf * (box as AABB).get_endpoint(i)).length())
	for c in n.get_children():
		if c is Node3D:
			_bound3(c, xf * c.transform, acc)


func _bound2(n: Node2D, xf: Transform2D, acc: Array) -> void:
	acc[1] += 1
	if acc[1] > 512:
		return
	var rect: Variant = null
	if n is Sprite2D:
		rect = (n as Sprite2D).get_rect()
	elif n is AnimatedSprite2D and n.sprite_frames != null and n.sprite_frames.has_animation(n.animation) and n.sprite_frames.get_frame_count(n.animation) > 0:
		var tex: Texture2D = n.sprite_frames.get_frame_texture(n.animation, 0)
		if tex:
			var sz := tex.get_size()
			rect = Rect2(-sz / 2.0 if n.centered else Vector2.ZERO, sz)
	elif n is Polygon2D and not n.polygon.is_empty():
		var pr := Rect2(n.polygon[0], Vector2.ZERO)
		for pt in n.polygon:
			pr = pr.expand(pt)
		rect = pr
	elif n is CollisionShape2D and n.shape != null:
		rect = n.shape.get_rect()
	elif n is TileMapLayer and n.tile_set != null:
		var used: Rect2i = n.get_used_rect()
		var ts := Vector2(n.tile_set.tile_size)
		rect = Rect2(Vector2(used.position) * ts, Vector2(used.size) * ts)
	if rect is Rect2:
		var r: Rect2 = rect
		for p in [r.position, r.position + Vector2(r.size.x, 0), r.position + Vector2(0, r.size.y), r.end]:
			acc[0] = maxf(acc[0], (xf * p).length())
	for c in n.get_children():
		if c is Node2D:
			_bound2(c, xf * c.transform, acc)


# ---------------------------------------------------------------------------------------------
# Server: lag compensation (Game.rewind)
# ---------------------------------------------------------------------------------------------

## Remembers where a moving node was this tick (global transform), for Game.rewind.
func _record_history(r: Rec, snap: bool, prev_local: Variant) -> void:
	if max_rewind <= 0.0:
		return
	var n := r.node
	if r.hist.is_empty() or int(r.hist[-1][0]) < _tick - 1:
		# Starting to move after standing still: it stood at prev until now.
		var parent := n.get_parent()
		var prev: Variant = prev_local
		if (parent is Node3D and r.xkind == 3) or (parent is Node2D and r.xkind == 2):
			prev = parent.global_transform * prev_local
		r.hist.append([_tick - 1, prev, false])
	r.hist.append([_tick, n.global_transform, snap])
	var keep := int(ceil(max_rewind * tick_rate)) + 3
	if r.hist.size() > keep:
		r.hist = r.hist.slice(r.hist.size() - keep)
	_hist_ids[r.id] = true


## The global transform [param r] had at server tick [param t] (fractional), or null if it
## was where it is now.
static func _hist_at(r: Rec, t: float) -> Variant:
	var h := r.hist
	if h.is_empty() or t >= float(h[-1][0]):
		return null
	if t <= float(h[0][0]):
		return h[0][1]
	for i in range(h.size() - 2, -1, -1):
		var a: Array = h[i]
		if float(a[0]) <= t:
			var b: Array = h[i + 1]
			if b[2]:
				return a[1]  # a teleport: no in-between
			var f := (t - float(a[0])) / maxf(float(b[0]) - float(a[0]), 0.0001)
			return a[1].interpolate_with(b[1], f)
	return h[0][1]


## Server: the server tick [param peer] was showing when it sent its latest remote (-1 if
## unknown, e.g. the host's own player, who sees the present).
func view_tick_of(peer: int) -> float:
	return float(_view_tick.get(peer, -1.0))


## Server, lag compensation: casts [param q] against the world as [param peer] saw it when it
## sent its latest remote. Moving bodies (with a transform history) are tested where they
## were then; everything else where it is. Returns intersect_ray's Dictionary ({} = no hit).
##
## Nothing is actually moved (physics engines like Jolt only see moved bodies after a physics
## step). Instead, for each moving body the ray is moved into that body's past frame
## (now · past⁻¹) and tested against that body alone.
func rewind_raycast(peer: int, space: PhysicsDirectSpaceState3D, q: PhysicsRayQueryParameters3D) -> Dictionary:
	var t := view_tick_of(peer)
	if t < 0.0 or max_rewind <= 0.0 or (is_client and peer == local_peer):
		return space.intersect_ray(q)
	var oldest := float(_tick) - max_rewind * tick_rate
	t = clampf(t, oldest, float(_tick))
	var cands: Array = []  # [CollisionObject3D, Transform3D now·past⁻¹]
	var moving: Array[RID] = []
	for id in _hist_ids.keys():
		var r: Rec = _recs.get(id)
		if r == null or not is_instance_valid(r.node) or not r.node.is_inside_tree() or r.xkind != 3:
			_hist_ids.erase(id)
			continue
		if r.hist.is_empty() or float(r.hist[-1][0]) < oldest - 1.0:
			r.hist.clear()  # still for longer than we ever rewind
			_hist_ids.erase(id)
			continue
		if r.owner_peer == peer:
			continue  # the caller's own character is where they had it
		var past: Variant = _hist_at(r, t)
		if past == null:
			continue
		var m: Transform3D = (r.node as Node3D).global_transform * (past as Transform3D).affine_inverse()
		for co in _collision_objects(r.node):
			if co is CollisionObject3D and not co.get_rid() in q.exclude:
				cands.append([co, m])
				moving.append(co.get_rid())
	if cands.is_empty():
		return space.intersect_ray(q)
	var q0 := _copy_query(q, q.from, q.to)
	q0.exclude = q.exclude + moving
	var best := space.intersect_ray(q0)
	var best_d: float = q.from.distance_to(best.position) if best else INF
	for c in cands:
		var co: CollisionObject3D = c[0]
		var m: Transform3D = c[1]
		var qq := _copy_query(q, m * q.from, m * q.to)
		var excl: Array[RID] = q.exclude.duplicate()
		for i in 8:
			qq.exclude = excl
			var hit := space.intersect_ray(qq)
			if hit.is_empty():
				break
			if hit.rid != co.get_rid():
				excl.append(hit.rid)  # something else is in the way here; look behind it
				continue
			var back := m.affine_inverse()
			var pos: Vector3 = back * (hit.position as Vector3)
			var d := q.from.distance_to(pos)
			if d < best_d:
				best_d = d
				hit.position = pos
				hit.normal = (back.basis * (hit.normal as Vector3)).normalized()
				best = hit
			break
	return best


## Server: [method rewind_raycast] for 2D (Transform2D history, PhysicsRayQueryParameters2D).
func rewind_raycast_2d(peer: int, space: PhysicsDirectSpaceState2D, q: PhysicsRayQueryParameters2D) -> Dictionary:
	var t := view_tick_of(peer)
	if t < 0.0 or max_rewind <= 0.0 or (is_client and peer == local_peer):
		return space.intersect_ray(q)
	var oldest := float(_tick) - max_rewind * tick_rate
	t = clampf(t, oldest, float(_tick))
	var cands: Array = []  # [CollisionObject2D, Transform2D now·past⁻¹]
	var moving: Array[RID] = []
	for id in _hist_ids.keys():
		var r: Rec = _recs.get(id)
		if r == null or not is_instance_valid(r.node) or not r.node.is_inside_tree() or r.xkind != 2:
			continue
		if r.hist.is_empty() or float(r.hist[-1][0]) < oldest - 1.0 or r.owner_peer == peer:
			continue
		var past: Variant = _hist_at(r, t)
		if past == null:
			continue
		var m: Transform2D = (r.node as Node2D).global_transform * (past as Transform2D).affine_inverse()
		for co in _collision_objects(r.node):
			if co is CollisionObject2D and not co.get_rid() in q.exclude:
				cands.append([co, m])
				moving.append(co.get_rid())
	if cands.is_empty():
		return space.intersect_ray(q)
	var q0 := _copy_query_2d(q, q.from, q.to)
	q0.exclude = q.exclude + moving
	var best := space.intersect_ray(q0)
	var best_d: float = q.from.distance_to(best.position) if best else INF
	for c in cands:
		var co: CollisionObject2D = c[0]
		var m: Transform2D = c[1]
		var qq := _copy_query_2d(q, m * q.from, m * q.to)
		var excl: Array[RID] = q.exclude.duplicate()
		for i in 8:
			qq.exclude = excl
			var hit := space.intersect_ray(qq)
			if hit.is_empty():
				break
			if hit.rid != co.get_rid():
				excl.append(hit.rid)
				continue
			var back := m.affine_inverse()
			var pos: Vector2 = back * (hit.position as Vector2)
			var d := q.from.distance_to(pos)
			if d < best_d:
				best_d = d
				hit.position = pos
				hit.normal = (back.basis_xform(hit.normal as Vector2)).normalized()
				best = hit
			break
	return best


static func _copy_query_2d(q: PhysicsRayQueryParameters2D, from: Vector2, to: Vector2) -> PhysicsRayQueryParameters2D:
	var c := PhysicsRayQueryParameters2D.create(from, to, q.collision_mask, q.exclude)
	c.collide_with_areas = q.collide_with_areas
	c.collide_with_bodies = q.collide_with_bodies
	c.hit_from_inside = q.hit_from_inside
	return c


static func _copy_query(q: PhysicsRayQueryParameters3D, from: Vector3, to: Vector3) -> PhysicsRayQueryParameters3D:
	var c := PhysicsRayQueryParameters3D.create(from, to, q.collision_mask, q.exclude)
	c.collide_with_areas = q.collide_with_areas
	c.collide_with_bodies = q.collide_with_bodies
	c.hit_from_inside = q.hit_from_inside
	c.hit_back_faces = q.hit_back_faces
	return c


## [param n] and its descendants that are physics objects (stops at nodes with their own
## history: those are rewound by themselves).
func _collision_objects(n: Node) -> Array:
	var out: Array = []
	if n is CollisionObject3D or n is CollisionObject2D:
		out.append(n)
	for c in n.get_children():
		if not _hist_ids.has(id_of(c)):
			out.append_array(_collision_objects(c))
	return out


# ---------------------------------------------------------------------------------------------
# Server: values a player's own machine authors (its player scene)
# ---------------------------------------------------------------------------------------------

## True if an ancestor of [param n] is owned by [param peer].
func _under_owned(n: Node, peer: int) -> bool:
	var c := n.get_parent()
	while c != null and not _anchors.has(c):
		var r: Rec = _recs.get(id_of(c))
		if r != null and r.owner_peer == peer:
			return true
		c = c.get_parent()
	return false


## The peer whose player scene holds [param n] (0 = none: a world node).
func _player_scene_peer(n: Node) -> int:
	var c := n
	while c != null and not _anchors.has(c):
		if c is Player:
			return (c as Player).user_id
		var p = c.get_meta(&"rgd_player") if c.has_meta(&"rgd_player") else null
		if p is Player and is_instance_valid(p):
			return (p as Player).user_id
		c = c.get_parent()
	return 0


## What the owning player's machine may set on [param n]: public variables of the scripts that
## run there and not on the server (e.g. controller.gd), and OWNER_PROFILE properties.
func _owner_writable(n: Node) -> Array:
	var path: String = n.get_meta(RGDInstancer.META_STRIPPED, "")
	var key := "%s|%s" % [n.get_class(), path]
	if _owner_allowed.has(key):
		return _owner_allowed[key]
	var out: Array = []
	for cls in OWNER_PROFILE:
		if n.is_class(cls):
			out.append_array(OWNER_PROFILE[cls])
	if path != "" and ResourceLoader.exists(path):
		var s := load(path) as Script
		if s and not (ScriptContext.run_mask(path, true) & ScriptContext.SERVER):
			out.append_array(owner_script_props(s))
	_owner_allowed[key] = out
	return out


## True if a value an owner sent for [param prop] has the variable's type, so it can be applied
## on every machine: a script variable's declared type, or a built-in's current type.
func _owner_value_ok(n: Node, prop: StringName, v: Variant) -> bool:
	var path: String = n.get_meta(RGDInstancer.META_STRIPPED, "")
	var key := "%s|%s" % [n.get_class(), path]
	if not _owner_types.has(key):
		var types := {}
		if path != "" and ResourceLoader.exists(path):
			var sc := load(path) as Script
			if sc:
				for p in sc.get_script_property_list():
					if p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
						types[StringName(p.name)] = [p.type, StringName(p.class_name)]
		_owner_types[key] = types
	var known: Dictionary = _owner_types[key]
	if known.has(prop):
		return game._fits(v, known[prop][0], known[prop][1])
	if prop in n:
		var cur = n.get(prop)
		return cur == null or game._fits(v, typeof(cur), &"")
	return true


## Public, replicable variables declared by [param s] (and its base scripts).
static func owner_script_props(s: Script) -> Array:
	var no_rep: Array = []
	var b := s
	while b != null:
		no_rep.append_array(b.get_script_constant_map().get("RGD_NO_REPLICATE", []))
		b = b.get_base_script()
	var out: Array = []
	for p in s.get_script_property_list():
		if not (p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE):
			continue
		var nm: String = p.name
		if nm.begins_with("_") or nm in no_rep or p.type in [TYPE_CALLABLE, TYPE_SIGNAL, TYPE_RID]:
			continue
		out.append(StringName(nm))
	return out


func _server_owner_props(peer: int, rd: R) -> void:
	var count := rd.varint()
	for i in count:
		var id := rd.varint()
		var n_props := rd.varint()
		var r: Rec = _recs.get(id)
		var ok := r != null and is_instance_valid(r.node) and _player_scene_peer(r.node) == peer
		var allowed: Array = _owner_writable(r.node) if ok else []
		for j in n_props:
			var prop := StringName(rd.string())
			var v: Variant = rd.value()
			if rd.failed:
				return
			if not ok or not prop in allowed:
				continue
			if not _owner_value_ok(r.node, prop, v):
				game._bad_input(peer, "a value of the wrong type for %s" % prop)
				continue
			if game.owner_value_validator.is_valid() and not game.owner_value_validator.call(game.players.get_by_id(peer), r.node, prop, v):
				continue
			_apply_owner_value(r, prop, v, peer)


func _apply_owner_value(r: Rec, prop: StringName, v: Variant, peer: int) -> void:
	var n := r.node
	if r.owner_vals.has(prop) and _same(r.owner_vals[prop], v):
		return
	r.owner_vals[prop] = _copy(v)
	r.owner_dirty_vals[prop] = true
	r.owner_author = peer
	_owner_dirty[r.id] = true
	if prop in r.props:
		# A built-in the owner drives (an AnimationPlayer): the server's copy follows it too.
		r.owner_set[prop] = true
		n.set(prop, v)
		if prop == &"animation" and (n is AnimatedSprite2D or n is AnimatedSprite3D) and v != &"":
			n.play(v)
	else:
		var vals: Dictionary = n.get_meta(META_VALUES, {})
		vals[prop] = v
		n.set_meta(META_VALUES, vals)
	emit_changed(n, prop, v)


func _msg_owner_props(r: Rec, names: Array) -> PackedByteArray:
	var w := W.new(Msg.PROPS, id_of)
	w.varint(r.id).u8(0).varint(names.size())
	for p in names:
		w.varint(_string_id(p))
		w.value(r.owner_vals[p])
	var b := w.bytes()
	_stat_node(r.id, b.size() * maxi(_ready_peers.size() - 1, 1))
	return b


func _unregister(id: int) -> void:
	var r: Rec = _recs.get(id)
	if r != null:
		_disconnect_rec(r)
	_recs.erase(id)
	_hist_ids.erase(id)
	_owner_dirty.erase(id)
	_units.erase(id)
	_unit_slices[id % RELEVANCE_EVERY].erase(id)
	_unbind(id)


func _unregister_subtree(n: Node) -> void:
	for id in _recs.keys():
		var r: Rec = _recs[id]
		if not is_instance_valid(r.node) or r.node == n or n.is_ancestor_of(r.node):
			_unregister(id)


func _same(a: Variant, b: Variant) -> bool:
	var ta := typeof(a)
	var tb := typeof(b)
	if (ta == TYPE_NIL or ta == TYPE_OBJECT) and (tb == TYPE_NIL or tb == TYPE_OBJECT):
		# A null Object property and a decoded nil are the same thing.
		var a_null: bool = ta == TYPE_NIL or not is_instance_valid(a)
		var b_null: bool = tb == TYPE_NIL or not is_instance_valid(b)
		if a_null or b_null:
			return a_null and b_null
		return is_same(a, b)
	if ta != tb:
		return false
	if a == b:
		return true
	# NaN is never == itself: compare the bytes, or a NaN value would look changed every tick
	# (sent again and again, and reported as a client write).
	return ta in _FLOAT_TYPES and var_to_bytes(a) == var_to_bytes(b)


const _FLOAT_TYPES := [TYPE_FLOAT, TYPE_VECTOR2, TYPE_VECTOR3, TYPE_VECTOR4, TYPE_RECT2, TYPE_TRANSFORM2D,
	TYPE_PLANE, TYPE_QUATERNION, TYPE_AABB, TYPE_BASIS, TYPE_TRANSFORM3D, TYPE_PROJECTION, TYPE_COLOR,
	TYPE_ARRAY, TYPE_DICTIONARY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY,
	TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_VECTOR4_ARRAY, TYPE_PACKED_COLOR_ARRAY]


## A typed array or dictionary variable only takes a value of its own type: convert what
## arrived (containers travel untyped unless they're native typed arrays) to the variable's type.
static func _fit_to(cur: Variant, v: Variant) -> Variant:
	if cur is Dictionary and v is Dictionary and (cur as Dictionary).is_typed() and not (v as Dictionary).is_same_typed(cur):
		var d: Dictionary = cur
		return Dictionary(v, d.get_typed_key_builtin(), d.get_typed_key_class_name(), d.get_typed_key_script(),
			d.get_typed_value_builtin(), d.get_typed_value_class_name(), d.get_typed_value_script())
	if cur is Array and v is Array and (cur as Array).is_typed() and not (v as Array).is_same_typed(cur):
		var a: Array = cur
		return Array(v, a.get_typed_builtin(), a.get_typed_class_name(), a.get_typed_script())
	return v


func _copy(v: Variant) -> Variant:
	if v is Array or v is Dictionary:
		return v.duplicate(true)
	return v


func _w() -> W:
	return W.new(-1, id_of)


func _msg_id(msg: int, id: int) -> PackedByteArray:
	return W.new(msg).varint(id).bytes()


func _msg_spawn(r: Rec, within: Node = null) -> PackedByteArray:
	return _msg_spawn_raw(r.id, r.node.name, r.spawn, within)


## Debug builds: warns once per script variable whose value can't cross the network (it
## arrives as null): a runtime-created Resource, or an Object that isn't a Node or Resource.
func _check_sendable(n: Node, prop: StringName, v: Object) -> void:
	if not is_instance_valid(v) or v is Node:
		return
	if v is Resource and v.resource_path.begins_with("res://") or RGDWire.can_inline(v):
		return
	var s: Script = n.get_script()
	var key := "%s|%s" % [s.resource_path if s else n.get_class(), prop]
	if _warned_values.has(key):
		return
	_warned_values[key] = true
	var what := "a %s created at runtime" % v.get_class() if v is Resource else "a %s" % v.get_class()
	push_warning("RGD: %s.%s holds %s; clients get null. Replicate plain data (numbers, strings, arrays, dictionaries) and build the object on each side, or save the resource to a file. Prefix with _ to keep it server-only." % [n.name, prop, what])

var _warned_values := {}


## [param within]: only list internals that are currently inside this node.
func _msg_spawn_raw(id: int, nm: StringName, spawn: Dictionary, within: Node = null) -> PackedByteArray:
	# Spawns always go to limbo (parent 0); the PLACE follows after the props, so nodes enter
	# the client's tree with their state already applied.
	var w := W.new(spawn.kind)
	w.varint(id).varint(0).string(nm)
	if spawn.kind == Msg.SPAWN_SCENE:
		w.string(spawn.scene).string(spawn.sub).varint(spawn.ctx_owner)
		var alive := (spawn.internals as Array).filter(func(e):
			var n := node_of(e[1])
			return n != null and (within == null or within == n or within.is_ancestor_of(n)))
		w.varint(alive.size())
		for e in alive:
			w.string(e[0]).varint(e[1])
	else:
		w.string(spawn.cls).string(spawn.script).varint(spawn.ctx_owner)
	return w.bytes()


func _msg_props(r: Rec, names: Array, with_xform: bool, snap: bool) -> PackedByteArray:
	var w := W.new(Msg.PROPS, id_of)
	w.varint(r.id)
	w.u8((1 if with_xform else 0) | (2 if snap else 0) | (4 if r.xkind == 2 else 0))
	if with_xform:
		w.xform(r.node.transform)
	w.varint(names.size())
	for p in names:
		w.varint(_string_id(p))
		var v = r.node.get(p)
		if OS.is_debug_build() and typeof(v) == TYPE_OBJECT:
			_check_sendable(r.node, p, v)
		w.value(v)
		var key := "%s.%s" % [r.node.name, p]
		_stats_props[key] = _stats_props.get(key, 0) + 1
	var b := w.bytes()
	_stat_node(r.id, b.size() * maxi(_ready_peers.size(), 1))
	return b


# ---------------------------------------------------------------------------------------------
# Server: peers and snapshot
# ---------------------------------------------------------------------------------------------

## Sends the full current state to [param peer] and starts sending it live updates.
func send_snapshot(peer: int) -> void:
	var out: Array[PackedByteArray] = []
	out.append(W.new(Msg.SNAPSHOT_BEGIN).varint(_recs.size()).bytes())
	# Props below may add strings; build them first, then send the whole string table first.
	var spawns: Array[PackedByteArray] = []
	var world_map := W.new(Msg.WORLD_MAP)
	var world_entries: Array = []
	var props: Array[PackedByteArray] = []
	var places: Array[PackedByteArray] = []
	var owners: Array[PackedByteArray] = []
	# Streaming: only the units in range; world units out of range get parked on the client.
	var units := {}
	var parked: Array = []  # [world path, id]
	if streaming():
		# Units may not be computed yet (right after change_scene).
		for id in _recs:
			var ur: Rec = _recs[id]
			if is_instance_valid(ur.node):
				_set_unit(ur, _unit_of(ur.node))
		var focus := _focus_of(peer)
		for uid in _units:
			var ur: Rec = _recs.get(uid)
			if ur == null or not is_instance_valid(ur.node):
				continue
			if _wants_unit(peer, focus, ur, false):
				units[uid] = true
			elif ur.spawn.is_empty() and ur.world_path != "":
				parked.append([ur.world_path, uid])
	_peer_units[peer] = units
	_pending_stream.erase(peer)
	for id in _recs:
		var r: Rec = _recs[id]
		if not is_instance_valid(r.node) or not r.node.is_inside_tree():
			continue
		if r.unit != 0 and not units.has(r.unit):
			continue
		if r.world_path != "":
			world_entries.append([r.world_path, id])
		if not r.spawn.is_empty():
			spawns.append(_msg_spawn(r))
		props.append(_msg_props(r, r.props, r.xkind != 0, true))
		if not r.owner_vals.is_empty() and r.owner_author != peer:
			props.append(_msg_owner_props(r, r.owner_vals.keys()))
		if r.parent_id != -1:
			var pid := id_of(r.node.get_parent())
			places.append(W.new(Msg.PLACE).varint(id).varint(pid).string(r.node.name).bytes())
		if r.owner_peer != 0:
			owners.append(W.new(Msg.OWNER).varint(id).varint(r.owner_peer).bytes())
	world_map.varint(world_entries.size())
	for e in world_entries:
		world_map.string(e[0]).varint(e[1])
	world_map.varint(parked.size())
	for e in parked:
		world_map.string(e[0]).varint(e[1])
	# Don't clear _new_strings: peers that were already ready still need those definitions
	# (sent at the next tick). The new peer gets the whole table now.
	for i in _string_list.size():
		out.append(W.new(Msg.STRING_DEF).varint(i).string(_string_list[i]).bytes())
	out.append(world_map.bytes())
	out.append_array(spawns)
	out.append_array(props)
	places.reverse()
	out.append_array(places)
	out.append_array(owners)
	out.append(W.new(Msg.SNAPSHOT_END).bytes())
	for b in out:
		_send(b, peer, MultiplayerPeer.TRANSFER_MODE_RELIABLE, RGDProtocol.CH_RELIABLE)
	_ready_peers[peer] = true


## Server: forgets [param peer]; nodes it owned go back to the server.
func peer_left(peer: int) -> void:
	_ready_peers.erase(peer)
	_owned_tick.erase(peer)
	_peer_units.erase(peer)
	_pending_stream.erase(peer)
	for id in _recs:
		var r: Rec = _recs[id]
		if r.owner_peer == peer:
			if is_instance_valid(r.node):
				# Back to the server, which simulates it again (a rigid body was frozen here,
				# following the owner): it carries on with the owner's last velocity.
				set_net_owner(r.node, 0)
			else:
				r.owner_peer = 0
				r.owner_dirty = true


## Server: true once [param peer] got its snapshot and receives live updates.
func is_peer_ready(peer: int) -> bool:
	return _ready_peers.has(peer)


## Server: peers that receive live updates.
func ready_peers() -> Array:
	return _ready_peers.keys()


## Server: [param peer] (0 = server) simulates [param n]. Rigid bodies simulate only on their owner.
func set_net_owner(n: Node, peer: int) -> void:
	var r: Rec = _recs.get(id_of(n))
	if r == null:
		push_error("RGD: set_network_owner: %s isn't replicated." % n)
		return
	if r.owner_peer != peer:
		r.owner_peer = peer
		r.owner_dirty = true
	n.set_meta(META_OWNER, peer)
	if _is_rigid(n):
		# The owner simulates: the server's copy follows the owner's stream while a
		# remote player owns it.
		_set_simulated(n, peer == 0 or (is_client and peer == local_peer))


## The peer that simulates [param n], 0 = the server.
func get_owner_peer(n: Node) -> int:
	if is_server:
		var r: Rec = _recs.get(id_of(n))
		return r.owner_peer if r else 0
	return int(n.get_meta(META_OWNER, 0))


## Server: polls [param n] right away, or starts replicating it if it just became replicable.
func mark_dirty(n: Node) -> void:
	var r: Rec = _recs.get(id_of(n))
	if r:
		r.idle = 0
		r.last.clear()  # resend every value, e.g. a runtime material edited in place
	elif n.is_inside_tree() and _replicable(n):
		# E.g. taken out of the `server_only` group at runtime: start replicating it.
		register_now(n)


## Server: moves [param n] without interpolation; its owner gets a CORRECTION.
func teleport(n: Node, xform: Variant) -> void:
	n.transform = xform
	var r: Rec = _recs.get(id_of(n))
	if r == null:
		return
	r.teleport = true
	r.idle = 0
	if r.owner_peer != 0 and r.owner_peer != local_peer and _ready_peers.has(r.owner_peer):
		_send(W.new(Msg.CORRECTION).varint(r.id).u8(1 if xform is Transform2D else 0).xform(xform).bytes(), r.owner_peer,
			MultiplayerPeer.TRANSFER_MODE_RELIABLE, RGDProtocol.CH_RELIABLE)


# ---------------------------------------------------------------------------------------------
# Remotes (both sides)
# ---------------------------------------------------------------------------------------------

## Sends a remote call for [param remote] to [param target_peer]. False if the remote isn't replicated.
func send_remote(target_peer: int, remote: Node, args: Array, msg := Msg.REMOTE_EVENT, extra := -1) -> bool:
	var id := id_of(remote)
	if id == 0:
		return false
	if not _connected(target_peer):
		return true  # they just left (a remote fired from player_removing): nothing to send
	if is_client and not is_server and not (_owned.is_empty() and _owner_xform.is_empty()):
		# The remote goes on the reliable channel, positions on the faster unreliable one, so
		# a remote could reach the server before the position it was sent from. Send pending
		# positions reliably first: the server then sees where we were when we sent it.
		_send_owned(false, true)
	if is_client and not is_server:
		_send_owner_props()
	var w := W.new(msg, id_of).varint(id)
	if extra >= 0:
		w.varint(extra)
	if is_client and not is_server:
		# The server tick this client is showing, for Game.rewind (lag compensation).
		w.f32(_play_tick if _latest_tick >= 0.0 else -1.0)
	w.value(args)
	_stats_remotes[remote.name] = _stats_remotes.get(remote.name, 0) + 1
	_send(w.bytes(), target_peer, MultiplayerPeer.TRANSFER_MODE_RELIABLE, RGDProtocol.CH_RELIABLE)
	return true


## Sends an already-encoded message reliably.
func send_raw(peer: int, bytes: PackedByteArray) -> void:
	if _connected(peer):
		_send(bytes, peer, MultiplayerPeer.TRANSFER_MODE_RELIABLE, RGDProtocol.CH_RELIABLE)


## False for a peer that has disconnected: sending to it would make Godot print an error.
func _connected(peer: int) -> bool:
	return peer <= 1 or not is_server or mp == null or mp.get_peers().has(peer)


# ---------------------------------------------------------------------------------------------
# Packets
# ---------------------------------------------------------------------------------------------

## Entry point for every RGD packet from [param peer].
func handle_packet(peer: int, data: PackedByteArray) -> void:
	_stats_in[peer] = _stats_in.get(peer, 0) + data.size()
	var rd := R.new(data, node_of)
	rd.allow_inline = not is_server
	rd.untrusted = is_server  # what clients send is checked before Godot decodes it
	var msg := rd.u8()
	if is_server:
		_server_packet(peer, msg, rd)
	else:
		_client_packet(msg, rd)
	if rd.failed:
		if is_server:
			game._bad_input(peer, "a malformed message (type %d)" % msg)
		else:
			game._warn_limited("malformed", "RGD: malformed message %d from the server" % msg)


func _server_packet(peer: int, msg: int, rd: R) -> void:
	if not _ready_peers.has(peer):
		return
	match msg:
		Msg.OWNED_STATE:
			var client_tick := rd.varint()
			# Skip states older than one already applied (a stream packet overtaken by a
			# reliable flush, see send_remote).
			if client_tick < int(_owned_tick.get(peer, 0)):
				return
			_owned_tick[peer] = client_tick
			var n := rd.varint()
			for i in n:
				var id := rd.varint()
				var is_2d := rd.u8() == 1
				var xf: Variant = rd.xform(is_2d)
				var vel: Variant = rd.vec2() if is_2d else rd.vec3()
				if rd.failed:
					return
				if not _sane_xform(xf) or not vel.is_finite():
					game._bad_input(peer, "a position that isn't a number (or a collapsed rotation)")
					continue
				var r: Rec = _recs.get(id)
				if r == null or not is_instance_valid(r.node):
					continue
				if r.owner_peer != peer:
					# A child of the peer's own body (e.g. a model turned to face movement).
					if r.xkind == 0 or not _under_owned(r.node, peer):
						continue
					r.xform_author = peer
				if game.ownership_validator.is_valid() and not game.ownership_validator.call(game.players.get_by_id(peer), r.node, {transform = xf, velocity = vel}):
					continue
				if (r.xkind == 2) != is_2d:
					continue
				r.node.transform = xf
				_set_velocity(r.node, vel)
		Msg.REMOTE_EVENT, Msg.INVOKE, Msg.INVOKE_RESULT:
			var id := rd.varint()
			var extra := rd.varint() if msg != Msg.REMOTE_EVENT else -1
			var view := rd.f32()
			var args = rd.value()
			var n := node_of(id)
			if n == null or rd.failed or not (args is Array):
				return
			if msg != Msg.INVOKE_RESULT:
				_view_tick[peer] = view
			_stats_remotes[n.name] = _stats_remotes.get(n.name, 0) + 1
			game._remote_from_client(peer, n, msg, extra, args)
		Msg.OWNER_PROPS:
			_server_owner_props(peer, rd)
		Msg.PING, Msg.PONG, Msg.CUSTOM:
			_common_packet(peer, msg, rd)


## PING/PONG (round-trip time on any transport) and CUSTOM (Game.send_message), both ways.
func _common_packet(peer: int, msg: int, rd: R) -> void:
	match msg:
		Msg.PING:
			var t := rd.f64()
			if not rd.failed:
				_send(W.new(Msg.PONG).f64(t).bytes(), peer, MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED, RGDProtocol.CH_STREAM)
		Msg.PONG:
			var t := rd.f64()
			if not rd.failed:
				var rtt := Time.get_ticks_usec() / 1000.0 - t
				_rtt[peer] = rtt if not _rtt.has(peer) else lerpf(_rtt[peer], rtt, 0.3)
		Msg.CUSTOM:
			var data = rd.value()
			if not rd.failed:
				game._deliver_message(peer, data)


## Round-trip time to [param peer] in msec (0 = not measured yet).
func ping_of(peer: int) -> int:
	return int(round(_rtt.get(peer, 0.0)))


## Sends a Game.send_message payload.
func send_custom(peer: int, data: Variant, reliable: bool) -> void:
	var b := W.new(Msg.CUSTOM, id_of).value(data).bytes()
	if reliable:
		_send(b, peer, MultiplayerPeer.TRANSFER_MODE_RELIABLE, RGDProtocol.CH_RELIABLE)
	else:
		_send(b, peer, MultiplayerPeer.TRANSFER_MODE_UNRELIABLE, RGDProtocol.CH_STREAM)


## Server: Game.set_auto_sync.
func set_auto_sync(n: Node, enabled: bool) -> void:
	var r: Rec = _recs.get(id_of(n))
	if r == null:
		push_error("RGD: set_auto_sync: %s isn't replicated." % n)
		return
	r.manual = not enabled
	r.idle = 0


## Server: Game.sync: sends [param n]'s values (all, or [param names]) and transform now.
func sync_now(n: Node, names: Array) -> void:
	var r: Rec = _recs.get(id_of(n))
	if r == null:
		push_error("RGD: sync: %s isn't replicated." % n)
		return
	var props: Array = r.props if names.is_empty() else names.filter(func(p): return StringName(p) in r.props).map(func(p): return StringName(p))
	for p in props:
		r.last[p] = _copy(n.get(p))
	var with_xform := r.xkind != 0 and names.is_empty()
	if with_xform:
		r.last_xform = n.transform
		r.xform_init = true
	var b := _msg_props(r, props, with_xform, true)
	# String definitions first (the message may use new ones).
	for sid in _new_strings:
		var def := W.new(Msg.STRING_DEF).varint(sid).string(_string_list[sid]).bytes()
		for peer in _ready_peers:
			_send(def, peer, MultiplayerPeer.TRANSFER_MODE_RELIABLE, RGDProtocol.CH_RELIABLE)
	_new_strings.clear()
	for peer in _ready_peers:
		var units: Dictionary = _peer_units.get(peer, {})
		if r.unit == 0 or units.has(r.unit):
			_send(b, peer, MultiplayerPeer.TRANSFER_MODE_RELIABLE, RGDProtocol.CH_RELIABLE)
	for p in props:
		emit_changed(n, p, n.get(p))


func _client_packet(msg: int, rd: R) -> void:
	match msg:
		Msg.SNAPSHOT_BEGIN:
			_in_snapshot = true
		Msg.STRING_DEF:
			var id := rd.varint()
			_client_strings[id] = StringName(rd.string())
		Msg.WORLD_MAP:
			_client_world_map(rd)
		Msg.SPAWN_SCENE:
			_client_spawn_scene(rd)
		Msg.SPAWN_NODE:
			_client_spawn_node(rd)
		Msg.PROPS:
			_client_props(rd)
		Msg.PLACE:
			var id := rd.varint()
			var pid := rd.varint()
			var nm := rd.string()
			_client_place(id, pid, nm)
		Msg.DESPAWN:
			_client_despawn(rd.varint())
		Msg.STREAM_OUT:
			var id := rd.varint()
			var park := rd.string()
			if not rd.failed:
				_client_stream_out(id, park)
		Msg.OWNER:
			var id := rd.varint()
			var peer := rd.varint()
			var n := node_of(id)
			if n:
				n.set_meta(META_OWNER, peer)
				if _is_rigid(n):
					_set_simulated(n, peer == local_peer and peer != 0)
			if peer == local_peer and peer != 0:
				_owned[id] = true
				_interp.erase(id)
			else:
				_owned.erase(id)
				_owned_last.erase(id)
		Msg.XFORM_BATCH:
			_client_xform_batch(rd)
		Msg.CORRECTION:
			var id := rd.varint()
			var is_2d := rd.u8() == 1
			var xf: Variant = rd.xform(is_2d)
			var n := node_of(id)
			if n != null and ((n is Node2D) == is_2d) and (n is Node3D or n is Node2D):
				n.transform = xf
				_set_velocity(n, Vector2.ZERO if is_2d else Vector3.ZERO)
		Msg.REMOTE_EVENT, Msg.INVOKE, Msg.INVOKE_RESULT:
			var id := rd.varint()
			var extra := rd.varint() if msg != Msg.REMOTE_EVENT else -1
			var args = rd.value()
			var n := node_of(id)
			if n == null or rd.failed or not (args is Array):
				return
			_stats_remotes[n.name] = _stats_remotes.get(n.name, 0) + 1
			game._remote_from_server(n, msg, extra, args)
		Msg.SNAPSHOT_END:
			_in_snapshot = false
			snapshot_finished.emit()
		Msg.PING, Msg.PONG, Msg.CUSTOM:
			_common_packet(1, msg, rd)
		_:
			game._client_message(msg, rd)


# ---------------------------------------------------------------------------------------------
# Client: applying the server's tree
# ---------------------------------------------------------------------------------------------

## Client: the world instance (outside the tree until the snapshot ends) and the Players anchor.
func client_set_world(world: Node, players_anchor: Node, players_anchor_id: int) -> void:
	_world = world
	_players_anchor = players_anchor
	_bind(players_anchor_id, players_anchor)


func _client_world_map(rd: R) -> void:
	var n := rd.varint()
	var keep := {}
	for i in n:
		var path := rd.string()
		var id := rd.varint()
		var node := _world.get_node_or_null(path) if path != "." else _world
		if node:
			_bind(id, node)
			keep[node] = true
	# Streaming: world parts out of range wait outside the tree until they stream in.
	var parked := rd.varint()
	for i in parked:
		var path := rd.string()
		var id := rd.varint()
		var node := _world.get_node_or_null(path) if not rd.failed else null
		if node and node != _world:
			node.get_parent().remove_child(node)
			_parked[path] = node
			_parked_ids[id] = path
	_prune_unmapped(_world, keep, null)


## Frees nodes of a fresh instance that the server doesn't have (it freed them, or they're
## not meant to exist), keeping client-only nodes.
func _prune_unmapped(n: Node, keep: Dictionary, ui: Node) -> void:
	for c in n.get_children():
		if keep.has(c):
			_prune_unmapped(c, keep, ui)
		elif c == ui or c.is_in_group(ScriptContext.GROUP_LOCAL) or c.has_meta(META_NO_REPLICATE):
			continue
		else:
			n.remove_child(c)
			c.free()


func _client_spawn_scene(rd: R) -> void:
	var id := rd.varint()
	var pid := rd.varint()
	var nm := rd.string()
	var path := rd.string()
	var sub := rd.string()
	var ctx_owner := rd.varint()
	var count := rd.varint()
	var internals: Array = []
	for i in count:
		internals.append([rd.string(), rd.varint()])
	if rd.failed or node_of(id) != null:
		return
	if not path.begins_with("res://") or not ResourceLoader.exists(path):
		push_error("RGD: server spawned unknown scene %s" % path)
		return
	var root: Node = null
	if path == game._world_path and _parked.has(sub):
		# A world part streaming back in: reuse the copy parked when it streamed out.
		root = _parked[sub]
		_parked.erase(sub)
		_parked_ids.erase(_parked_ids.find_key(sub))
		sub = ""
	else:
		var packed := load(path) as PackedScene
		var ctx := RGDInstancer.make_ctx(false, true, ctx_owner != 0, ctx_owner == local_peer)
		root = RGDInstancer.instantiate(packed, ctx)
	if root == null:
		return
	if sub != "":
		var part := root.get_node_or_null(NodePath(sub))
		if part == null:
			root.free()
			return
		part.get_parent().remove_child(part)
		root.free()
		root = part
	root.name = nm
	if ctx_owner != 0:
		root.set_meta(RGDInstancer.META_CTX_OWNER, ctx_owner)
	_bind(id, root)
	var keep := {}
	for e in internals:
		var n := root.get_node_or_null(NodePath(e[0]))
		if n:
			_bind(e[1], n)
			keep[n] = true
	var ui = root.get(&"ui") if ctx_owner != 0 and sub == "" else null
	_prune_unmapped(root, keep, ui if ui is Node else null)
	if ctx_owner != 0 and ctx_owner == local_peer and not is_server:
		_register_owner_node(id, root)
		for e in internals:
			var inner := node_of(e[1])
			if inner:
				_register_owner_node(e[1], inner)
	_limbo[id] = root
	node_spawned.emit(root, ctx_owner)
	if pid != 0:
		_client_place(id, pid, nm)


func _client_spawn_node(rd: R) -> void:
	var id := rd.varint()
	var pid := rd.varint()
	var nm := rd.string()
	var cls := rd.string()
	var script_path := rd.string()
	var ctx_owner := rd.varint()
	if rd.failed or node_of(id) != null:
		return
	if not ClassDB.class_exists(cls) or not ClassDB.can_instantiate(cls) or not ClassDB.is_parent_class(cls, &"Node"):
		push_error("RGD: server spawned unknown class %s" % cls)
		return
	var n: Node = ClassDB.instantiate(cls)
	if script_path.begins_with("res://") and ResourceLoader.exists(script_path):
		var s := load(script_path) as Script
		if s:
			var keep := ScriptContext.script_that_runs_here(s, false, &"", false, true, false)
			if keep:
				n.set_script(keep)
	n.name = nm
	if ctx_owner != 0:
		n.set_meta(RGDInstancer.META_CTX_OWNER, ctx_owner)
	_bind(id, n)
	_limbo[id] = n
	node_spawned.emit(n, ctx_owner)
	if pid != 0:
		_client_place(id, pid, nm)


func _client_place(id: int, pid: int, nm: String) -> void:
	var n := node_of(id)
	var p := node_of(pid)
	if n == null or p == null or n == p or n.is_ancestor_of(p):
		return
	_limbo.erase(id)
	var cur := n.get_parent()
	if cur == p:
		if n.name != nm:
			n.name = nm
		return
	if cur:
		cur.remove_child(n)
	n.name = nm
	_clear_foreign_owner(n, p)
	p.add_child(n)


## A node moved out of its instance keeps an owner that's no longer an ancestor; clear it
## (and for its descendants) like Node.reparent() would.
static func _clear_foreign_owner(n: Node, new_parent: Node) -> void:
	var o := n.owner
	if o != null and o != new_parent and not o.is_ancestor_of(new_parent):
		n.owner = null
		_clear_owner_below(n, o)


static func _clear_owner_below(n: Node, old_owner: Node) -> void:
	for c in n.get_children():
		if c.owner == old_owner:
			c.owner = n
		_clear_owner_below(c, old_owner)


## Streaming: the unit left this client's radius. World parts are parked (outside the tree,
## reused when they stream back in); everything else is freed.
func _client_stream_out(id: int, park: String) -> void:
	var n := node_of(id)
	if n == null or park == "":
		_client_despawn(id)
		return
	_unbind(id)
	_limbo.erase(id)
	_interp.erase(id)
	_owned.erase(id)
	_unbind_subtree(n)
	if n.get_parent():
		n.get_parent().remove_child(n)
	if _parked.has(park) and is_instance_valid(_parked[park]):
		_parked[park].free()
	_parked[park] = n
	_parked_ids[id] = park


func _client_despawn(id: int) -> void:
	if _parked_ids.has(id):
		# Freed on the server while parked here.
		var path: String = _parked_ids[id]
		_parked_ids.erase(id)
		if _parked.has(path) and is_instance_valid(_parked[path]):
			_parked[path].free()
		_parked.erase(path)
	var n := node_of(id)
	_unbind(id)
	_limbo.erase(id)
	_interp.erase(id)
	_owned.erase(id)
	if n == null:
		return
	_unbind_subtree(n)
	if n.get_parent():
		n.get_parent().remove_child(n)
	n.queue_free()


func _unbind_subtree(n: Node) -> void:
	for c in n.get_children():
		var cid := id_of(c)
		if cid:
			_unbind(cid)
			_interp.erase(cid)
			_owned.erase(cid)
		_unbind_subtree(c)


func _client_props(rd: R) -> void:
	var id := rd.varint()
	var flags := rd.u8()
	var xf: Variant = null
	if flags & 1:
		xf = rd.xform(flags & 4 != 0)
	var count := rd.varint()
	var pairs: Array = []
	for i in count:
		var sid := rd.varint()
		pairs.append([_client_strings.get(sid, &""), rd.value()])
	if rd.failed:
		return
	var n := node_of(id)
	if n == null:
		return
	if flags & 1 and _xform_matches(n, xf) and not _owned.has(id) and not (_owner_xform.has(id) and _under_owned_here(n)):
		var buf: Array = _interp.get(id, [])
		if buf.is_empty() or flags & 2 or _in_snapshot:
			_interp.erase(id)
			n.transform = xf
		elif not buf[-1][1].is_equal_approx(xf):
			buf.append([buf[-1][0] + 1.0, xf, false])
	for pv in pairs:
		if pv[0] != &"":
			_apply_value(n, pv[0], pv[1])


func _apply_value(n: Node, prop: StringName, value: Variant) -> void:
	if value is RGDWire.SubRes:
		var cur = n.get(prop) if prop in n else null
		if cur is Resource and cur.resource_path == value.path:
			return  # the client's copy came from the same scene file
		if ResourceLoader.has_cached(value.path):
			value = ResourceLoader.get_cached_ref(value.path)
		else:
			value = null
	if prop in n:
		value = _fit_to(n.get(prop), value)
		n.set(prop, value)
		if prop == &"animation" and (n is AnimatedSprite2D or n is AnimatedSprite3D) and value != &"":
			n.play(value)  # the sender was playing it
		if OS.is_debug_build() and not WRITE_CHECK_EXEMPT.has(prop):
			(_applied.get_or_add(id_of(n), {}) as Dictionary)[prop] = _copy(value)
	else:
		var vals: Dictionary = n.get_meta(META_VALUES, {})
		vals[prop] = value
		n.set_meta(META_VALUES, vals)
	emit_changed(n, prop, value)


## Emits the signal returned by Game.changed(node, prop), if anyone asked for it.
func emit_changed(n: Node, prop: StringName, value: Variant) -> void:
	var sig := CHANGED_PREFIX + String(prop)
	if n.has_user_signal(sig):
		n.emit_signal(sig, value)


func _client_xform_batch(rd: R) -> void:
	var tick := float(rd.varint())
	var count := rd.varint()
	for i in count:
		var id := rd.varint()
		var flags := rd.u8()
		var snap := flags & 1 != 0
		var xf: Variant = rd.xform(flags & 2 != 0)
		if rd.failed:
			return
		if _owned.has(id) or not _xform_matches(node_of(id), xf):
			continue
		if _owner_xform.has(id) and _under_owned_here(node_of(id)):
			continue  # I move it myself
		var buf: Array = _interp.get_or_add(id, [])
		if buf and tick <= buf[-1][0]:
			continue
		buf.append([tick, xf, snap])
	if tick > _latest_tick:
		if _latest_tick < 0.0:
			_play_tick = tick - interpolation_delay * tick_rate
		_latest_tick = tick


func _process(delta: float) -> void:
	if not is_client or is_server:
		return
	_write_check_frame += 1
	if _write_check_frame % 30 == 0 and OS.is_debug_build() and not _in_snapshot:
		_check_client_writes()
	if _latest_tick < 0.0:
		return
	# Playback clock: runs at tick rate, eased toward (latest received - delay).
	_play_tick += delta * tick_rate
	var target := _latest_tick - interpolation_delay * tick_rate
	var err := target - _play_tick
	if absf(err) > tick_rate * 0.5:
		_play_tick = target
	else:
		_play_tick += err * minf(1.0, delta * 2.0)
	for id in _interp.keys():
		var n := node_of(id)
		var buf: Array = _interp[id]
		if n == null:
			_interp.erase(id)
			continue
		while buf.size() >= 2 and buf[1][0] <= _play_tick:
			buf.pop_front()
		if buf.is_empty():
			continue
		var a: Array = buf[0]
		if buf.size() == 1 or a[0] >= _play_tick:
			n.transform = a[1]
			if buf.size() == 1 and _play_tick - a[0] > tick_rate:
				_interp.erase(id)
			continue
		var b: Array = buf[1]
		if b[2]:
			n.transform = a[1]
			continue
		var t := clampf((_play_tick - a[0]) / maxf(b[0] - a[0], 0.0001), 0.0, 1.0)
		n.transform = a[1].interpolate_with(b[1], t)


## Debug builds: warn once when a client changes a replicated property locally.
func _check_client_writes() -> void:
	for id in _applied.keys():
		var n := node_of(id)
		if n == null:
			_applied.erase(id)
			continue
		if _in_owned_subtree(n):
			continue
		var vals: Dictionary = _applied[id]
		for prop in vals:
			if _same(vals[prop], n.get(prop)):
				continue
			var key := "%s|%s" % [n.get_path(), prop]
			if not _write_warned.has(key):
				_write_warned[key] = true
				push_warning("RGD: Client changed %s.%s, which is the server's (it replicates from there), so this change stays on this machine and the next server value overwrites it. To change it for everyone, ask the server with a RemoteEvent. If it's just this machine's own state, name it _%s (variables starting with _ don't replicate)." % [n.name, prop, prop])
			vals[prop] = _copy(n.get(prop))


func _in_owned_subtree(n: Node) -> bool:
	var c := n
	while c != null:
		if _owned.has(id_of(c)):
			return true
		c = c.get_parent()
	return false


func _client_tick() -> void:
	_tick += 1
	if not _owner_props.is_empty():
		_send_owner_props()
	if not _owned.is_empty() or not _owner_xform.is_empty():
		_send_owned(_tick % 10 == 0, false)


## Client: true if an ancestor of [param n] is a body this machine owns.
func _under_owned_here(n: Node) -> bool:
	var c := n.get_parent()
	while c != null:
		if _owned.has(id_of(c)):
			return true
		c = c.get_parent()
	return false


## Client: registers the nodes of this machine's own player scene whose values it authors
## (public variables of scripts that run only here, AnimationPlayer state).
func _register_owner_node(id: int, n: Node) -> void:
	var props: Array = []
	for cls in OWNER_PROFILE:
		if n.is_class(cls):
			props.append_array(OWNER_PROFILE[cls])
	var s: Script = n.get_script()
	if s != null and not (ScriptContext.run_mask(s.resource_path, true) & ScriptContext.SERVER):
		props.append_array(owner_script_props(s))
	if not props.is_empty():
		_owner_props[id] = props
	if _authors_transform(n):
		_owner_xform[id] = true


## Client: true if this machine sends [param n]'s transform when it changes it (a child of
## its own character). Not cameras, spring arms, `top_level` nodes (rigs that follow on
## their own) or anything under them, and not bone attachments (each machine poses those).
static func _authors_transform(n: Node) -> bool:
	if not (n is Node3D or n is Node2D):
		return false
	if n is BoneAttachment3D and not n.override_pose:
		return false
	var c := n
	while c != null and (c is Node3D or c is Node2D):
		if c is Camera3D or c is SpringArm3D or c is Camera2D or c.top_level:
			return false
		c = c.get_parent()
	return true


## Client: sends the values it authors that changed since they were last sent (reliable).
func _send_owner_props() -> void:
	var entries: Array = []  # [id, node, [props]]
	for id in _owner_props.keys():
		var n := node_of(id)
		if n == null:
			_owner_props.erase(id)
			_owner_last.erase(id)
			continue
		var last: Dictionary = _owner_last.get_or_add(id, {})
		var changed: Array = []
		for p in _owner_props[id]:
			var v = n.get(p)
			if not last.has(p) or not _same(last[p], v):
				last[p] = _copy(v)
				changed.append(p)
		if changed:
			entries.append([id, n, changed])
	if entries.is_empty():
		return
	var w := W.new(Msg.OWNER_PROPS, id_of).varint(entries.size())
	for e in entries:
		w.varint(e[0]).varint(e[2].size())
		for p in e[2]:
			w.string(p).value(e[1].get(p))
	_send(w.bytes(), 1, MultiplayerPeer.TRANSFER_MODE_RELIABLE, RGDProtocol.CH_RELIABLE)


## Client: sends the transforms of the nodes this machine owns that changed since they were
## last sent ([param heartbeat]: all of them). Normally on the unreliable stream; [param
## reliable] puts them on the reliable channel, ahead of a remote call (see send_remote).
func _send_owned(heartbeat: bool, reliable: bool) -> void:
	var entries: Array = []
	var ids: Array = _owned.keys()
	for id in _owner_xform.keys():
		if not _owned.has(id):
			ids.append(id)
	for id in ids:
		var n := node_of(id)
		if n == null or not (n is Node3D or n is Node2D):
			if n == null:
				_owner_xform.erase(id)
			continue
		if _owner_xform.has(id) and not _owned.has(id) and not _under_owned_here(n):
			continue  # not under my body any more (or not yet): the server decides
		var xf: Variant = n.transform
		if _owned_last.get(id) == xf and not heartbeat:
			continue
		_owned_last[id] = xf
		entries.append([id, xf, _get_velocity(n)])
	if entries.is_empty():
		return
	var w := W.new(Msg.OWNED_STATE).varint(_tick).varint(entries.size())
	for e in entries:
		var is_2d: bool = e[1] is Transform2D
		w.varint(e[0]).u8(1 if is_2d else 0).xform(e[1])
		if is_2d:
			w.vec2(e[2])
		else:
			w.vec3(e[2])
	if reliable:
		_send(w.bytes(), 1, MultiplayerPeer.TRANSFER_MODE_RELIABLE, RGDProtocol.CH_RELIABLE)
	else:
		_send(w.bytes(), 1, MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED, RGDProtocol.CH_STREAM)


static func _is_rigid(n: Node) -> bool:
	return n is RigidBody3D or n is RigidBody2D


## Rigid bodies simulate only where they're owned; elsewhere they're kinematic and follow
## the stream.
static func _set_simulated(n: Node, simulated: bool) -> void:
	if n is RigidBody3D:
		n.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	elif n is RigidBody2D:
		n.freeze_mode = RigidBody2D.FREEZE_MODE_KINEMATIC
	n.freeze = not simulated


static func _get_velocity(n: Node) -> Variant:
	if n is CharacterBody3D or n is CharacterBody2D:
		return n.velocity
	if n is RigidBody3D or n is RigidBody2D:
		return n.linear_velocity
	return Vector2.ZERO if n is Node2D else Vector3.ZERO


static func _set_velocity(n: Node, v: Variant) -> void:
	if n is CharacterBody3D or n is CharacterBody2D:
		n.velocity = v
	elif n is RigidBody3D or n is RigidBody2D:
		n.linear_velocity = v


static func _xform_matches(n: Node, xf: Variant) -> bool:
	return (n is Node3D and xf is Transform3D) or (n is Node2D and xf is Transform2D)


# ---------------------------------------------------------------------------------------------
# Net stats (plan 6.9)
# ---------------------------------------------------------------------------------------------

var _stats_out := {}  # peer -> bytes this window
var _stats_in := {}  # peer -> bytes this window
var _stats_nodes := {}  # id -> bytes this window
var _stats_props := {}  # "Node.prop" -> changes this window
var _stats_remotes := {}  # remote name -> calls this window
var _stats_window_start := 0
var _stats_tick_usec := 0
var _stats_tick_max := 0
var _stats_ticks := 0
var _stats_last := {}  # last full window, see net_stats()
## Network stats are averaged over this many milliseconds.
const STATS_WINDOW_MSEC := 2000


func _send(bytes: PackedByteArray, peer: int, mode: int, channel: int) -> void:
	_stats_out[peer] = _stats_out.get(peer, 0) + bytes.size()
	_tick_bytes[peer] = _tick_bytes.get(peer, 0) + bytes.size()
	mp.send_bytes(bytes, peer, mode, channel)


func _stat_node(id: int, size: int) -> void:
	_stats_nodes[id] = _stats_nodes.get(id, 0) + size


func _roll_stats() -> void:
	var now := Time.get_ticks_msec()
	if _stats_window_start == 0:
		_stats_window_start = now
	var span := now - _stats_window_start
	if span < STATS_WINDOW_MSEC:
		return
	var secs := span / 1000.0
	var per_sec := func(d: Dictionary) -> Dictionary:
		var out := {}
		for k in d:
			out[k] = d[k] / secs
		return out
	var nodes := []
	for id in _stats_nodes:
		var n := node_of(id)
		nodes.append([String(n.name) if n else "#%d" % id, _stats_nodes[id] / secs])
	nodes.sort_custom(func(a, b): return a[1] > b[1])
	var props := []
	for k in _stats_props:
		props.append([k, _stats_props[k] / secs])
	props.sort_custom(func(a, b): return a[1] > b[1])
	var ping := {}
	if mp.multiplayer_peer is ENetMultiplayerPeer:
		var enet := mp.multiplayer_peer as ENetMultiplayerPeer
		var peers: Array = _ready_peers.keys() if is_server else ([1] if enet.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED else [])
		for peer in peers:
			var link := enet.get_peer(peer)
			if link:
				ping[peer] = link.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME)
	for peer in _rtt:
		if not ping.has(peer):
			ping[peer] = ping_of(peer)  # other transports: RGD's own PING/PONG
	_stats_last = {
		bytes_out_per_sec = per_sec.call(_stats_out),
		bytes_in_per_sec = per_sec.call(_stats_in),
		top_nodes = nodes.slice(0, 10),
		top_props = props.slice(0, 10),
		remote_calls_per_sec = per_sec.call(_stats_remotes),
		ping_msec = ping,
		tick_usec_avg = _stats_tick_usec / maxi(_stats_ticks, 1),
		tick_usec_max = _stats_tick_max,
	}
	_stats_tick_usec = 0
	_stats_tick_max = 0
	_stats_ticks = 0
	_stats_out.clear()
	_stats_in.clear()
	_stats_nodes.clear()
	_stats_props.clear()
	_stats_remotes.clear()
	_stats_window_start = now


## Network numbers for the last couple of seconds (plan 6.9).
func net_stats() -> Dictionary:
	var d := _stats_last.duplicate()
	d.replicated_nodes = _recs.size() if is_server else _nodes.size()
	d.role = "host" if is_server and is_client else ("server" if is_server else "client")
	d.interpolating = _interp.size()
	if is_server:
		d.streamed_units = {}
		for peer in _peer_units:
			d.streamed_units[peer] = "%d/%d" % [_peer_units[peer].size(), _units.size()]
		var waiting := 0
		for peer in _pending_stream:
			waiting += _pending_stream[peer].size()
		d.stream_waiting = waiting
	else:
		d.parked = _parked.size()
	d.owned = _owned.size() if not is_server else _recs.values().filter(func(r): return r.owner_peer != 0).size()
	return d


## Client: true if this machine simulates [param n].
func owns(n: Node) -> bool:
	return _owned.has(id_of(n))
