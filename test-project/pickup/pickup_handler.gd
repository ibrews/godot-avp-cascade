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
	if not has_index and not has_thumb:
		return

	var target_position := Vector3.ZERO
	var new_src := "none"
	if has_index and has_thumb:
		var index_tip := hand_tracker.get_hand_joint_transform(index_joint).origin
		var thumb_tip := hand_tracker.get_hand_joint_transform(thumb_joint).origin
		target_position = (index_tip + thumb_tip) * 0.5
		# Record the midpoint relative to each tip so we can hold it if one drops next frame.
		_mid_from_index = target_position - index_tip
		_mid_from_thumb = target_position - thumb_tip
		_have_mid_offsets = true
		new_src = "both"
	elif has_index:
		# Only the index is tracked: reconstruct the midpoint from the last offset instead of
		# snapping the anchor onto the bare fingertip (continuity across the flicker).
		var index_tip := hand_tracker.get_hand_joint_transform(index_joint).origin
		target_position = index_tip + (_mid_from_index if _have_mid_offsets else Vector3.ZERO)
		new_src = "index"
	else:
		var thumb_tip := hand_tracker.get_hand_joint_transform(thumb_joint).origin
		target_position = thumb_tip + (_mid_from_thumb if _have_mid_offsets else Vector3.ZERO)
		new_src = "thumb"
	# Log anchor-source changes while holding — catches the tracking flicker that used to lurch
	# the grab point (both → index/thumb → both).
	if new_src != anchor_src:
		if picked_up_body != null:
			_gdiag("ANCHORSRC %s %s->%s" % [_side(), anchor_src, new_src])
		anchor_src = new_src

	# De-spike: median-of-3 of the raw anchor kills isolated single-frame fingertip jumps
	# (the telemetry's "anchor teleports 8 cm at 1 m/s" spikes) with ~zero lag on real motion.
	_anchor_hist.push_back(target_position)
	if _anchor_hist.size() > 3:
		_anchor_hist.pop_front()
	var despiked := target_position
	if _anchor_hist.size() == 3:
		despiked = Vector3(
			_median3(_anchor_hist[0].x, _anchor_hist[1].x, _anchor_hist[2].x),
			_median3(_anchor_hist[0].y, _anchor_hist[1].y, _anchor_hist[2].y),
			_median3(_anchor_hist[0].z, _anchor_hist[1].z, _anchor_hist[2].z))
		if picked_up_body != null:
			var rej := (target_position - despiked).length() * 1000.0
			if rej > 15.0:
				_gdiag("DESPIKE %s rejected_mm=%.1f" % [_side(), rej])

	# Choose the anchor POSITION per the live A/B grab mode (cycled by the in-world debug
	# button). WRIST mode is the key experiment: anchoring on the wrist joint instead of the
	# fingertips dodges the multi-frame occlusion bursts the telemetry showed when a held plate
	# blocks the fingers from the cameras. SMOOTH/RAW use the raw fingertip (body filter differs).
	var anchor_pos := despiked
	match PickupAbleBody3D.grab_mode:
		1:  # WRIST
			if _joint_has_tracked_position(hand_tracker, XRHandTracker.HAND_JOINT_WRIST):
				anchor_pos = hand_tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_WRIST).origin
		2, 3:  # SMOOTH / RAW
			anchor_pos = target_position

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


# Anchor re-pin MUST run at render rate (90 Hz), NOT physics rate (60 Hz). The held
# body rides this handler 1:1 via reparenting, so the handler's pose is the rendered
# pose. Re-pinning the origin to the fingertip in _physics_process (60 Hz) injected a
# periodic position correction sampled by the 90 Hz display = a 3:2 beat saw-tooth
# (grab_trace.txt: baseline ~1.4 mm/frame, re-pin frames ~5.4 mm, every ~4 frames).
# Running the re-pin here in _process flattens it: the correction now lands on every
# rendered frame instead of fighting the display cadence. Pickup/release latch +
# closest-body detection stay in _physics_process (logic, not visual smoothness).
func _process(_delta: float) -> void:
	_update_anchor_from_hand_tracker()


# Called every physics frame
func _physics_process(delta) -> void:
	# As we move our hands we need to check if the closest body
	# has changed.
	_update_closest_body()

	# Check if our pickup action is true
	var pickup_pressed = false
	var pickup_value : float = 0.0
	var controller : XRController3D = _get_parent_controller()
	if controller:
		# While OpenXR can return this as a boolean, there is a lot of
		# difference in handling thresholds between platforms.
		# So we implement our own logic here.
		pickup_value = _get_pickup_value(controller)
		var threshold : float = pickup_release_threshold if was_pickup_pressed else pickup_press_threshold
		pickup_pressed = pickup_value > threshold

	# Do we need to let go?
	if picked_up_body:
		if pickup_pressed:
			release_started_msec = 0
		else:
			var can_evaluate_release := true
			if hold_while_hand_tracking_uncertain and controller:
				can_evaluate_release = _has_confident_hand_release_signal(controller)

			if not can_evaluate_release:
				# Keep latch engaged until we have enough confidence to evaluate release intent.
				release_started_msec = 0
				pickup_pressed = true
			else:
				if pickup_value <= quick_release_value:
					_gdiag("RELEASE %s obj=%s#%d (quick)" % [_side(), picked_up_body.name, picked_up_body.get_instance_id()])
					picked_up_body.let_go()
					picked_up_body = null
					release_started_msec = 0
					was_pickup_pressed = false
					return

				var now_msec := Time.get_ticks_msec()
				if release_started_msec == 0:
					release_started_msec = now_msec

				if now_msec - release_started_msec >= release_grace_msec:
					_gdiag("RELEASE %s obj=%s#%d (grace)" % [_side(), picked_up_body.name, picked_up_body.get_instance_id()])
					picked_up_body.let_go()
					picked_up_body = null
					release_started_msec = 0
				else:
					# Keep latch engaged while within grace window.
					pickup_pressed = true
	else:
		release_started_msec = 0

	# Do we need to pick something up
	if not picked_up_body and not was_pickup_pressed and pickup_pressed and closest_body:
		picked_up_body = closest_body
		picked_up_body.pick_up(self)
		_gdiag("PICKUP %s obj=%s#%d at=%s" % [_side(), picked_up_body.name, picked_up_body.get_instance_id(), str(picked_up_body.global_position)])
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
