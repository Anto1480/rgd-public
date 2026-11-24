@tool
class_name RGDPlayerTemplate
## Creates a starter player scene (plan 6.2), 3D or 2D, and sets it as `rgd/player_scene`
## if that's empty:
##   3D: Player ▸ Character (CharacterBody3D: capsule, camera, controller) ▸ UI (CanvasLayer)
##   2D: Player ▸ Character (CharacterBody2D: circle, Camera2D, top-down controller) ▸ UI

## Which template to create: a 3D (CharacterBody3D) or 2D (CharacterBody2D) player scene.
enum Kind { PLAYER_3D, PLAYER_2D }

## Source of the 3D template's controller script.
const CONTROLLER := """extends CharacterBody3D
## Runs only on this player's own machine (it's in the player scene).
## The character is owned by the player, so moving it here replicates to everyone.

const SPEED := 6.0
const JUMP_VELOCITY := 5.0

var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")


func _ready() -> void:
	$Camera3D.current = true


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= _gravity * delta
	elif Input.is_physical_key_pressed(KEY_SPACE):
		velocity.y = JUMP_VELOCITY
	var input := Vector2(
		float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)),
		float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W)))
	var dir := (global_basis * Vector3(input.x, 0, input.y)).normalized()
	velocity.x = dir.x * SPEED
	velocity.z = dir.z * SPEED
	move_and_slide()
"""

## Source of the 2D template's top-down controller script.
const CONTROLLER_2D := """extends CharacterBody2D
## Runs only on this player's own machine (it's in the player scene).
## The character is owned by the player, so moving it here replicates to everyone.
## Top-down: WASD or the arrow keys.

const SPEED := 240.0


func _ready() -> void:
	$Camera2D.enabled = true
	$Camera2D.make_current()


func _physics_process(_delta: float) -> void:
	var input := Vector2(
		float(Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT))
			- float(Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT)),
		float(Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN))
			- float(Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP)))
	velocity = input.normalized() * SPEED
	move_and_slide()
	if input != Vector2.ZERO:
		$Body.rotation = input.angle()  # a child turned here: everyone sees it
"""

## Source of the templates' UI script.
const HUD := """extends CanvasLayer
## The player's UI. Exists only on this player's own machine.


func _ready() -> void:
	var me := Game.players.local_player
	$Label.text = "You are %s" % (me.display_name if me else "?")
"""


## Writes the scene + scripts into [param dir] and returns the scene path ("" on failure).
static func create(dir: String = "res://player", kind: Kind = Kind.PLAYER_3D) -> String:
	DirAccess.make_dir_recursive_absolute(dir)
	var base := "player" if kind == Kind.PLAYER_3D else "player_2d"
	var scene_path := dir.path_join(base + ".tscn")
	var i := 2
	while FileAccess.file_exists(scene_path):
		scene_path = dir.path_join("%s%d.tscn" % [base, i])
		i += 1
	var ctrl_path := scene_path.get_basename() + "_controller.gd"
	var hud_path := scene_path.get_basename() + "_hud.gd"
	_write(ctrl_path, CONTROLLER if kind == Kind.PLAYER_3D else CONTROLLER_2D)
	_write(hud_path, HUD)

	var root := Player.new()
	root.name = "Player"
	var ch: Node = _character_3d() if kind == Kind.PLAYER_3D else _character_2d()
	root.add_child(ch)
	ch.set_script(load(ctrl_path))
	var ui := CanvasLayer.new()
	ui.name = "UI"
	root.add_child(ui)
	ui.set_script(load(hud_path))
	var label := Label.new()
	label.name = "Label"
	label.position = Vector2(16, 12)
	ui.add_child(label)
	for n in [ch, ui, label] + ch.find_children("*", "", true, false):
		n.owner = root
	root.character = ch
	root.ui = ui

	var packed := PackedScene.new()
	var err := packed.pack(root)
	root.free()
	if err != OK or ResourceSaver.save(packed, scene_path) != OK:
		push_error("RGD: couldn't save %s." % scene_path)
		return ""
	if String(ProjectSettings.get_setting(RGDSettings.PLAYER_SCENE, "")) == "":
		ProjectSettings.set_setting(RGDSettings.PLAYER_SCENE, scene_path)
		ProjectSettings.save()
	return scene_path


static func _character_3d() -> Node:
	var ch := CharacterBody3D.new()
	ch.name = "Character"
	var mesh := MeshInstance3D.new()
	mesh.name = "Mesh"
	mesh.mesh = CapsuleMesh.new()
	mesh.position.y = 1.0
	ch.add_child(mesh)
	var shape := CollisionShape3D.new()
	shape.name = "Shape"
	shape.shape = CapsuleShape3D.new()
	shape.position.y = 1.0
	ch.add_child(shape)
	var cam := Camera3D.new()
	cam.name = "Camera3D"
	cam.position = Vector3(0, 2.2, 4)
	cam.rotation.x = -0.25
	ch.add_child(cam)
	return ch


static func _character_2d() -> Node:
	var ch := CharacterBody2D.new()
	ch.name = "Character"
	ch.motion_mode = CharacterBody2D.MOTION_MODE_FLOATING  # top-down
	var body := Polygon2D.new()  # a circle with a nose, so turning shows
	body.name = "Body"
	var pts := PackedVector2Array()
	for k in 20:
		var a := TAU * k / 20.0
		pts.append(Vector2(cos(a), sin(a)) * (24.0 if k != 0 else 34.0))
	body.polygon = pts
	body.color = Color(0.45, 0.65, 1.0)
	ch.add_child(body)
	var shape := CollisionShape2D.new()
	shape.name = "Shape"
	var circle := CircleShape2D.new()
	circle.radius = 24.0
	shape.shape = circle
	ch.add_child(shape)
	var cam := Camera2D.new()
	cam.name = "Camera2D"
	ch.add_child(cam)
	return ch


## Creates a player scene from the template (see [method create]), opens it in the editor
## and reports whether it became `rgd/player_scene`.
static func create_and_open(kind: Kind = Kind.PLAYER_3D) -> void:
	var path := create("res://player", kind)
	if path == "":
		return
	EditorInterface.get_resource_filesystem().scan()
	EditorInterface.open_scene_from_path(path)
	print_rich("[color=#8ef]RGD:[/color] created %s%s" % [path,
		" and set it as rgd/player_scene" if ProjectSettings.get_setting(RGDSettings.PLAYER_SCENE) == path else
		" (rgd/player_scene is already set; change it in Project Settings ▸ Rgd to use this one)"])


static func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()
