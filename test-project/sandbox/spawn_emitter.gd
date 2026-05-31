class_name SpawnEmitter3D
extends PickupAbleBody3D

# Grabbable spawn point. Cubes are emitted from this node's position by main.
# Non-blocking (layer 2, mask 0). Purely a visual marker + grab handle:
# a glowing ring with a downward-pointing arrow showing fall direction, plus
# a pulse each time a cube is emitted.

const RING_RADIUS := 0.09

var _ring_mat: StandardMaterial3D
var _pulse := 0.0

func _ready() -> void:
	collision_layer = 2
	collision_mask = 0
	freeze = true
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	freeze_on_release = true
	add_to_group("emitter")

	# Emission ring (lies flat, hole faces down).
	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = RING_RADIUS - 0.018
	torus.outer_radius = RING_RADIUS + 0.018
	ring.mesh = torus
	_ring_mat = StandardMaterial3D.new()
	_ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	_ring_mat.albedo_color = Color(0.55, 1.0, 0.45)
	_ring_mat.emission_enabled = true
	_ring_mat.emission = Color(0.55, 1.0, 0.45)
	_ring_mat.emission_energy_multiplier = 2.0
	ring.material_override = _ring_mat
	add_child(ring)

	# Downward arrow (cone pointing -Y) to show spawn/fall direction.
	var arrow := MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 0.035
	cone.height = 0.07
	arrow.mesh = cone
	arrow.rotation_degrees = Vector3(180.0, 0.0, 0.0)  # tip points down
	arrow.position = Vector3(0.0, -0.06, 0.0)
	var amat := StandardMaterial3D.new()
	amat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	amat.albedo_color = Color(0.55, 1.0, 0.45)
	amat.emission_enabled = true
	amat.emission = Color(0.55, 1.0, 0.45)
	amat.emission_energy_multiplier = 1.8
	arrow.material_override = amat
	add_child(arrow)

	# Grab collider.
	var grab_cs := CollisionShape3D.new()
	var grab_shape := SphereShape3D.new()
	grab_shape.radius = RING_RADIUS + 0.02
	grab_cs.shape = grab_shape
	add_child(grab_cs)

func pulse() -> void:
	_pulse = 1.0

func _process(delta: float) -> void:
	if _pulse > 0.0:
		_pulse = move_toward(_pulse, 0.0, delta * 4.0)
		if _ring_mat:
			_ring_mat.emission_energy_multiplier = 2.0 + _pulse * 4.0
