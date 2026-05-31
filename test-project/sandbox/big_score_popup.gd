class_name BigScorePopup3D
extends MeshInstance3D

# Volumetric final-score popup for the goal-portal cash-out. Unlike the flat,
# billboarded ScorePopup3D multipliers (+5 / x3), this is a REAL extruded
# TextMesh (depth > 0) that does NOT billboard — it faces the user once at
# spawn, then holds that orientation so its depth reads as genuine 3D while it
# arcs upward. The contrast with the flat multipliers is the point: the final
# score should feel weighty.
#
# Usage: BigScorePopup3D.spawn(parent, world_pos, "1234", Color(0.55,0.95,1.0))

var _age := 0.0
var _lifetime := 1.9
var _velocity := Vector3(0.0, 0.58, 0.0)
var _mat: StandardMaterial3D
var _base_emission := 2.0

static func spawn(parent: Node3D, world_pos: Vector3, content: String, color: Color) -> void:
	var p := BigScorePopup3D.new()

	var tm := TextMesh.new()
	tm.text = content
	tm.font_size = 200
	tm.depth = 0.06                                  # the extrusion = the "3D"
	tm.pixel_size = 0.0007
	tm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	p.mesh = tm

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = p._base_emission
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# PER_PIXEL (not unshaded) so the extruded side faces catch light and the
	# depth is visible; emission keeps it readable against passthrough.
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	p.material_override = mat
	p._mat = mat

	parent.add_child(p)
	p.global_position = world_pos

	# Face the user at spawn (yaw only, stay upright), then hold orientation.
	# TextMesh's readable face is +Z; look_at points -Z at the target, so flip
	# 180° about local Y to turn the front toward the camera.
	var cam := p.get_viewport().get_camera_3d()
	if cam:
		var look := cam.global_position
		look.y = p.global_position.y
		if not look.is_equal_approx(p.global_position):
			p.look_at(look, Vector3.UP)
			p.rotate_object_local(Vector3.UP, PI)

func _process(delta: float) -> void:
	_age += delta
	var t := _age / _lifetime
	if t >= 1.0:
		queue_free()
		return
	global_position += _velocity * delta
	_velocity.y -= 0.22 * delta                      # gentle gravity → arc

	# Fade out over the last 40% of life (alpha + emission together).
	var a := 1.0
	if t > 0.6:
		a = 1.0 - (t - 0.6) / 0.4
	_mat.albedo_color.a = a
	_mat.emission_energy_multiplier = _base_emission * a

	# Quick pop-in scale for the first ~quarter of life.
	var s := 1.0 + 0.4 * (1.0 - minf(t * 4.0, 1.0))
	scale = Vector3.ONE * s
