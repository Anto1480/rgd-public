@tool
extends HBoxContainer
## Studio-style Play Test (plan 6.7): one click launches a server and N clients locally.
## Lives in the editor's main toolbar next to Godot's Play buttons.

## Play Test looks for a free port from here up.
const BASE_PORT := 24800
## Every Play Test process starts in this empty scene; Game then loads the world (server) or
## joins (client). The project's own main scene (often a menu) doesn't run.
const BOOT_SCENE := "res://addons/rgd/runtime/boot.tscn"
## Where Play Test remembers its choices (editor settings).
const SETTINGS_PREFIX := "rgd/play_test/"

## SERVER: a headless server + N client windows. HOST: the first window hosts.
enum Mode { SERVER, HOST }
## Which scene Play Test runs as the world: the one open in the editor, or the main scene.
enum SceneChoice { CURRENT, MAIN }

## Menu id: Server + clients.
const ID_MODE_SERVER := 0
## Menu id: Host + clients.
const ID_MODE_HOST := 1
## Menu ids for the client count are this + 1..8.
const ID_CLIENTS_BASE := 10  # 11..18
## Menu id: play the current scene.
const ID_SCENE_CURRENT := 30
## Menu id: play the main scene.
const ID_SCENE_MAIN := 31

## Server + clients, or Host + clients.
var mode := Mode.SERVER
## How many windows to open (1–8).
var clients := 2
## Which scene to play (current or main).
var scene_choice := SceneChoice.CURRENT
## Run every process headless (used by tests).
var headless := false
## Play this scene instead of the current/main one (used by tests).
var scene_override := ""
## Called with each output line (label, line); used by tests.
var output_hook: Callable

var _menu: MenuButton
var _play: Button
var _stop: Button
var _procs: Array = []  # {label, pid, stdio, stderr, buf}


func _init() -> void:
	name = "RGDPlayTest"


func _ready() -> void:
	_load_prefs()
	_menu = MenuButton.new()
	_menu.flat = true
	_menu.tooltip_text = "RGD Play Test options"
	add_child(_menu)
	var pm := _menu.get_popup()
	pm.add_separator("Mode")
	pm.add_radio_check_item("Server + clients", ID_MODE_SERVER)
	pm.add_radio_check_item("Host + clients", ID_MODE_HOST)
	pm.add_separator("Clients")
	for i in range(1, 9):
		pm.add_radio_check_item(str(i), ID_CLIENTS_BASE + i)
	pm.add_separator("World scene")
	pm.add_radio_check_item("Current scene", ID_SCENE_CURRENT)
	pm.add_radio_check_item("Main scene", ID_SCENE_MAIN)
	pm.hide_on_checkable_item_selection = false
	pm.id_pressed.connect(_on_menu)

	_play = Button.new()
	_play.flat = true
	_play.tooltip_text = "Play Test: start a local server and clients (RGD)"
	_play.pressed.connect(play)
	add_child(_play)

	_stop = Button.new()
	_stop.flat = true
	_stop.tooltip_text = "Stop all Play Test processes"
	_stop.disabled = true
	_stop.pressed.connect(stop)
	add_child(_stop)

	if Engine.is_editor_hint():
		_play.icon = get_theme_icon(&"PlayRemote", &"EditorIcons")
		_stop.icon = get_theme_icon(&"Stop", &"EditorIcons")
		_menu.icon = get_theme_icon(&"GuiDropdown", &"EditorIcons")
	_refresh()


func _exit_tree() -> void:
	stop()


func _on_menu(id: int) -> void:
	if id == ID_MODE_SERVER:
		mode = Mode.SERVER
	elif id == ID_MODE_HOST:
		mode = Mode.HOST
	elif id > ID_CLIENTS_BASE and id <= ID_CLIENTS_BASE + 8:
		clients = id - ID_CLIENTS_BASE
	elif id == ID_SCENE_CURRENT:
		scene_choice = SceneChoice.CURRENT
	elif id == ID_SCENE_MAIN:
		scene_choice = SceneChoice.MAIN
	_save_prefs()
	_refresh()


func _refresh() -> void:
	var pm := _menu.get_popup()
	pm.set_item_checked(pm.get_item_index(ID_MODE_SERVER), mode == Mode.SERVER)
	pm.set_item_checked(pm.get_item_index(ID_MODE_HOST), mode == Mode.HOST)
	for i in range(1, 9):
		pm.set_item_checked(pm.get_item_index(ID_CLIENTS_BASE + i), clients == i)
	pm.set_item_checked(pm.get_item_index(ID_SCENE_CURRENT), scene_choice == SceneChoice.CURRENT)
	pm.set_item_checked(pm.get_item_index(ID_SCENE_MAIN), scene_choice == SceneChoice.MAIN)
	_menu.text = ("Server + %d" if mode == Mode.SERVER else "Host + %d") % (clients if mode == Mode.SERVER else clients - 1)
	_play.text = "Play Test"
	_stop.disabled = _procs.is_empty()


# ---------------------------------------------------------------------------------------------
# Launching
# ---------------------------------------------------------------------------------------------

## Starts the processes for the selected mode (server/host + N clients) on the open scene.
## Stops a running Play Test first and saves all scenes.
func play() -> void:
	stop()
	var scene := _world_scene()
	if scene == "":
		push_error("RGD Play Test: no scene to play. Open a scene or set a main scene.")
		return
	if Engine.is_editor_hint():
		EditorInterface.save_all_scenes()
	var port := _free_port()
	var address := "127.0.0.1:%d" % port
	var windows := clients if mode == Mode.SERVER else clients
	var rects := tile_rects(windows, DisplayServer.screen_get_usable_rect(DisplayServer.get_primary_screen()))
	if mode == Mode.SERVER:
		_launch("Server", ["--headless"], ["--rgd-role=server", "--rgd-address=" + address, "--rgd-scene=" + scene])
		for i in clients:
			_launch("Client %d" % (i + 1), _window_args(rects[i]),
				["--rgd-role=client", "--rgd-address=" + address, "--rgd-name=Player%d" % (i + 1), "--rgd-window=Client %d" % (i + 1)], 0.3)
	else:
		_launch("Host", _window_args(rects[0]),
			["--rgd-role=host", "--rgd-address=" + address, "--rgd-scene=" + scene, "--rgd-name=Host", "--rgd-window=Host"])
		for i in range(1, clients):
			_launch("Client %d" % i, _window_args(rects[i]),
				["--rgd-role=client", "--rgd-address=" + address, "--rgd-name=Player%d" % i, "--rgd-window=Client %d" % i], 0.3)
	print_rich("[color=#8ef]RGD Play Test:[/color] %s on port %d, world %s" % [_menu.text, port, scene])
	_refresh()


## Kills every Play Test process.
func stop() -> void:
	for p in _procs:
		if p.pid > 0 and OS.is_process_running(p.pid):
			OS.kill(p.pid)
	if not _procs.is_empty():
		print_rich("[color=#8ef]RGD Play Test:[/color] stopped.")
	_procs.clear()
	if is_inside_tree() and _stop:
		_refresh()


## True while Play Test processes are running.
func is_running() -> bool:
	return not _procs.is_empty()


func _launch(label: String, engine_args: Array, rgd_args: Array, delay := 0.0) -> void:
	var args := PackedStringArray(["--path", ProjectSettings.globalize_path("res://")])
	args.append_array(engine_args)
	args.append(BOOT_SCENE)
	args.append("--")
	args.append_array(rgd_args)
	var entry := {label = label, pid = -1, stdio = null, stderr = null, buf = ""}
	_procs.append(entry)
	if delay > 0.0:
		# Give the server a moment to open its port so clients connect on the first try.
		get_tree().create_timer(delay).timeout.connect(func(): _start(entry, args))
	else:
		_start(entry, args)


func _start(entry: Dictionary, args: PackedStringArray) -> void:
	if not _procs.has(entry):
		return
	var r := OS.execute_with_pipe(OS.get_executable_path(), args, false)
	if r.is_empty():
		push_error("RGD Play Test: couldn't start %s." % entry.label)
		_procs.erase(entry)
		return
	entry.pid = r.pid
	entry.stdio = r.stdio
	entry.stderr = r.stderr


func _window_args(rect: Rect2i) -> Array:
	if headless:
		return ["--headless"]
	return ["--position", "%d,%d" % [rect.position.x, rect.position.y], "--resolution", "%dx%d" % [rect.size.x, rect.size.y]]


## Splits [param area] into [param n] tiles, as square as possible.
static func tile_rects(n: int, area: Rect2i) -> Array[Rect2i]:
	var out: Array[Rect2i] = []
	if n <= 0:
		return out
	var cols := ceili(sqrt(float(n)))
	var rows := ceili(float(n) / cols)
	var w := area.size.x / cols
	var h := area.size.y / rows
	# Leave room for window decorations.
	var deco := Vector2i(0, 32)
	for i in n:
		var c := i % cols
		var r := i / cols
		out.append(Rect2i(area.position + Vector2i(c * w, r * h + deco.y), Vector2i(w - 4, h - deco.y - 4)))
	return out


func _world_scene() -> String:
	if scene_override != "":
		return scene_override
	if scene_choice == SceneChoice.CURRENT and Engine.is_editor_hint():
		var root := EditorInterface.get_edited_scene_root()
		if root and root.scene_file_path != "":
			return root.scene_file_path
	return ProjectSettings.get_setting("application/run/main_scene", "")


static func _free_port() -> int:
	for port in range(BASE_PORT, BASE_PORT + 200):
		var udp := PacketPeerUDP.new()
		if udp.bind(port, "127.0.0.1") == OK:
			udp.close()
			return port
	return BASE_PORT


# ---------------------------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------------------------

func _process(_delta: float) -> void:
	if _procs.is_empty():
		return
	var changed := false
	for p in _procs.duplicate():
		if p.pid <= 0:
			continue
		_drain(p)
		if not OS.is_process_running(p.pid):
			_drain(p)
			if p.buf != "":
				print("[%s] %s" % [p.label, p.buf])
			print_rich("[color=#8ef]RGD Play Test:[/color] %s exited (code %d)." % [p.label, OS.get_process_exit_code(p.pid)])
			_procs.erase(p)
			changed = true
	if changed:
		_refresh()


func _drain(p: Dictionary) -> void:
	for key in ["stdio", "stderr"]:
		var io: FileAccess = p[key]
		if io == null:
			continue
		while true:
			var b := io.get_buffer(65536)
			if b.is_empty():
				break
			p.buf += b.get_string_from_utf8()
	var lines: PackedStringArray = p.buf.split("\n")
	p.buf = lines[lines.size() - 1]
	for i in lines.size() - 1:
		var line := lines[i].strip_edges(false, true)
		if line == "" or line.begins_with("Godot Engine v"):
			continue
		if output_hook.is_valid():
			output_hook.call(p.label, line)
		if line.begins_with("ERROR") or line.begins_with("SCRIPT ERROR"):
			printerr("[%s] %s" % [p.label, line])
		elif line.begins_with("WARNING"):
			print_rich("[color=yellow][%s] %s[/color]" % [p.label, line.replace("[", "[lb]")])
		else:
			print("[%s] %s" % [p.label, line])


# ---------------------------------------------------------------------------------------------
# Preferences (stored in the project's editor metadata, not in project.godot)
# ---------------------------------------------------------------------------------------------

func _load_prefs() -> void:
	if not Engine.is_editor_hint():
		return
	var es := EditorInterface.get_editor_settings()
	mode = es.get_project_metadata("rgd", "play_mode", Mode.SERVER)
	clients = es.get_project_metadata("rgd", "play_clients", 2)
	scene_choice = es.get_project_metadata("rgd", "play_scene", SceneChoice.CURRENT)


func _save_prefs() -> void:
	if not Engine.is_editor_hint():
		return
	var es := EditorInterface.get_editor_settings()
	es.set_project_metadata("rgd", "play_mode", mode)
	es.set_project_metadata("rgd", "play_clients", clients)
	es.set_project_metadata("rgd", "play_scene", scene_choice)
