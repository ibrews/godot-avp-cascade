extends RigidBody3D
class_name PickupAbleBody3D

# Hand-tracking pickup body — based on Marshall Nowak (Nocxr)'s PickupAbleBody3D
# from the visionosxr_hand_tracking reference project.
# Added: throw velocity from recent position history on release.

# Two outline states: a soft "candidate" outline when this body is the closest
# grabbable (pinch now to grab it), and a brighter/thicker "held" outline while
# it's actually picked up. Both are inverted-hull overlays (highlight_shader).
var _candidate_material : ShaderMaterial = _make_outline(Color(0.30, 0.80, 1.00, 1.0), 0.018)  # cyan
var _held_material : ShaderMaterial = _make_outline(Color(0.45, 1.00, 0.55, 1.0), 0.030)        # green, thicker
var picked_up_by : Area3D
var closest_areas : Array

static func _make_outline(color: Color, width: float) -> ShaderMaterial:
	var base := load("res://shaders/highlight_material.tres") as ShaderMaterial
	var m := base.duplicate() as ShaderMaterial
	m.set_shader_parameter("outline_color", color)
	m.set_shader_parameter("outline_width", width)
	return m

# When true, the body stays frozen in place on release instead of falling/throwing.
# Used for the catch plates and wall so they can be repositioned but don't drop.
@export var freeze_on_release := false

# Resting freeze mode, restored on release. While held we force STATIC (see pick_up).
var _saved_freeze_mode : int = FREEZE_MODE_STATIC

# Position history for throw velocity: Array of {pos: Vector3, t: int}
var _pos_history : Array = []
const _POS_HISTORY_MAX := 6

# Held-follow smoothing. While held the body is NOT reparented to the handler;
# instead it damps its own WORLD transform toward the handler's each physics frame
# (first-order low-pass). This filters hand-tracking jitter — a body rigidly locked
# as the handler's child inherits every twitch and cannot filter anything. Higher
# rate = snappier follow / less smoothing; lower = smoother / more lag.
const FOLLOW_SMOOTH_RATE := 30.0


# Called when this object becomes the closest body in an area
func add_is_closest(area : Area3D) -> void:
	if not closest_areas.has(area):
		closest_areas.push_back(area)
	_update_highlight()


# Called when this object is no longer the closest body in an area
func remove_is_closest(area : Area3D) -> void:
	if closest_areas.has(area):
		closest_areas.erase(area)
	_update_highlight()


# Returns whether we have been picked up.
func is_picked_up() -> bool:
	return picked_up_by != null


# Damp our WORLD transform toward the handler's each physics frame (position +
# rotation, scale preserved), then record the smoothed global position so throw
# velocity reflects what was actually shown.
func _physics_process(delta: float) -> void:
	if picked_up_by == null:
		return
	var target := picked_up_by.global_transform
	var gt := global_transform
	var a: float = clampf(1.0 - exp(-FOLLOW_SMOOTH_RATE * delta), 0.0, 1.0)
	var sc := gt.basis.get_scale()
	var new_origin := gt.origin.lerp(target.origin, a)
	var new_quat := gt.basis.get_rotation_quaternion().slerp(target.basis.get_rotation_quaternion(), a).normalized()
	global_transform = Transform3D(Basis(new_quat).scaled(sc), new_origin)
	_pos_history.append({"pos": global_position, "t": Time.get_ticks_msec()})
	if _pos_history.size() > _POS_HISTORY_MAX:
		_pos_history.pop_front()


# Pick this object up.
func pick_up(pick_up_by) -> void:
	# Already picked up? Can't pick up twice.
	if picked_up_by:
		if picked_up_by == pick_up_by:
			return
		let_go()

	# We do NOT reparent to the handler — the body stays in place in the world tree
	# and _physics_process damps its world transform toward the handler each frame.
	picked_up_by = pick_up_by
	# Held bodies use STATIC freeze so our per-frame global_transform writes apply as
	# clean teleports. KINEMATIC freeze (the course obstacles' resting mode) instead
	# sweeps the move through the solver one frame late = grab stutter. Cubes already
	# default to STATIC, which is why they always grabbed smoothly.
	_saved_freeze_mode = freeze_mode
	freeze_mode = FREEZE_MODE_STATIC
	freeze = true
	_pos_history.clear()
	_update_highlight()


# Let this object go — applies throw velocity from position history.
func let_go() -> void:
	if not picked_up_by:
		return

	# Compute throw velocity from recent hand movement (skipped for stay-put bodies).
	var throw_velocity := Vector3.ZERO
	if not freeze_on_release and _pos_history.size() >= 2:
		var newest: Dictionary = _pos_history[-1]
		var oldest: Dictionary = _pos_history[0]
		var dt_sec: float = (float(newest["t"]) - float(oldest["t"])) / 1000.0
		if dt_sec > 0.001:
			var new_pos: Vector3 = newest["pos"]
			var old_pos: Vector3 = oldest["pos"]
			throw_velocity = (new_pos - old_pos) / dt_sec
	_pos_history.clear()

	# Not reparented while held, so there is nothing to move — the body is already at
	# its smoothed world pose. Just release and restore the resting freeze mode.
	picked_up_by = null
	freeze_mode = _saved_freeze_mode  # e.g. KINEMATIC for course obstacles

	if freeze_on_release:
		# Stay where dropped (plates/wall) — remain a frozen collider, no throw.
		freeze = true
	else:
		freeze = false
		linear_velocity = throw_velocity
		# Zero the spin: a frozen body otherwise resumes whatever angular velocity it
		# had before pickup, which reads as a weird flick on release. Keep the exact
		# orientation it was let go at.
		angular_velocity = Vector3.ZERO
	_update_highlight()


# Outline state: held > candidate > none. Held = green/thick while picked up;
# candidate = cyan/thin when this is the closest grabbable; none otherwise.
func _update_highlight() -> void:
	var overlay : Material = null
	if picked_up_by:
		overlay = _held_material
	elif not closest_areas.is_empty():
		overlay = _candidate_material
	for child in get_children():
		if child is MeshInstance3D:
			(child as MeshInstance3D).material_overlay = overlay
