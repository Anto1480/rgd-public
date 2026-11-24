@tool
extends EditorInspectorPlugin
## Shows a short description above each RGD setting in Project Settings. Godot has no API to
## give custom project settings a description, but every inspector, including Project
## Settings', runs inspector plugins. The text comes from the doc comments in
## runtime/core/settings.gd, the same text as in the API reference.

const SETTINGS_SCRIPT := "res://addons/rgd/runtime/core/settings.gd"

var _docs := {}  # "rgd/network/tick_rate" -> description
var _section := ""  # the RGD section being shown ("rgd/network"), "" if none


func _init() -> void:
	_docs = descriptions()


## Every RGD setting key with its description, read from settings.gd's doc comments.
static func descriptions() -> Dictionary:
	var out := {}
	var doc: PackedStringArray = []
	for line in FileAccess.get_file_as_string(SETTINGS_SCRIPT).split("\n"):
		if line.begins_with("##"):
			doc.append(line.substr(2).strip_edges())
			continue
		var m := RegEx.create_from_string('^const \\w+ := "(rgd/[^"]+)"').search(line)
		if m and not doc.is_empty():
			out[m.get_string(1)] = " ".join(doc).replace("[code]", "").replace("[/code]", "").replace("[param ", "").replace("[member ", "").replace("[", "").replace("]", "")
		doc.clear()
	return out


func _can_handle(object: Object) -> bool:
	_section = ""
	if object == null or object.get_class() != &"SectionedInspectorFilter":
		return false
	_section = section_of(object.get_property_list().filter(func(p): return p.usage & PROPERTY_USAGE_EDITOR and p.name != "script").map(func(p): return String(p.name)), _docs)
	return _section != ""


## The RGD section ("rgd/network") whose settings are exactly [param names] (Project Settings
## shows a section's settings without its prefix), or "" if they aren't RGD's.
static func section_of(names: Array, docs: Dictionary) -> String:
	if names.is_empty():
		return ""
	for key: String in docs:
		var name: String = names[0]
		if key.ends_with("/" + name):
			var prefix := key.trim_suffix("/" + name)
			if names.all(func(n): return docs.has(prefix + "/" + n)):
				return prefix
	return ""


func _parse_property(_object: Object, _type: Variant.Type, name: String, _hint: PropertyHint, _hint_string: String, _usage: int, _wide: bool) -> bool:
	var key := _section + "/" + name
	if _docs.has(key):
		var l := Label.new()
		l.text = _docs[key]
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.modulate = Color(1, 1, 1, 0.6)
		l.add_theme_font_size_override(&"font_size", 12)
		l.tooltip_text = "%s\n%s" % [key, _docs[key]]
		l.mouse_filter = Control.MOUSE_FILTER_PASS
		add_custom_control(l)
	return false  # keep Godot's own editor for the value
