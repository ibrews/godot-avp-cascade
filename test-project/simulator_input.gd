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
	"M": "smoothing",   # SIMHANDS_SMOOTHING      — hand stabilizer 0=raw .. 1=max (sMoothing slider)
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

# Head-tracking prototype (#7): a fake (panel head-pad) or, later, webcam face signal moves the
# XROrigin so the rendered viewpoint travels with the head — same mechanism as WASD nav and the hand
# WASD-follow (move the XROrigin, NOT the native head_tracker; the sim head pose doesn't match the
# rendered camera — that's the view-anchoring dead-end). Position-only, eased + clamped, sim-only.
var _xr_origin: Node3D
var _head_active := false
var _head_target := Vector3.ZERO     # latest commanded offset (m), already scaled + clamped
var _head_smoothed := Vector3.ZERO   # per-frame eased offset actually applied to the origin
const _HEAD_BASE_M := 0.5            # origin travel at full pad deflection, before the hand-scale mult
const _HEAD_MAX_M := 1.5             # hard per-axis clamp so the viewpoint can't fly off
const _HEAD_SMOOTH_RATE := 12.0      # exponential-approach rate (× delta → ease alpha)

func _ready() -> void:
	_main = get_parent()
	# Simulator-only (bulletproof: these env vars exist only in the sim process, never device).
	_sim_active = OS.has_environment("SIMULATOR_DEVICE_NAME") \
		or OS.has_environment("SIMULATOR_UDID") \
		or OS.has_environment("SIMULATOR_ROOT")
	if not _sim_active:
		return
	_handler = _main._hand_handlers.get("right_hand") as PickupHandler3D
	_xr_origin = _main.get_node_or_null("XROrigin3D") as Node3D
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

func _process(delta: float) -> void:
	if not _sim_active:
		return

	# Drain any queued UDP commands.
	while _udp.get_available_packet_count() > 0:
		var cmd := _udp.get_packet().get_string_from_ascii().strip_edges()
		if cmd != "":
			_handle_cmd(cmd)

	# Head-tracking prototype (#7): ease the XROrigin toward the commanded head offset (or back to its
	# home pose when disengaged), so the viewpoint travels with the head. Position-only; runs every frame
	# independent of the grab handler. When fully recentered we STOP writing the origin so WASD nav, the
	# world handle, and reset keep control — head-tracking only "owns" the origin while engaged.
	if is_instance_valid(_xr_origin):
		var target: Vector3 = _head_target if _head_active else Vector3.ZERO
		var a: float = clampf(_HEAD_SMOOTH_RATE * delta, 0.0, 1.0)
		_head_smoothed = _head_smoothed.lerp(target, a)
		if _head_active or _head_smoothed.length() > 0.001:
			var home: Transform3D = _main._origin_home
			_xr_origin.transform = Transform3D(home.basis, home.origin + _head_smoothed)

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
	# Hand-source select ("H0"/"H1"/"H2": 0=off, 1=canned panel feed, 2=webcam real helper) picks
	# which Bonjour feed drives the SimHands bridge, so the panel, the canned sender, and the real
	# webcam helper can all stay connected while only one drives. See _handle_source.
	if cmd.length() >= 2 and cmd[0] == "H":
		_handle_source(cmd)
		return
	# Explicit immersion SET ("N1" immersive / "N0" mixed) — distinct from the bare "N" toggle below.
	# Lets the panel stay authoritative so it can label the button Immersive/Mixed (#1). See _handle_immersion.
	if cmd.length() >= 2 and cmd[0] == "N":
		_handle_immersion(cmd)
		return
	# Head-tracking ("G<x>,<y>,<z>" fake/webcam head position, "GR" recenter) → moves the XROrigin (#7).
	if cmd.length() >= 1 and cmd[0] == "G":
		_handle_head(cmd)
		return
	match cmd:
		"C1":
			_c_held = true
		"C0":
			_c_held = false
		"B":
			# Panel Reset = a FULL scene reset (#2). A deliberate click shouldn't be gated by the
			# in-headset gesture cooldown (that debounce is for stray pinches), and _reset_sandbox alone
			# leaves the round running (score/timer/spawn grid/music bed) — so also restart the round for a
			# fresh cascade. _reset_sandbox already clears cubes, returns grabbables, recenters the origin,
			# and resets the portal.
			_main.call("_reset_sandbox")
			if _main.has_method("_start_round"):
				_main.call("_start_round")
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

# Parse an "H<n>" hand-source packet (0=off, 1=canned, 2=webcam) and persist it to the "source" key
# of user://simhands_calibration.cfg, which the native bridge polls (~9 Hz) to restrict which
# connected MultipeerConnectivity peer drives the trackers — so every hand feed can stay connected
# while only one drives. Only acts when GODOT_SIMHANDS is set; on a real headset ARKit drives the
# hands and none of this runs.
func _handle_source(cmd: String) -> void:
	var n := cmd.substr(1).to_int()
	if n < 0 or n > 2:
		return
	var cf := ConfigFile.new()
	cf.load(_CALIB_PATH)  # OK if absent — we just add/overwrite the source key
	cf.set_value("simhands", "source", n)
	cf.save(_CALIB_PATH)
	_diag("source=%d" % n)

# Explicit immersion set ("N1" = immersive/opaque sky, "N0" = mixed/passthrough). The panel is the
# only immersion controller in the sim, so it stays authoritative and can label the button
# Immersive/Mixed (#1). We read _main._immersive and toggle only when it differs (the engine's
# _toggle_immersion runs the dissolve transition). Deliberate click → no gesture-cooldown gate.
func _handle_immersion(cmd: String) -> void:
	var want := cmd.substr(1) == "1"
	if bool(_main._immersive) != want:
		_main.call("_toggle_immersion")
	_diag("immersion=%s" % ("immersive" if want else "mixed"))

# Head-tracking prototype (#7). "G<x>,<y>,<z>" sets a fake head position (normalized ~-1..1 per axis,
# from the panel's head pad and, later, webcam face detection); "GR" disengages and recenters. We map
# it to an XROrigin offset with the SAME hand-scale multiplier as the hand travel (#5: bigger scale →
# travel far through the scene with small head moves), clamp it per axis, and ease it in _process.
func _handle_head(cmd: String) -> void:
	if cmd.substr(1) == "R":
		_head_active = false
		_head_target = Vector3.ZERO
		_diag("head recenter")
		return
	var parts := cmd.substr(1).split(",")
	if parts.size() < 3:
		return
	var scale_mult: float = clampf(_current_hand_scale() / 0.09, 0.3, 6.0)
	var off := Vector3(parts[0].to_float(), parts[1].to_float(), parts[2].to_float()) * _HEAD_BASE_M * scale_mult
	off.x = clampf(off.x, -_HEAD_MAX_M, _HEAD_MAX_M)
	off.y = clampf(off.y, -_HEAD_MAX_M, _HEAD_MAX_M)
	off.z = clampf(off.z, -_HEAD_MAX_M, _HEAD_MAX_M)
	_head_target = off
	_head_active = true

# Read the live hand_scale the panel wrote, so head travel uses the SAME scale multiplier as the hands
# (#5/#7). Falls back to the 0.09 m default when the cfg is absent.
func _current_hand_scale() -> float:
	var cf := ConfigFile.new()
	if cf.load(_CALIB_PATH) != OK:
		return 0.09
	return float(cf.get_value("simhands", "hand_scale", 0.09))

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
