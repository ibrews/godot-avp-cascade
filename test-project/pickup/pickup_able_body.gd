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
var tween : Tween
# Resting freeze mode, restored on release. While held we force STATIC (see pick_up).
var _saved_freeze_mode : int = FREEZE_MODE_STATIC

# Position history for throw velocity: Array of {pos: Vector3, t: int}
var _pos_history : Array = []
const _POS_HISTORY_MAX := 6

const PICKUP_SNAP_DURATION := 0.03

# --- Per-render-frame grab trace (diagnostic for the POSITIONAL stutter) ---
# While held, capture (t_usec, global_position, basis euler) every RENDER frame into
# a ring buffer. After TRACE_FRAMES frames we write the frame-to-frame deltas ONCE to
# user://grab_trace.txt and stop, so it never spams. The position deltas expose the
# 60 Hz anchor re-pin saw-tooth on the 90 Hz display (smooth ramp + periodic jump).
# Build 1 = this trace only (anchor still re-pinned in handler._physics_process, so
# the saw-tooth should be visible). Build 2 (Fix A) moves the re-pin to render rate;
# re-capture should then show the per-frame |dpos| go flat.
const TRACE_FRAMES := 90
var _trace : Array = []
var _trace_done := false


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


# Track global position while held (for throw velocity) — physics rate is fine here.
func _physics_process(_delta: float) -> void:
	if not is_picked_up():
		return
	_pos_history.append({"pos": global_position, "t": Time.get_ticks_msec()})
	if _pos_history.size() > _POS_HISTORY_MAX:
		_pos_history.pop_front()

# Render-frame hook while held. The body follows the handler purely via reparenting
# (local transform snapped to IDENTITY at pickup → rides the handler's 90 Hz pose 1:1,
# rotation included). We do NOT rewrite the transform here: the old HELD_ROT_DAMP
# low-pass was removed once grab_trace.txt proved rotation was never the stutter
# (deuler <1°/frame) — it only added rotation lag. This hook now just captures the
# one-shot diagnostic trace.
func _process(_delta: float) -> void:
	if not is_picked_up():
		return
	# Don't capture during the brief pickup snap tween (it animates transform → IDENTITY).
	if tween != null and tween.is_running():
		return
	# Per-render-frame grab trace (one-shot per grab, ~90 frames ≈ 1 s at 90 Hz).
	if not _trace_done:
		_trace.append([Time.get_ticks_usec(), global_position, global_transform.basis.get_euler()])
		if _trace.size() >= TRACE_FRAMES:
			_dump_trace()
			_trace_done = true


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
	_trace.clear()
	_trace_done = false
	_update_highlight()

	# Kill any existing tween and snap to the pinch midpoint (local origin of handler).
	if tween:
		tween.kill()
	tween = create_tween()
	tween.tween_property(self, "transform", Transform3D.IDENTITY, PICKUP_SNAP_DURATION)


# Let this object go — applies throw velocity from position history.
func let_go() -> void:
	if not picked_up_by:
		return

	if tween:
		tween.kill()
		tween = null

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
		# Zero the spin so the body keeps the exact orientation it was let go at
		# instead of resuming whatever angular velocity it had before being frozen.
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


# Write the captured render-frame trace as frame-to-frame deltas to user://grab_trace.txt
# (lands in the app's Documents on visionOS — pull it the same way as xr_diag.txt).
# WRITE truncates each dump, so the file always holds the most recent grab's trace.
func _dump_trace() -> void:
	var f := FileAccess.open("user://grab_trace.txt", FileAccess.WRITE)
	if f == null:
		return
	f.store_string("# grab trace: %d render frames, body=%s\n" % [_trace.size(), name])
	f.store_string("# dt_ms | dpos_mm x,y,z | |dpos|_mm | deuler_deg x,y,z\n")
	var sum_mag := 0.0
	var max_mag := 0.0
	for i in range(1, _trace.size()):
		var prev: Array = _trace[i - 1]
		var cur: Array = _trace[i]
		var dt_ms := (float(cur[0]) - float(prev[0])) / 1000.0
		var dpos: Vector3 = (cur[1] - prev[1]) * 1000.0   # metres → mm
		var deu: Vector3 = cur[2] - prev[2]
		var mag := dpos.length()
		sum_mag += mag
		max_mag = maxf(max_mag, mag)
		f.store_string("%6.2f | %7.3f %7.3f %7.3f | %7.3f | %6.3f %6.3f %6.3f\n" % [
			dt_ms, dpos.x, dpos.y, dpos.z, mag,
			rad_to_deg(deu.x), rad_to_deg(deu.y), rad_to_deg(deu.z)])
	var n := maxi(1, _trace.size() - 1)
	f.store_string("# |dpos|_mm  mean=%.3f  max=%.3f  (a flat mean≈max means smooth; spikes = re-pin beat)\n" % [sum_mag / float(n), max_mag])
	f.close()
