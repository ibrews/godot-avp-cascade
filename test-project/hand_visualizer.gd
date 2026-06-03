class_name HandVisualizer3D
extends Node3D

# OPTIONAL DEBUG TOOL — not wired into the shipped scene. Renders a small glowing sphere at every
# XRHandTracker joint so you can see the raw tracked skeleton (handy when debugging hand-tracking
# alignment, or the VALID vs TRACKED joint flags). To use it: add a HandVisualizer3D as a child of
# XROrigin3D and set tracker_name to "/user/hand_tracker/left" or "/user/hand_tracker/right" (joint
# transforms are in XROrigin3D's local frame). The game itself uses HandMeshDriver3D (the GLTF mesh).
@export var tracker_name: String

var _joints: Array[MeshInstance3D] = []

func _ready() -> void:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.85, 0.95, 1.0, 0.75)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = Color(0.55, 0.80, 1.0)
	mat.emission_energy_multiplier = 1.8

	var sphere := SphereMesh.new()
	sphere.radius = 0.010
	sphere.height = 0.020
	sphere.material = mat

	for _i in range(XRHandTracker.HAND_JOINT_MAX):
		var mi := MeshInstance3D.new()
		mi.mesh = sphere
		mi.visible = false
		add_child(mi)
		_joints.append(mi)

func _process(_delta: float) -> void:
	var tracker := XRServer.get_tracker(tracker_name)
	if not tracker is XRHandTracker:
		_hide_all()
		return
	var ht := tracker as XRHandTracker
	if not ht.get_has_tracking_data():
		_hide_all()
		return
	for i in range(XRHandTracker.HAND_JOINT_MAX):
		var flags := int(ht.get_hand_joint_flags(i))
		var ok := (flags & XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID) != 0 \
				and (flags & XRHandTracker.HAND_JOINT_FLAG_POSITION_TRACKED) != 0
		_joints[i].visible = ok
		if ok:
			_joints[i].transform = ht.get_hand_joint_transform(i)

func _hide_all() -> void:
	for j in _joints:
		j.visible = false
