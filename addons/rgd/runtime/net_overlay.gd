class_name RGDNetOverlay
extends CanvasLayer
## In-game network numbers (plan 6.9). Toggle with F9 in debug builds, or
## Game.show_net_stats(true).

var _label: Label
var _timer := 0.0


func _init() -> void:
	name = "RGDNetOverlay"
	layer = 128
	var panel := PanelContainer.new()
	panel.position = Vector2(8, 8)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.6)
	style.set_content_margin_all(8)
	style.set_corner_radius_all(4)
	panel.add_theme_stylebox_override(&"panel", style)
	_label = Label.new()
	_label.add_theme_font_size_override(&"font_size", 12)
	panel.add_child(_label)
	add_child(panel)


func _process(delta: float) -> void:
	_timer += delta
	if _timer < 0.5:
		return
	_timer = 0.0
	_label.text = RGDNetOverlay.format(Game.get_net_stats())


## The overlay text for a [method Game.get_net_stats] dictionary.
static func format(st: Dictionary) -> String:
	if st.is_empty() or not st.has("role"):
		return "RGD: not in a session"
	var lines: PackedStringArray = []
	lines.append("RGD %s · %d replicated nodes · %d interpolating · %d owned" % [st.role, st.get("replicated_nodes", 0), st.get("interpolating", 0), st.get("owned", 0)])
	if st.has("tick_usec_avg") and st.role != "client":
		lines.append("  server tick %.2f ms avg · %.2f ms max" % [st.tick_usec_avg / 1000.0, st.tick_usec_max / 1000.0])
	if st.has("streamed_units") and not (st.streamed_units as Dictionary).is_empty():
		lines.append("  streamed units per peer: %s · stream waiting %d" % [st.streamed_units, st.get("stream_waiting", 0)])
	var out: Dictionary = st.get("bytes_out_per_sec", {})
	var inn: Dictionary = st.get("bytes_in_per_sec", {})
	var ping: Dictionary = st.get("ping_msec", {})
	var peers := {}
	for d in [out, inn, ping]:
		for k in d:
			peers[k] = true
	for peer in peers:
		lines.append("  peer %d: out %s/s · in %s/s · ping %s" % [peer, _bytes(out.get(peer, 0.0)), _bytes(inn.get(peer, 0.0)),
			("%d ms" % ping[peer]) if ping.has(peer) else "–"])
	var nodes: Array = st.get("top_nodes", [])
	if nodes:
		lines.append("Chattiest nodes:")
		for e in nodes.slice(0, 5):
			lines.append("  %s  %s/s" % [e[0], _bytes(e[1])])
	var props: Array = st.get("top_props", [])
	if props:
		lines.append("Chattiest properties:")
		for e in props.slice(0, 5):
			lines.append("  %s  %.1f/s" % [e[0], e[1]])
	var remotes: Dictionary = st.get("remote_calls_per_sec", {})
	if remotes:
		lines.append("Remote calls: " + ", ".join(remotes.keys().map(func(k): return "%s %.1f/s" % [k, remotes[k]])))
	return "\n".join(lines)


static func _bytes(b: float) -> String:
	if b >= 1024.0 * 1024.0:
		return "%.1f MB" % (b / 1048576.0)
	if b >= 1024.0:
		return "%.1f KB" % (b / 1024.0)
	return "%d B" % int(b)
