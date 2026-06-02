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

# --- Grab telemetry (grab_diag.txt). Flip GRAB_DIAG off (or delete) for release. ---
const GRAB_DIAG := true
var _gdiag_frame := 0

# --- A/B grab-follow modes, cycled live by the big in-world DEBUG button (main_v2). Shared
# static so the handler (anchor source) and this body (follow filter) both read it. Once we
# pick a winner this collapses to that one approach.
#   0 FINGER+MED  fingertip midpoint, median-of-3 de-spike, tight follow
#   1 WRIST       anchor on the WRIST joint (immune to held-object finger occlusion), tight
#   2 SMOOTH      fingertip midpoint, heavy low-pass (stable but laggy)
#   3 RAW         fingertip midpoint, ~1:1 (no smoothing) — baseline feel
static var grab_mode : int = 0
const GRAB_MODE_NAMES := ["FINGER+MED", "WRIST", "SMOOTH", "RAW"]

# Position one-euro min-cutoff per mode (Hz). Higher = tighter/less lag.
func _mode_pos_cutoff() -> float:
	match grab_mode:
		2: return 2.5     # SMOOTH
		3: return 30.0    # RAW (effectively 1:1)
		_: return 9.0     # FINGER+MED / WRIST — tight

func _gdiag(line: String) -> void:
	if not GRAB_DIAG:
		return
	var f := FileAccess.open("user://grab_diag.txt", FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open("user://grab_diag.txt", FileAccess.WRITE)
	if f != null:
		f.seek_end()
		f.store_line("%8.2f %s" % [Time.get_ticks_msec() / 1000.0, line])
		f.close()

func _holder_side() -> String:
	if picked_up_by != null and picked_up_by.get_parent() != null and "tracker" in picked_up_by.get_parent():
		return str(picked_up_by.get_parent().tracker)
	return "?"

# --- Held-follow smoothing (one-euro: position + adaptive-slerp rotation) ---
# The held body used to ride the handler 1:1, which passed raw XRHandTracker sensor
# noise straight through ("electric" jitter on pos AND rotation). We instead keep a
# PERSISTENT world-space filtered transform and, each render frame, ease it toward the
# handler's raw world pose. That persistent state is the stable frame the smoothing
# needs — we never read it back from the reparented body (doing so would re-absorb the
# jitter, which is the trap the KB warns about). One-euro = smooth at rest, opens its
# cutoff with speed so fast moves keep ~zero lag. Render-rate (_process), never physics.
# Tune on-device: *_MIN_CUTOFF ↓ = smoother/laggier at rest ; *_BETA ↑ = snappier when moving.
const FOLLOW_POS_MIN_CUTOFF := 9.0   # Hz — track tight (~18 ms lag). The anchor is now de-spiked
                                     # upstream (median-of-3 in pickup_handler), so spikes don't
                                     # reach this filter and we don't need smoothing to hide them.
const FOLLOW_POS_BETA := 1.0         # per (m/s) — small extra opening at speed
const FOLLOW_ROT_MIN_CUTOFF := 3.0   # Hz
const FOLLOW_ROT_BETA := 0.35        # per (rad/s)
const FOLLOW_DCUTOFF := 2.5          # Hz — was 1.0; the speed estimate must react FAST or the
                                     # adaptive cutoff opens late and a quick move lags ~1s behind
# Spike rejection: a single bad XRHandTracker sample makes target_pos leap, which
# spikes d_pos, opens the one-euro cutoff, and snaps the held body to the glitch for
# one frame (then back) — the "glitches into other positions for a frame" report.
# Clamp the target to a max plausible HAND speed each frame, so a superhuman jump is
# capped (rejected) rather than chased; real fast moves up to the cap pass through.
const FOLLOW_MAX_LIN_SPEED := 6.0    # m/s — backstop only now (median de-spikes upstream); pass
                                     # genuine fast moves (~1-3 m/s) and still reject gross teleports.
const FOLLOW_MAX_ANG_SPEED := 25.0   # rad/s — same idea for orientation
var _follow_ready := false
var _filt_pos : Vector3 = Vector3.ZERO
var _filt_basis : Basis = Basis.IDENTITY
var _filt_vel : Vector3 = Vector3.ZERO      # filtered linear speed (m/s)
var _filt_avel : float = 0.0                # filtered angular speed (rad/s)
var _grab_rot_offset : Basis = Basis.IDENTITY   # held body's basis relative to the holder, at grab
# The GRABBED POINT, expressed in the body's own (unscaled, mesh-local) frame at grab time.
# The follow offsets the body origin so this exact point stays pinned under the finger and the
# object rotates ABOUT it — instead of snapping the body CENTRE onto the fingertip (which made
# a grabbed panel orbit your finger, and teleported its centre onto a button you didn't mean to
# poke). Captured in pick_up, applied in _process.
var _grab_point_local : Vector3 = Vector3.ZERO
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
	# One-hand follow, GRAB-BY-POINT. We smooth the INPUTS — the pinch/PIVOT point (your grab
	# point = the holder origin) and the orientation — then reconstruct the body origin so the
	# grabbed local point sits EXACTLY on the smoothed pivot every frame. Smoothing the pivot
	# (which only moves at hand-translation speed) instead of the body origin is the whole
	# trick: when you rotate your wrist, the body ORIGIN has to swing fast to keep a far grab
	# point pinned, and the linear speed-cap below would throttle that origin motion — sliding
	# the object off your finger (the "it doesn't stay locked, swings all over" bug). The pivot
	# never trips the cap, so the grab point stays locked through arbitrary rotation.
	# _filt_pos now holds the filtered PIVOT (grab-point world pos), not the body origin.
	var target_pivot := holder_xform.origin
	var finger_anchor := holder_xform.origin   # the RAW fingertip pinch this frame (pre-clamp)
	var target_basis := (holder_xform.basis.orthonormalized() * _grab_rot_offset).orthonormalized()
	var clamp_lin := false
	var clamp_ang := false

	if not _follow_ready or delta <= 0.0:
		# Seed the filtered pivot from the grab point's CURRENT world position so it eases in.
		_filt_basis = global_transform.basis.orthonormalized()
		_filt_pos = global_position + _filt_basis.scaled(_grab_scale) * _grab_point_local
		_filt_vel = Vector3.ZERO
		_filt_avel = 0.0
		_follow_ready = true
	else:
		# --- Spike rejection on the PIVOT (hand point). A superhuman jump is a tracking glitch,
		# not a real move: clamp to the max-speed sphere. The pivot tracks the hand at hand
		# speed, so genuine moves are never clamped — only teleport glitches. ---
		var max_step := FOLLOW_MAX_LIN_SPEED * delta
		var to_target := target_pivot - _filt_pos
		if to_target.length() > max_step:
			target_pivot = _filt_pos + to_target.normalized() * max_step
			clamp_lin = true
		var max_ang_step := FOLLOW_MAX_ANG_SPEED * delta
		var raw_ang := _filt_basis.get_rotation_quaternion().angle_to(target_basis.get_rotation_quaternion())
		if raw_ang > max_ang_step and raw_ang > 0.0:
			# Clamp the rotation target to the max angular step toward it.
			target_basis = _filt_basis.slerp(target_basis, max_ang_step / raw_ang).orthonormalized()
			clamp_ang = true

		var a_d := _oe_alpha(FOLLOW_DCUTOFF, delta)
		# Pivot one-euro. Cap the velocity estimate so the adaptive cutoff can't blow
		# wide open from any residual spike (belt-and-suspenders with the clamp above).
		var d_pos := (target_pivot - _filt_pos) / delta
		_filt_vel = _filt_vel.lerp(d_pos, a_d)
		var p_cut := _mode_pos_cutoff() + FOLLOW_POS_BETA * minf(_filt_vel.length(), FOLLOW_MAX_LIN_SPEED)
		_filt_pos = _filt_pos.lerp(target_pivot, _oe_alpha(p_cut, delta))
		# Rotation one-euro (adaptive slerp).
		var ang := _filt_basis.get_rotation_quaternion().angle_to(target_basis.get_rotation_quaternion())
		_filt_avel = lerpf(_filt_avel, ang / delta, a_d)
		var r_cut := FOLLOW_ROT_MIN_CUTOFF + FOLLOW_ROT_BETA * minf(_filt_avel, FOLLOW_MAX_ANG_SPEED)
		_filt_basis = _filt_basis.slerp(target_basis, _oe_alpha(r_cut, delta)).orthonormalized()

	# Reconstruct the body origin so the grabbed local point lands EXACTLY on the filtered pivot.
	var body_origin := _filt_pos - _filt_basis.scaled(_grab_scale) * _grab_point_local
	global_transform = Transform3D(_filt_basis.scaled(_grab_scale), body_origin)

	# --- Diagnostics: the grabbed point ends up at _filt_pos by construction; SLIP is how far
	# that is from the actual fingertip this frame. ~0 = glued; a spike during rotation = the
	# "lost my attach point" bug, now quantified. Throttled to ~12 Hz, plus always log a big slip.
	if GRAB_DIAG:
		_gdiag_frame += 1
		var slip_mm := (_filt_pos - finger_anchor).length() * 1000.0
		if _gdiag_frame % 8 == 0 or slip_mm > 15.0 or clamp_lin:
			var src := "?"
			if picked_up_by != null and "anchor_src" in picked_up_by:
				src = picked_up_by.anchor_src
			_gdiag("HOLD %s obj=%s slip_mm=%.1f anchor_spd=%.2f src=%s clampL=%d clampA=%d" % [
				_holder_side(), name, slip_mm, _filt_vel.length(), src, int(clamp_lin), int(clamp_ang)])

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
		# Where on the body did we grab? Map the holder (fingertip/pinch) world point into the
		# body's local mesh frame so the follow can keep THAT point under the finger and rotate
		# the body about it. affine_inverse divides out the body's scale, giving unscaled local.
		_grab_point_local = current_transform.affine_inverse() * holder.global_transform.origin
	else:
		_grab_rot_offset = Basis.IDENTITY
		_grab_point_local = Vector3.ZERO
	_grab_scale = current_transform.basis.get_scale()
	_follow_ready = false   # seed the filter from the current pose on the first frame
	if holder != null:
		_gdiag("GRABBED obj=%s#%d body=%s anchor=%s gp_local=%s scale=%s" % [
			name, get_instance_id(), str(current_transform.origin),
			str(holder.global_transform.origin), str(_grab_point_local), str(_grab_scale)])

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
	if picked_up_by != null:
		_gdiag("LETGO obj=%s#%d body=%s" % [name, get_instance_id(), str(global_position)])
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
