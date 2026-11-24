class_name RGDWire
## Binary encoding for RGD messages: `u8 msg_type` + payload, little-endian, varint ids.
##
## Values go through [method Writer.value] / [method Reader.value]: plain data is stored with
## Godot's own Variant encoding (objects disabled), nodes become net ids, file-backed
## resources become their path. Resources created at runtime of the classes in
## [constant INLINE_CLASSES] (materials, primitive meshes, shapes, gradients...) are sent by
## value. Anything else is sent as null.

## How a value is encoded: plain data, a node id, a resource path, a container, an inline resource...
enum Tag { NIL, PLAIN, NODE, RESOURCE, ARRAY, TYPED_ARRAY, DICT, SUBRES, INLINE }

## Arrays and dictionaries nested deeper than this are sent as null (and refused when they
## arrive): a message nested thousands of levels deep would overflow the stack.
const MAX_DEPTH := 64

static var _deep_warned := false


## The rotation of [param b], also when it squashes an axis to nothing (a node scaled to 0 to
## disappear): Godot's get_rotation_quaternion() only works on an invertible basis.
static func _rotation_of(b: Basis) -> Quaternion:
	if absf(b.determinant()) > 1e-12:
		return b.get_rotation_quaternion()
	var axes: Array[Vector3] = [b.x, b.y, b.z]
	var flat := axes.filter(func(a: Vector3): return a.length_squared() <= 1e-18)
	if flat.size() != 1:
		return Quaternion.IDENTITY  # scaled to a line or a point: nothing to turn
	# One axis is flat: rebuild it from the other two (if they aren't parallel).
	var i := axes.find(flat[0])
	var u := axes[(i + 1) % 3]
	var v := axes[(i + 2) % 3]
	var w := u.cross(v)
	if w.length_squared() <= 1e-18:
		return Quaternion.IDENTITY
	axes[i] = w.normalized() * maxf(u.length(), 1e-6)
	var fixed := Basis(axes[0], axes[1], axes[2])
	return fixed.get_rotation_quaternion() if absf(fixed.determinant()) > 1e-12 else Quaternion.IDENTITY


## True if [param d] from [param a] to [param b] is valid UTF-8 without NUL characters. Godot's
## own decoder is fast but reports bad text as errors, so they're muted while it only checks:
## valid text decodes and encodes back to the same bytes.
static func _utf8_ok(d: PackedByteArray, a: int, b: int) -> bool:
	var bytes := d if a == 0 and b == d.size() else d.slice(a, b)
	var printing := Engine.print_error_messages
	Engine.print_error_messages = false
	var text := bytes.get_string_from_utf8()
	Engine.print_error_messages = printing
	return text.to_utf8_buffer() == bytes


## True if [param d] from [param at] to [param end] is Godot's encoding (var_to_bytes) of a
## value that Writer sends as PLAIN, with sizes and text that fit. Reader uses it on data from
## clients, before Godot's own decoder (which prints errors on bad data) sees it.
static func _variant_fits(d: PackedByteArray, at: int, end: int) -> bool:
	if at + 4 > end:
		return false
	var header := d.decode_u32(at)
	var f := 8 if header & 0x10000 else 4  # 64-bit ints and floats, doubles
	var p := at + 4
	var body := end - p
	match header & 0xFF:
		TYPE_NIL:
			return true
		TYPE_BOOL:
			return body >= 4
		TYPE_INT, TYPE_FLOAT:
			return body >= f
		TYPE_VECTOR2:
			return body >= 2 * f
		TYPE_VECTOR2I:
			return body >= 8
		TYPE_VECTOR3:
			return body >= 3 * f
		TYPE_VECTOR3I:
			return body >= 12
		TYPE_RECT2, TYPE_VECTOR4, TYPE_PLANE, TYPE_QUATERNION:
			return body >= 4 * f
		TYPE_RECT2I, TYPE_VECTOR4I, TYPE_COLOR:
			return body >= 16
		TYPE_TRANSFORM2D, TYPE_AABB:
			return body >= 6 * f
		TYPE_BASIS:
			return body >= 9 * f
		TYPE_TRANSFORM3D:
			return body >= 12 * f
		TYPE_PROJECTION:
			return body >= 16 * f
		TYPE_STRING, TYPE_STRING_NAME:
			return _text_end(d, p, end) >= 0
		TYPE_NODE_PATH:
			if body < 12 or d.decode_u32(p) & 0x80000000 == 0:
				return false
			var count := (d.decode_u32(p) & 0x7FFFFFFF) + d.decode_u32(p + 4)
			if count > body / 4:
				return false
			p += 12
			for i in count:
				p = _text_end(d, p, end)
				if p < 0:
					return false
			return true
		TYPE_PACKED_STRING_ARRAY:
			if body < 4 or d.decode_u32(p) > (body - 4) / 4:
				return false
			var count := d.decode_u32(p)
			p += 4
			for i in count:
				p = _text_end(d, p, end, true)
				if p < 0:
					return false
			return true
	var each := 0
	match header & 0xFF:
		TYPE_PACKED_BYTE_ARRAY:
			each = 1
		TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_FLOAT32_ARRAY:
			each = 4
		TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_FLOAT64_ARRAY:
			each = 8
		TYPE_PACKED_VECTOR2_ARRAY:
			each = 2 * f
		TYPE_PACKED_VECTOR3_ARRAY:
			each = 3 * f
		TYPE_PACKED_COLOR_ARRAY:
			each = 16
		TYPE_PACKED_VECTOR4_ARRAY:
			each = 4 * f
		_:
			return false  # objects, containers, callables...: Writer never sends these as PLAIN
	return body >= 4 and d.decode_u32(p) * each <= body - 4


## Where an encoded string starting at [param p] ends (after its padding), or -1 if it
## doesn't fit before [param end] or isn't valid UTF-8. [param nul_ended]: the elements of a
## PackedStringArray count and carry their final NUL byte.
static func _text_end(d: PackedByteArray, p: int, end: int, nul_ended := false) -> int:
	if p + 4 > end:
		return -1
	var n := d.decode_u32(p)
	if n > end - p - 4:
		return -1
	var text_end := p + 4 + n
	if nul_ended:
		if n < 1 or d[text_end - 1] != 0:
			return -1
		text_end -= 1
	if not _utf8_ok(d, p + 4, text_end):
		return -1
	return mini(p + 4 + n + (4 - n % 4) % 4, end)

## Runtime-created resources of these classes are sent with their properties (server →
## clients only). Nothing that runs code (scripts) or costs a lot to build on arrival.
const INLINE_CLASSES := {
	&"StandardMaterial3D": true, &"ORMMaterial3D": true, &"ShaderMaterial": true,
	&"CanvasItemMaterial": true, &"ParticleProcessMaterial": true,
	&"BoxMesh": true, &"SphereMesh": true, &"CapsuleMesh": true, &"CylinderMesh": true,
	&"PlaneMesh": true, &"QuadMesh": true, &"PrismMesh": true, &"TorusMesh": true,
	&"BoxShape3D": true, &"SphereShape3D": true, &"CapsuleShape3D": true, &"CylinderShape3D": true,
	&"RectangleShape2D": true, &"CircleShape2D": true, &"CapsuleShape2D": true,
	&"Gradient": true, &"GradientTexture1D": true, &"GradientTexture2D": true,
	&"Curve": true, &"CurveTexture": true, &"StyleBoxFlat": true, &"LabelSettings": true,
}
const _SKIP_PROPS := ["resource_path", "resource_name", "resource_local_to_scene", "resource_scene_unique_id", "script"]
## Decoded inline resources by content, so the same material sent to many nodes is one object.
static var _inline_cache := {}


## True if [param r] is a runtime-created resource that can be sent by value.
static func can_inline(r: Object) -> bool:
	return r is Resource and (r as Resource).resource_path == "" and INLINE_CLASSES.has(StringName(r.get_class()))


## A resource embedded in a scene file ("res://x.tscn::Mesh_ab12"). It can't be loaded by
## path, but the client's node came from the same file and already holds it.
class SubRes:
	extends RefCounted
	## The resource's path inside its scene file ("res://x.tscn::Mesh_ab12").
	var path: String

	func _init(p: String) -> void:
		path = p


class Writer:
	## The bytes written so far.
	var buf := StreamPeerBuffer.new()
	## (Node) -> int. Returns 0 if the node isn't replicated.
	var node_to_id: Callable

	func _init(msg_type: int = -1, p_node_to_id: Callable = Callable()) -> void:
		buf.big_endian = false
		node_to_id = p_node_to_id
		if msg_type >= 0:
			buf.put_u8(msg_type)

	## Writes one byte (0–255).
	func u8(v: int) -> Writer:
		buf.put_u8(v)
		return self

	## Writes a bool as one byte.
	func boolean(v: bool) -> Writer:
		buf.put_u8(1 if v else 0)
		return self

	## Writes a non-negative int in as few bytes as it needs (7 bits per byte).
	func varint(v: int) -> Writer:
		assert(v >= 0, "varint must be non-negative")
		while v >= 0x80:
			buf.put_u8((v & 0x7f) | 0x80)
			v >>= 7
		buf.put_u8(v)
		return self

	## Writes a 32-bit float.
	func f32(v: float) -> Writer:
		buf.put_float(v)
		return self

	## Writes a 64-bit float.
	func f64(v: float) -> Writer:
		buf.put_double(v)
		return self

	## Writes a UTF-8 string with its length first.
	func string(v: String) -> Writer:
		var b := v.to_utf8_buffer()
		varint(b.size())
		buf.put_data(b)
		return self

	## Writes a Transform3D as position + rotation, plus scale only when it isn't 1.
	func xform3(t: Transform3D) -> Writer:
		var q := RGDWire._rotation_of(t.basis)
		var b := t.basis
		# get_scale() of a squashed basis is all zeros (its sign is the determinant's, 0): use
		# the axis lengths then.
		var s := b.get_scale() if absf(b.determinant()) > 1e-12 else Vector3(b.x.length(), b.y.length(), b.z.length())
		for c in [t.origin.x, t.origin.y, t.origin.z, q.x, q.y, q.z, q.w]:
			buf.put_float(c)
		if s.is_equal_approx(Vector3.ONE):
			buf.put_u8(0)
		else:
			buf.put_u8(1)
			for c in [s.x, s.y, s.z]:
				buf.put_float(c)
		return self

	## Writes a Transform2D as position + angle, plus scale and skew only when needed.
	func xform2(t: Transform2D) -> Writer:
		for c in [t.origin.x, t.origin.y, t.get_rotation()]:
			buf.put_float(c)
		var sc := t.get_scale()
		var sk := t.get_skew()
		if sc.is_equal_approx(Vector2.ONE) and is_zero_approx(sk):
			buf.put_u8(0)
		else:
			buf.put_u8(1)
			for c in [sc.x, sc.y, sk]:
				buf.put_float(c)
		return self

	## A Transform3D or Transform2D (the reader must know which).
	func xform(t: Variant) -> Writer:
		return xform2(t) if t is Transform2D else xform3(t)

	## Writes a Vector2 (two floats).
	func vec2(v: Vector2) -> Writer:
		buf.put_float(v.x)
		buf.put_float(v.y)
		return self

	## Writes a Vector3 (three floats).
	func vec3(v: Vector3) -> Writer:
		buf.put_float(v.x)
		buf.put_float(v.y)
		buf.put_float(v.z)
		return self

	## Writes any replicable value: plain data, nodes as ids, file resources as paths, whitelisted runtime resources inline, containers recursively.
	func value(v: Variant) -> Writer:
		match typeof(v):
			TYPE_OBJECT:
				if v == null or not is_instance_valid(v):
					buf.put_u8(Tag.NIL)
				elif v is Node:
					var id: int = node_to_id.call(v) if node_to_id.is_valid() else 0
					if id > 0:
						buf.put_u8(Tag.NODE)
						varint(id)
					else:
						buf.put_u8(Tag.NIL)
				elif v is Resource and _is_file_resource(v):
					buf.put_u8(Tag.RESOURCE)
					string(v.resource_path)
				elif v is Resource and v.resource_path.begins_with("res://") and v.resource_path.contains("::"):
					buf.put_u8(Tag.SUBRES)
					string(v.resource_path)
				elif RGDWire.can_inline(v) and _depth < 4:
					buf.put_u8(Tag.INLINE)
					string(v.get_class())
					var props := _inline_props(v)
					varint(props.size())
					_depth += 1
					for p in props:
						string(p[0])
						value(p[1])
					_depth -= 1
				else:
					buf.put_u8(Tag.NIL)
			TYPE_ARRAY, TYPE_DICTIONARY when _nest >= RGDWire.MAX_DEPTH:
				buf.put_u8(Tag.NIL)
				if not RGDWire._deep_warned:
					RGDWire._deep_warned = true
					push_warning("RGD: a value nested deeper than %d arrays or dictionaries was sent as null." % RGDWire.MAX_DEPTH)
			TYPE_ARRAY:
				var a: Array = v
				_nest += 1
				if a.is_typed() and a.get_typed_script() == null:
					buf.put_u8(Tag.TYPED_ARRAY)
					varint(a.get_typed_builtin())
					string(a.get_typed_class_name())
				else:
					buf.put_u8(Tag.ARRAY)
				varint(a.size())
				for e in a:
					value(e)
				_nest -= 1
			TYPE_DICTIONARY:
				var d: Dictionary = v
				_nest += 1
				buf.put_u8(Tag.DICT)
				varint(d.size())
				for k in d:
					value(k)
					value(d[k])
				_nest -= 1
			TYPE_CALLABLE, TYPE_SIGNAL, TYPE_RID:
				buf.put_u8(Tag.NIL)
			_:
				buf.put_u8(Tag.PLAIN)
				buf.put_var(v, false)
		return self

	## The finished message.
	func bytes() -> PackedByteArray:
		return buf.data_array

	var _depth := 0
	var _nest := 0

	## Stored properties of [param r] that differ from its class defaults.
	static func _inline_props(r: Resource) -> Array:
		var cls := StringName(r.get_class())
		var out: Array = []
		for p in r.get_property_list():
			if not (p.usage & PROPERTY_USAGE_STORAGE) or p.name in RGDWire._SKIP_PROPS:
				continue
			var v = r.get(p.name)
			var def = ClassDB.class_get_property_default_value(cls, p.name)
			if typeof(def) == typeof(v) and typeof(v) != TYPE_OBJECT and def == v:
				continue
			if typeof(v) == TYPE_OBJECT and v == null and def == null:
				continue
			out.append([p.name, v])
		return out

	static func _is_file_resource(r: Resource) -> bool:
		return r.resource_path.begins_with("res://") and not r.resource_path.contains("::")


class Reader:
	## The message being read.
	var buf := StreamPeerBuffer.new()
	## (int) -> Node. Returns null if unknown.
	var id_to_node: Callable
	## True once the message turned out shorter or malformed; later reads return defaults.
	var failed := false
	## False on the server: clients can't make it build resources.
	var allow_inline := true
	## True on the server, for what clients send: text must be valid UTF-8 and Godot-encoded
	## values must be well formed, or the message counts as malformed (instead of Godot
	## printing errors while decoding it).
	var untrusted := false
	var _nest := 0

	func _init(data: PackedByteArray, p_id_to_node: Callable = Callable()) -> void:
		buf.big_endian = false
		buf.data_array = data
		id_to_node = p_id_to_node

	## True when everything was read (or reading failed).
	func at_end() -> bool:
		return buf.get_position() >= buf.get_size() or failed

	func _need(n: int) -> bool:
		if buf.get_position() + n > buf.get_size():
			failed = true
			return false
		return true

	## Reads one byte.
	func u8() -> int:
		return buf.get_u8() if _need(1) else 0

	## Reads a bool.
	func boolean() -> bool:
		return u8() != 0

	## Reads an int written by Writer.varint.
	func varint() -> int:
		var result := 0
		var shift := 0
		while true:
			if not _need(1):
				return 0
			var b := buf.get_u8()
			result |= (b & 0x7f) << shift
			if b & 0x80 == 0:
				break
			shift += 7
			if shift > 63:
				failed = true
				return 0
		return result

	## Reads a 32-bit float.
	func f32() -> float:
		return buf.get_float() if _need(4) else 0.0

	## Reads a 64-bit float.
	func f64() -> float:
		return buf.get_double() if _need(8) else 0.0

	## Reads a string written by Writer.string.
	func string() -> String:
		var n := varint()
		if n == 0 or not _need(n):
			return ""
		var bytes: PackedByteArray = buf.get_data(n)[1]
		if untrusted and not RGDWire._utf8_ok(bytes, 0, bytes.size()):
			failed = true
			return ""
		return bytes.get_string_from_utf8()

	## A Godot-encoded value from a client: a size that fits, a type Writer sends as PLAIN, and
	## sizes and text inside that fit. (Godot's decoder prints errors for anything else.)
	func _plain_fits() -> bool:
		var d := buf.data_array
		var at := buf.get_position()
		if at + 8 > d.size():
			return false
		var size := d.decode_s32(at)
		return size >= 4 and at + 4 + size <= d.size() and RGDWire._variant_fits(d, at + 4, at + 4 + size)

	## Reads a Transform3D written by Writer.xform3.
	func xform3() -> Transform3D:
		if not _need(29):
			return Transform3D.IDENTITY
		var o := Vector3(buf.get_float(), buf.get_float(), buf.get_float())
		var q := Quaternion(buf.get_float(), buf.get_float(), buf.get_float(), buf.get_float())
		var s := Vector3.ONE
		if buf.get_u8() == 1 and _need(12):
			s = Vector3(buf.get_float(), buf.get_float(), buf.get_float())
		if not q.is_normalized():
			q = q.normalized() if q.length_squared() > 0.0 else Quaternion.IDENTITY
		return Transform3D(Basis(q).scaled(s), o)

	## Reads a Transform2D written by Writer.xform2.
	func xform2() -> Transform2D:
		if not _need(13):
			return Transform2D.IDENTITY
		var o := Vector2(buf.get_float(), buf.get_float())
		var rot := buf.get_float()
		var sc := Vector2.ONE
		var sk := 0.0
		if buf.get_u8() == 1 and _need(12):
			sc = Vector2(buf.get_float(), buf.get_float())
			sk = buf.get_float()
		return Transform2D(rot, sc, sk, o)

	## Reads a Transform2D or Transform3D.
	func xform(is_2d: bool) -> Variant:
		return xform2() if is_2d else xform3()

	## Reads a Vector2.
	func vec2() -> Vector2:
		if not _need(8):
			return Vector2.ZERO
		return Vector2(buf.get_float(), buf.get_float())

	## Reads a Vector3.
	func vec3() -> Vector3:
		if not _need(12):
			return Vector3.ZERO
		return Vector3(buf.get_float(), buf.get_float(), buf.get_float())

	## Top-level values may be a [SubRes] marker; inside containers those become null.
	func value(top := true) -> Variant:
		if _nest > RGDWire.MAX_DEPTH:
			failed = true  # nested deeper than any sender makes: refuse, don't recurse
			return null
		_nest += 1
		var v = _value(top)
		_nest -= 1
		return v

	func _value(top: bool) -> Variant:
		var tag := u8()
		match tag:
			Tag.NIL:
				return null
			Tag.PLAIN:
				if untrusted and not _plain_fits():
					failed = true
					return null
				var v = buf.get_var(false)
				return v
			Tag.NODE:
				var id := varint()
				return id_to_node.call(id) if id_to_node.is_valid() else null
			Tag.RESOURCE:
				var path := string()
				if path.begins_with("res://") and ResourceLoader.exists(path):
					return load(path)
				return null
			Tag.SUBRES:
				var path := string()
				return SubRes.new(path) if top else null
			Tag.INLINE:
				var start := buf.get_position() - 1
				var cls := StringName(string())
				var n := varint()
				var props: Array = []
				for i in n:
					if failed:
						return null
					props.append([string(), value(false)])
				if failed or not allow_inline or not RGDWire.INLINE_CLASSES.has(cls):
					return null
				var key: int = hash(buf.data_array.slice(start, buf.get_position()))
				var cached = RGDWire._inline_cache.get(key)
				if cached != null:
					return cached
				var r: Resource = ClassDB.instantiate(cls)
				for p in props:
					r.set(p[0], p[1])
				if RGDWire._inline_cache.size() > 512:
					RGDWire._inline_cache.clear()
				RGDWire._inline_cache[key] = r
				return r
			Tag.ARRAY:
				var n := varint()
				var a := []
				for i in n:
					if failed:
						break
					a.append(value(false))
				return a
			Tag.TYPED_ARRAY:
				var builtin := varint()
				var cls := StringName(string())
				var n := varint()
				# Only what Writer makes: a real type, a native class for objects (and only then).
				if failed or builtin <= TYPE_NIL or builtin >= TYPE_MAX or (builtin == TYPE_OBJECT) != (cls != &"") \
						or (cls != &"" and not ClassDB.class_exists(cls)):
					failed = true
					return null
				var a := Array([], builtin, cls, null)
				for i in n:
					if failed:
						break
					var e = value(false)
					if e == null and builtin == TYPE_OBJECT:
						continue
					if typeof(e) != builtin or (builtin == TYPE_OBJECT and not (e as Object).is_class(cls)):
						failed = true
						break
					a.append(e)
				return a
			Tag.DICT:
				var n := varint()
				var d := {}
				for i in n:
					if failed:
						break
					var k = value(false)
					d[k] = value(false)
				return d
		failed = true
		return null
