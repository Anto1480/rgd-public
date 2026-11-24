extends CanvasLayer
## The chat window. It's the player scene's `ui`, so it exists only on this player's own
## machine, and this script runs there.

const TYPING_TIMEOUT := 2.0
const COLORS := {say = Color("#e9ecef"), me = Color("#ffd43b"), system = Color("#868e96"), whisper = Color("#da77f2")}

## Every message shown, oldest first (also read by the sample's test).
var entries: Array = []

var _seen := {}  # message id -> true
var _typing := false
var _typing_left := 0.0
var _refresh_left := 0.0

@onready var _me: Player = get_parent()
@onready var _room: Node = get_tree().current_scene
@onready var _log: RichTextLabel = %Log
@onready var _input: LineEdit = %Input


func _ready() -> void:
	# New messages arrive through say.gd (show_entry). Fetch what came before: anything that
	# arrives in between is in both, and message ids drop the duplicate.
	_input.text_submitted.connect(_send)
	_input.text_changed.connect(_on_text_changed)
	%Send.pressed.connect(func(): _send(_input.text))
	_input.grab_focus()
	_show_topic(Game.get_value(_room, &"topic", ""))
	Game.changed(_room, &"topic").connect(_show_topic)
	var history = await _room.get_node("History").invoke_server()
	if history is Array:
		for entry in history:
			show_entry(entry)


func _send(text: String) -> void:
	if text.strip_edges() == "":
		return
	if text.strip_edges() == "/leave":
		Game.leave()  # back to the menu (a client-side command: the server never sees it)
		return
	_room.get_node("Say").fire_server(text)
	_input.clear()
	_typing = false  # the server clears it when the message arrives


func _on_text_changed(text: String) -> void:
	_typing_left = TYPING_TIMEOUT
	if not _typing and text != "":
		_typing = true
		_room.get_node("Typing").fire_server(true)


func _process(delta: float) -> void:
	if _typing:
		_typing_left -= delta
		if _typing_left <= 0.0 or _input.text == "":
			_typing = false
			_room.get_node("Typing").fire_server(false)
	_refresh_left -= delta
	if _refresh_left <= 0.0:
		_refresh_left = 0.25
		_refresh_people()


## Adds a message to the window (called by say.gd and for the history).
func show_entry(entry) -> void:
	if not entry is Dictionary or _seen.has(entry.get("id")):
		return
	_seen[entry.get("id")] = true
	entries.append(entry)
	var kind: String = entry.get("kind", "say")
	_log.push_color(Color("#495057"))
	_log.add_text("%s  " % entry.get("time", ""))
	_log.pop()
	_log.push_color(COLORS.get(kind, Color.WHITE))
	# add_text never parses BBCode, so "[b]" in a message or a name shows up as typed.
	match kind:
		"say":
			_log.push_bold()
			_log.add_text(str(entry.get("from", "?")))
			_log.pop()
			_log.add_text(": " + str(entry.get("text", "")))
		"me":
			_log.add_text("* %s %s" % [entry.get("from", "?"), entry.get("text", "")])
		"whisper":
			_log.add_text("%s → %s: %s" % [entry.get("from", "?"), entry.get("to", "?"), entry.get("text", "")])
		_:
			_log.add_text(str(entry.get("text", "")))
	_log.pop()
	_log.newline()


func _show_topic(topic: String) -> void:
	%Topic.text = topic


func _refresh_people() -> void:
	var lines: PackedStringArray = []
	var typing: PackedStringArray = []
	for p in Game.players.get_players():
		var line := p.display_name
		if p == _me:
			line += " (you)"
		if p.user_id == 1:  # the host (a dedicated server has no player 1)
			line += " ★"
		lines.append(line)
		if p != _me and p.typing:  # chat_player.gd's variable, the server's value
			typing.append(p.display_name)
	%People.text = "Online (%d)\n%s" % [lines.size(), "\n".join(lines)]
	%TypingLabel.text = "" if typing.is_empty() else "%s %s typing…" % [", ".join(typing), "is" if typing.size() == 1 else "are"]
