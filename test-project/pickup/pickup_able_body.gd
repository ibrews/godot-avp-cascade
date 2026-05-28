extends RigidBody3D
class_name PickupAbleBody3D

# Hand-tracking pickup body — based on Marshall Nowak (Nocxr)'s PickupAbleBody3D
# from the visionosxr_hand_tracking reference project.
# Added: throw velocity from recent position history on release.

var highlight_material : Material = load("res://shaders/highlight_material.tres")
var picked_up_by : Area3D
var closest_areas : Array

var original_parent : Node3D
var tween : Tween

# Position history for throw velocity: Array of {pos: Vector3, t: int}
var _pos_history : Array = []
const _POS_HISTORY_MAX := 6

const PICKUP_SNAP_DURATION := 0.03


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


# Track global position while held so we can throw on release.
func _physics_process(_delta: float) -> void:
	if not is_picked_up():
		return
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
	freeze = true
	_pos_history.clear()

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

	# Compute throw velocity from recent hand movement.
	var throw_velocity := Vector3.ZERO
	if _pos_history.size() >= 2:
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
	freeze = false
	linear_velocity = throw_velocity


# Update our highlight to show that we can be picked up
func _update_highlight() -> void:
	if not picked_up_by and not closest_areas.is_empty():
		for child in get_children():
			if child is MeshInstance3D:
				(child as MeshInstance3D).material_overlay = highlight_material
	else:
		for child in get_children():
			if child is MeshInstance3D:
				(child as MeshInstance3D).material_overlay = null
