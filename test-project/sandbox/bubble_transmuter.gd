class_name BubbleTransmuter3D
extends PickupAbleBody3D

# Grabbable reflective bubble. Cubes that pass through are transmuted into
# spheres (main handles the geometry swap on the cube_passed signal). The
# bubble vibrates briefly each time a cube passes through.
#
# Non-blocking (layer 2, mask 0) so cubes fly through it; a child Area3D
# (mask 1) detects pass-through.

signal cube_passed(cube: Node3D, at: Vector3)

const BUBBLE_RADIUS := 0.14

var _mesh: MeshInstance3D
var _vibrate := 0.0
var _base_scale := Vector3.ONE
var _seed_phase := 0.0

func _ready() -> void:
	collision_layer = 2
	collision_mask = 0
	freeze = true
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	freeze_on_release = true
	add_to_group("bubble")

	# Reflective bubble surface — metallic, low roughness, slight transparency.
	_mesh = MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = BUBBLE_RADIUS
	sphere.height = BUBBLE_RADIUS * 2.0
	_mesh.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	mat.albedo_color = Color(0.85, 0.92, 1.0, 0.35)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.metallic = 1.0
	mat.metallic_specular = 1.0
	mat.roughness = 0.02
	# Reflection: sample the environment/sky for a soapy mirror look.
	mat.metallic_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
	mat.rim_enabled = true
	mat.rim = 0.9
	mat.rim_tint = 0.5
	mat.emission_enabled = true
	mat.emission = Color(0.5, 0.7, 1.0)
	mat.emission_energy_multiplier = 0.25
	_mesh.material_override = mat
	add_child(_mesh)

	# Grab collider (layer 2 — cubes ignore it).
	var grab_cs := CollisionShape3D.new()
	var grab_shape := SphereShape3D.new()
	grab_shape.radius = BUBBLE_RADIUS
	grab_cs.shape = grab_shape
	add_child(grab_cs)

	# Pass-through detector (mask 1 — detects cubes).
	var detector := Area3D.new()
	detector.name = "Detector"
	detector.collision_layer = 0
	detector.collision_mask = 1
	var dcs := CollisionShape3D.new()
	var dshape := SphereShape3D.new()
	dshape.radius = BUBBLE_RADIUS * 0.9
	dcs.shape = dshape
	detector.add_child(dcs)
	detector.body_entered.connect(_on_detector_body_entered)
	add_child(detector)

func _on_detector_body_entered(body: Node3D) -> void:
	# Only cubes transmute — spheres (already transmuted) pass silently.
	if body.is_in_group("cube") and not body.is_in_group("sphere"):
		_vibrate = 1.0
		emit_signal("cube_passed", body, global_position)

func _process(delta: float) -> void:
	if _vibrate > 0.0:
		_vibrate = move_toward(_vibrate, 0.0, delta * 3.5)
		# Wobble scale on each axis for a jelly vibration.
		_seed_phase += delta * 40.0
		var w := _vibrate * 0.12
		_mesh.scale = Vector3(
			1.0 + sin(_seed_phase) * w,
			1.0 + sin(_seed_phase * 1.3 + 1.0) * w,
			1.0 + sin(_seed_phase * 0.7 + 2.0) * w)
	elif _mesh.scale != Vector3.ONE:
		_mesh.scale = _mesh.scale.move_toward(Vector3.ONE, delta * 2.0)
