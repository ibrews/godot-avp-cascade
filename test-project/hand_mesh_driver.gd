class_name HandMeshDriver3D
extends Node3D

# Drives the XR Tools low-poly hand GLTF from XRHandTracker joints via
# set_bone_global_pose_override().
#
# The Clancey fork pre-rotates each joint basis into Godot's humanoid-rig
# convention, which doesn't match how the XR Tools GLTF is rigged. The
# correcting transform (found via an A-F colour sweep on device) is a local
# Y +90° rotation applied in each bone's own frame. See git history for the
# sweep harness if a different mesh ever needs re-tuning.
#
# Joint indices are raw OpenXR values (0-25) — stable across Godot versions
# that rename enum members (PHALANX_* vs PROXIMAL_*, PINKY_* vs LITTLE_*).

@export var tracker_name: String
@export var is_left: bool = true

# Bone-frame correction: local Y +90°. Right-multiplied onto each joint basis.
const BONE_CORRECTION := Basis(Vector3(0, 1, 0), PI / 2.0)

var _skeleton: Skeleton3D
var _mesh_root: Node3D
var _bone_to_joint: Dictionary = {}  # bone_idx → joint_idx (0-25)

func _ready() -> void:
	var path := "res://hands/hand_l.gltf" if is_left else "res://hands/hand_r.gltf"
	var scene := load(path) as PackedScene
	if scene == null:
		push_error("HandMeshDriver: cannot load %s" % path)
		return

	_mesh_root = scene.instantiate()
	add_child(_mesh_root)

	var white := StandardMaterial3D.new()
	white.albedo_color = Color.WHITE
	white.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	_apply_material(_mesh_root, white)

	_skeleton = _find_skeleton(_mesh_root)
	if _skeleton == null:
		push_error("HandMeshDriver: Skeleton3D not found in %s" % path)
		return

	_build_bone_map()
	print("[HandMesh] %s: mapped %d / 26 bones" % [tracker_name, _bone_to_joint.size()])

func _process(_delta: float) -> void:
	if _skeleton == null:
		return
	var tracker := XRServer.get_tracker(tracker_name)
	if not tracker is XRHandTracker:
		_mesh_root.visible = false
		return
	var ht := tracker as XRHandTracker
	if not ht.get_has_tracking_data():
		_mesh_root.visible = false
		return
	_mesh_root.visible = true

	var world_to_skel := _skeleton.global_transform.affine_inverse()

	for bone_idx: int in _bone_to_joint:
		var joint_idx: int = _bone_to_joint[bone_idx]
		var flags := int(ht.get_hand_joint_flags(joint_idx))
		if not (flags & 8):  # HAND_JOINT_FLAG_POSITION_TRACKED = 8
			continue
		var t := world_to_skel * ht.get_hand_joint_transform(joint_idx)
		t.basis = t.basis * BONE_CORRECTION  # bone-frame correction
		_skeleton.set_bone_global_pose_override(bone_idx, t, 1.0, false)

func _build_bone_map() -> void:
	var sfx := "L" if is_left else "R"
	var name_to_joint := {
		"Wrist_" + sfx:               1,
		"Palm_" + sfx:                0,
		"Thumb_Metacarpal_" + sfx:    2,
		"Thumb_Proximal_" + sfx:      3,
		"Thumb_Distal_" + sfx:        4,
		"Thumb_Tip_" + sfx:           5,
		"Index_Metacarpal_" + sfx:    6,
		"Index_Proximal_" + sfx:      7,
		"Index_Intermediate_" + sfx:  8,
		"Index_Distal_" + sfx:        9,
		"Index_Tip_" + sfx:           10,
		"Middle_Metacarpal_" + sfx:   11,
		"Middle_Proximal_" + sfx:     12,
		"Middle_Intermediate_" + sfx: 13,
		"Middle_Distal_" + sfx:       14,
		"Middle_Tip_" + sfx:          15,
		"Ring_Metacarpal_" + sfx:     16,
		"Ring_Proximal_" + sfx:       17,
		"Ring_Intermediate_" + sfx:   18,
		"Ring_Distal_" + sfx:         19,
		"Ring_Tip_" + sfx:            20,
		"Little_Metacarpal_" + sfx:   21,
		"Little_Proximal_" + sfx:     22,
		"Little_Intermediate_" + sfx: 23,
		"Little_Distal_" + sfx:       24,
		"Little_Tip_" + sfx:          25,
	}
	for bone_idx in range(_skeleton.get_bone_count()):
		var name: String = _skeleton.get_bone_name(bone_idx)
		if name_to_joint.has(name):
			_bone_to_joint[bone_idx] = name_to_joint[name]

func _apply_material(node: Node, mat: Material) -> void:
	if node is MeshInstance3D:
		(node as MeshInstance3D).material_override = mat
	for child in node.get_children():
		_apply_material(child, mat)

static func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node as Skeleton3D
	for child in node.get_children():
		var found := _find_skeleton(child)
		if found:
			return found
	return null
