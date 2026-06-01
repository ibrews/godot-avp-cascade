extends RigidBody3D
class_name PickupAbleBody3D

# Hand-tracking pickup body — based on Marshall Nowak (Nocxr)'s PickupAbleBody3D
# from the visionosxr_hand_tracking reference project.
# Added: throw velocity from recent position history on release.

# Two outline states: a soft "candidate" outline when this body is the closest
# grabbable (pinch now to grab it), and a brighter/thicker "held" outline while
# it's actually picked up. Both are inverted-hull overlays (highlight_shader).
# `grow` is in LOCAL metres along the vertex normal (base shader default was 0.002 = 2mm).
# Keep these small — large values explode the inverted hull. Blue (scale) is the thickest.
var _candidate_material : ShaderMaterial = _make_outline(Color(0.30, 0.80, 1.00, 1.0), 0.004)  # cyan, thin
var _held_material : ShaderMaterial = _make_outline(Color(0.45, 1.00, 0.55, 1.0), 0.008)        # green, thicker
var _scale_material : ShaderMaterial = _make_outline(Color(0.12, 0.45, 1.00, 1.0), 0.014)       # BLUE, two-hand scale — thickest + saturated so it's unmistakable
var picked_up_by : Area3D
var closest_areas : Array

# While true, an external driver (main_v2 two-hand scale) owns this body's transform;
# the single-hand follow is suspended and the body is frozen so physics won't fight it.
var two_hand := false
var _saved_two_hand_freeze := true
var _saved_collision_layer := 0
var _saved_collision_mask := 0

static func _make_outline(color: Color, width: float) -> ShaderMaterial:
	# NOTE: the highlight shader's uniforms are `albedo` (color) and `grow` (width),
	# NOT outline_color/outline_width. Setting the wrong names silently no-ops, which
	# is why every outline rendered as the base material's yellow at grow=0.002
	# (skinny) regardless of state. Use the real uniform names.
	var base := load("res://shaders/highlight_material.tres") as ShaderMaterial
	var m := base.duplicate() as ShaderMaterial
	m.set_shader_parameter("albedo", color)
	m.set_shader_parameter("grow", width)
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

# --- Release-transition probe (diagnostic for "snaps to a different orientation on let go") ---
# On release we record the held orientation (last frame before physics took over) then the
# global orientation for the next REL_FRAMES physics frames, and dump euler deltas to
# user://release_trace.txt. If frame 0→1 already shows a big jump = transform discontinuity
# at release; if it grows over several frames = physics settling (gravity/contact torque).
const REL_FRAMES := 12
var _rel_log : Array = []
var _rel_active := false

# --- Held-follow smoothing (one-euro: position + adaptive-slerp rotation) ---
# The held body used to ride the handler 1:1, which passed raw XRHandTracker sensor
# noise straight through ("electric" jitter on pos AND rotation). We instead keep a
# PERSISTENT world-space filtered transform and, each render frame, ease it toward the
# handler's raw world pose. That persistent state is the stable frame the smoothing
# needs — we never read it back from the reparented body (doing so would re-absorb the
# jitter, which is the trap the KB warns about). One-euro = smooth at rest, opens its
# cutoff with speed so fast moves keep ~zero lag. Render-rate (_process), never physics.
# Tune on-device: *_MIN_CUTOFF ↓ = smoother/laggier at rest ; *_BETA ↑ = snappier when moving.
const FOLLOW_POS_MIN_CUTOFF := 2.0   # Hz
const FOLLOW_POS_BETA := 0.7         # per (m/s)
const FOLLOW_ROT_MIN_CUTOFF := 3.0   # Hz
const FOLLOW_ROT_BETA := 0.35        # per (rad/s)
const FOLLOW_DCUTOFF := 1.0          # Hz, cutoff for the speed estimates themselves
# Spike rejection: a single bad XRHandTracker sample makes target_pos leap, which
# spikes d_pos, opens the one-euro cutoff, and snaps the held body to the glitch for
# one frame (then back) — the "glitches into other positions for a frame" report.
# Clamp the target to a max plausible HAND speed each frame, so a superhuman jump is
# capped (rejected) rather than chased; real fast moves up to the cap pass through.
const FOLLOW_MAX_LIN_SPEED := 4.0    # m/s — hands don't outrun this; spikes are noise
const FOLLOW_MAX_ANG_SPEED := 25.0   # rad/s — same idea for orientation
var _follow_ready := false
var _filt_pos : Vector3 = Vector3.ZERO
var _filt_basis : Basis = Basis.IDENTITY
var _filt_vel : Vector3 = Vector3.ZERO      # filtered linear speed (m/s)
var _filt_avel : float = 0.0                # filtered angular speed (rad/s)
var _grab_rot_offset : Basis = Basis.IDENTITY   # held body's basis relative to the holder, at grab
# The body CENTRE (origin) expressed in the HOLDER's local frame at grab time. Driving the
# follow with this offset (instead of the bare holder origin) keeps the GRABBED POINT under
# the finger and makes the object rotate ABOUT that point, not snap its centre to the hand.
# Without it, grabbing a wide panel by its edge teleported the panel centre onto your fingertip
# (so you'd then poke a button you didn't mean to). Captured in pick_up, applied in _process.
var _grab_pos_offset : Vector3 = Vector3.ZERO
var _grab_scale : Vector3 = Vector3.ONE


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
	# Release-transition probe: after let_go() arms this, log the post-release world
	# orientation for a few physics frames, then dump once. Runs whether or not held.
	if _rel_active:
		_rel_log.append([Time.get_ticks_usec(), global_transform.basis.get_euler()])
		if _rel_log.size() >= REL_FRAMES + 1:
			_dump_release_trace()
			_rel_active = false

	if not is_picked_up():
		return
	_pos_history.append({"pos": global_position, "t": Time.get_ticks_msec()})
	if _pos_history.size() > _POS_HISTORY_MAX:
		_pos_history.pop_front()

# Render-frame hook while held. Drives the body's world transform via a one-euro filter
# easing toward the handler's raw pose (smooths the hand-tracking jitter on pos + rot).
# Render rate, so it tracks the 90 Hz display. Replaces both the old 1:1 reparent ride
# (too raw — "electric") and the pickup snap tween (the filter eases in the grab itself).
func _process(delta: float) -> void:
	if two_hand:
		return  # main_v2 two-hand scale owns the transform this frame
	if not is_picked_up():
		return
	var holder := picked_up_by as Node3D
	if holder == null:
		return

	var holder_xform := holder.global_transform
	# Drive the body so the GRAB POINT (not the centre) stays under the finger. _grab_pos_offset
	# is the body centre in holder-local space at grab; mapping it back through the (possibly
	# rotated) holder frame each frame gives the centre position that keeps the grabbed point put
	# and lets the object orbit about that point. Use orthonormalized basis so a uniformly-scaled
	# holder doesn't smear the offset.
	var target_pos := holder_xform.origin + holder_xform.basis.orthonormalized() * _grab_pos_offset
	var target_basis := (holder_xform.basis.orthonormalized() * _grab_rot_offset).orthonormalized()

	if not _follow_ready or delta <= 0.0:
		# Seed from the body's current visual pose so the grab eases in from where it is.
		_filt_pos = global_position
		_filt_basis = global_transform.basis.orthonormalized()
		_filt_vel = Vector3.ZERO
		_filt_avel = 0.0
		_follow_ready = true
	else:
		# --- Spike rejection (before the filter sees it). If this frame's target implies a
		# superhuman hand speed, it's a tracking glitch, not a real move: clamp the target to
		# the max-speed sphere around the current filtered pose. A genuine fast move (≤ cap)
		# is untouched; a one-frame teleport is reined in so it can't snap the body. ---
		var max_step := FOLLOW_MAX_LIN_SPEED * delta
		var to_target := target_pos - _filt_pos
		if to_target.length() > max_step:
			target_pos = _filt_pos + to_target.normalized() * max_step
		var max_ang_step := FOLLOW_MAX_ANG_SPEED * delta
		var raw_ang := _filt_basis.get_rotation_quaternion().angle_to(target_basis.get_rotation_quaternion())
		if raw_ang > max_ang_step and raw_ang > 0.0:
			# Clamp the rotation target to the max angular step toward it.
			target_basis = _filt_basis.slerp(target_basis, max_ang_step / raw_ang).orthonormalized()

		var a_d := _oe_alpha(FOLLOW_DCUTOFF, delta)
		# Position one-euro. Cap the velocity estimate so the adaptive cutoff can't blow
		# wide open from any residual spike (belt-and-suspenders with the clamp above).
		var d_pos := (target_pos - _filt_pos) / delta
		_filt_vel = _filt_vel.lerp(d_pos, a_d)
		var p_cut := FOLLOW_POS_MIN_CUTOFF + FOLLOW_POS_BETA * minf(_filt_vel.length(), FOLLOW_MAX_LIN_SPEED)
		_filt_pos = _filt_pos.lerp(target_pos, _oe_alpha(p_cut, delta))
		# Rotation one-euro (adaptive slerp).
		var ang := _filt_basis.get_rotation_quaternion().angle_to(target_basis.get_rotation_quaternion())
		_filt_avel = lerpf(_filt_avel, ang / delta, a_d)
		var r_cut := FOLLOW_ROT_MIN_CUTOFF + FOLLOW_ROT_BETA * minf(_filt_avel, FOLLOW_MAX_ANG_SPEED)
		_filt_basis = _filt_basis.slerp(target_basis, _oe_alpha(r_cut, delta)).orthonormalized()

	global_transform = Transform3D(_filt_basis.scaled(_grab_scale), _filt_pos)

	# Per-render-frame grab trace (one-shot per grab, ~90 frames ≈ 1 s at 90 Hz).
	if not _trace_done:
		_trace.append([Time.get_ticks_usec(), global_position, global_transform.basis.get_euler()])
		if _trace.size() >= TRACE_FRAMES:
			_dump_trace()
			_trace_done = true


# Smoothing factor for a first-order low-pass at the given cutoff (Hz) and dt (s).
func _oe_alpha(cutoff: float, dt: float) -> float:
	var tau := 1.0 / (TAU * cutoff)
	return 1.0 / (1.0 + tau / dt)


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

	# Capture the body's orientation RELATIVE to the holder at grab, and its scale, so the
	# follow filter preserves "grab it as-is" (no re-align to the hand axis — the old
	# IDENTITY snap rotated through ~149°, see grab_snap.txt) while still letting the cube
	# rotate WITH the hand. The one-euro follow in _process eases position to the fingertips
	# and tracks rotation; no snap tween needed (it would fight the filter).
	var holder := pick_up_by as Node3D
	if holder != null:
		_grab_rot_offset = holder.global_transform.basis.orthonormalized().inverse() * current_transform.basis.orthonormalized()
		# Body centre expressed in the holder's local frame at grab. Replaying this offset in
		# _process keeps the grabbed point (e.g. the edge you pinched) under the finger instead
		# of forcing the centre to the hand. affine_inverse handles any holder translation/rotation.
		_grab_pos_offset = holder.global_transform.affine_inverse() * current_transform.origin
	else:
		_grab_rot_offset = Basis.IDENTITY
		_grab_pos_offset = Vector3.ZERO
	_grab_scale = current_transform.basis.get_scale()
	_follow_ready = false   # seed the filter from the current pose on the first frame

	# Grab-snap probe: the resting→hand angle the old IDENTITY snap would have applied.
	if holder != null:
		var rest_q: Quaternion = current_transform.basis.orthonormalized().get_rotation_quaternion()
		var hand_q: Quaternion = holder.global_transform.basis.orthonormalized().get_rotation_quaternion()
		_dump_grab_snap(rad_to_deg(rest_q.angle_to(hand_q)))

	if tween:
		tween.kill()
		tween = null


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

	# Arm the release-transition probe: seed with the held orientation (= current_transform,
	# the last visual pose), then _physics_process logs the next REL_FRAMES frames.
	_rel_log = [[Time.get_ticks_usec(), current_transform.basis.get_euler()]]
	_rel_active = true

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
	if two_hand:
		overlay = _scale_material            # blue — two-hand scale/rotate
	elif picked_up_by:
		overlay = _held_material
	elif not closest_areas.is_empty():
		overlay = _candidate_material
	for child in get_children():
		if child is MeshInstance3D:
			(child as MeshInstance3D).material_overlay = overlay

# Enter/exit external two-hand control: freeze so physics can't fight the driver,
# DISABLE collision so the scaling/rotating body doesn't shove (and get shoved by)
# other bodies, and — CRITICAL — FREEZE the holding hand handler's fingertip-follow
# so that handler node can't drag this body.
#
# THE TWO-WRITER BUG (the "glitches to a couple of specific spots, worse when scaled
# big" report): a held body is a CHILD of the hand handler (pick_up reparents it).
# main's _update_two_hand_scale sets the body's global_transform first (tree root runs
# first), then the holding handler's _process moves the handler NODE to the fingertip —
# and the body, being its child, is carried by that motion AFTER the scale already
# placed it. Holding still it's a steady offset; scaling big you move that hand fast,
# so the handler's per-frame motion spikes and the body jumps to the dragged spot for
# one frame, then back. We stop the handler from MOVING during the scale by turning off
# its follow_fingertips — the scale math reads the hand tracker directly (via main's
# _index_pinch_point), NOT the handler anchor, so scaling is unaffected. No reparenting,
# so the grab/release lifecycle (which assumes child-of-handler) is untouched.
var _two_hand_follow_was_on := true

func set_two_hand(on: bool) -> void:
	two_hand = on
	if on:
		_saved_two_hand_freeze = freeze
		freeze_mode = FREEZE_MODE_STATIC
		freeze = true
		# Phase out of all collision while transformed (restored on exit).
		_saved_collision_layer = collision_layer
		_saved_collision_mask = collision_mask
		collision_layer = 0
		collision_mask = 0
		# Freeze the holding handler's anchor so it stops dragging us (the second writer).
		if picked_up_by != null:
			_two_hand_follow_was_on = bool(picked_up_by.get("follow_fingertips"))
			picked_up_by.set("follow_fingertips", false)
	else:
		# Restore the handler's fingertip-follow.
		if picked_up_by != null:
			picked_up_by.set("follow_fingertips", _two_hand_follow_was_on)
		collision_layer = _saved_collision_layer
		collision_mask = _saved_collision_mask
		freeze = true if freeze_on_release else false
		_follow_ready = false  # re-seed the one-euro follow from the current pose
	_update_highlight()


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


# Dump the release-transition probe: euler deltas from the held pose (frame 0) through
# the first few post-release physics frames. Big 0→1 = discontinuity at release; growth
# over frames = physics settling. Lands in user:// (Documents on visionOS).
func _dump_release_trace() -> void:
	var f := FileAccess.open("user://release_trace.txt", FileAccess.WRITE)
	if f == null:
		return
	f.store_string("# release trace: frame 0 = held pose, then post-release physics frames. body=%s\n" % name)
	f.store_string("# dt_ms | deuler_deg x,y,z (vs previous) | cumulative_deg from held pose\n")
	var base_eu: Vector3 = _rel_log[0][1]
	for i in range(1, _rel_log.size()):
		var prev: Array = _rel_log[i - 1]
		var cur: Array = _rel_log[i]
		var dt_ms := (float(cur[0]) - float(prev[0])) / 1000.0
		var deu: Vector3 = cur[1] - prev[1]
		var cum: Vector3 = cur[1] - base_eu
		f.store_string("%6.2f | %7.3f %7.3f %7.3f | %7.3f %7.3f %7.3f\n" % [
			dt_ms, rad_to_deg(deu.x), rad_to_deg(deu.y), rad_to_deg(deu.z),
			rad_to_deg(cum.x), rad_to_deg(cum.y), rad_to_deg(cum.z)])
	f.close()


# Grab-snap probe: write the resting→hand orientation angle (deg) at the last grab.
# After the orientation-preserving fix this is the angle the cube NO LONGER snaps through.
func _dump_grab_snap(angle_deg: float) -> void:
	var f := FileAccess.open("user://grab_snap.txt", FileAccess.WRITE)
	if f == null:
		return
	f.store_string("last grab: resting→hand orientation = %.1f deg (this is the reorientation the old IDENTITY snap applied; now preserved)\n" % angle_deg)
	f.close()
