class_name RGDProfiles
## Which built-in properties replicate, per class (plan 6.3). Inherited classes inherit profiles.
## Transforms of Node3D/Node2D are handled by the transform stream, not by this list.

static var _profiles := {
	&"Node3D": [&"visible"],
	&"Node2D": [&"visible"],
	&"CanvasItem": [&"visible", &"modulate"],
	&"MeshInstance3D": [&"mesh", &"material_override"],
	&"GeometryInstance3D": [&"material_override"],
	&"CSGShape3D": [&"material_override", &"operation", &"use_collision"],
	&"CSGBox3D": [&"size", &"material"],
	&"CSGSphere3D": [&"radius", &"material"],
	&"CSGCylinder3D": [&"radius", &"height", &"material"],
	&"CSGTorus3D": [&"inner_radius", &"outer_radius", &"material"],
	&"CSGPolygon3D": [&"polygon", &"depth", &"material"],
	&"Light3D": [&"light_color", &"light_energy"],
	&"Label": [&"text"],
	&"Label3D": [&"text", &"modulate"],
	&"CollisionShape3D": [&"shape", &"disabled"],
	&"CollisionShape2D": [&"shape", &"disabled"],
	&"AnimationPlayer": [&"current_animation", &"speed_scale"],
	&"Sprite2D": [&"texture", &"frame", &"flip_h", &"flip_v"],
	&"AnimatedSprite2D": [&"sprite_frames", &"animation", &"speed_scale", &"flip_h", &"flip_v"],
	&"AnimatedSprite3D": [&"sprite_frames", &"animation", &"speed_scale", &"flip_h", &"flip_v"],
	&"Polygon2D": [&"color", &"texture"],
	&"Light2D": [&"color", &"energy", &"enabled"],
	&"TileMapLayer": [&"tile_map_data", &"enabled"],
}

## Cache: class name -> Array[StringName]
static var _resolved := {}


## Adds replicated built-in properties for [param cls] (see Game.register_profile); the
## existing ones stay. Both sides must register the same profiles: they're part of the
## handshake's schema hash.
static func register(cls: StringName, props: Array) -> void:
	var list: Array = _profiles.get(cls, []).duplicate()
	for p in props:
		if not StringName(p) in list:
			list.append(StringName(p))
	_profiles[cls] = list
	_resolved.clear()


## Built-in properties of [param cls] (and its parents) that replicate.
static func props_for(cls: StringName) -> Array:
	if _resolved.has(cls):
		return _resolved[cls]
	var out: Array = []
	var c := cls
	while c != &"":
		for p in _profiles.get(c, []):
			if not out.has(p):
				out.append(p)
		c = ClassDB.get_parent_class(c)
	_resolved[cls] = out
	return out


## Hash of every profile, part of the schema handshake.
static func schema_hash() -> int:
	var keys: Array = _profiles.keys().map(func(k): return String(k))
	keys.sort()
	var s := ""
	for k in keys:
		s += k + ":" + ",".join(PackedStringArray(_profiles[StringName(k)].map(func(p): return String(p)))) + ";"
	return s.hash()
