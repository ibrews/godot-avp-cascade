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

var _main: Node3D
var _handler: PickupHandler3D
var _sim_active := false
var _udp := PacketPeerUDP.new()
var _c_held := false

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

	# Grab follows the view-centre while held; feeds BOTH the pickup handler and the poke-
	# button proximity test (_index_tip_world returns sim_cursor_world for the right hand).
	var cursor := _cursor_world() if _c_held else Vector3.ZERO
	_main.sim_cursor_world = cursor if _c_held else null
	if is_instance_valid(_handler):
		_handler.sim_pickup_override = 1.0 if _c_held else 0.0
		if _c_held:
			_handler.global_position = cursor

func _handle_cmd(cmd: String) -> void:
	_diag("rx:" + cmd)
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
