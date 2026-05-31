class_name BigScorePopup3D
extends MeshInstance3D

# Volumetric final-score popup for the goal-portal cash-out. A real extruded
# TextMesh (depth > 0), gold + emissive, that:
#   - punches in with an overshoot pop,
#   - spins in from a yaw offset and settles facing the user (shows its depth),
#   - shimmers (emission flicker) and arcs upward, then fades.
# The flat billboarded ScorePopup3D multipliers stay flat — the contrast sells
# the cash-out.
#
# Usage: BigScorePopup3D.spawn(parent, world_pos, "1234")

var _age := 0.0
const _LIFETIME := 2.1
var _velocity := Vector3(0.0, 0.55, 0.0)
var _mat: StandardMaterial3D
var _base_emission := 2.6
var _face_basis := Basis.IDENTITY
const _SPIN_SPEED := 3.0   # rad/s — constant turntable spin while it floats up

static func spawn(parent: Node3D, world_pos: Vector3, content: String, _unused := Color.WHITE) -> void:
	var p := BigScorePopup3D.new()

	var tm := TextMesh.new()
	tm.text = content
	tm.font_size = 250
	tm.depth = 0.045                                 # extrusion (halved — was too deep)
	tm.pixel_size = 0.0008
	tm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	p.mesh = tm

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.86, 0.36)        # warm gold
	mat.metallic = 0.7
	mat.metallic_specular = 0.7
	mat.roughness = 0.28
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.72, 0.18)
	mat.emission_energy_multiplier = p._base_emission
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	p.material_override = mat
	p._mat = mat

	parent.add_child(p)
	p.global_position = world_pos

	# Face the user (yaw only), then hold — _process layers the spin-in on top.
	var cam := p.get_viewport().get_camera_3d()
	if cam != null:
		var look := cam.global_position
		look.y = p.global_position.y
		if not look.is_equal_approx(p.global_position):
			p.look_at(look, Vector3.UP)
			p.rotate_object_local(Vector3.UP, PI)
	p._face_basis = p.global_transform.basis

func _process(delta: float) -> void:
	_age += delta
	var t := _age / _LIFETIME
	if t >= 1.0:
		queue_free()
		return

	# Arc upward with a little gravity.
	global_position += _velocity * delta
	_velocity.y -= 0.20 * delta

	# Overshoot pop for the first ~28% of life, then hold at 1.0.
	var s := 1.0
	if t < 0.28:
		s = 0.2 + 0.8 * _ease_back_out(t / 0.28)

	# Continuous turntable spin about vertical — shows off the extrusion as it rises.
	var spin := _age * _SPIN_SPEED
	transform.basis = (_face_basis * Basis(Vector3.UP, spin)).scaled(Vector3.ONE * s)

	# Emission shimmer + fade over the last 35%.
	var a := 1.0
	if t > 0.65:
		a = 1.0 - (t - 0.65) / 0.35
	_mat.albedo_color.a = a
	_mat.emission_energy_multiplier = _base_emission * a * (1.0 + 0.22 * sin(_age * 20.0))

# Back-out easing: overshoots ~1.1 then settles to 1.0.
func _ease_back_out(u: float) -> float:
	var c1 := 1.70158
	var c3 := c1 + 1.0
	var p := u - 1.0
	return 1.0 + c3 * p * p * p + c1 * p * p
