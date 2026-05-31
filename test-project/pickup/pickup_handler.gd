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
	if has_index and has_thumb:
		var index_tip := hand_tracker.get_hand_joint_transform(index_joint).origin
		var thumb_tip := hand_tracker.get_hand_joint_transform(thumb_joint).origin
		target_position = (index_tip + thumb_tip) * 0.5
	elif has_index:
		target_position = hand_tracker.get_hand_joint_transform(index_joint).origin
	else:
		target_position = hand_tracker.get_hand_joint_transform(thumb_joint).origin

	# Raw fingertip anchor at render rate. The still-hold grab_trace.txt proved this is
	# already clean (<0.3 mm/frame jitter); a one-euro filter here only added rubber-band
	# lag against natural hand sway, so it was reverted. Fix A (this running in _process,
	# not _physics_process) is what removed the 60/90 Hz beat — that's the real fix.
	# target_position is TRACKING-space (XROrigin-relative); render it through the origin
	# so the grab anchor (and the held body riding it) stays on the real hand after a
	# world-handle drag shifts the origin. Reduces to identity at origin-home.
	var anchor_transform := global_transform
	anchor_transform.origin = _origin_xform() * target_position
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

	for body in get_overlapping_bodies():
		if body is PickupAbleBody3D and not body.is_picked_up():
			var distance_squared = (body.global_position - global_position).length_squared()
			if distance_squared < closest_distance:
				new_closest_body = body
				closest_distance = distance_squared

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
					picked_up_body.let_go()
					picked_up_body = null
					release_started_msec = 0
					was_pickup_pressed = false
					return

				var now_msec := Time.get_ticks_msec()
				if release_started_msec == 0:
					release_started_msec = now_msec

				if now_msec - release_started_msec >= release_grace_msec:
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

	# Remember our state for the next frame
	was_pickup_pressed = pickup_pressed
