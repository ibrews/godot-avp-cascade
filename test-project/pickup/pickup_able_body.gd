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

var original_parent : Node3D
# Resting freeze mode, restored on release. While held we force STATIC (see pick_up).
var _saved_freeze_mode : int = FREEZE_MODE_STATIC

# Position history for throw velocity: Array of {pos: Vector3, t: int}
var _pos_history : Array = []
const _POS_HISTORY_MAX := 6

# Held-follow smoothing: each physics frame the body damps its LOCAL transform
# toward the handler origin (identity) rather than snapping. This low-pass-filters
# hand-tracking jitter so grabbed objects don't shimmy, and makes the on-release
# pose exactly the smoothed pose on screen. Higher = snappier, less smoothing.
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


# Damp toward the handler each physics frame, then record the (smoothed) global
# position so throw velocity reflects what was actually shown.
func _physics_process(delta: float) -> void:
	if not is_picked_up():
		return
	var a: float = clampf(1.0 - exp(-FOLLOW_SMOOTH_RATE * delta), 0.0, 1.0)
	var cur := transform
	var sc := cur.basis.get_scale()
	var new_origin := cur.origin.lerp(Vector3.ZERO, a)
	var new_quat := cur.basis.get_rotation_quaternion().slerp(Quaternion.IDENTITY, a).normalized()
	transform = Transform3D(Basis(new_quat).scaled(sc), new_origin)
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

	# Remember some state we want to reapply on release.
	original_parent = get_parent()
	var current_transform = global_transform

	# Remove us from our old parent.
	original_parent.remove_child(self)

	# Process our pickup.
	picked_up_by = pick_up_by
	picked_up_by.add_child(self)
	global_transform = current_transform
	# Held bodies MUST use STATIC freeze: the handler rewrites global_transform every
	# physics frame, and STATIC freeze applies that as a clean teleport. KINEMATIC
	# freeze (used by the course obstacles at rest) instead sweeps the move through
	# the solver one frame behind, fighting the handler = grab stutter. Cubes already
	# default to STATIC, which is why they grab smoothly.
	_saved_freeze_mode = freeze_mode
	freeze_mode = FREEZE_MODE_STATIC
	freeze = true
	_pos_history.clear()
	_update_highlight()
	# No snap tween: _physics_process smoothly damps the body to the handler origin.


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

	# Remember our current transform.
	var current_transform = global_transform

	# Reparent back to original parent.
	picked_up_by.remove_child(self)
	picked_up_by = null

	original_parent.add_child(self)
	global_transform = current_transform

	# Restore the resting freeze mode (e.g. KINEMATIC for course obstacles).
	freeze_mode = _saved_freeze_mode

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
