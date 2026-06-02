@tool
extends Area3D
class_name PickupHandler3D

# This area3D class detects all physics bodys based on
# PickupAbleBody3D within range and handles the logic
# for selecting the closest one and allowing pickup
# of that object.

# Detect range specifies within what radius we detect
# objects we can pick up.
@export var detect_range : float = 0.3:
	set(value):
		detect_range = value
		if is_inside_tree():
			_update_detect_range()
			_update_closest_body()

# Pickup Action specifies the action in the OpenXR
# action map that triggers our pickup function.
@export var pickup_action : String = "pickup"
@export var pickup_press_threshold : float = 0.35
@export var pickup_release_threshold : float = 0.12
@export var release_grace_msec : int = 180
@export var quick_release_value : float = 0.04
# A "clearly wide-open" pinch must STAY open this long before the quick release fires. A hand-
# tracking burst splays the thumb-index estimate for 1-3 frames mid-grab (val 1.0 -> ~0 -> 1.0
# in ~30-60 ms), which the telemetry caught dropping the grab and re-anchoring the object at a
# new point. This debounce rejects those spikes; a real release stays open far longer. Any frame
# back above the release threshold resets the timer, so an oscillating burst never accumulates.
@export var quick_release_debounce_msec : int = 300
@export var follow_fingertips : bool = true
@export var hold_while_hand_tracking_uncertain : bool = true

# Hand-tracked pinch geometry: thumb–index TIP distance. Grab begins as the tips
# close to HAND_PINCH_GRAB (with pickup_press_threshold this needs ~1 cm) and holds
# until they open past HAND_PINCH_RELEASE (hysteresis).
const HAND_PINCH_GRAB := 0.010
const HAND_PINCH_RELEASE := 0.024

var closest_body : PickupAbleBody3D
var picked_up_body: PickupAbleBody3D
var was_pickup_pressed : bool = false
var release_started_msec : int = 0

# Last good offsets from each fingertip to the pinch midpoint. When BOTH tips track we use
# their midpoint AND record these; if one tip then drops to untracked for a frame (common
# mid-rotation), we reconstruct the SAME midpoint from the surviving tip instead of snapping
# the anchor onto that single tip (a ~1–2 cm lurch that slid the held object off the grab
# point). Keeps the anchor continuous across tracking flickers.
var _mid_from_index : Vector3 = Vector3.ZERO
var _mid_from_thumb : Vector3 = Vector3.ZERO
var _have_mid_offsets : bool = false

# Median-of-3 de-spiker for the fingertip anchor. The telemetry showed isolated single-frame
# jumps (anchor teleports ~8 cm while hand speed is ~1 m/s) — especially on the hand holding a
# plate (fingers occluded from the cameras). A component-wise median of the last 3 samples
# removes a one-frame spike with ~0 lag on real (monotonic) motion — the right tool for spikes
# (a low-pass lags everything; a speed clamp only caps a spike's size). Tracking space.
var _anchor_hist : Array[Vector3] = []

func _median3(a: float, b: float, c: float) -> float:
	return a + b + c - minf(a, minf(b, c)) - maxf(a, maxf(b, c))

# --- Diagnostics (grab_diag.txt). Flip GRAB_DIAG off (or delete) for release. ---
const GRAB_DIAG := true
var anchor_src : String = "none"     # both / index / thumb / none — read by the held body's HOLD log
var _blocked_held : PickupAbleBody3D = null   # nearest in-range body we skipped because it's already held
var _blocked_logged := false

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

func _side() -> String:
	var c := _get_parent_controller()
	return str(c.tracker) if c != null else "?"


# --- Pinch-side telemetry (grab_diag.txt) -------------------------------------------------
# The follow side is already heavily logged (HOLD/slip_mm). This logs what the GRAB LATCH
# sees per hand so we can catch "right hand can't grab": the pinch value vs the active
# threshold, the RAW thumb-index distance (computed from positions even when a tip is only
# VALID-not-TRACKED — which _get_pickup_value can't report because it returns 0.0 then),
# per-joint VALID/TRACKED flags, and raw fingertip-midpoint jitter (mm/frame) for a direct
# L-vs-R noise comparison. Strip with the rest of GRAB_DIAG for release.
const PINCH_DIAG_PERIOD_MS := 100         # ~10 Hz idle sampling; press/release edges bypass it
var _pinch_diag_last_ms : int = 0
var _pinch_prev_raw_pressed : bool = false
var _pinch_raw_mid_prev : Vector3 = Vector3.ZERO
var _pinch_raw_mid_have : bool = false
var _pinch_raw_mid_max_mm : float = 0.0   # max raw-midpoint delta seen this throttle window

# Rigid-hand anchor (the fix) + its parallel jitter measurement. The telemetry proved the
# thumb-index fingertip MIDPOINT is the noise source (~10-12 mm/frame jitter during a pinch,
# BOTH hands — the tips occlude each other when pressed together), which no downstream filter
# can clean. During a firm grab the hand is ~rigid, so we capture the pinch point in the WRIST
# joint's frame at grab and reconstruct it from the live (stable) wrist each frame: same
# location, far stabler source. grab_mode 0 = RIGID (this), 1 = FINGER (old midpoint) for A/B.
# _pinch_rigid_* measure the rigid anchor's jitter EVERY run so the log compares both sources
# regardless of the active mode.
var _grab_anchor_offset : Vector3 = Vector3.ZERO   # pinch point in wrist-local frame at grab
var _have_grab_anchor_offset : bool = false
var _pinch_rigid_prev : Vector3 = Vector3.ZERO
var _pinch_rigid_have : bool = false
var _pinch_rigid_max_mm : float = 0.0

# Glitch-gate (grab_mode 0 only). The telemetry showed the right hand throws frequent MULTI-
# frame bursts where the whole-hand pose teleports >4 m/s while the hand is ~stationary (24% of
# frames vs 0% on the left, motion identical) — beyond what the median-of-3 or the body speed-
# clamp clean up. So while holding we HOLD the last-good anchor through an implausible jump
# (> GLITCH_MAX_STEP_M in one render frame) for up to GLITCH_MAX_HOLD frames, then accept it (a
# genuine sustained move). Clean frames pass untouched → no added lag.
const GLITCH_MAX_STEP_M := 0.045   # ~4 m/s @ 90 Hz single-frame jump = implausible for a held hand
const GLITCH_MAX_HOLD := 6         # accept after this many held frames (real move, not a glitch)
var _gate_last_good : Vector3 = Vector3.ZERO
var _gate_have : bool = false
var _gate_hold_count : int = 0

# Sticky-release stability signal: a leaky-max of the active anchor's per-frame jump (mm). High =
# the hand is poorly observed (jumping / going out of view), so its pinch-open signal can't be
# trusted to mean "released" — hold the grab instead. Maintained EVERY frame (not gated by
# diagnostics — the release gate below depends on it).
const JITTER_DECAY := 0.88           # per physics frame (~60 Hz) → a spike decays over ~150 ms
const STABLE_JITTER_MM := 28.0       # recent jitter under this = hand observed well enough to act on a release
const RELEASE_FALLBACK_MSEC := 2500  # open+degraded this long still releases (can't get permanently stuck)
var _recent_jitter_mm : float = 0.0

# Compact joint-confidence tag: "VT" valid+tracked, "V-" valid only (estimated/low-confidence),
# "--" neither. The right-hand "can't grab" theory: index/thumb tips read "V-" under occlusion,
# and _get_pickup_value returns 0 in that case -> no pinch -> no grab, with nothing else logging it.
func _joint_flag_tag(hand_tracker: XRHandTracker, joint: int) -> String:
	var flags := int(hand_tracker.get_hand_joint_flags(joint))
	var v := (flags & XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID) != 0
	var t := (flags & XRHandTracker.HAND_JOINT_FLAG_POSITION_TRACKED) != 0
	return ("V" if v else "-") + ("T" if t else "-")

# Raw thumb-index fingertip midpoint in TRACKING space, or null if either tip isn't VALID.
func _raw_fingertip_mid(hand_tracker: XRHandTracker):
	if hand_tracker == null or not hand_tracker.get_has_tracking_data():
		return null
	var idx := XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP
	var thb := XRHandTracker.HAND_JOINT_THUMB_TIP
	var iv := (int(hand_tracker.get_hand_joint_flags(idx)) & XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID) != 0
	var tv := (int(hand_tracker.get_hand_joint_flags(thb)) & XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID) != 0
	if not (iv and tv):
		return null
	return (hand_tracker.get_hand_joint_transform(idx).origin + hand_tracker.get_hand_joint_transform(thb).origin) * 0.5

# Capture the pinch point in the wrist's local frame at grab (from the handler's CURRENT
# de-spiked anchor, so the rigid point coincides exactly with what the body grabbed → no jump).
func _capture_grab_anchor() -> void:
	_have_grab_anchor_offset = false
	var ht := _get_hand_tracker()
	if ht == null or not _joint_has_tracked_position(ht, XRHandTracker.HAND_JOINT_WRIST):
		return
	var anchor_tracking := _origin_xform().affine_inverse() * global_transform.origin
	var w := ht.get_hand_joint_transform(XRHandTracker.HAND_JOINT_WRIST)
	_grab_anchor_offset = w.affine_inverse() * anchor_tracking
	_have_grab_anchor_offset = true

# The RIGID anchor (TRACKING space): the captured pinch point carried by the live wrist
# transform. null if unavailable (no capture / wrist not tracked) → caller uses the fingertip.
func _rigid_anchor(hand_tracker: XRHandTracker):
	if not _have_grab_anchor_offset or hand_tracker == null:
		return null
	if not _joint_has_tracked_position(hand_tracker, XRHandTracker.HAND_JOINT_WRIST):
		return null
	return hand_tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_WRIST) * _grab_anchor_offset

# Hold the last-good anchor through an implausible single-frame jump (a tracking burst), for up
# to GLITCH_MAX_HOLD frames; then accept it (a real sustained move). Returns the anchor to use.
func _glitch_gate(p: Vector3) -> Vector3:
	if not _gate_have:
		_gate_last_good = p
		_gate_have = true
		_gate_hold_count = 0
		return p
	if (p - _gate_last_good).length() > GLITCH_MAX_STEP_M and _gate_hold_count < GLITCH_MAX_HOLD:
		_gate_hold_count += 1
		if _gate_hold_count == 1:
			_gdiag("GLITCH %s step_mm=%.1f (hold)" % [_side(), (p - _gate_last_good).length() * 1000.0])
		return _gate_last_good   # reject this frame: hold the last good anchor
	_gate_last_good = p
	_gate_hold_count = 0
	return p

# Sample the raw fingertip-midpoint AND the rigid anchor every physics frame, tracking each
# one's max per-frame jump this throttle window (a jitter measure that survives the 10 Hz log
# throttle). Both in TRACKING space. rigid is only present while holding (offset captured).
func _sample_mid_jitter() -> void:
	var ht := _get_hand_tracker()
	var jf := -1.0   # this-frame jump (mm) of the active anchor; -1 = no sample to add
	var mid = _raw_fingertip_mid(ht)
	if mid == null:
		_pinch_raw_mid_have = false
	else:
		if _pinch_raw_mid_have:
			var d := ((mid as Vector3) - _pinch_raw_mid_prev).length() * 1000.0
			_pinch_raw_mid_max_mm = maxf(_pinch_raw_mid_max_mm, d)
			jf = d
		_pinch_raw_mid_prev = mid
		_pinch_raw_mid_have = true
	var rigid = _rigid_anchor(ht)
	if rigid == null:
		_pinch_rigid_have = false
	else:
		if _pinch_rigid_have:
			var dr := ((rigid as Vector3) - _pinch_rigid_prev).length() * 1000.0
			_pinch_rigid_max_mm = maxf(_pinch_rigid_max_mm, dr)
			jf = dr   # while holding, the wrist-rigid anchor is the one we follow → use it for stability
		_pinch_rigid_prev = rigid
		_pinch_rigid_have = true
	# Leaky-max recent jitter (rises with any jump, decays over ~150 ms) — the sticky-release gate.
	if jf >= 0.0:
		_recent_jitter_mm = maxf(jf, _recent_jitter_mm * JITTER_DECAY)
	else:
		_recent_jitter_mm *= JITTER_DECAY

# "Is the hand observed well enough to TRUST a pinch-open as a real release?" Pinch joints must be
# tracked, no anchor glitch in progress, and recent jitter low. When false (hand jumping / out of
# view), the release logic holds the grab instead of dropping it on a degraded signal.
func _hand_well_observed() -> bool:
	var ht := _get_hand_tracker()
	if ht == null or not ht.get_has_tracking_data():
		return false
	if not (_joint_has_tracked_position(ht, XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP) and _joint_has_tracked_position(ht, XRHandTracker.HAND_JOINT_THUMB_TIP)):
		return false
	if _gate_hold_count > 0:
		return false
	return _recent_jitter_mm <= STABLE_JITTER_MM

# Emit one PINCH line. raw_pressed = the unmutated (pre-grace) threshold decision the latch
# made this frame; edge = "press"/"release"/"-". Resets the jitter accumulator after logging.
func _pinch_diag(pickup_value: float, threshold: float, raw_pressed: bool, edge: String) -> void:
	if not GRAB_DIAG:
		return
	var dist_mm := -1.0
	var idx_tag := "??"
	var thb_tag := "??"
	var wr_tag := "??"
	var ht := _get_hand_tracker()
	if ht != null and ht.get_has_tracking_data():
		var idx := XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP
		var thb := XRHandTracker.HAND_JOINT_THUMB_TIP
		idx_tag = _joint_flag_tag(ht, idx)
		thb_tag = _joint_flag_tag(ht, thb)
		wr_tag = _joint_flag_tag(ht, XRHandTracker.HAND_JOINT_WRIST)
		var idx_valid := (int(ht.get_hand_joint_flags(idx)) & XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID) != 0
		var thb_valid := (int(ht.get_hand_joint_flags(thb)) & XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID) != 0
		if idx_valid and thb_valid:
			dist_mm = ht.get_hand_joint_transform(idx).origin.distance_to(ht.get_hand_joint_transform(thb).origin) * 1000.0
	_gdiag("PINCH %s val=%.2f thr=%.2f press=%d held=%d dist_mm=%.1f idx=%s thb=%s wr=%s midjit_mm=%.1f rigidjit_mm=%.1f recjit_mm=%.1f obs=%d edge=%s" % [
		_side(), pickup_value, threshold, int(raw_pressed), int(picked_up_body != null),
		dist_mm, idx_tag, thb_tag, wr_tag, _pinch_raw_mid_max_mm, _pinch_rigid_max_mm, _recent_jitter_mm, int(_hand_well_observed()), edge])
	_pinch_raw_mid_max_mm = 0.0
	_pinch_rigid_max_mm = 0.0


# Reads a normalized pickup value from whichever input naming convention
# the active XR interface provides.
func _get_pickup_value(controller: XRController3D) -> float:
	# Hand tracking present → drive pickup SOLELY from thumb–index TIP distance. The
	# platform's pinch/grip/primary actions report a pinch from ~2 inches out, far
	# looser than wanted, so we ignore them on hand input and require the fingertips
	# to actually meet (~1 cm). This is the firm pinch the user asked for.
	var hand_tracker := _get_hand_tracker()
	if hand_tracker != null and hand_tracker.get_has_tracking_data():
		var index_joint := XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP
		var thumb_joint := XRHandTracker.HAND_JOINT_THUMB_TIP
		if _joint_has_tracked_position(hand_tracker, index_joint) and _joint_has_tracked_position(hand_tracker, thumb_joint):
			var index_tip := hand_tracker.get_hand_joint_transform(index_joint).origin
			var thumb_tip := hand_tracker.get_hand_joint_transform(thumb_joint).origin
			var pinch_distance := index_tip.distance_to(thumb_tip)
			return clampf((HAND_PINCH_RELEASE - pinch_distance) / (HAND_PINCH_RELEASE - HAND_PINCH_GRAB), 0.0, 1.0)
		return 0.0

	# Physical-controller fallback: OpenXR action-map + generic aliases.
	var pickup_value : float = 0.0
	var mapped_input: Variant = controller.get_input(pickup_action)
	if mapped_input != null:
		pickup_value = maxf(pickup_value, controller.get_float(pickup_action))
	pickup_value = maxf(pickup_value, controller.get_float("grip"))
	pickup_value = maxf(pickup_value, controller.get_float("grip_click"))
	pickup_value = maxf(pickup_value, controller.get_float("select_button"))
	pickup_value = maxf(pickup_value, controller.get_float("trigger"))
	pickup_value = maxf(pickup_value, controller.get_float("trigger_click"))
	pickup_value = maxf(pickup_value, controller.get_float("primary"))
	pickup_value = maxf(pickup_value, controller.get_float("primary_click"))
	pickup_value = maxf(pickup_value, controller.get_float("pinch"))
	pickup_value = maxf(pickup_value, controller.get_float("grasp"))
	return pickup_value


func _is_controller_profile_input(controller: XRController3D) -> bool:
	# On visionOS hand input, "primary" is reported as a scalar pinch value.
	# On physical controllers, "primary" is typically a 2D stick/touchpad axis.
	var primary_input: Variant = controller.get_input("primary")
	return primary_input is Vector2


func _has_confident_hand_release_signal(controller: XRController3D) -> bool:
	if controller == null:
		return false
	if not controller.get_has_tracking_data():
		return false

	# For true controller profiles, controller-level tracking is enough.
	if _is_controller_profile_input(controller):
		return true

	var hand_tracker := _get_hand_tracker()
	if hand_tracker == null or not hand_tracker.get_has_tracking_data():
		return false

	var index_joint := XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP
	var thumb_joint := XRHandTracker.HAND_JOINT_THUMB_TIP
	return _joint_has_tracked_position(hand_tracker, index_joint) and _joint_has_tracked_position(hand_tracker, thumb_joint)


func _get_hand_tracker() -> XRHandTracker:
	var controller : XRController3D = _get_parent_controller()
	if controller == null:
		return null

	var tracker_name := ""
	match controller.get_tracker_hand():
		XRPositionalTracker.TRACKER_HAND_LEFT:
			tracker_name = "/user/hand_tracker/left"
		XRPositionalTracker.TRACKER_HAND_RIGHT:
			tracker_name = "/user/hand_tracker/right"
		_:
			return null

	var tracker := XRServer.get_tracker(tracker_name)
	if tracker is XRHandTracker:
		return tracker
	return null


func _joint_has_tracked_position(hand_tracker: XRHandTracker, joint: int) -> bool:
	var flags := int(hand_tracker.get_hand_joint_flags(joint))
	var position_valid := (flags & XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID) != 0
	var position_tracked := (flags & XRHandTracker.HAND_JOINT_FLAG_POSITION_TRACKED) != 0
	return position_valid and position_tracked


func _update_anchor_from_hand_tracker() -> void:
	if not follow_fingertips:
		return

	var hand_tracker := _get_hand_tracker()
	if hand_tracker == null or not hand_tracker.get_has_tracking_data():
		return

	var index_joint := XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP
	var thumb_joint := XRHandTracker.HAND_JOINT_THUMB_TIP
	var has_index := _joint_has_tracked_position(hand_tracker, index_joint)
	var has_thumb := _joint_has_tracked_position(hand_tracker, thumb_joint)
	# Fingertip midpoint when visible (null if neither tip is tracked). Used as the anchor when
	# NOT holding (reach/proximity) and as the fallback while holding if the wrist is unavailable.
	var fingertip_mid = null
	var new_src := anchor_src
	if has_index and has_thumb:
		var index_tip := hand_tracker.get_hand_joint_transform(index_joint).origin
		var thumb_tip := hand_tracker.get_hand_joint_transform(thumb_joint).origin
		fingertip_mid = (index_tip + thumb_tip) * 0.5
		# Record the midpoint relative to each tip so we can hold it if one drops next frame.
		_mid_from_index = fingertip_mid - index_tip
		_mid_from_thumb = fingertip_mid - thumb_tip
		_have_mid_offsets = true
		new_src = "both"
	elif has_index:
		# Only the index is tracked: reconstruct the midpoint from the last offset instead of
		# snapping the anchor onto the bare fingertip (continuity across the flicker).
		var index_tip := hand_tracker.get_hand_joint_transform(index_joint).origin
		fingertip_mid = index_tip + (_mid_from_index if _have_mid_offsets else Vector3.ZERO)
		new_src = "index"
	elif has_thumb:
		var thumb_tip := hand_tracker.get_hand_joint_transform(thumb_joint).origin
		fingertip_mid = thumb_tip + (_mid_from_thumb if _have_mid_offsets else Vector3.ZERO)
		new_src = "thumb"

	# Pick the RAW anchor. While HOLDING: prefer the wrist-carried grab point — it keeps following
	# the hand even when BOTH fingertips drop out of sight (carry the object with whatever's
	# visible); fall back to the fingertip midpoint, then to holding the last anchor (never
	# snap/drop). When NOT holding: the fingertip midpoint, else hold. We never re-capture the grab
	# offset mid-hold, so the grab point auto-"snaps back" when the pinch returns into view.
	var raw_anchor := Vector3.ZERO
	if picked_up_body != null:
		var rigid = _rigid_anchor(hand_tracker)
		if rigid != null:
			raw_anchor = rigid
			if fingertip_mid == null:
				new_src = "wrist"
		elif fingertip_mid != null:
			raw_anchor = fingertip_mid
		else:
			return   # holding but nothing tracked — hold the last anchor, don't drop
	elif fingertip_mid != null:
		raw_anchor = fingertip_mid
	else:
		return   # not holding and no fingertips — nothing to track

	# Log anchor-source changes while holding.
	if new_src != anchor_src:
		if picked_up_body != null:
			_gdiag("ANCHORSRC %s %s->%s" % [_side(), anchor_src, new_src])
		anchor_src = new_src

	# De-spike: median-of-3 of the SELECTED anchor kills ISOLATED single-frame jumps with ~zero
	# lag on real motion. (Earlier bug: RIGID overrode the anchor AFTER this, bypassing it — so
	# the rigid anchor had no spike protection. Now we de-spike whichever source we use.)
	_anchor_hist.push_back(raw_anchor)
	if _anchor_hist.size() > 3:
		_anchor_hist.pop_front()
	var despiked := raw_anchor
	if _anchor_hist.size() == 3:
		despiked = Vector3(
			_median3(_anchor_hist[0].x, _anchor_hist[1].x, _anchor_hist[2].x),
			_median3(_anchor_hist[0].y, _anchor_hist[1].y, _anchor_hist[2].y),
			_median3(_anchor_hist[0].z, _anchor_hist[1].z, _anchor_hist[2].z))
		if picked_up_body != null:
			var rej := (raw_anchor - despiked).length() * 1000.0
			if rej > 15.0:
				_gdiag("DESPIKE %s rejected_mm=%.1f" % [_side(), rej])

	# Use the de-spiked anchor directly. (A glitch-gate that HELD the anchor through multi-frame
	# jumps throttled real fast drags/flicks to ~1/7 speed — the "takes a second to catch up" lag —
	# because sustained fast motion reads as one long "glitch". The median de-spike above + the
	# body's speed clamp reject true spikes WITHOUT throttling sustained motion.)
	var anchor_pos := despiked

	# target_position is TRACKING-space (XROrigin-relative); render it through the origin
	# so the grab anchor (and the held body riding it) stays on the real hand after a
	# world-handle drag shifts the origin. Reduces to identity at origin-home.
	var anchor_transform := global_transform
	anchor_transform.origin = _origin_xform() * anchor_pos
	global_transform = anchor_transform


# World transform of the XROrigin this handler hangs under (tracking→world).
func _origin_xform() -> Transform3D:
	var n: Node = get_parent()
	while n != null:
		if n is XROrigin3D:
			return (n as XROrigin3D).global_transform
		n = n.get_parent()
	return Transform3D.IDENTITY


# --- Held-body ROTATION source (fix: "object keeps rotating on every pinch"). The held body used
# to rotate with THIS handler's basis = the CONTROLLER (aim) pose, which is derived from the pinch
# and swings violently as the fingers close/open (telemetry: ~20 rad/s MEDIAN, clampA on 55% of
# held frames) → the object's orientation walked every grab/release. The PALM joint is a stable
# bone at the centre of the hand; its orientation doesn't move when you pinch. We drive the grab
# rotation from it. Rendered through the XROrigin (like the position anchor) so a world-handle drag
# can't twist held objects. ---

# World-space orientation basis of a hand joint, or null if the joint's orientation isn't VALID.
func _joint_world_basis(hand_tracker: XRHandTracker, joint: int):
	if hand_tracker == null or not hand_tracker.get_has_tracking_data():
		return null
	var flags := int(hand_tracker.get_hand_joint_flags(joint))
	if (flags & XRHandTracker.HAND_JOINT_FLAG_ORIENTATION_VALID) == 0:
		return null
	var jb := hand_tracker.get_hand_joint_transform(joint).basis.orthonormalized()
	return (_origin_xform().basis.orthonormalized() * jb).orthonormalized()

# Read by the held body each frame (PickupAbleBody3D._orient_basis) as its rotation source. Returns
# the requested hand JOINT's world orientation basis (WRIST or PALM, per grab_mode), holding the last
# good value PER JOINT through a one-frame flicker so the source never drops to null mid-hold (which
# would snap). null only if that joint's orientation has NEVER been valid (e.g. controller) → aim.
var _last_ori_basis : Dictionary = {}   # joint:int -> Basis (last good)
func joint_orientation_basis(joint: int):
	var b = _joint_world_basis(_get_hand_tracker(), joint)
	if b != null:
		_last_ori_basis[joint] = b
		return b
	return _last_ori_basis.get(joint, null)

# De-spiked THUMB-TIP world transform — the THUMB grab mode's anchor (object rigid to the thumb tip
# for both position and rotation, so index movement during a pinch/pull doesn't disturb it). The raw
# thumb-tip POSITION glitches at the grab instant (telemetry: 3/21 grabs spiked 0.35-0.40 m, baking a
# wrong grab point → a ~15-20 cm object jump), so we median-of-3 de-spike the position (same trick as
# the fingertip anchor), sampled every render frame, and hold the last good value through a dropout.
# Orientation passes through (the body's one-euro slerp + angular clamp smooth it). null until the
# thumb tip has been tracked at least once.
var _thumb_pos_hist : Array[Vector3] = []
var _thumb_anchor_xf : Variant = null
func _sample_thumb_anchor() -> void:
	var ht := _get_hand_tracker()
	if ht == null or not ht.get_has_tracking_data() or not _joint_has_tracked_position(ht, XRHandTracker.HAND_JOINT_THUMB_TIP):
		return   # keep the last good anchor (don't null) so a brief dropout holds rather than snaps
	var raw := _origin_xform() * ht.get_hand_joint_transform(XRHandTracker.HAND_JOINT_THUMB_TIP)
	_thumb_pos_hist.push_back(raw.origin)
	if _thumb_pos_hist.size() > 3:
		_thumb_pos_hist.pop_front()
	var pos := raw.origin
	if _thumb_pos_hist.size() == 3:
		pos = Vector3(
			_median3(_thumb_pos_hist[0].x, _thumb_pos_hist[1].x, _thumb_pos_hist[2].x),
			_median3(_thumb_pos_hist[0].y, _thumb_pos_hist[1].y, _thumb_pos_hist[2].y),
			_median3(_thumb_pos_hist[0].z, _thumb_pos_hist[1].z, _thumb_pos_hist[2].z))
	_thumb_anchor_xf = Transform3D(raw.basis, pos)

# Read by the held body (PickupAbleBody3D._thumb_xform) in THUMB mode for both pivot and rotation.
func thumb_anchor_xform():
	return _thumb_anchor_xf

# --- Orientation-source comparison telemetry (strip with GRAB_DIAG). Logs per-frame angular speed
# (rad/s, max-per-window so it survives the ~5 Hz throttle) of PALM vs WRIST vs the old AIM basis
# while holding, to confirm the palm is the calmest rotation source. ---
var _ori_prev_palm : Basis = Basis.IDENTITY
var _ori_prev_wrist : Basis = Basis.IDENTITY
var _ori_prev_aim : Basis = Basis.IDENTITY
var _ori_have_palm := false
var _ori_have_wrist := false
var _ori_have_aim := false
var _ori_palm_max := 0.0
var _ori_wrist_max := 0.0
var _ori_aim_max := 0.0
var _ori_log_last_ms := 0

func _ang_speed_basis(a: Basis, b: Basis, dt: float) -> float:
	if dt <= 0.0:
		return 0.0
	return a.get_rotation_quaternion().angle_to(b.get_rotation_quaternion()) / dt

func _sample_orient_compare(delta: float) -> void:
	var ht := _get_hand_tracker()
	var palm = _joint_world_basis(ht, XRHandTracker.HAND_JOINT_PALM)
	var wrist = _joint_world_basis(ht, XRHandTracker.HAND_JOINT_WRIST)
	var aim := global_transform.basis.orthonormalized()
	if palm != null:
		var pb : Basis = palm
		if _ori_have_palm:
			_ori_palm_max = maxf(_ori_palm_max, _ang_speed_basis(_ori_prev_palm, pb, delta))
		_ori_prev_palm = pb
		_ori_have_palm = true
	if wrist != null:
		var wb : Basis = wrist
		if _ori_have_wrist:
			_ori_wrist_max = maxf(_ori_wrist_max, _ang_speed_basis(_ori_prev_wrist, wb, delta))
		_ori_prev_wrist = wb
		_ori_have_wrist = true
	if _ori_have_aim:
		_ori_aim_max = maxf(_ori_aim_max, _ang_speed_basis(_ori_prev_aim, aim, delta))
	_ori_prev_aim = aim
	_ori_have_aim = true
	var now := Time.get_ticks_msec()
	if now - _ori_log_last_ms >= 200:
		_gdiag("ORICMP %s palm_max=%.1f wrist_max=%.1f aim_max=%.1f palm_ok=%d" % [
			_side(), _ori_palm_max, _ori_wrist_max, _ori_aim_max, int(palm != null)])
		_ori_palm_max = 0.0
		_ori_wrist_max = 0.0
		_ori_aim_max = 0.0
		_ori_log_last_ms = now


# Update our detection range.
func _update_detect_range() -> void:
	var shape : SphereShape3D = $CollisionShape3D.shape
	if shape:
		shape.radius = detect_range


# Update our closest body.
func _update_closest_body() -> void:
	# Do not do this when we're in the editor.
	if Engine.is_editor_hint():
		return

	# Do not check this if we've picked something up.
	if picked_up_body:
		if closest_body:
			closest_body.remove_is_closest(self)
			closest_body = null

		return

	# Find the body that is currently the closest.
	var new_closest_body : PickupAbleBody3D
	var closest_distance : float = 1000000.0
	_blocked_held = null   # nearest in-range body we can't grab because another hand holds it

	for body in get_overlapping_bodies():
		if body is PickupAbleBody3D:
			if not body.is_picked_up():
				var distance_squared = (body.global_position - global_position).length_squared()
				if distance_squared < closest_distance:
					new_closest_body = body
					closest_distance = distance_squared
			elif body.picked_up_by != self:
				_blocked_held = body   # held by the OTHER hand — diagnostic for "can't grab" reports

	# Unchanged? Just exit
	if closest_body == new_closest_body:
		return

	# We had a closest body
	if closest_body:
		closest_body.remove_is_closest(self)

	closest_body = new_closest_body
	if closest_body:
		closest_body.add_is_closest(self)


# Get our controller that we are a child of
func _get_parent_controller() -> XRController3D:
	var parent : Node = get_parent()
	while parent:
		if parent is XRController3D:
			return parent

		parent = parent.get_parent()

	return null


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	_update_detect_range()
	_update_closest_body()
	# One-time pinch config dump so grab_diag is self-describing (thresholds + pinch-distance ramp).
	_gdiag("PINCHCFG %s press_thr=%.2f rel_thr=%.2f quick_rel=%.3f pinch_grab=%.3f pinch_rel=%.3f detect=%.3f" % [
		_side(), pickup_press_threshold, pickup_release_threshold, quick_release_value,
		HAND_PINCH_GRAB, HAND_PINCH_RELEASE, detect_range])


# Anchor re-pin MUST run at render rate (90 Hz), NOT physics rate (60 Hz). The held
# body rides this handler 1:1 via reparenting, so the handler's pose is the rendered
# pose. Re-pinning the origin to the fingertip in _physics_process (60 Hz) injected a
# periodic position correction sampled by the 90 Hz display = a 3:2 beat saw-tooth
# (grab_trace.txt: baseline ~1.4 mm/frame, re-pin frames ~5.4 mm, every ~4 frames).
# Running the re-pin here in _process flattens it: the correction now lands on every
# rendered frame instead of fighting the display cadence. Pickup/release latch +
# closest-body detection stay in _physics_process (logic, not visual smoothness).
func _process(delta: float) -> void:
	_update_anchor_from_hand_tracker()
	_sample_thumb_anchor()   # keep the de-spiked thumb-tip anchor warm (THUMB grab mode reads it)
	# Compare candidate rotation sources (palm/wrist/aim) while holding — telemetry for the
	# "object keeps rotating on every pinch" fix. Strip with GRAB_DIAG.
	if GRAB_DIAG and picked_up_body != null:
		_sample_orient_compare(delta)


# Called every physics frame
func _physics_process(delta) -> void:
	# As we move our hands we need to check if the closest body
	# has changed.
	_update_closest_body()

	# Check if our pickup action is true
	var pickup_pressed = false
	var pickup_value : float = 0.0
	var threshold : float = pickup_press_threshold
	var controller : XRController3D = _get_parent_controller()
	if controller:
		# While OpenXR can return this as a boolean, there is a lot of
		# difference in handling thresholds between platforms.
		# So we implement our own logic here.
		pickup_value = _get_pickup_value(controller)
		threshold = pickup_release_threshold if was_pickup_pressed else pickup_press_threshold
		pickup_pressed = pickup_value > threshold

	# Maintain the recent-jitter stability signal EVERY frame (the sticky-release gate depends on
	# it — this is production logic, not diagnostics).
	if controller:
		_sample_mid_jitter()

	# Pinch telemetry: emit a throttled PINCH line (~10 Hz) and ALWAYS on a raw press/release edge,
	# so a missed-grab attempt can't slip between samples. raw_pressed is the unmutated threshold
	# decision (before the grace/hold latch logic below can force pickup_pressed back to true).
	if GRAB_DIAG and controller:
		var raw_pressed := pickup_value > threshold
		var edge := "-"
		if raw_pressed and not _pinch_prev_raw_pressed:
			edge = "press"
		elif not raw_pressed and _pinch_prev_raw_pressed:
			edge = "release"
		var now_ms := Time.get_ticks_msec()
		if edge != "-" or now_ms - _pinch_diag_last_ms >= PINCH_DIAG_PERIOD_MS:
			_pinch_diag(pickup_value, threshold, raw_pressed, edge)
			_pinch_diag_last_ms = now_ms
		_pinch_prev_raw_pressed = raw_pressed

	# Do we need to let go?
	if picked_up_body:
		if pickup_pressed:
			release_started_msec = 0
			picked_up_body.follow_suspended = false
		else:
			# Freeze-on-open: the instant the pinch opens, stop a freeze-on-release body (plate/wall)
			# from following the hand out — otherwise the opening thumb drags the placed object ("it
			# stays resting on my thumb"). The latch below still HOLDS the grab through the grace
			# window (no false drop); the body just holds its pose, so a real release leaves it where
			# you opened and a re-pinch resumes from there. Throwable bodies ignore this (they need
			# the release motion for throw velocity). See PickupAbleBody3D._process.
			picked_up_body.follow_suspended = true
			# STICKY RELEASE: never drop the grab on degraded/lost tracking. Release only on a
			# CONFIDENT open — fingers clearly open, SUSTAINED, AND the hand currently well-observed
			# (pinch joints tracked, low recent jitter, no glitch in progress). If the hand is poorly
			# observed (jumping / out of view), HOLD: the wrist anchor keeps carrying the object and
			# the grab point is retained, so the pinch "snaps back" when it returns. A long fallback
			# still guarantees a release can't get permanently stuck. Any frame back above the
			# release threshold reset release_started_msec above, so an oscillating burst never
			# accumulates toward a release.
			var well_observed := (not hold_while_hand_tracking_uncertain) or _hand_well_observed()
			var now_msec := Time.get_ticks_msec()
			# Only accrue the release timer while the hand is WELL-OBSERVED and open. If tracking is
			# degraded (pinch joints untracked / hand jumping out of view), RESET it so a multi-frame
			# disappearance can't carry an elapsed timer. That was the false-release bug: the
			# index+thumb tips vanished for a few frames while the user kept pinching, the timer
			# accrued past release_grace_msec during the blackout, and the instant tracking returned
			# (often with the estimate still splayed, val≈0) an immediate "(grace)" release fired.
			# Now a real release needs a FRESH sustained open in clear view; the wrist anchor carries
			# the object through the dropout.
			if not well_observed:
				release_started_msec = 0
			elif release_started_msec == 0:
				release_started_msec = now_msec
			var held_open_ms := (now_msec - release_started_msec) if release_started_msec != 0 else 0
			var quick := pickup_value <= quick_release_value and held_open_ms >= quick_release_debounce_msec
			var graced := held_open_ms >= release_grace_msec
			var fallback := held_open_ms >= RELEASE_FALLBACK_MSEC
			if (well_observed and (quick or graced)) or fallback:
				var how := ("fallback" if (fallback and not (well_observed and (quick or graced))) else ("quick" if quick else "grace"))
				_gdiag("RELEASE %s obj=%s#%d (%s)" % [_side(), picked_up_body.name, picked_up_body.get_instance_id(), how])
				picked_up_body.let_go()
				picked_up_body = null
				_have_grab_anchor_offset = false
				_gate_have = false
				release_started_msec = 0
				was_pickup_pressed = false
				return
			else:
				# Hold the latch (sticky / debounce / grace) — the object stays attached and keeps
				# wrist-following, so this absorbs a finger-splay with no detach/blip. Log every
				# wide-open hold (obs distinguishes a wrist-instability hold from a finger-splay
				# hold) so we can measure how long the splays actually persist.
				pickup_pressed = true
				if pickup_value <= quick_release_value:
					_gdiag("STICKYHOLD %s val=%.2f open_ms=%d obs=%d jit=%.1f" % [_side(), pickup_value, held_open_ms, int(well_observed), _recent_jitter_mm])
	else:
		release_started_msec = 0

	# Do we need to pick something up
	if not picked_up_body and not was_pickup_pressed and pickup_pressed and closest_body:
		picked_up_body = closest_body
		picked_up_body.pick_up(self)
		_capture_grab_anchor()
		_gdiag("PICKUP %s obj=%s#%d at=%s rigid=%d" % [_side(), picked_up_body.name, picked_up_body.get_instance_id(), str(picked_up_body.global_position), int(_have_grab_anchor_offset)])
		_blocked_logged = false
	# Diagnostic: pinching hard, nothing grabbed, but a held body is right here = the
	# "I'm pinching but can't grab it" case (object held by the other hand).
	elif pickup_pressed and not picked_up_body and closest_body == null and _blocked_held != null and not _blocked_logged:
		_gdiag("GRAB_BLOCKED %s reason=held_by_other obj=%s#%d holder=%s" % [
			_side(), _blocked_held.name, _blocked_held.get_instance_id(),
			str(_blocked_held.picked_up_by.get_parent().tracker) if _blocked_held.picked_up_by != null and _blocked_held.picked_up_by.get_parent() != null else "?"])
		_blocked_logged = true

	# Remember our state for the next frame
	was_pickup_pressed = pickup_pressed
