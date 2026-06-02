class_name GoalPortal3D
extends PickupAbleBody3D

# Grabbable goal portal. Cubes that pass through the throat score and despawn.
# Non-blocking (layer 2, mask 0) so cubes fly through the ring; a child Area3D
# detects arrivals. Emits cube_entered(cube, throat_world_pos).
#
# Carries a Label3D running-total display that moves with the portal.

signal cube_entered(cube: Node3D, at: Vector3)

const RING_RADIUS := 0.18
const RING_TUBE := 0.028

var _ring_mat: StandardMaterial3D
var _pulse := 0.0
var _total_label: Label3D
var _mult_label: Label3D
var _running_total := 0

# Goal-size difficulty multiplier. The portal is grabbable + two-hand scalable, so its
# node scale is the difficulty dial: a SMALLER goal is harder to hit → bigger multiplier;
# a BIGGER goal is easier → smaller multiplier. Inverse-proportional, clamped so it can
# never trivialise or nullify a round.
const MULT_MIN := 0.25
const MULT_MAX := 4.0

func score_multiplier() -> float:
	var s := (scale.x + scale.y + scale.z) / 3.0
	s = clampf(s, 0.1, 10.0)
	return clampf(1.0 / s, MULT_MIN, MULT_MAX)

func _ready() -> void:
	# Grabbable but non-blocking: cubes (mask 1) ignore layer 2; hand handler
	# (mask 1|2) can still grab it.
	collision_layer = 2
	collision_mask = 0
	freeze = true
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	freeze_on_release = true
	add_to_group("portal")

	# Ring visual (torus).
	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = RING_RADIUS - RING_TUBE
	torus.outer_radius = RING_RADIUS + RING_TUBE
	ring.mesh = torus
	# Torus lies in XY plane by default; rotate so the hole faces +Z (cubes enter along Z).
	ring.rotation_degrees = Vector3(90.0, 0.0, 0.0)
	_ring_mat = StandardMaterial3D.new()
	_ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	_ring_mat.albedo_color = Color(0.30, 0.85, 1.0)
	_ring_mat.emission_enabled = true
	_ring_mat.emission = Color(0.30, 0.85, 1.0)
	_ring_mat.emission_energy_multiplier = 2.2
	ring.material_override = _ring_mat
	add_child(ring)

	# Inner glow membrane — faint translucent disk in the hole.
	var disk := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = RING_RADIUS - RING_TUBE
	cyl.bottom_radius = RING_RADIUS - RING_TUBE
	cyl.height = 0.004
	disk.mesh = cyl
	disk.rotation_degrees = Vector3(90.0, 0.0, 0.0)
	var dmat := StandardMaterial3D.new()
	dmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dmat.albedo_color = Color(0.35, 0.80, 1.0, 0.22)
	dmat.emission_enabled = true
	dmat.emission = Color(0.40, 0.90, 1.0)
	dmat.emission_energy_multiplier = 1.4
	disk.material_override = dmat
	add_child(disk)

	# Grab collider (small sphere at center, layer 2 so cubes ignore it).
	var grab_cs := CollisionShape3D.new()
	var grab_shape := SphereShape3D.new()
	grab_shape.radius = RING_RADIUS
	grab_cs.shape = grab_shape
	add_child(grab_cs)

	# Throat detector — thin cylinder Area3D filling the hole, detects cubes (mask 1).
	var throat := Area3D.new()
	throat.name = "Throat"
	throat.collision_layer = 0
	throat.collision_mask = 1
	var tcs := CollisionShape3D.new()
	var tshape := CylinderShape3D.new()
	tshape.radius = RING_RADIUS - RING_TUBE
	tshape.height = 0.08
	tcs.shape = tshape
	tcs.rotation_degrees = Vector3(90.0, 0.0, 0.0)
	throat.add_child(tcs)
	throat.body_entered.connect(_on_throat_body_entered)
	add_child(throat)

	# Running-total label floating above the ring.
	_total_label = Label3D.new()
	_total_label.text = "0"
	_total_label.font_size = 140
	_total_label.outline_size = 18
	_total_label.modulate = Color(0.6, 0.95, 1.0)
	_total_label.outline_modulate = Color(0, 0, 0, 0.9)
	_total_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_total_label.shaded = false
	_total_label.pixel_size = 0.0006
	_total_label.position = Vector3(0.0, RING_RADIUS + 0.10, 0.0)
	add_child(_total_label)

	# Live difficulty-multiplier readout below the ring. Hidden at ~1.0x; appears when
	# the player resizes the goal so they see the reward (smaller) or penalty (bigger).
	_mult_label = Label3D.new()
	_mult_label.text = ""
	_mult_label.font_size = 84
	_mult_label.outline_size = 12
	_mult_label.modulate = Color(1.0, 0.85, 0.35)
	_mult_label.outline_modulate = Color(0, 0, 0, 0.9)
	_mult_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_mult_label.shaded = false
	_mult_label.pixel_size = 0.0006
	_mult_label.position = Vector3(0.0, -(RING_RADIUS + 0.07), 0.0)
	add_child(_mult_label)

func _on_throat_body_entered(body: Node3D) -> void:
	if body.is_in_group("cube"):
		_pulse = 1.0
		emit_signal("cube_entered", body, global_position)

func add_to_total(points: int) -> void:
	_running_total += points
	if _total_label:
		_total_label.text = str(_running_total)

func reset_total() -> void:
	_running_total = 0
	if _total_label:
		_total_label.text = "0"

func _process(delta: float) -> void:
	if _pulse > 0.0:
		_pulse = move_toward(_pulse, 0.0, delta * 3.0)
		if _ring_mat:
			_ring_mat.emission_energy_multiplier = 2.2 + _pulse * 6.0

	# Keep the difficulty readout in sync with the current size. Show nothing near 1.0x;
	# green when the goal is shrunk (bonus), red-orange when enlarged (penalty).
	if _mult_label:
		var m := score_multiplier()
		if absf(m - 1.0) <= 0.05:
			_mult_label.text = ""
		else:
			_mult_label.text = "x%.1f" % m
			_mult_label.modulate = Color(0.45, 1.0, 0.5) if m > 1.0 else Color(1.0, 0.55, 0.35)
