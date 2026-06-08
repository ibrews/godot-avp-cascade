extends Node

# Simulator input bridge — localhost UDP.
#
# WHY UDP (not keyboard): in the visionOS SIMULATOR there is no working in-app keyboard
# channel for a custom-Metal-immersive app. GCKeyboard never receives the sim's forwarded
# Mac keys (verified: keyChangedHandler never fires), and the immersive CompositorServices
# scene has no app-controlled UIResponder. But the sim app SHARES the host loopback, so a
# Mac-side sender can push commands over UDP to a listener here. Active only in the sim.
#
# Protocol (ASCII packets to 127.0.0.1:SIM_INPUT_PORT):
#   "C1" / "C0"  grab down / up   (grab = view-center raycast; also pokes panel buttons)
#   "B"          reset sandbox    (ring-pinch)
#   "V"          cycle hands      (middle-pinch)
#   "N"          toggle sky       (pinky-pinch)
# See KB godot-avp-simulator-input.md.

const SIM_INPUT_PORT := 9999

# Live SimHands-bridge calibration (SimControlPanel dev tool). "K<key><float>" packets tune
# hand placement/scale while you watch the sim; we persist them to this cfg and the native
# bridge (simhands_bridge.mm) re-reads it ~9 Hz. "KR" resets (deletes the file → bridge
# falls back to its compiled first-light defaults). See _handle_calibration.
const _CALIB_PATH := "user://simhands_calibration.cfg"
const _CALIB_KEYS := {
	"S": "hand_scale",  # SIMHANDS_HAND_KNUCKLE_M — self-normalized hand size
	"P": "plane",       # SIMHANDS_PLANE_M        — x/y travel across the image plane
	"D": "depth",       # SIMHANDS_DEPTH_M        — wrist distance in front of the origin
	"Y": "y_offset",    # SIMHANDS_Y_OFFSET_M     — head-relative height (pre floor offset)
	"Z": "z_gain",      # SIMHANDS_Z_SHAPE_GAIN   — finger-curl depth from MediaPipe z
}

var _main: Node3D
var _handler: PickupHandler3D
var _sim_active := false
var _udp := PacketPeerUDP.new()
var _c_held := false

# Rigid-to-head grab: once a body is actually held, the handler rides a FIXED pose relative to the
# camera (captured at the grab instant) instead of the view-centre raycast hit. That gives the held
# object a steady distance and makes it move AND rotate with the head, like a child of the camera —
# and (with C as a toggle, mouse free) it follows the view while you Option-drag look. The raycast is
# kept ONLY for the initial reach/pick (the handler must sit on the target to grab it).
var _was_holding := false
var _grab_cam_offset := Transform3D.IDENTITY

func _ready() -> void:
	_main = get_parent()
	# Simulator-only (bulletproof: these env vars exist only in the sim process, never device).
	_sim_active = OS.has_environment("SIMULATOR_DEVICE_NAME") \
		or OS.has_environment("SIMULATOR_UDID") \
		or OS.has_environment("SIMULATOR_ROOT")
	if not _sim_active:
		return
	_handler = _main._hand_handlers.get("right_hand") as PickupHandler3D
	var err := _udp.bind(SIM_INPUT_PORT, "127.0.0.1")
	_diag("SimInput UDP listening on 127.0.0.1:%d (bind err=%d)" % [SIM_INPUT_PORT, err])

# World point at the centre of the camera view; raycast vs solid+grab-only (mask 3) so it
# hits cubes and the control panel, else 1.5 m straight ahead.
func _cursor_world() -> Vector3:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return Vector3.ZERO
	var from := cam.global_position
	var fwd := cam.global_transform.basis.z * -1.5
	var q := PhysicsRayQueryParameters3D.create(from, from + fwd)
	q.collision_mask = 3  # LAYER_SOLID | LAYER_GRAB_ONLY
	var hit := _main.get_world_3d().direct_space_state.intersect_ray(q)
	return hit["position"] if hit else from + fwd

func _process(_delta: float) -> void:
	if not _sim_active:
		return

	# Drain any queued UDP commands.
	while _udp.get_available_packet_count() > 0:
		var cmd := _udp.get_packet().get_string_from_ascii().strip_edges()
		if cmd != "":
			_handle_cmd(cmd)

	if not is_instance_valid(_handler):
		return

	if not _c_held:
		_handler.sim_pickup_override = 0.0
		_main.sim_cursor_world = null
		_was_holding = false
		return

	_handler.sim_pickup_override = 1.0
	var cam := get_viewport().get_camera_3d()

	# Once a body is actually held, ride a fixed camera-relative pose (rigid-to-head): constant
	# distance, follows head translation AND rotation. Pre-grab we still drive the handler to the
	# view-centre raycast hit so it can reach and grab the target under the cursor.
	if _handler.picked_up_body != null and is_instance_valid(cam):
		if not _was_holding:
			# Capture the handler's pose relative to the camera at the instant of grab, so the
			# object stays exactly where it was grabbed and then rides the head from there.
			_grab_cam_offset = cam.global_transform.affine_inverse() * _handler.global_transform
		_handler.global_transform = cam.global_transform * _grab_cam_offset
		_was_holding = true
	else:
		_handler.global_position = _cursor_world()
		_was_holding = false

	# Feed the poke-button proximity test (_index_tip_world returns sim_cursor_world for the right
	# hand): the "hand" is wherever the handler now sits (raycast hit pre-grab, held point after).
	_main.sim_cursor_world = _handler.global_position

func _handle_cmd(cmd: String) -> void:
	_diag("rx:" + cmd)
	# Calibration verbs ("K<key><float>" or "KR") tune the native SimHands bridge LIVE; they
	# never touch the device path (this whole node is sim-gated). See _handle_calibration.
	if cmd.length() >= 1 and cmd[0] == "K":
		_handle_calibration(cmd)
		return
	match cmd:
		"C1":
			_c_held = true
		"C0":
			_c_held = false
		"B":
			if _main._gesture_cooldown <= 0.0 and _main._gestures_enabled:
				_main.call("_reset_sandbox")
				_main._gesture_cooldown = 1.0
		"V":
			if _main._gesture_cooldown <= 0.0 and _main._gestures_enabled:
				_main.call("_cycle_hands_mode")
				_main._gesture_cooldown = 0.8
		"N":
			if _main._gesture_cooldown <= 0.0 and _main._gestures_enabled:
				_main.call("_toggle_immersion")
				_main._gesture_cooldown = 0.8

# Parse a "K<key><float>" calibration packet and persist it to user://simhands_calibration.cfg
# (one key per packet; the file accumulates as you touch sliders). "KR" deletes the file so the
# bridge falls back to its compiled defaults. The bridge only acts on this when GODOT_SIMHANDS
# is set; on a real headset ARKit drives the hands and none of this runs.
func _handle_calibration(cmd: String) -> void:
	var key := cmd.substr(1, 1)
	if key == "R":
		_reset_calibration()
		return
	if not _CALIB_KEYS.has(key):
		return
	var value := cmd.substr(2).to_float()
	var cf := ConfigFile.new()
	cf.load(_CALIB_PATH)  # OK if absent — we just add/overwrite this one key
	cf.set_value("simhands", _CALIB_KEYS[key], value)
	cf.save(_CALIB_PATH)
	_diag("calib %s=%f" % [_CALIB_KEYS[key], value])

func _reset_calibration() -> void:
	var d := DirAccess.open("user://")
	if d != null and d.file_exists("simhands_calibration.cfg"):
		d.remove("simhands_calibration.cfg")
	_diag("calib reset")

# Append-only diagnostic so a headless run can confirm packets arrive. Pull via
# simctl get_app_container ... data -> Documents/sim_keys.txt.
func _diag(s: String) -> void:
	var f := FileAccess.open("user://sim_keys.txt", FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open("user://sim_keys.txt", FileAccess.WRITE)
	if f:
		f.seek_end()
		f.store_string(s + "\n")
		f.close()
