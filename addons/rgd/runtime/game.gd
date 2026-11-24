extends Node
## The RGD runtime, registered as the `Game` autoload (plan 6.1, D12). It is the whole pipeline:
## sessions, [code]Game.players[/code], replication and remotes. No scene structure is required.
##
## [codeblock]
## func _on_host_pressed(): Game.host(7777, "res://levels/map.tscn")
## func _on_join_pressed(): Game.join($Address.text, {name = $Name.text})
## [/codeblock]

## The session is running: the world is loaded (and on clients, the initial state arrived).
signal session_started
## The session ended: left, server closed, or kicked.
## [codeblock]
## Game.session_ended.connect(func(reason: String):
##     $Menu/Status.text = "Disconnected: " + reason)
## [/codeblock]
signal session_ended(reason: String)
## A join attempt failed (couldn't connect, rejected, different builds...).
## [codeblock]
## Game.join_failed.connect(func(reason: String): $Status.text = "Couldn't join: " + reason)
## [/codeblock]
signal join_failed(reason: String)
## Everyone moved to a new world (Game.change_scene). Emitted on every machine.
signal scene_changed(path: String)
## A raw message from Game.send_message (the escape hatch). [param from_peer] is 1 for the
## server; on the server it's the sender's peer id (`Game.players.get_by_id(from_peer)`).
signal message_received(from_peer: int, data: Variant)

## Message types (see [RGDProtocol]).
const Msg := RGDProtocol.Msg
## The port used when none is given: 7777.
const DEFAULT_PORT := 7777
## Seconds a new connection has to say hello before the server drops it.
const HANDSHAKE_TIMEOUT := 10.0
## Metadata on a level's root node that overrides `rgd/player_scene` for that level.
const META_PLAYER_SCENE := &"rgd_player_scene"
## Metadata on a level's root node that overrides `rgd/menu_scene` for that level.
const META_MENU_SCENE := &"rgd_menu_scene"

## Every connected player (Roblox's `Players`).
var players: RGDPlayers
## Optional server-side check of owner-sent states: `func(player, node, state: Dictionary) -> bool`.
## [codeblock]
## # Reject characters moving faster than they could run.
## Game.ownership_validator = func(player: Player, node: Node, state: Dictionary) -> bool:
##     return node.global_position.distance_to(state.transform.origin) < 3.0
## [/codeblock]
var ownership_validator: Callable
## Optional server-side check of values a player's own machine sets in its player scene
## (public variables of its client scripts, its AnimationPlayers):
## `func(player, node, prop: StringName, value) -> bool`. Return false to ignore the value.
## [codeblock]
## Game.owner_value_validator = func(player: Player, node: Node, prop: StringName, value) -> bool:
##     return prop != &"aim_pitch" or absf(value) <= 1.5
## [/codeblock]
var owner_value_validator: Callable
## Optional server-side check of a joining client: `func(peer: int, name: String, data:
## Dictionary) -> String`. Return "" to let them in, or a reason to turn them away (they get
## join_failed(reason)). May `await` (e.g. ask your backend, or check a Steam auth ticket).
## [codeblock]
## Game.join_validator = func(peer: int, name: String, data: Dictionary) -> String:
##     var ok: bool = await Backend.check_token(data.get("token", ""))
##     return "" if ok else "not signed in"
## [/codeblock]
var join_validator: Callable

## RGD's empty scene, used to start processes without the project's main scene.
const BOOT_SCENE := "res://addons/rgd/runtime/boot.tscn"

var _rep: RGDReplicator
var _active := false
var _joining := false
var _is_server := false
var _is_client := false
var _world: Node
var _world_path := ""
var _pending_world: Node
var _pending_peers := {}  # peer -> seconds waited for HELLO
var _join_opts := {}
var _startup_role := ""
var _cmdline := {}
var _spawn_index := 0
var _closing_peers: Array = []  # [MultiplayerPeer, seconds, was_server]
var _overlay: CanvasLayer
var _print_stats_every := 0.0
var _print_stats_timer := 0.0
## Why the last session ended, when it wasn't your own choice: "the host left", "kicked", "the
## server shut down"... ("" otherwise). A menu can show it when the game returns to it.
## [codeblock]
## func _ready() -> void:   # menu.gd
##     if Game.last_end_reason != "":
##         $Status.text = "Session ended: " + Game.last_end_reason
## [/codeblock]
var last_end_reason := ""
## Why the last host / start_server / join / start_local_server call failed, in words a
## player understands ("port 7777 is already in use: ..."). "" after a success.
## [codeblock]
## if Game.host(Game.default_port(), LEVEL) != OK:
##     $Status.text = Game.last_error
## [/codeblock]
var last_error := ""

var _join_elapsed := 0.0
var _join_address := ""
var _join_local_port := 0  # joining / joined a local server this game started (0 = no)
var _wait_local := {}  # a join waiting for that local server to open its port: {host, port}
var _quitting := false
# Local servers (start_local_server). Each child watches its own "beat" file: a background thread
# here touches it every second while this game runs; deleting it stops that server.
var _local_servers := {}  # port -> {pid, scene, beat}
var _stopping := {}  # port -> pid of a local server that was told to stop
var _beat_files: PackedStringArray = []
var _server_pipes: Array = []  # debug builds: each local server's output, read by the beat thread
var _server_lines: PackedStringArray = []  # ...and printed here by the main thread
var _beat_mutex := Mutex.new()
var _beat_thread: Thread
var _beat_stop := false
var _parent_beat := ""  # in a local server: the starting game's beat file
var _parent_check := 0.0
var _calls: Array = []  # RemoteFunction.Call waiting for an answer (see _finish_calls)
var _bad_input_count := {}  # peer -> malformed messages received from it
var _warned_at := {}  # warning key -> [msec when last printed, how many were held back since]

## A client that sends this many malformed messages (or positions that aren't numbers) is
## kicked with "sent invalid data": a working client never sends one.
const BAD_INPUT_LIMIT := 50


func _enter_tree() -> void:
	RGDSettings.register()
	_cmdline = _parse_cmdline()
	_startup_role = _cmdline.get("rgd-role", "")
	if _startup_role == "" and OS.has_feature("dedicated_server"):
		_startup_role = "server"
	# Pausing the game (get_tree().paused, a pause menu) pauses your nodes, not the network:
	# replication, remotes and timeouts keep running, so nobody is disconnected or frozen.
	# Players (and their UI) pause like any other node.
	process_mode = Node.PROCESS_MODE_ALWAYS
	players = RGDPlayers.new()
	players.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(players)
	_rep = RGDReplicator.new()
	add_child(_rep)
	get_tree().node_added.connect(_on_any_node_added)


func _ready() -> void:
	if _cmdline.has("rgd-netstats"):
		_print_stats_every = float(_cmdline["rgd-netstats"]) if String(_cmdline["rgd-netstats"]).is_valid_float() else 5.0
	_parent_beat = _cmdline.get("rgd-parent-beat", "")
	if _startup_role != "":
		_start_from_cmdline.call_deferred()


func _process(delta: float) -> void:
	if _parent_beat != "":
		_parent_check += delta
		if _parent_check >= 0.25:
			_parent_check = 0.0
			if not _beat_alive(_parent_beat):
				_parent_beat = ""
				_quitting = true
				leave()  # the goodbye first: the game reading our output may be gone already
				print("RGD: the game that started this server closed or stopped it; shutting down.")
				get_tree().quit()
	if not _server_pipes.is_empty():
		_print_server_output()
	if not _calls.is_empty():
		_finish_calls()
	if not _wait_local.is_empty():
		_poll_wait_local()
	elif _joining and not _is_client:
		# No answer yet (no WELCOME): give up after rgd/network/timeout instead of hanging.
		_join_elapsed += delta
		if _join_elapsed > float(RGDSettings.get_value(RGDSettings.TIMEOUT)):
			_fail_join("couldn't reach %s (no answer)" % _join_address)
	if _print_stats_every > 0.0 and _active:
		_print_stats_timer += delta
		if _print_stats_timer >= _print_stats_every:
			_print_stats_timer = 0.0
			print("[netstats] ", RGDNetOverlay.format(get_net_stats()).replace("\n", "\n[netstats] "))
	for c in _closing_peers.duplicate():
		var p: MultiplayerPeer = c[0]
		c[1] += delta
		p.poll()
		var done := p.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED
		if not p is ENetMultiplayerPeer and c[1] > 0.3:
			done = true  # other transports: a moment to send what's queued, then close
		if not done and c[2] and p is ENetMultiplayerPeer:
			var enet_host := _enet_host(p)
			done = enet_host == null or enet_host.get_peers().all(
				func(l: ENetPacketPeer): return l.get_state() == ENetPacketPeer.STATE_DISCONNECTED)
		if done or c[1] > 1.0:
			p.close()
			_closing_peers.erase(c)
	if _pending_peers.is_empty():
		return
	for peer in _pending_peers.keys():
		_pending_peers[peer] += delta
		if _pending_peers[peer] > HANDSHAKE_TIMEOUT:
			_pending_peers.erase(peer)
			if multiplayer.has_multiplayer_peer():
				multiplayer.multiplayer_peer.disconnect_peer(peer)


# ---------------------------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------------------------

## Starts a dedicated server (no local player). [param scene]: the world; defaults to the
## current scene. [param port] 0 means [method default_port]; a port in use fails like
## [method host].
## [codeblock]
## # A "Start dedicated server" button in a tools menu:
## func _on_server_pressed() -> void:
##     Game.start_server(7777, "res://levels/arena.tscn")
## [/codeblock]
## A dedicated-server export doesn't need this call: it starts a server by itself, loading
## `rgd/server_scene` (or `--rgd-scene=...`, port from `--rgd-address=:7777`).
## [codeblock]
## # Command line for a server build:
## # ./server.x86_64 --headless -- --rgd-scene=res://levels/arena.tscn
## [/codeblock]
func start_server(port: int = 0, scene: String = "") -> Error:
	var made := _listen(port)
	if made[1] != OK:
		return made[1]
	return _begin_server(made[0], scene, false, {})


## Starts a dedicated server for this game on this computer, in a separate headless process,
## and returns its process id (-1 on failure, with the reason in [member last_error]). Join it
## with `Game.join("127.0.0.1")` right away: the join waits until the server is up.
## [codeblock]
## func _on_dedicated_pressed() -> void:
##     if Game.start_local_server(0, "res://levels/arena.tscn") > 0:
##         Game.join("127.0.0.1", {name = $Name.text})
##     else:
##         $Status.text = Game.last_error
## [/codeblock]
## The server stops when you leave a session on it, when this game quits (or crashes), when you
## host on its port, or with [method stop_local_server]. Calling this again while it runs returns
## the same server. Works from the editor and from exported builds.
func start_local_server(port: int = 0, scene: String = "") -> int:
	port = _port(port)
	if _local_servers.has(port):
		var mine: Dictionary = _local_servers[port]
		if OS.is_process_running(mine.pid) and mine.scene == scene:
			last_error = ""
			return mine.pid  # already running (a double click, or back from the menu)
		stop_local_server(port)  # another world on that port: replace it
	_wait_stopped(port)
	_close_closing_peers()
	if not port_free(port):
		_reap_orphans(port)
	if not port_free(port):
		last_error = "port %d is already in use: is a game already hosting on this computer? Join it instead." % port
		push_warning("RGD: " + last_error)
		return -1
	var beat := _add_beat_file(port)
	var args := PackedStringArray()
	if OS.has_feature("editor"):
		args.append_array(["--path", ProjectSettings.globalize_path("res://")])
	args.append_array(["--headless", BOOT_SCENE, "--", "--rgd-role=server", "--rgd-address=:%d" % port,
		"--rgd-parent-beat=" + beat])
	if scene != "":
		args.append("--rgd-scene=" + scene)
	var pid := -1
	if OS.is_debug_build():
		# Show what the server prints in this game's output (the editor's Output panel).
		var r := OS.execute_with_pipe(OS.get_executable_path(), args, false)
		if not r.is_empty():
			pid = r.pid
			_beat_mutex.lock()
			_server_pipes.append({pid = pid, out = r.stdio, err = r.stderr, rest = ["", ""]})
			_beat_mutex.unlock()
	else:
		pid = OS.create_process(OS.get_executable_path(), args)
	if pid <= 0:
		_remove_beat_file(beat)
		last_error = "couldn't start a server process"
		push_warning("RGD: " + last_error)
		return -1
	_local_servers[port] = {pid = pid, scene = scene, beat = beat}
	last_error = ""
	return pid


## Stops the dedicated server this game started on [param port] with [method start_local_server]
## (0 = all of them). Its players get "the server shut down". With [param wait], returns once
## the port is free again (at most 2 seconds).
## [codeblock]
## func _on_stop_server_pressed() -> void:
##     Game.stop_local_server()
## [/codeblock]
func stop_local_server(port: int = 0, wait := false) -> void:
	for p in _local_servers.keys():
		if port != 0 and p != port:
			continue
		_remove_beat_file(_local_servers[p].beat)  # the server sees it within 0.25 s and leaves
		_stopping[p] = _local_servers[p].pid
		_local_servers.erase(p)
		if wait:
			_wait_stopped(p)


## A local server on [param port] was told to stop: wait until it's gone (and its port free).
func _wait_stopped(port: int) -> void:
	if not _stopping.has(port):
		return
	var pid: int = _stopping[port]
	_stopping.erase(port)
	var end := Time.get_ticks_msec() + 2000
	while OS.is_process_running(pid):
		if Time.get_ticks_msec() > end:
			OS.kill(pid)  # didn't stop by itself (stuck): stop it the hard way
			OS.delay_msec(100)
			break
		OS.delay_msec(20)


## The port this game uses when you don't give one: `rgd/network/port` (7777 by default), or
## the RGD_PORT environment variable when it's set.
## [codeblock]
## Game.host(Game.default_port(), "res://levels/arena.tscn", {name = $Name.text})
## [/codeblock]
func default_port() -> int:
	var env := OS.get_environment("RGD_PORT")
	if env.is_valid_int() and int(env) > 0:
		return int(env)
	return int(RGDSettings.get_value(RGDSettings.PORT))


## True if nothing on this computer is listening on [param port] for this game's transport
## (UDP for ENet, TCP for WebSocket), so Game.host / start_server can use it.
## [codeblock]
## if not Game.port_free(7777):
##     $Status.text = "Someone on this computer is already hosting: join them!"
## [/codeblock]
static func port_free(port: int) -> bool:
	if str(RGDSettings.get_value(RGDSettings.TRANSPORT)) == "websocket":
		var tcp := TCPServer.new()
		var ok := tcp.listen(port) == OK
		tcp.stop()
		return ok
	var udp := PacketPeerUDP.new()
	var free := udp.bind(port) == OK  # unlike ENet, a busy port prints no error
	udp.close()
	return free


static func _beat_dir() -> String:
	return OS.get_user_data_dir().path_join("rgd_local_servers")


func _add_beat_file(port: int) -> String:
	var dir := _beat_dir()
	DirAccess.make_dir_recursive_absolute(dir)
	for f in DirAccess.get_files_at(dir):  # left behind by a crash
		if Time.get_unix_time_from_system() - FileAccess.get_modified_time(dir.path_join(f)) > 60.0:
			DirAccess.remove_absolute(dir.path_join(f))
	var beat := dir.path_join("%d_%d" % [OS.get_process_id(), port])
	DirAccess.remove_absolute(beat + ".state")
	_beat_mutex.lock()
	_touch(beat)
	_beat_files.append(beat)
	_beat_mutex.unlock()
	if _beat_thread == null:
		_beat_stop = false
		_beat_thread = Thread.new()
		_beat_thread.start(_beat_loop)
	return beat


func _remove_beat_file(beat: String) -> void:
	_beat_mutex.lock()
	var i := _beat_files.find(beat)
	if i >= 0:
		_beat_files.remove_at(i)
	DirAccess.remove_absolute(beat)
	DirAccess.remove_absolute(beat + ".state")
	_beat_mutex.unlock()


## Background thread: keeps the beat files fresh and reads the local servers' output, even while
## the game is paused in the debugger (a full pipe would freeze the server).
func _beat_loop() -> void:
	var n := 0
	while not _beat_stop:
		_beat_mutex.lock()
		if n % 10 == 0:
			for f in _beat_files:
				_touch(f)
		for p in _server_pipes:
			_read_pipes(p)
		_beat_mutex.unlock()
		n += 1
		OS.delay_msec(100)


## Reads what a local server printed since last time into _server_lines (lock the mutex first).
func _read_pipes(p: Dictionary) -> void:
	for i in 2:
		var io: FileAccess = p.out if i == 0 else p.err
		if io == null:
			continue
		var text: String = p.rest[i]
		while true:
			var b := io.get_buffer(65536)
			if b.is_empty():
				break
			text += b.get_string_from_utf8()
		var lines := text.split("\n")
		p.rest[i] = lines[lines.size() - 1]  # an unfinished line waits for the rest
		for j in lines.size() - 1:
			var line := lines[j].strip_edges(false, true)
			if line != "" and not line.begins_with("Godot Engine v"):
				_server_lines.append(("!" if i == 1 else " ") + line)


## Main thread: prints the local servers' output, and forgets servers that exited.
func _print_server_output() -> void:
	_beat_mutex.lock()
	for p in _server_pipes.duplicate():
		if not OS.is_process_running(p.pid):
			_read_pipes(p)  # what it printed last
			_server_pipes.erase(p)
	var lines := _server_lines
	_server_lines = PackedStringArray()
	_beat_mutex.unlock()
	for line in lines:
		if line.begins_with("!"):
			printerr("[Local server] ", line.substr(1))
		else:
			print("[Local server] ", line.substr(1))


static func _touch(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(str(Time.get_unix_time_from_system()))
		f.close()


## In a local server: false once the starting game deleted its beat file (stop) or stopped
## updating it for 3 seconds (it quit, crashed, or was stopped from the editor).
static func _beat_alive(beat: String) -> bool:
	return _beat_age(beat) < 3.0


## Seconds since the beat file was last touched (INF if it's gone).
static func _beat_age(beat: String) -> float:
	var f := FileAccess.open(beat, FileAccess.READ)
	if f == null:
		return INF
	var t := f.get_as_text().to_float()
	f.close()
	if t <= 0.0:
		return 0.0  # being rewritten this instant
	return Time.get_unix_time_from_system() - t


## The game that started a local server on [param port] is gone (stopped from the editor a
## moment ago, crashed) but the server hasn't noticed yet: stop it now and wait for the port.
func _reap_orphans(port: int) -> void:
	var dir := _beat_dir()
	var found := false
	for f in DirAccess.get_files_at(dir):
		if f.ends_with("_%d" % port) and not f.begins_with("%d_" % OS.get_process_id()):
			if _beat_age(dir.path_join(f)) > 1.5:
				DirAccess.remove_absolute(dir.path_join(f))
				found = true
	if found:
		var end := Time.get_ticks_msec() + 2000
		while Time.get_ticks_msec() < end and not port_free(port):
			OS.delay_msec(20)


## A join to a local server we just started: connect as soon as it says it's listening.
func _poll_wait_local() -> void:
	var port: int = _wait_local.port
	var mine: Dictionary = _local_servers.get(port, {})
	var state := ""
	if not mine.is_empty() and FileAccess.file_exists(mine.beat + ".state"):
		state = FileAccess.get_file_as_string(mine.beat + ".state")
	if state == "ready":
		var host_name: String = _wait_local.host
		_wait_local = {}
		var err := _connect_client(host_name, port)
		if err != OK:
			_fail_join("couldn't connect to %s (%s)" % [_join_address, error_string(err)])
		return
	if state.begins_with("error: ") or mine.is_empty() or not OS.is_process_running(mine.pid):
		var why := state.trim_prefix("error: ") if state.begins_with("error: ") else "it stopped while starting"
		stop_local_server(port)
		_fail_join("the dedicated server couldn't start: " + why)
		return
	_join_elapsed += get_process_delta_time()
	if _join_elapsed > 30.0:
		stop_local_server(port)
		_fail_join("the dedicated server took too long to start")


func _fail_join(reason: String) -> void:
	_end_session("couldn't join", false)
	last_error = reason
	join_failed.emit(reason)


func _exit_tree() -> void:
	if _beat_thread:
		_beat_stop = true
		_beat_thread.wait_to_finish()
		_beat_thread = null
	stop_local_server()  # they stop right away instead of 3 s later
	_server_pipes.clear()


## Server, lag compensation: casts the ray [param query] against the world as [param player]
## saw it when they sent the remote being handled. Other players' characters, drones and any
## other moving body are tested where they were on that player's screen, so a shot that looked
## like a hit is a hit. Returns the same Dictionary as `intersect_ray` ({} = no hit).
## [codeblock]
## func _on_shoot(player: Player, origin: Vector3, dir: Vector3) -> void:
##     var q := PhysicsRayQueryParameters3D.create(origin, origin + dir * 100.0)
##     q.exclude = [player.character.get_rid()]
##     var hit := Game.rewind_raycast(player, q)
##     if hit and Game.players.get_player_from_character(hit.collider):
##         ...
## [/codeblock]
## Works in 2D too: pass a PhysicsRayQueryParameters2D. Goes back at most
## `rgd/network/max_rewind` seconds. For the host's own player (who sees the present) it's a
## plain raycast.
func rewind_raycast(player: Player, query: Object) -> Dictionary:
	var root := get_tree().root
	if query is PhysicsRayQueryParameters2D:
		var space2 := root.world_2d.direct_space_state
		if not _is_server or player == null:
			return space2.intersect_ray(query)
		return _rep.rewind_raycast_2d(player.user_id, space2, query)
	var space := root.world_3d.direct_space_state
	if not _is_server or player == null:
		return space.intersect_ray(query)
	return _rep.rewind_raycast(player.user_id, space, query)


## Starts a server with a local player (listen server, peer id 1). [param port] 0 means
## [method default_port]. If another game on this computer already uses the port, returns an
## error and [member last_error] says so (a local server this game started there is stopped
## first: you're hosting there now).
## [codeblock]
## func _on_host_pressed() -> void:
##     if Game.host(7777, "res://levels/arena.tscn", {name = $Name.text}) != OK:
##         $Status.text = "Couldn't host: " + Game.last_error   # e.g. the port is in use
## [/codeblock]
func host(port: int = 0, scene: String = "", opts: Dictionary = {}) -> Error:
	var made := _listen(port)
	if made[1] != OK:
		return made[1]
	return _begin_server(made[0], scene, true, opts)


## Starts a single-player game: you're the host and nobody can join (nothing is opened on the
## network). The same game code runs as in multiplayer: world scripts on the "server" (this
## machine), your player scene, remotes (delivered locally). One code path for both modes.
## [codeblock]
## func _on_single_player_pressed() -> void:
##     Game.play_solo("res://levels/level_1.tscn", {name = "Player"})
## [/codeblock]
func play_solo(scene: String = "", opts: Dictionary = {}) -> Error:
	if not _ready_to_start():
		return ERR_ALREADY_IN_USE
	return _begin_server(OfflineMultiplayerPeer.new(), scene, true, opts)


## True in a single-player game started with [method play_solo].
func is_solo() -> bool:
	return _active and _is_server and multiplayer.multiplayer_peer is OfflineMultiplayerPeer


## Hosts using any MultiplayerPeer (already set up as a server): ENet, WebSocket, WebRTC,
## Steam (GodotSteam's SteamMultiplayerPeer)... RGD only needs `send_bytes` and peer ids.
## [codeblock]
## var peer := SteamMultiplayerPeer.new()
## peer.create_host(0)
## Game.host_with_peer(peer, "res://levels/arena.tscn", {name = Steam.getPersonaName()})
## [/codeblock]
func host_with_peer(peer: MultiplayerPeer, scene: String = "", opts: Dictionary = {}) -> Error:
	return _begin_server(peer, scene, true, opts)


## Starts a dedicated server (no local player) on any MultiplayerPeer already set up as a
## server. See [method host_with_peer].
func start_server_with_peer(peer: MultiplayerPeer, scene: String = "") -> Error:
	return _begin_server(peer, scene, false, {})


## Joins a server at `host:port` (without a port: [method default_port]). [param opts]: `{name = "...",
## data = {...}}`. `data` (plain values) reaches the server's [member join_validator] and
## `player.join_data`: use it for a login token, a Steam id or auth ticket, a chosen skin.
## [codeblock]
## func _on_join_pressed() -> void:
##     Game.join($Address.text, {name = $Name.text})  # "192.168.1.20", "myserver.com:7777"
## [/codeblock]
func join(address: String, opts: Dictionary = {}) -> Error:
	if not _ready_to_start():
		return ERR_ALREADY_IN_USE
	var parts := _split_address(address, default_port())
	var host_name: String = parts[0]
	var port: int = parts[1]
	if host_name == "" or host_name == "localhost":
		host_name = "127.0.0.1"
	if port < 1 or port > 65535:
		last_error = "%d isn't a valid port (1 to 65535)" % port
		join_failed.emit(last_error)
		return ERR_INVALID_PARAMETER
	var to := "%s:%d" % [("[%s]" % host_name) if ":" in host_name else host_name, port]
	var local := host_name in ["127.0.0.1", "::1"] and _local_servers.has(port) \
		and OS.is_process_running(_local_servers[port].pid)
	if local and not FileAccess.file_exists(_local_servers[port].beat + ".state"):
		# Our own local server is still starting: join once it's listening.
		_joining = true
		_join_opts = opts
		_join_elapsed = 0.0
		_join_address = to
		_join_local_port = port
		_wait_local = {host = host_name, port = port}
		last_error = ""
		last_end_reason = ""
		return OK
	_join_address = to
	var err := _connect_client(host_name, port, opts)
	if err == ERR_CANT_RESOLVE:
		last_error = "couldn't find \"%s\": check the address" % host_name
	elif err != OK:
		last_error = "couldn't connect to %s (%s)" % [to, error_string(err)]
	if err != OK:
		_join_address = ""
		join_failed.emit(last_error)
		return err
	if local:
		_join_local_port = port
	return OK


## Creates the client peer for this game's transport and starts joining.
func _connect_client(host_name: String, port: int, opts = null) -> Error:
	var peer: MultiplayerPeer
	var err: Error
	if _transport() == "websocket":
		var ws := WebSocketMultiplayerPeer.new()
		err = ws.create_client("ws://%s:%d" % [("[%s]" % host_name) if ":" in host_name else host_name, port])
		peer = ws
	else:
		# Resolve first: ENet prints errors for a name it can't find; this just fails.
		var ip := host_name if host_name.is_valid_ip_address() else IP.resolve_hostname(host_name)
		if ip == "":
			return ERR_CANT_RESOLVE
		var enet := ENetMultiplayerPeer.new()
		err = enet.create_client(ip, port, RGDProtocol.ENET_CHANNELS)
		peer = enet
	if err != OK:
		return err
	if peer is ENetMultiplayerPeer and (peer as ENetMultiplayerPeer).get_peer(1):
		_set_link_timeout_on((peer as ENetMultiplayerPeer).get_peer(1))  # give up as fast as we'd notice a drop
	if opts == null:
		# The join was already started (waiting for a local server): just plug in the peer.
		_join_elapsed = 0.0
		_connect_mp()
		multiplayer.multiplayer_peer = peer
		return OK
	return join_with_peer(peer, opts)


## Joins using any MultiplayerPeer (already set up as a client).
func join_with_peer(peer: MultiplayerPeer, opts: Dictionary = {}) -> Error:
	if not _ready_to_start():
		return ERR_ALREADY_IN_USE
	_joining = true
	_join_elapsed = 0.0
	if _join_address == "":
		_join_address = "the server"
	last_error = ""
	last_end_reason = ""
	_join_opts = opts
	_connect_mp()
	multiplayer.multiplayer_peer = peer
	return OK


## Leaves the session (or stops the server). Goes to `rgd/menu_scene` if set.
## When the server or host leaves, clients get session_ended with "the host left".
## [codeblock]
## func _on_quit_pressed() -> void:
##     Game.leave()
## [/codeblock]
func leave() -> void:
	if not _active and not _joining:
		return
	if _is_server:
		var reason := "the host left" if _is_client else "the server shut down"
		for peer in _rep.ready_peers():
			_rep.send_raw(peer, RGDWire.Writer.new(Msg.REJECT).string(reason).bytes())
		_flush_peer()
	_end_session("left")


## Server: disconnects [param player] with a reason they'll see in session_ended.
## [codeblock]
## Game.kick(player, "AFK for too long")
## [/codeblock]
func kick(player: Player, reason: String = "kicked") -> void:
	if not _is_server or player == null:
		return
	if _is_client and player.user_id == local_peer_id():
		push_error("RGD: the host can't kick itself; use Game.leave().")
		return
	var peer := player.user_id
	_rep.send_raw(peer, RGDWire.Writer.new(Msg.REJECT).string(reason).bytes())
	_flush_peer()
	get_tree().create_timer(0.2).timeout.connect(func():
		if multiplayer.has_multiplayer_peer() and _is_server and multiplayer.get_peers().has(peer):
			multiplayer.multiplayer_peer.disconnect_peer(peer))


func _transport() -> String:
	return str(RGDSettings.get_value(RGDSettings.TRANSPORT))


## [peer, Error]: a server peer for the configured transport.
func _server_peer(port: int) -> Array:
	if _transport() == "websocket":
		var ws := WebSocketMultiplayerPeer.new()
		return [ws, ws.create_server(port)]
	var enet := ENetMultiplayerPeer.new()
	return [enet, enet.create_server(port, RGDSettings.get_value(RGDSettings.MAX_PLAYERS), RGDProtocol.ENET_CHANNELS)]


## Before starting a session: a join that's still connecting is cancelled (the player changed
## their mind), and old connections still closing are closed now so their port is free. False
## (with an error) only when a session is really running: leave it first.
func _ready_to_start() -> bool:
	if _active:
		push_error("RGD: already in a session. Call Game.leave() first.")
		last_error = "already in a game"
		return false
	if _joining:
		_end_session("cancelled", false)  # a pending join: cancel it, no signals, no scene change
	_close_closing_peers()
	return true


## Closes connections still saying goodbye (left a moment ago), so their port is free again.
func _close_closing_peers() -> void:
	for c in _closing_peers:
		var p: MultiplayerPeer = c[0]
		p.poll()
		var enet_host := _enet_host(p)
		if enet_host:
			enet_host.flush()  # send the goodbyes still queued
		p.close()
	_closing_peers.clear()


## [param port], or the project's port when it's 0.
func _port(port: int) -> int:
	return port if port > 0 else default_port()


## Opens the server's port: [peer, error]. A local server this game started on that port is
## stopped first (you're hosting there now); a port someone else uses fails with a clear
## [member last_error] instead of ENet's error.
func _listen(port: int) -> Array:
	if not _ready_to_start():
		return [null, ERR_ALREADY_IN_USE]
	port = _port(port)
	if _local_servers.has(port):
		stop_local_server(port)  # you're hosting there now
	_wait_stopped(port)
	if not port_free(port):
		_reap_orphans(port)
	var made: Array = [null, ERR_ALREADY_IN_USE]
	if port_free(port):
		made = _server_peer(port)
	if made[1] == ERR_CANT_CREATE or made[1] == ERR_ALREADY_IN_USE:
		last_error = "port %d is already in use: is another game hosting on this computer? Join it, or use another port." % port
	elif made[1] != OK:
		last_error = "couldn't open port %d (%s)" % [port, error_string(made[1])]
	if made[1] != OK:
		push_warning("RGD: " + last_error)
	return made


## Splits "host", "host:port", "[ipv6]:port" or a bare IPv6 address into [host, port].
static func _split_address(address: String, port_if_none: int = DEFAULT_PORT) -> Array:
	var a := address.strip_edges()
	if a.begins_with("["):
		var close := a.find("]")
		if close > 0:
			var rest := a.substr(close + 1)
			var port := rest.substr(1).to_int() if rest.begins_with(":") and rest.substr(1).is_valid_int() else port_if_none
			return [a.substr(1, close - 1), port]
	if a.count(":") == 1:
		var colon := a.find(":")
		if a.substr(colon + 1).is_valid_int():
			return [a.substr(0, colon), a.substr(colon + 1).to_int()]
	return [a, port_if_none]  # no port, or a bare IPv6 address


## A display name as players type it, made safe to show: control characters (new lines, tabs)
## become spaces, runs of spaces become one, at most 32 characters.
static func _clean_name(raw: String) -> String:
	var out := ""
	for ch in raw.substr(0, 256):
		var c := ch.unicode_at(0)
		out += " " if c < 32 or c == 127 else ch
	while out.contains("  "):
		out = out.replace("  ", " ")
	return out.strip_edges().substr(0, 32).strip_edges()


## The ENet connection of [param p], or null if it isn't ENet or is closed (reading `host` then
## prints an engine error).
static func _enet_host(p: MultiplayerPeer) -> ENetConnection:
	if p is ENetMultiplayerPeer and p.get_connection_status() != MultiplayerPeer.CONNECTION_DISCONNECTED:
		return (p as ENetMultiplayerPeer).host
	return null


func _flush_peer() -> void:
	var peer := multiplayer.multiplayer_peer
	var enet_host := _enet_host(peer)
	if enet_host:
		enet_host.flush()


## True on the server and on the host.
func is_server() -> bool:
	return _is_server


## True on clients and on the host (the host is both).
func is_client() -> bool:
	return _is_client


## True on a listen server: the server with a local player.
func is_host() -> bool:
	return _is_server and _is_client


## True while in a session (hosting, serving, or joined and the initial state arrived).
func is_session_active() -> bool:
	return _active


## This process's peer id (1 on the server/host, 0 when not in a session).
func local_peer_id() -> int:
	if not multiplayer.has_multiplayer_peer() or not (_active or _joining):
		return 0
	return multiplayer.get_unique_id()


## A replicated value: the script variable [param prop] if this machine's node has it,
## otherwise the value the server sent (for variables of server-only scripts).
## [codeblock]
## # door.gd runs on the server only, so clients don't have its variables.
## # They still get the values:
## var open: bool = Game.get_value($Door, &"is_open", false)
## [/codeblock]
func get_value(node: Node, prop: StringName, default: Variant = null) -> Variant:
	if prop in node:
		return node.get(prop)
	return (node.get_meta(RGDReplicator.META_VALUES, {}) as Dictionary).get(prop, default)


## A Signal emitted with the new value whenever [param prop] of [param node] changes
## (on clients when the server's value arrives, on the server when the change is detected).
## [codeblock]
## # coin_counter.local.gd: update a label whenever the server changes `coins`.
## func _ready() -> void:
##     Game.changed(stats, &"coins").connect(func(value): $Label.text = str(value))
## [/codeblock]
func changed(node: Node, prop: StringName) -> Signal:
	var sig := RGDReplicator.CHANGED_PREFIX + String(prop)
	if not node.has_user_signal(sig):
		node.add_user_signal(sig, [{name = "value", type = TYPE_NIL}])
	return Signal(node, sig)


## Server: wakes a node's change detection right away (otherwise idle nodes are polled less
## often). Also starts replicating a node that just left the `local`/`server_only` group.
## [codeblock]
## lamp.remove_from_group(&"server_only")
## Game.mark_dirty(lamp)  # clients get it now
## [/codeblock]
func mark_dirty(node: Node) -> void:
	if _is_server:
		_rep.mark_dirty(node)


## Server: moves a node (Node3D or Node2D) without interpolation, and corrects its owner if
## a player owns it.
## [codeblock]
## Game.teleport(player.character, Transform3D(Basis(), Vector3(0, 2, 0)))
## [/codeblock]
func teleport(node: Node, xform: Variant) -> void:
	if not _is_server:
		push_error("RGD: Game.teleport() is server-only.")
		return
	_rep.teleport(node, xform)


## Server: gives simulation of [param node] to [param player] (null = the server).
## [codeblock]
## # The player who picks up the ball simulates it (no lag for them).
## func _on_pickup(player: Player) -> void:
##     Game.set_network_owner($Ball, player)
##
## func _on_drop() -> void:
##     Game.set_network_owner($Ball, null)  # back to the server
## [/codeblock]
func set_network_owner(node: Node, player: Player) -> void:
	if not _is_server:
		push_error("RGD: Game.set_network_owner() is server-only.")
		return
	_rep.set_net_owner(node, player.user_id if player else 0)


## The player who simulates [param node], or null if the server does.
func get_network_owner(node: Node) -> Player:
	var peer := _rep.get_owner_peer(node)
	return players.get_by_id(peer) if peer != 0 else null


## True if this machine simulates [param node] (its own character, on a client or the host).
func is_network_owner(node: Node) -> bool:
	if _is_server:
		var peer := _rep.get_owner_peer(node)
		return peer == 0 or (peer == local_peer_id() and _is_client)
	return _rep.owns(node)


## Round-trip time to [param player] in milliseconds (server), or to the server when
## [param player] is null (client). Measured by RGD itself, so it works on any transport.
func get_ping(player: Player = null) -> int:
	if player != null:
		return _rep.ping_of(player.user_id)
	return _rep.ping_of(1)


## The escape hatch for anything RGD doesn't model: sends [param data] (plain values, and
## replicated nodes as references) straight to [param to_peer]. Arrives as
## [signal message_received] on that machine. A client can only send to the server (1). On the
## server, 0 sends to every client. Unreliable messages may be dropped or arrive out of order.
## No rate limit: check what you receive. Godot's own `@rpc` works too, on nodes that have the
## same path everywhere (your level's nodes, players).
## [codeblock]
## # client: stream a custom input state, unreliable
## Game.send_message(1, {move = input, t = Time.get_ticks_msec()}, false)
## # server
## Game.message_received.connect(func(from_peer: int, data): _inputs[from_peer] = data)
## [/codeblock]
func send_message(to_peer: int, data: Variant, reliable := true) -> void:
	if not (_active or _joining):
		push_error("RGD: send_message: not in a session.")
		return
	if not _is_server and to_peer != 1:
		push_error("RGD: send_message: a client can only send to the server (peer 1).")
		return
	var targets: Array = ([1] if not _is_server else (_rep.ready_peers() if to_peer == 0 else [to_peer]))
	if _is_server and _is_client and (to_peer == 0 or to_peer == 1):
		_deliver_message.call_deferred(1, data)  # the host's own client
	for peer in targets:
		if _is_server and peer == 1:
			continue
		_rep.send_custom(peer, data, reliable)


func _deliver_message(from_peer: int, data: Variant) -> void:
	message_received.emit(from_peer, data)


## Server, the other escape hatch: [param enabled] false stops RGD from sending [param node]'s
## values and transform on its own. It still exists everywhere and spawns/despawns as usual;
## you decide when clients get its state with [method sync].
## [codeblock]
## Game.set_auto_sync($Scoreboard, false)
## # ...change it as much as you like, then once:
## Game.sync($Scoreboard)
## [/codeblock]
func set_auto_sync(node: Node, enabled: bool) -> void:
	if _is_server:
		_rep.set_auto_sync(node, enabled)


## Server: sends [param node]'s current values now (all its replicated properties and its
## transform, or only [param props]). Works for any node, auto-synced or not.
func sync(node: Node, props: Array = []) -> void:
	if _is_server:
		_rep.sync_now(node, props)


## Server: moves everyone to a new world. Players and their characters are kept; characters
## are placed at the new world's spawn points.
## [codeblock]
## # round_manager.gd (server): next map when the round ends.
## func _on_round_over() -> void:
##     Game.change_scene("res://levels/map2.tscn")
## [/codeblock]
func change_scene(path: String) -> Error:
	if not _is_server:
		push_error("RGD: Game.change_scene() is server-only.")
		return ERR_UNAUTHORIZED
	var packed := load(path) as PackedScene
	if packed == null:
		push_error("RGD: change_scene: couldn't load %s." % path)
		return ERR_CANT_OPEN
	var old := _world
	var moved: Array[Player] = []
	for p in players.get_players():
		var ch := p.character
		if ch and is_instance_valid(ch) and old.is_ancestor_of(ch):
			ch.get_parent().remove_child(ch)
			moved.append(p)
	var kept := _rep.server_reset_world(old)
	var world := RGDInstancer.instantiate(packed, RGDInstancer.make_ctx(true, _is_client))
	_world_path = path
	_rep.server_set_world(world, players)
	_install_world(world)
	for p in moved:
		_place_character(p, p.character)
	for peer in _rep.ready_peers():
		var w := RGDWire.Writer.new(Msg.CHANGE_SCENE).string(path).varint(kept.size())
		for id in kept:
			w.varint(id)
		_rep.send_raw(peer, w.bytes())
		_rep.send_snapshot(peer)
	# Owners simulate their characters, so tell them where they are now.
	for p in moved:
		if p.character is Node3D or p.character is Node2D:
			_rep.teleport(p.character, p.character.transform)
	scene_changed.emit(path)
	return OK


## Adds built-in properties that replicate for [param cls] (and classes inheriting it), e.g.
## `Game.register_profile(&"OmniLight3D", [&"omni_range"])`. Call it on every machine before
## hosting or joining (an autoload's `_ready` is a good place): profiles are part of the
## handshake, so a client with different profiles is rejected as a different build.
func register_profile(cls: StringName, props: Array) -> void:
	RGDProfiles.register(cls, props)
	_rep._prop_cache.clear()


## Network numbers for the last couple of seconds (plan 6.9). Keys: `role`,
## `replicated_nodes`, `bytes_out_per_sec` / `bytes_in_per_sec` (per peer), `ping_msec`,
## `top_nodes`, `top_props`, `remote_calls_per_sec`, `interpolating`, `owned`. Server:
## `tick_usec_avg` / `tick_usec_max` (replication tick cost), `streamed_units` (per peer,
## "in/total") and `stream_waiting` (entries held back by the bandwidth limit). Client: `parked`
## (streamed-out world parts kept for later).
func get_net_stats() -> Dictionary:
	if not (_active or _joining):
		return {}
	return _rep.net_stats()


## Shows or hides the in-game network overlay (also F9 in debug builds).
func show_net_stats(visible: bool) -> void:
	if visible and _overlay == null:
		_overlay = RGDNetOverlay.new()
		add_child(_overlay)
	elif not visible and _overlay != null:
		_overlay.queue_free()
		_overlay = null


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and (_active or _joining):
		# Window closed, or the hosting service stops a server: say goodbye properly, so
		# clients get "the server shut down" at once instead of a timeout.
		_quitting = true
		leave()
		_flush_peer()
		# The process quits right after this: give other transports (WebSocket, Steam) a
		# moment to send the goodbye now.
		var end := Time.get_ticks_msec() + 200
		while Time.get_ticks_msec() < end and not _closing_peers.is_empty():
			for c in _closing_peers:
				(c[0] as MultiplayerPeer).poll()
			OS.delay_msec(10)


func _unhandled_key_input(event: InputEvent) -> void:
	if OS.is_debug_build() and event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F9:
		show_net_stats(_overlay == null)


## The replicated id of [param node] (0 if it doesn't replicate). Mostly for debugging.
func net_id(node: Node) -> int:
	return _rep.id_of(node)


# ---------------------------------------------------------------------------------------------
# Server side
# ---------------------------------------------------------------------------------------------

func _begin_server(peer: MultiplayerPeer, scene: String, hosting: bool, opts: Dictionary) -> Error:
	if not _ready_to_start():
		return ERR_ALREADY_IN_USE
	last_error = ""
	last_end_reason = ""
	_connect_mp()
	multiplayer.multiplayer_peer = peer
	_is_server = true
	_is_client = hosting
	_rep.setup(self, multiplayer as SceneMultiplayer, true, hosting)
	var world := _load_world_server(scene)
	if world == null:
		_end_session("no world scene", false)
		return ERR_CANT_OPEN
	_active = true
	_strip_autoloads()
	session_started.emit()
	if hosting and RGDSettings.get_value(RGDSettings.AUTO_SPAWN):
		_spawn_player(1, opts.get("name", "Host"))
	return OK


func _load_world_server(scene: String) -> Node:
	var tree := get_tree()
	var path := scene
	if path == "" and tree.current_scene != null:
		path = tree.current_scene.scene_file_path
	if path == "":
		push_error("RGD: no world scene. Pass one to Game.host()/start_server() or open a scene first.")
		return null
	var packed := load(path) as PackedScene
	if packed == null:
		push_error("RGD: couldn't load world scene %s." % path)
		return null
	var world := RGDInstancer.instantiate(packed, RGDInstancer.make_ctx(true, _is_client))
	_world_path = path
	_rep.server_set_world(world, players)
	_install_world(world)
	return world


func _install_world(world: Node) -> void:
	var tree := get_tree()
	var old := tree.current_scene
	var old_is_level := old != null and old == _world
	_world = world
	if old != null and old != world and is_instance_valid(old) and old.name == world.name:
		# Same scene again (change_scene to restart a level): free the name first, so the new
		# world is "Arena" and not "@Node3D@2".
		old.name = String(old.name) + "_old"
	tree.root.add_child(world)
	tree.current_scene = world
	if old != null and old != world and is_instance_valid(old):
		if not old_is_level:
			# The menu goes away at the end of this frame: hide and pause it now, so a second
			# click on Host or Join in the same frame does nothing.
			if old is CanvasItem or old is Node3D:
				old.visible = false
			old.process_mode = Node.PROCESS_MODE_DISABLED
		old.queue_free()


func _on_peer_connected(peer: int) -> void:
	if _is_server:
		_pending_peers[peer] = 0.0
		_set_link_timeout(peer)


## ENet notices a silent peer after up to 30 s by default; use rgd/network/timeout instead.
func _set_link_timeout(peer: int) -> void:
	var mp := multiplayer.multiplayer_peer
	if mp is ENetMultiplayerPeer:
		var link := (mp as ENetMultiplayerPeer).get_peer(peer)
		if link:
			_set_link_timeout_on(link)


static func _set_link_timeout_on(link: ENetPacketPeer) -> void:
	var ms := int(float(RGDSettings.get_value(RGDSettings.TIMEOUT)) * 1000.0)
	link.set_timeout(32, mini(3000, ms), ms)


func _on_peer_disconnected(peer: int) -> void:
	if not _is_server:
		return
	_pending_peers.erase(peer)
	_bad_input_count.erase(peer)
	_rep.peer_left(peer)
	for key in _rate.keys():
		if key[0] == peer:
			_rate.erase(key)
			_rate_warned.erase(key)
	var p := players.get_by_id(peer)
	if p:
		if p.character and is_instance_valid(p.character) and p.character.get_parent() != p:
			p.character.queue_free()
		p.queue_free()


func _server_hello(peer: int, rd: RGDWire.Reader) -> void:
	if not _pending_peers.has(peer):
		return
	_pending_peers.erase(peer)
	var ver := rd.varint()
	var build := rd.string()
	var schema := rd.varint()
	var display := _clean_name(rd.string())
	var data = rd.value() if not rd.at_end() else {}
	if not data is Dictionary:
		data = {}
	var reason := ""
	if rd.failed or ver != RGDProtocol.VERSION or build != _build_id() or schema != RGDProfiles.schema_hash():
		reason = "client and server are different builds"
	elif players.get_children().size() >= int(RGDSettings.get_value(RGDSettings.MAX_PLAYERS)):
		reason = "server is full"
	elif join_validator.is_valid():
		var r = await join_validator.call(peer, display, data)
		reason = str(r) if r != null else ""
		if not _is_server or not multiplayer.has_multiplayer_peer() or not multiplayer.get_peers().has(peer):
			return  # they left (or we stopped) while we were checking
		if reason == "" and players.get_children().size() >= int(RGDSettings.get_value(RGDSettings.MAX_PLAYERS)):
			reason = "server is full"  # others got in while we were checking
	if reason != "":
		_rep.send_raw(peer, RGDWire.Writer.new(Msg.REJECT).string(reason).bytes())
		get_tree().create_timer(0.5).timeout.connect(func():
			if multiplayer.has_multiplayer_peer() and multiplayer.get_peers().has(peer):
				multiplayer.multiplayer_peer.disconnect_peer(peer))
		return
	if display == "":
		display = "Player%d" % peer
	var w := RGDWire.Writer.new(Msg.WELCOME)
	w.varint(peer).varint(_rep.tick_rate).f32(_rep.interpolation_delay).string(_world_path).varint(_rep.players_anchor_id())
	_rep.send_raw(peer, w.bytes())
	_rep.send_snapshot(peer)
	if RGDSettings.get_value(RGDSettings.AUTO_SPAWN):
		var p := _spawn_player(peer, display)
		if p:
			p.join_data = data


func _player_scene() -> PackedScene:
	var path := _world_setting(META_PLAYER_SCENE, RGDSettings.PLAYER_SCENE)
	if path == "":
		return null
	var ps := load(path) as PackedScene
	if ps == null:
		push_error("RGD: couldn't load the player scene %s." % path)
	return ps


## A level can override some project settings with metadata on its root node (Inspector ▸
## Add Metadata), so one project can hold several games: `rgd_player_scene`, `rgd_menu_scene`.
func _world_setting(meta: StringName, setting: String) -> String:
	if _world != null and is_instance_valid(_world) and _world.has_meta(meta):
		return str(_world.get_meta(meta))
	return str(RGDSettings.get_value(setting))


func _spawn_player(peer: int, display: String) -> Player:
	var ctx := RGDInstancer.make_ctx(true, _is_client, true, _is_client and peer == local_peer_id())
	var ps := _player_scene()
	var p: Player
	if ps:
		var root := RGDInstancer.instantiate(ps, ctx)
		if not root is Player:
			push_error("RGD: the player scene's root must be a Player node (rgd/player_scene).")
			root.free()
			return null
		p = root
	else:
		p = Player.new()
	p.user_id = peer
	if RGDSettings.get_value(RGDSettings.UNIQUE_NAMES):
		display = _unique_name(display, players.get_players().map(func(o): return o.display_name))
	p.display_name = display
	p.name = _unique_child_name(players, display)
	p.set_meta(RGDInstancer.META_CTX_OWNER, peer)
	if p.ui:
		p.ui.set_meta(RGDReplicator.META_NO_REPLICATE, true)
	players.add_child(p)
	if p.character and is_instance_valid(p.character):
		_place_character(p, p.character)
	return p


func _place_character(p: Player, ch: Node) -> void:
	if ch.get_parent():
		ch.get_parent().remove_child(ch)
	RGDReplicator._clear_foreign_owner(ch, _world)
	ch.name = _unique_child_name(_world, p.display_name)
	ch.set_meta(&"rgd_player", p)
	_world.add_child(ch)
	var sp := _next_spawn_point()
	if (ch is Node3D and sp is Node3D) or (ch is Node2D and sp is Node2D):
		ch.global_transform = sp.global_transform
	_rep.set_net_owner(ch, p.user_id)


func _next_spawn_point() -> Node:
	var points := get_tree().get_nodes_in_group(&"spawn_point").filter(func(n): return _world.is_ancestor_of(n))
	if points.is_empty():
		return null
	_spawn_index += 1
	return points[_spawn_index % points.size()]


func _respawn(p: Player) -> void:
	if not _is_server:
		push_error("RGD: Player.respawn() is server-only.")
		return
	var old := p.character
	if old and is_instance_valid(old):
		p.character = null
		old.queue_free()
	var ps := _player_scene()
	if ps == null:
		return
	var ctx := RGDInstancer.make_ctx(true, _is_client, true, _is_client and p.user_id == local_peer_id())
	var tmp := RGDInstancer.instantiate(ps, ctx) as Player
	if tmp == null or tmp.character == null:
		if tmp:
			tmp.free()
		return
	var ch := tmp.character
	var sub := String(tmp.get_path_to(ch)) if tmp.is_ancestor_of(ch) else ""
	tmp.character = null
	ch.get_parent().remove_child(ch)
	ch.owner = null
	tmp.free()
	ch.set_meta(RGDReplicator.META_SPAWN_SCENE, [ps.resource_path, sub, p.user_id])
	# Assign before it enters the tree, so the new character's _ready can find its player
	# (Game.players.get_player_from_character), like on the first spawn.
	p.character = ch
	_place_character(p, ch)


## [param wanted], or wanted2, wanted3... if one of [param taken] already has it (ignoring case).
static func _unique_name(wanted: String, taken: Array) -> String:
	var lower := taken.map(func(t): return String(t).to_lower())
	var chosen := wanted
	var i := 2
	while chosen.to_lower() in lower:
		chosen = wanted.substr(0, 32 - str(i).length()) + str(i)  # stays within 32 characters
		i += 1
	return chosen


func _unique_child_name(parent: Node, wanted: String) -> String:
	var base := wanted.validate_node_name()
	if base == "":
		base = "Node"
	var n := base
	var i := 2
	while parent.has_node(NodePath(n)):
		n = "%s%d" % [base, i]
		i += 1
	return n


func _ready_peers() -> Array:
	return _rep.ready_peers()


# ---------------------------------------------------------------------------------------------
# Client side
# ---------------------------------------------------------------------------------------------

func _on_connected_to_server() -> void:
	_set_link_timeout(1)
	var w := RGDWire.Writer.new(Msg.HELLO)
	w.varint(RGDProtocol.VERSION).string(_build_id()).varint(RGDProfiles.schema_hash())
	w.string(str(_join_opts.get("name", "")))
	var data = _join_opts.get("data", {})
	w.value(data if data is Dictionary else {})
	(multiplayer as SceneMultiplayer).send_bytes(w.bytes(), 1, MultiplayerPeer.TRANSFER_MODE_RELIABLE, RGDProtocol.CH_RELIABLE)


func _on_connection_failed() -> void:
	if _joining:
		_fail_join("couldn't reach %s (no answer)" % _join_address)


func _on_server_disconnected() -> void:
	if not _active and not _joining:
		return  # already ended (e.g. after a REJECT with a reason)
	if _joining and not _active:
		_fail_join("the server closed the connection while joining")
	else:
		_end_session("disconnected from the server")


func _client_welcome(rd: RGDWire.Reader) -> void:
	var my_id := rd.varint()
	var tick_rate := rd.varint()
	var delay := rd.f32()
	var world_path := rd.string()
	var anchor_id := rd.varint()
	if rd.failed:
		return
	_is_client = true
	_rep.setup(self, multiplayer as SceneMultiplayer, false, true)
	_rep.local_peer = my_id
	_rep.tick_rate = tick_rate
	_rep.interpolation_delay = delay
	var packed := load(world_path) as PackedScene if world_path.begins_with("res://") and ResourceLoader.exists(world_path) else null
	if packed == null:
		_fail_join("this build doesn't have the server's world scene %s" % world_path)
		return
	_world_path = world_path
	_pending_world = RGDInstancer.instantiate(packed, RGDInstancer.make_ctx(false, true))
	_rep.client_set_world(_pending_world, players, anchor_id)
	if not _rep.snapshot_finished.is_connected(_on_snapshot_finished):
		_rep.snapshot_finished.connect(_on_snapshot_finished)


func _on_snapshot_finished() -> void:
	if _pending_world == null:
		return
	var world := _pending_world
	_pending_world = null
	_install_world(world)
	if _active:
		scene_changed.emit(_world_path)
		return
	_joining = false
	_active = true
	_strip_autoloads()
	session_started.emit()


func _client_message(msg: int, rd: RGDWire.Reader) -> void:
	match msg:
		Msg.CHANGE_SCENE:
			var path := rd.string()
			var n := rd.varint()
			var kept: Array = []
			for i in n:
				kept.append(rd.varint())
			if rd.failed or not path.begins_with("res://") or not ResourceLoader.exists(path):
				_end_session("missing world scene")
				return
			_rep.client_reset_world(_world, kept)
			_world_path = path
			_pending_world = RGDInstancer.instantiate(load(path), RGDInstancer.make_ctx(false, true))
			_rep.client_set_world(_pending_world, players, _rep.id_of(players))
		Msg.REJECT:
			var reason := rd.string()
			if _active:
				_end_session(reason)  # kicked, or the host left
			else:
				_fail_join(reason)


# ---------------------------------------------------------------------------------------------
# Shared
# ---------------------------------------------------------------------------------------------

func _connect_mp() -> void:
	var mp := multiplayer as SceneMultiplayer
	mp.server_relay = false
	var pairs := [
		[mp.peer_connected, _on_peer_connected],
		[mp.peer_disconnected, _on_peer_disconnected],
		[mp.peer_packet, _on_peer_packet],
		[mp.connected_to_server, _on_connected_to_server],
		[mp.connection_failed, _on_connection_failed],
		[mp.server_disconnected, _on_server_disconnected],
	]
	for p in pairs:
		if not (p[0] as Signal).is_connected(p[1]):
			(p[0] as Signal).connect(p[1])


func _on_peer_packet(peer: int, data: PackedByteArray) -> void:
	if data.is_empty():
		return
	var msg := data[0]
	if _is_server:
		if msg == Msg.HELLO:
			var rd := RGDWire.Reader.new(data)
			rd.allow_inline = false
			rd.untrusted = true
			rd.u8()
			_server_hello(peer, rd)
		else:
			_rep.handle_packet(peer, data)
	elif peer == 1:
		if msg == Msg.WELCOME:
			var rd := RGDWire.Reader.new(data)
			rd.u8()
			_client_welcome(rd)
		elif msg == Msg.REJECT:
			var rd := RGDWire.Reader.new(data)
			rd.u8()
			_client_message(msg, rd)
		elif _is_client:
			_rep.handle_packet(peer, data)


func _end_session(reason: String, emit := true) -> void:
	# Only a session that was running ends with session_ended and a trip to the menu. A join
	# that fails or is cancelled stays on the screen it started from (the menu).
	var was_active := _active
	_active = false
	_joining = false
	_pending_peers.clear()
	_bad_input_count.clear()
	_rate.clear()
	_rate_warned.clear()
	_own_rate.clear()
	_own_rate_warned.clear()
	if multiplayer.has_multiplayer_peer():
		var peer := multiplayer.multiplayer_peer
		var server_link: ENetPacketPeer = null
		if not _is_server and peer is ENetMultiplayerPeer and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			server_link = (peer as ENetMultiplayerPeer).get_peer(1)
		if server_link:
			# Graceful: ENet sends what's queued (e.g. a fire_server right before leave())
			# and then disconnects. The old peer is polled in _process until it's done.
			server_link.peer_disconnect_later()
			_closing_peers.append([peer, 0.0, false])
		elif _is_server and _enet_host(peer):
			# Same for a server: clients get the "host left" reason before the disconnect.
			for link in _enet_host(peer).get_peers():
				link.peer_disconnect_later()
			_closing_peers.append([peer, 0.0, true])
		elif peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			# Any other transport (WebSocket, Steam...): keep polling briefly so queued
			# messages (a goodbye, a kick reason) go out, then close.
			_closing_peers.append([peer, 0.0, _is_server])
		else:
			peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	for p in players.get_children():
		players.remove_child(p)
		p.queue_free()
	players.local_player = null
	if _pending_world and is_instance_valid(_pending_world):
		_pending_world.free()
	_pending_world = null
	_rep.clear()
	var menu := _world_setting(META_MENU_SCENE, RGDSettings.MENU_SCENE)
	if _world and is_instance_valid(_world):
		_world.queue_free()
	_world = null
	_is_server = false
	_is_client = false
	_join_address = ""
	_wait_local = {}
	if was_active and _join_local_port > 0:
		stop_local_server(_join_local_port)  # you left your own dedicated server: it stops
	_join_local_port = 0
	if was_active and reason != "left":
		last_end_reason = reason
	if emit and was_active:
		session_ended.emit(reason)
	if menu != "" and was_active and is_inside_tree() and not _quitting:
		get_tree().change_scene_to_file.call_deferred(menu)


func _build_id() -> String:
	return "%s|%s" % [ProjectSettings.get_setting("application/config/version", ""), Engine.get_version_info().string]


## "" if [param cb] can take [param args], else why not ("takes 2 argument(s) but 3 were sent",
## "takes int for n, got String"). Counts are checked for any callable; types for named
## methods, whose parameter types Godot knows (a lambda's it doesn't).
static func _call_mismatch(cb: Callable, args: Array) -> String:
	var count := _arity_mismatch(cb, args.size())
	if count != "":
		return "takes %s but %d were sent" % [count, args.size()]
	var obj := cb.get_object()
	var method := cb.get_method()
	if obj == null or method == &"" or not obj.has_method(method):
		return ""
	for info in obj.get_method_list():
		if info.name != method:
			continue
		var params: Array = info.args
		for i in mini(args.size(), params.size() - cb.get_bound_arguments_count()):
			var p: Dictionary = params[i]
			if not _fits(args[i], p.type, p.class_name):
				var wanted: String = p.class_name if p.class_name != &"" else type_string(p.type)
				var got: String = args[i].get_class() if args[i] is Object else type_string(typeof(args[i]))
				return "takes %s for %s, got %s" % [wanted, p.name, got]
		return ""
	return ""


## True if [param v] can be passed to a parameter of [param type] (TYPE_NIL: untyped) and,
## for objects, of class [param cls] (native or a script's class_name). Lenient where GDScript
## converts by itself: numbers, text, vectors and their int versions, arrays and packed arrays.
static func _fits(v: Variant, type: int, cls: StringName) -> bool:
	var t := typeof(v)
	if type == TYPE_NIL or t == type:
		return type != TYPE_OBJECT or v == null or cls == &"" or _is_a(v, cls)
	const GROUPS := [[TYPE_BOOL, TYPE_INT, TYPE_FLOAT], [TYPE_STRING, TYPE_STRING_NAME, TYPE_NODE_PATH],
		[TYPE_VECTOR2, TYPE_VECTOR2I], [TYPE_VECTOR3, TYPE_VECTOR3I], [TYPE_VECTOR4, TYPE_VECTOR4I],
		[TYPE_RECT2, TYPE_RECT2I]]
	for g in GROUPS:
		if t in g and type in g:
			return true
	if type == TYPE_OBJECT:
		return t == TYPE_NIL
	var arrays := [TYPE_ARRAY, TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY,
		TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY,
		TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_COLOR_ARRAY, TYPE_PACKED_VECTOR4_ARRAY]
	return t in arrays and type in arrays


static func _is_a(obj: Object, cls: StringName) -> bool:
	if ClassDB.class_exists(cls):
		return obj.is_class(cls)
	var s: Script = obj.get_script()
	while s != null:
		if s.get_global_name() == cls:
			return true
		s = s.get_base_script()
	return false


## RemoteFunction calls: emits the answers that arrived, and finishes with null the calls that
## won't get one (the RemoteFunction was freed, the session ended, the player who was asked
## left, the timeout passed). Code awaiting invoke_server / invoke_client never hangs.
func _finish_calls() -> void:
	var now := Time.get_ticks_msec()
	for c in _calls.duplicate():
		if not c.done:
			var why := ""
			if not is_instance_id_valid(c.remote_id) or not (_active or _joining):
				why = "-"  # a scene change or the end of the session: expected, no warning
			elif _is_server and c.peer != 1 and players.get_by_id(c.peer) == null:
				why = "the other side disconnected before answering"
			elif c.deadline > 0 and now > c.deadline:
				why = "no answer after %.1f s (timeout)" % c.timeout
			if why == "":
				continue
			if why != "-":
				push_warning("RGD: %s: %s." % [c.remote_name, why])
			c.done = true
			c.value = null
		_calls.erase(c)
		c.finished.emit(c.value)


## Prints a warning (or error) at most once every 5 s per [param key], saying how many were held back.
func _warn_limited(key: String, text: String, error := false) -> void:
	var now := Time.get_ticks_msec()
	var e: Array = _warned_at.get(key, [-100000, 0])
	if now - e[0] < 5000:
		e[1] += 1
		_warned_at[key] = e
		return
	var msg := text + ((" (and %d more like it)" % e[1]) if e[1] > 0 else "")
	if error:
		push_error(msg)
	else:
		push_warning(msg)
	_warned_at[key] = [now, 0]


## Server: [param peer] sent something no working client sends (a malformed message, a
## position that isn't a number). Warns, at most every few seconds; kicks it after
## [constant BAD_INPUT_LIMIT] of them.
func _bad_input(peer: int, what: String) -> void:
	var n: int = _bad_input_count.get(peer, 0) + 1
	_bad_input_count[peer] = n
	var p := players.get_by_id(peer)
	var who: String = p.display_name if p else "peer %d" % peer
	_warn_limited("bad:%d" % peer, "RGD: %s sent %s." % [who, what])
	if n == BAD_INPUT_LIMIT and _is_server:
		push_warning("RGD: %s sent %d invalid messages: kicked." % [who, n])
		if p:
			kick(p, "sent invalid data")
		elif multiplayer.has_multiplayer_peer():
			multiplayer.multiplayer_peer.disconnect_peer(peer)


## "" if [param cb] can be called with [param n] arguments, otherwise what it takes
## ("2 argument(s)", "1 to 2 argument(s)", "at least 1 argument(s)"). Knows about default
## and variadic (`...args`) parameters of named methods; lambdas must match exactly.
static func _arity_mismatch(cb: Callable, n: int) -> String:
	var obj := cb.get_object()
	var method := cb.get_method()
	if obj != null and method != &"" and obj.has_method(method):
		for info in obj.get_method_list():
			if info.name != method:
				continue
			var bound := cb.get_bound_arguments_count()
			var total: int = info.args.size() - bound
			var required: int = maxi(total - info.default_args.size(), 0)
			if info.flags & METHOD_FLAG_VARARG:
				return "" if n >= required else "at least %d argument(s)" % required
			if n >= required and n <= total:
				return ""
			return ("%d argument(s)" % total) if required == total else ("%d to %d argument(s)" % [required, total])
	var count := cb.get_argument_count()
	return "" if n == count else "%d argument(s)" % count


func _send_remote(peer: int, remote: Node, args: Array) -> bool:
	return _send_remote_msg(peer, remote, Msg.REMOTE_EVENT, -1, args)


func _send_remote_msg(peer: int, remote: Node, msg: int, extra: int, args: Array) -> bool:
	if not _active and not _joining:
		push_error("RGD: %s: not in a session." % remote.name)
		return false
	return _rep.send_remote(peer, remote, args, msg, extra)


func _remote_from_client(peer: int, node: Node, msg: int, extra: int, args: Array) -> void:
	var p := players.get_by_id(peer)
	if p == null:
		return
	if msg != Msg.INVOKE_RESULT and not _rate_ok(peer, node):
		return
	if node is RemoteEvent and msg == Msg.REMOTE_EVENT:
		node._deliver_server(p, args)
	elif node is RemoteFunction:
		if msg == Msg.INVOKE:
			node._server_invoke(p, extra, args)
		elif msg == Msg.INVOKE_RESULT:
			node._resolve(extra, args, peer)


func _remote_from_server(node: Node, msg: int, extra: int, args: Array) -> void:
	if node is RemoteEvent and msg == Msg.REMOTE_EVENT:
		node._deliver_client(args)
	elif node is RemoteFunction:
		if msg == Msg.INVOKE:
			node._client_invoke(extra, args)
		elif msg == Msg.INVOKE_RESULT:
			node._resolve(extra, args, 1)


## Debug builds, client side: warns once per remote when this machine calls it faster than its
## `rate_limit`. The server drops those calls, and otherwise the sender never finds out.
func _check_client_rate(node: Node) -> void:
	if not OS.is_debug_build() or _is_server:
		return
	var limit: int = node.get(&"rate_limit") if &"rate_limit" in node else 60
	if limit <= 0:
		return
	var id := node.get_instance_id()
	var now := Time.get_ticks_msec()
	var e: Array = _own_rate.get_or_add(id, [now, 0])
	if now - e[0] >= 1000:
		e[0] = now
		e[1] = 0
	e[1] += 1
	if e[1] > limit and not _own_rate_warned.has(id):
		_own_rate_warned[id] = true
		push_warning("RGD: %s: called more than %d times in a second (its rate_limit). The server drops the extra calls. Raise rate_limit on the node or call it less often." % [node.name, limit])

var _own_rate := {}
var _own_rate_warned := {}


## Per-player, per-remote calls per second (the remote's `rate_limit`, default 60).
var _rate := {}  # [peer, instance id] -> [window start msec, count]
var _rate_warned := {}


func _rate_ok(peer: int, node: Node) -> bool:
	var limit: int = node.get(&"rate_limit") if &"rate_limit" in node else 60
	if limit <= 0:
		return true
	var key := [peer, node.get_instance_id()]
	var now := Time.get_ticks_msec()
	var e: Array = _rate.get_or_add(key, [now, 0])
	if now - e[0] >= 1000:
		e[0] = now
		e[1] = 0
	e[1] += 1
	if e[1] > limit:
		if not _rate_warned.has(key):
			_rate_warned[key] = true
			push_warning("RGD: %s: player %d is over the rate limit (%d/s); dropping calls." % [node.name, peer, limit])
		return false
	return true


# ---------------------------------------------------------------------------------------------
# Script context for nodes the game creates itself, and user autoloads (plan 6.5)
# ---------------------------------------------------------------------------------------------

## Which side this process is, or null if not known yet (no session, no command-line role).
func _side() -> Variant:
	if _active or _joining:
		if _is_server or _is_client:
			return [_is_server, _is_client]
		return null
	match _startup_role:
		"server":
			return [true, false]
		"host", "solo":
			return [true, true]
		"client":
			return [false, true]
	return null


func _on_any_node_added(n: Node) -> void:
	var side = _side()
	if side == null:
		return
	var ctx := RGDInstancer.make_ctx(side[0], side[1])
	var group := ScriptContext.group_of(n)
	if (group == ScriptContext.GROUP_SERVER_ONLY and not ctx.is_server) or (group == ScriptContext.GROUP_LOCAL and not ctx.is_client):
		if n.get_script() != null and not String(n.get_script().resource_path).begins_with(ScriptContext.ADDON_DIR):
			n.set_script(null)
		if n.is_in_group(group):
			n.queue_free.call_deferred()
		return
	RGDInstancer.strip_script(n, ctx, group, true)


## Frees user autoloads named `*.server.gd` / `*.local.gd` on the wrong side once the side
## is known. With a command-line role they were already stripped before their `_ready`.
func _strip_autoloads() -> void:
	var side = _side()
	if side == null:
		return
	var ctx := RGDInstancer.make_ctx(side[0], side[1])
	for c in get_tree().root.get_children():
		if c == self or not ProjectSettings.has_setting("autoload/" + c.name):
			continue
		var s: Script = c.get_script()
		var stripped: String = c.get_meta(RGDInstancer.META_STRIPPED, "")
		var path := stripped if stripped != "" else (s.resource_path if s else "")
		if path != "" and not ScriptContext.runs_here(path, false, &"", ctx.is_server, ctx.is_client, false, true):
			c.queue_free()


func _parse_cmdline() -> Dictionary:
	var out := {}
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--"):
			var kv := a.substr(2).split("=", true, 1)
			out[kv[0]] = kv[1] if kv.size() > 1 else "true"
	return out


func _start_from_cmdline() -> void:
	var role := _startup_role
	# Hosting services usually pass settings in the environment: RGD_PORT, RGD_SCENE.
	var address: String = _cmdline.get("rgd-address", "127.0.0.1:%d" % default_port())
	if _cmdline.has("rgd-port"):
		address = "%s:%s" % [_split_address(address, default_port())[0], _cmdline["rgd-port"]]
	var port: int = _split_address(address, default_port())[1]
	var scene: String = _cmdline.get("rgd-scene", OS.get_environment("RGD_SCENE"))
	if scene == "":
		scene = RGDSettings.get_value(RGDSettings.SERVER_SCENE)
	var opts := {name = _cmdline.get("rgd-name", "")}
	if _cmdline.has("rgd-data"):  # join data as JSON, e.g. --rgd-data={"token":"abc"}
		var d = JSON.parse_string(_cmdline["rgd-data"])
		if d is Dictionary:
			opts.data = d
	if _cmdline.has("rgd-window") and DisplayServer.get_name() != "headless":
		get_window().title = "%s — %s" % [_cmdline["rgd-window"], ProjectSettings.get_setting("application/config/name", "RGD")]
	match role:
		"server":
			var err := start_server(port, scene)
			if _parent_beat != "":
				# Tell the game that started us (start_local_server) that we're listening.
				var f := FileAccess.open(_parent_beat + ".state", FileAccess.WRITE)
				if f:
					f.store_string("ready" if err == OK else "error: " + (last_error if last_error != "" else error_string(err)))
					f.close()
			if err != OK:
				printerr("RGD: the server couldn't start: ", last_error if last_error != "" else error_string(err))
				get_tree().quit(1)
		"host":
			host(port, scene, opts)
		"solo":
			play_solo(scene, opts)
		"client":
			join(address, opts)
		_:
			push_error("RGD: unknown --rgd-role=%s (server, host, client or solo)." % role)
