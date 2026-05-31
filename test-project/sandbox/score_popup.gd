class_name ScorePopup3D
extends Label3D

# Self-animating floating score/multiplier text. Billboards toward the viewer,
# arcs upward, pops in, fades out, then frees itself.
#
# Usage: ScorePopup3D.spawn(parent, world_pos, "x3", Color.YELLOW, big=false)

var _age := 0.0
var _lifetime := 1.0
var _velocity := Vector3(0.0, 0.35, 0.0)

static func spawn(parent: Node3D, world_pos: Vector3, content: String, color: Color, big: bool = false) -> void:
	var p := ScorePopup3D.new()
	p.text = content
	p.modulate = color
	p.outline_modulate = Color(0.0, 0.0, 0.0, 0.9)
	p.font_size = 220 if big else 120
	p.outline_size = 26 if big else 14
	p.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	p.shaded = false
	p.pixel_size = 0.0007 if big else 0.00045
	p.no_depth_test = true  # always readable over geometry
	p._lifetime = 1.7 if big else 1.0
	p._velocity = Vector3(0.0, 0.55 if big else 0.38, 0.0)
	parent.add_child(p)
	p.global_position = world_pos

func _process(delta: float) -> void:
	_age += delta
	var t := _age / _lifetime
	if t >= 1.0:
		queue_free()
		return
	global_position += _velocity * delta
	# Fade out over the last 40% of life.
	var a := 1.0
	if t > 0.6:
		a = 1.0 - (t - 0.6) / 0.4
	modulate.a = a
	# Quick pop-in scale for the first ~quarter of life.
	var s := 1.0 + 0.35 * (1.0 - minf(t * 4.0, 1.0))
	scale = Vector3.ONE * s
