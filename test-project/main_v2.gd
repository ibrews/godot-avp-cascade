extends Node3D

# Physics Sandbox — arrange a course in mixed-immersion and route falling cubes
# from a grabbable spawn emitter, through grabbable obstacles, into a grabbable
# goal portal that scores them. All geometry built procedurally in _ready().
# Hand tracking pickup/throw courtesy of Marshall Nowak (Nocxr).
#
# Gestures: index→thumb = grab | middle→thumb = toggle hand mesh | ring→thumb = reset

# Shown on the in-world info panel. Bump on meaningful releases.
const APP_VERSION := "v0.5.1-grabscale"

const SPAWN_INTERVAL := 0.55
const KILL_Y := -2.0
const MAX_CUBES := 20
const GLOBAL_AUDIO_RATE_HZ := 9.0
const SAMPLE_RATE := 44100.0
const FORWARD_Z := -1.3
# Lift the whole course up to roughly chest/eye height so nothing sits in the floor.
const BASE_HEIGHT := 0.9
const SPAWN_HEIGHT := 1.6 + BASE_HEIGHT
const PLATE_HEIGHT := 0.55 + BASE_HEIGHT

# Two-hand scale: hold an object with one hand, pinch with the other; the
# inter-pinch distance drives scale relative to the distance when scaling began.
const SCALE_MIN := 0.1
const SCALE_MAX := 10.0
const SCALE_ENGAGE_DIST := 0.32   # other-hand pinch must start within this of the held object

# Collision layers: bit1 = solid (cubes/surfaces/obstacles), bit2 = grabbable-only
# (emitter/portal/bubble — cubes pass through, hands still grab).
const LAYER_SOLID := 1
const LAYER_GRAB_ONLY := 2

# --- Scoring (chain/combo, anti-gaming) ---
# Only NEW distinct surfaces (group "surface"/"obstacle") count. Cube-on-cube and
# repeat hits on the same surface are ignored, so trapping a cube in a bounce
# pocket earns nothing.
const TIME_POINTS_PER_SEC := 6.0
const SURFACE_BASE := 5
const CHAIN_WINDOW_MS := 1500
const CHAIN_MAX := 8

# Fire-plasma palette — warm tones + contrast pops for mixed-mode variety.
const CUBE_PALETTE := [
	Color(1.00, 0.55, 0.10),  # classic orange
	Color(1.00, 0.80, 0.00),  # amber / gold
	Color(1.00, 0.95, 0.30),  # yellow
	Color(1.00, 0.22, 0.04),  # deep red-orange
	Color(1.00, 0.97, 0.88),  # white-hot
	Color(0.75, 0.28, 1.00),  # electric violet
	Color(0.20, 0.82, 1.00),  # ice blue
	Color(1.00, 0.38, 0.70),  # hot pink
]

var _xr_ok := false
var _frame_count := 0
var _log_timer := 0.0
var _spawn_timer := 0.0
var _last_global_audio := 0.0
var _physics_material: PhysicsMaterial
var _shared_audio: AudioStreamPlayer3D
var _audio_playback: AudioStreamGeneratorPlayback
var _flash_light: OmniLight3D
var _flash_energy := 0.0
var _active_cubes: Array = []
var _collision_count := 0
var _hand_drivers: Array = []
var _hand_mesh_visible := true
var _gesture_cooldown := 0.0
# Grab-stutter diagnostics: count physics vs render frames to confirm the 90 Hz
# display / 60 Hz physics beat, and log held/pause/double-grab state per window.
var _phys_frame_count := 0
var _last_proc_log := 0
var _last_phys_log := 0

# --- Sandbox state ---
var _emitter: SpawnEmitter3D
var _portal: GoalPortal3D
var _grabbables: Array = []            # everything reset() returns home
var _home_transforms: Dictionary = {}  # instance_id → Transform3D
var _hand_handlers: Dictionary = {}    # side → PickupHandler3D

# Two-hand scaling state.
var _scaling_body: Node3D = null
var _scale_start_dist := 0.0
var _scale_start_scale := Vector3.ONE
var _scale_pivot := Vector3.ZERO  # held object's position frozen at engage
# Two-anchor (glued-pinch) two-hand transform state.
var _scale_active := false
var _scale_is_world := false
var _scale_target: Node3D = null
var _scale_A0 := Vector3.ZERO   # world pinch points (L,R) at engage — object case
var _scale_B0 := Vector3.ZERO
var _scale_WA := Vector3.ZERO   # world points under the pinches at engage — world case
var _scale_WB := Vector3.ZERO
var _scale_T0: Transform3D = Transform3D.IDENTITY  # target object transform at engage
var _two_hand_world_active := false  # suppress single-hand handle drag while two-handing the world

# Per-hand index-pinch hysteresis (true once pinched, stays true until clearly
# released — kills the grab/release flicker that made grabbing stutter).
var _index_pinch_state := {"left_hand": false, "right_hand": false}
const PINCH_START := 0.024   # must close to here to BEGIN an index pinch (firm pinch)
const PINCH_END := 0.052     # must open past here to END it (hysteresis gap)

# Retained only for the _grab_diag readout (always false now): the world handle
# moves the XROrigin, so no physics ever needs to be frozen.
var _sim_paused := false

# Scene handle: grab the chrome handlebar to move/scale the whole course.
# Manual grab (the handle is a plain Node3D, NOT a pickup body) so the
# PickupHandler can never auto-grab it by proximity near the face.
const HANDLE_GRAB_DIST := 0.09   # pinch must start this close to the handle (on-bar only)
var _world_root: Node3D            # all course objects + spawned cubes live here
var _scene_handle: SceneHandle3D
var _handle_held_side := ""        # "", "left_hand", or "right_hand"
var _handle_prev_pinch = null      # Vector3 or null; holder hand's last pinch pos
var _world_scale_start_dist := 0.0
var _world_scale_start_scale := Vector3.ONE
var _world_scale_pivot := Vector3.ZERO  # captured ONCE at scale engage (stable)
var _world_home: Transform3D = Transform3D.IDENTITY
var _origin_home: Transform3D = Transform3D.IDENTITY  # XROrigin3D rest pose; the world handle moves the origin, reset restores it

# Immersion toggle (pinky→thumb pinch). Mixed = transparent bg (passthrough);
# "immersive" = opaque sky drawn by Godot, occluding passthrough. NOTE: this does
# NOT change the real CompositorServices immersion style (that's launch-bound in
# SwiftUI) — it just fills the background so it LOOKS fully immersive, and also
# makes reflections obvious. Doubles as a diagnostic for the alpha halo.
var _world_env: WorldEnvironment
var _immersive := false
var _skybox: MeshInstance3D    # giant inward sphere; toggled to block passthrough
var _sky_mat: StandardMaterial3D  # stored so the immersion toggle can fade it in/out

# Info panel: a rigid stack (no per-element billboard — we face the whole panel
# to the camera each frame so the layers never drift apart). _info_accent pulses
# gently as a subtle delight flourish.
var _info_panel_root: Node3D
var _info_accent: MeshInstance3D
var _info_accent_mat: StandardMaterial3D
var _info_panel_t := 0.0

# --- 30-second time-attack mode + global leaderboard ---
# Poke the START button to begin a 30 s round; rack up the most points. On end,
# the round score posts to the leaderboard (Apps Script GET-submit) and updates
# the local best. Paste your deployed /exec URL into LEADERBOARD_URL to go live;
# empty = local-best only (no network).
const ROUND_SECONDS := 30.0
const LEADERBOARD_URL := "https://script.google.com/macros/s/AKfycbzfnTbrGnRE0ANAVujqDWRyYi_eub7HOvS-m3uI3WY-ysMw0LohX3d48iyE7D86jn5R/exec"
const LEADERBOARD_KEY := "cascade-2026"   # must match Code.gs APP_KEY
const PLAYER_INITIALS := "AGL"            # 3-letter tag posted with the score
var _timer_active := false
var _timer_remaining := 0.0
var _round_score := 0
var _best_score := 0
var _start_button: Node3D
var _start_button_label: Label3D
var _start_button_mat: StandardMaterial3D
var _start_cooldown := 0.0
var _btn_face: Node3D            # mesh+label container that depresses on press
var _http: HTTPRequest

# Real Persona-arm (upper-limb passthrough) toggle — a pokable button distinct from
# the virtual GLTF hand mesh (_hand_mesh_visible / middle-pinch). It writes
# user://upper_limb.txt ("visible"/"hidden"); the recompiled visionOS engine polls
# that file (~0.5s) and applies it to SwiftUI .upperLimbVisibility live — no relaunch.
var _arms_button: Node3D
var _arms_button_label: Label3D
var _arms_button_mat: StandardMaterial3D
var _arms_btn_face: Node3D
var _real_arms_visible := false
var _arms_cooldown := 0.0

# --- In-world live leaderboard panel (grabbable, like the info panel) ---
const LB_REFRESH_SEC := 15.0
const LB_ROWS := 8
var _lb_rows_label: Label3D
var _lb_http: HTTPRequest
var _lb_refresh_t := 0.0

# Self-destruct buttons: each entry {panel, button}. Poking a panel's red button
# dissolves the panel (shard burst); a reset (ring-pinch) brings them all back.
var _panels: Array = []
var _destruct_cooldown := 0.0
# #5: smallest grab collider edge — tiny objects get an inflated grab box so they
# stay easy to pick up (visual mesh unchanged).
const MIN_GRAB_SIDE := 0.10

func _ready():
	var interface = XRServer.find_interface("visionOS")
	if interface and interface.initialize():
		print("[Sandbox] visionOS XR initialized OK")
		_xr_ok = true
		var viewport = get_viewport()
		viewport.use_xr = true
		# VRS_XR is REQUIRED for the layered compositor to produce output — disabling it
		# renders nothing (all passthrough). So foveation stays; if it IS the blockiness,
		# that's an engine-level tune (can't soften the XR density map from GDScript).
		viewport.vrs_mode = Viewport.VRS_XR
		# Mixed-mode blockiness is CompositorServices FOVEATION (coarse rasterization-rate
		# map → blocky alpha tiles against passthrough). Empirically ruled out from GDScript:
		# MSAA/SSAA crash boot, VRS_DISABLED renders nothing, FXAA does nothing, no glow/SSAO
		# in the env. The real fix is engine-level: set configuration.isFoveationEnabled=false
		# in the fork's app_visionos.swift ContentStageConfiguration. See KB.
		# DO NOT touch the XR render buffer here. Both viewport.msaa_3d (MSAA) AND
		# viewport.scaling_3d_scale (SSAA/supersample) CRASH AT BOOT on the .layered
		# foveated CompositorServices target — any multisampled OR resized render
		# buffer breaks the compositor handoff. Verified on device: v0.1.9-msaa and
		# v0.2.1-ssaa both failed to launch; v0.2.0-aa-off (neither) boots fine.
		# Mixed-mode alpha-edge blockiness (no fractional alpha at silhouettes) is
		# therefore an ENGINE-LEVEL fix only — bundle with the fork recompile.
		# See KB intelligence/techniques/godot-avp-alpha-edge-aa.md.
	else:
		print("[Sandbox] visionOS XR init FAILED")
	_write_log("Sandbox boot — XR=%s" % ("OK" if _xr_ok else "FAILED"))
	_world_env = $WorldEnvironment
	_build_resources()
	_build_static_scene()
	_build_info_panel()
	_setup_audio()
	_setup_hands()
	_http = HTTPRequest.new()
	add_child(_http)
	_lb_http = HTTPRequest.new()
	add_child(_lb_http)
	_lb_http.request_completed.connect(_on_lb_completed)
	_load_best()
	_build_start_button()
	_load_arms_pref()
	_build_arms_button()
	_build_leaderboard_panel()
	_build_instructions_panel()
	_fetch_leaderboard()
	_write_log("Sandbox built; audio ready; hand tracking active")

func _build_resources():
	_physics_material = PhysicsMaterial.new()
	_physics_material.bounce = 0.38
	_physics_material.friction = 0.22

	# Collision flash light — repositioned on each impact (PER_PIXEL surfaces only).
	_flash_light = OmniLight3D.new()
	_flash_light.light_color = Color(1.0, 0.90, 0.60)
	_flash_light.light_energy = 0.0
	_flash_light.omni_range = 1.2
	_flash_light.omni_attenuation = 2.0
	add_child(_flash_light)

# Register a grabbable so reset() can return it to where it started.
func _register_grabbable(b: Node3D) -> void:
	_grabbables.append(b)
	_home_transforms[b.get_instance_id()] = b.transform
	_ensure_min_grab_collider(b)

# Inflate a grabbable's collision shape so its biggest side is >= MIN_GRAB_SIDE,
# making small objects easy to grab. Visual mesh is untouched. Box + sphere only.
func _ensure_min_grab_collider(b: Node3D) -> void:
	for child in b.get_children():
		if child is CollisionShape3D:
			var sh: Shape3D = (child as CollisionShape3D).shape
			if sh is BoxShape3D:
				var s: Vector3 = (sh as BoxShape3D).size
				var mx: float = maxf(s.x, maxf(s.y, s.z))
				if mx > 0.0 and mx < MIN_GRAB_SIDE:
					(sh as BoxShape3D).size = s * (MIN_GRAB_SIDE / mx)
			elif sh is SphereShape3D:
				if (sh as SphereShape3D).radius < MIN_GRAB_SIDE * 0.5:
					(sh as SphereShape3D).radius = MIN_GRAB_SIDE * 0.5
			return

func _build_plate(y: float, z: float, x_rot_deg: float) -> void:
	var plate := PickupAbleBody3D.new()
	plate.freeze = true
	plate.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	plate.freeze_on_release = true
	plate.add_to_group("surface")
	plate.physics_material_override = _physics_material
	plate.transform = Transform3D(
		Basis().rotated(Vector3.RIGHT, deg_to_rad(x_rot_deg)),
		Vector3(0.0, y, z)
	)
	# Smaller starting plates — 1.6×1.2 m read as huge/unwieldy on device.
	var plate_size := Vector3(0.95, 0.04, 0.72)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = plate_size
	mi.mesh = bm
	var plate_mat := StandardMaterial3D.new()
	plate_mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	plate_mat.albedo_color = Color(0.35, 0.40, 0.55, 1.0)
	mi.material_override = plate_mat
	plate.add_child(mi)
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = plate_size
	cs.shape = bs
	plate.add_child(cs)
	_world_root.add_child(plate)
	_register_grabbable(plate)

# Generic grabbable obstacle from a mesh + matching shape. Group "obstacle"
# so it counts for scoring.
func _build_obstacle(mesh: Mesh, shape: Shape3D, xform: Transform3D, color: Color) -> PickupAbleBody3D:
	var ob := PickupAbleBody3D.new()
	ob.freeze = true
	ob.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	ob.freeze_on_release = true
	ob.add_to_group("obstacle")
	ob.physics_material_override = _physics_material
	ob.transform = xform
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	mat.albedo_color = color
	mi.material_override = mat
	ob.add_child(mi)
	var cs := CollisionShape3D.new()
	cs.shape = shape
	ob.add_child(cs)
	_world_root.add_child(ob)
	_register_grabbable(ob)
	return ob

func _build_static_scene():
	# WorldRoot holds the entire course + spawned cubes. The scene handle moves
	# and scales THIS node, so grabbing the handle moves/scales everything at once.
	_world_root = Node3D.new()
	_world_root.name = "WorldRoot"
	add_child(_world_root)
	_world_home = _world_root.transform
	_origin_home = $XROrigin3D.transform

	# Chrome scene handle — sibling of WorldRoot (NOT inside it), so moving the
	# world never drags the handle out of your hand. Starts right in front of the
	# user at seated reach so it can be grabbed from wherever they're sitting.
	_scene_handle = SceneHandle3D.new()
	_scene_handle.position = Vector3(0.0, 1.25, -0.4)
	add_child(_scene_handle)

	# Reflection probe so chrome/metal picks up the actual course geometry (not
	# just the sky radiance). Covers the play volume; updates once (static scene).
	var probe := ReflectionProbe.new()
	probe.size = Vector3(3.0, 3.0, 3.0)
	probe.position = Vector3(0.0, PLATE_HEIGHT, FORWARD_Z)
	probe.update_mode = ReflectionProbe.UPDATE_ALWAYS  # course moves via handle
	probe.intensity = 1.0
	probe.max_distance = 8.0
	add_child(probe)

	# Immersion skybox — a large inward-facing sphere that surrounds the user and
	# blocks the real world when toggled on (pinky pinch). Hidden by default
	# (we boot in mixed/passthrough). Centered on the camera rig, not the course.
	_skybox = MeshInstance3D.new()
	var sky_sphere := SphereMesh.new()
	sky_sphere.radius = 8.0
	sky_sphere.height = 16.0
	sky_sphere.is_hemisphere = false
	_skybox.mesh = sky_sphere
	_sky_mat = StandardMaterial3D.new()
	_sky_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_sky_mat.cull_mode = BaseMaterial3D.CULL_FRONT  # render inside faces
	# OPAQUE — it must fully occlude passthrough for immersive mode. (The dissolve
	# effect is carried by the shard burst, not by fading this material.)
	# Vertical gradient via a simple emissive deep-space blue; bright enough to lift
	# the previously-black scene and give metals something to reflect.
	_sky_mat.albedo_color = Color(0.06, 0.09, 0.18)
	_sky_mat.emission_enabled = true
	_sky_mat.emission = Color(0.10, 0.16, 0.32)
	_sky_mat.emission_energy_multiplier = 0.8
	_skybox.mesh.surface_set_material(0, _sky_mat)
	_skybox.position = Vector3(0.0, 1.3, 0.0)
	_skybox.visible = false
	add_child(_skybox)
	# Note: deliberately NOT registered as a course grabbable — reset shouldn't
	# move it, and it isn't part of the scored course.

	# Spawn emitter (grabbable marker — cubes are emitted from its position).
	_emitter = SpawnEmitter3D.new()
	_emitter.position = Vector3(0.0, SPAWN_HEIGHT, FORWARD_Z)
	_world_root.add_child(_emitter)
	_register_grabbable(_emitter)

	# Two catch plates (group "surface").
	_build_plate(PLATE_HEIGHT, FORWARD_Z, -22.0)
	_build_plate(PLATE_HEIGHT - 0.6, FORWARD_Z - 0.35, 15.0)

	# Side deflector wall (group "surface").
	var wall := PickupAbleBody3D.new()
	wall.freeze = true
	wall.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	wall.freeze_on_release = true
	wall.add_to_group("surface")
	wall.physics_material_override = _physics_material
	wall.transform = Transform3D(
		Basis().rotated(Vector3.UP, deg_to_rad(-25.0)),
		Vector3(0.65, PLATE_HEIGHT + 0.15, FORWARD_Z)
	)
	var wmi := MeshInstance3D.new()
	var wbm := BoxMesh.new()
	wbm.size = Vector3(0.04, 0.35, 0.7)
	wmi.mesh = wbm
	var wmat := StandardMaterial3D.new()
	wmat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	wmat.albedo_color = Color(0.25, 0.45, 0.70, 1.0)
	wmi.material_override = wmat
	wall.add_child(wmi)
	var wcs := CollisionShape3D.new()
	var wbs := BoxShape3D.new()
	wbs.size = Vector3(0.04, 0.35, 0.7)
	wcs.shape = wbs
	wall.add_child(wcs)
	_world_root.add_child(wall)
	_register_grabbable(wall)

	# Ramp / wedge — angled deflector (group "obstacle").
	var ramp_mesh := BoxMesh.new()
	ramp_mesh.size = Vector3(0.5, 0.03, 0.3)
	var ramp_shape := BoxShape3D.new()
	ramp_shape.size = Vector3(0.5, 0.03, 0.3)
	_build_obstacle(ramp_mesh, ramp_shape,
		Transform3D(Basis().rotated(Vector3.FORWARD, deg_to_rad(35.0)),
			Vector3(-0.35, PLATE_HEIGHT + 0.45, FORWARD_Z)),
		Color(0.55, 0.40, 0.70))

	# Pegs — three round cylinder bumpers for pachinko scattering (group "obstacle").
	for i in range(3):
		var peg_mesh := CylinderMesh.new()
		peg_mesh.top_radius = 0.03
		peg_mesh.bottom_radius = 0.03
		peg_mesh.height = 0.22
		var peg_shape := CylinderShape3D.new()
		peg_shape.radius = 0.03
		peg_shape.height = 0.22
		var px := -0.2 + i * 0.2
		_build_obstacle(peg_mesh, peg_shape,
			Transform3D(Basis().rotated(Vector3.RIGHT, deg_to_rad(90.0)),  # axis along Z
				Vector3(px, SPAWN_HEIGHT - 0.45, FORWARD_Z)),
			Color(0.30, 0.55, 0.65))

	# Bubble transmuter — cubes passing through become spheres.
	var bubble := BubbleTransmuter3D.new()
	bubble.position = Vector3(0.25, PLATE_HEIGHT + 0.55, FORWARD_Z)
	bubble.cube_passed.connect(_on_bubble_passed)
	_world_root.add_child(bubble)
	_register_grabbable(bubble)

	# Goal portal.
	_portal = GoalPortal3D.new()
	# Bottom-center of the cascade, ring standing VERTICAL (hole faces the user /
	# the cascade flow) and clear of the plates. Still grabbable — grab-and-aim.
	_portal.position = Vector3(0.0, PLATE_HEIGHT - 0.78, FORWARD_Z + 0.12)
	_portal.rotation_degrees = Vector3(0.0, 0.0, 0.0)
	_portal.cube_entered.connect(_on_portal_entered)
	_world_root.add_child(_portal)
	_register_grabbable(_portal)

	# Kill plane — despawns escaped cubes (score 0).
	var killer := Area3D.new()
	killer.collision_mask = LAYER_SOLID
	var kc := CollisionShape3D.new()
	var ks := BoxShape3D.new()
	ks.size = Vector3(50.0, 0.5, 50.0)
	kc.shape = ks
	killer.add_child(kc)
	killer.position = Vector3(0.0, KILL_Y, 0.0)
	killer.body_entered.connect(_on_kill_entered)
	add_child(killer)

func _setup_audio():
	_shared_audio = AudioStreamPlayer3D.new()
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = SAMPLE_RATE
	gen.buffer_length = 0.6  # room for the one-shot score fanfare (boom is ~0.55s)
	_shared_audio.stream = gen
	_shared_audio.volume_db = -3.0
	_shared_audio.max_distance = 5.0
	_shared_audio.unit_size = 1.0
	add_child(_shared_audio)
	_shared_audio.play()
	_audio_playback = _shared_audio.get_stream_playback()

# Build one XRController3D + PickupHandler3D + hand mesh per hand.
func _setup_hands() -> void:
	var xr_origin := $XROrigin3D
	for side in ["left_hand", "right_hand"]:
		var controller := XRController3D.new()
		controller.tracker = side

		var handler := PickupHandler3D.new()
		# Require near-contact to grab (was 0.3 = grabbed objects ~30 cm away). The
		# detect sphere sits at the fingertip midpoint; with the grabbable's own
		# collider this means you must basically touch a thing to pick it up.
		handler.detect_range = 0.07
		handler.follow_fingertips = true
		handler.hold_while_hand_tracking_uncertain = true
		# Firm pinch: with the hand-tracked ramp (0.024→0.010 m), 0.85 makes a grab
		# begin only when the thumb/index tips are ~1.2 cm apart, releasing near 2.2 cm.
		handler.pickup_press_threshold = 0.85
		# Detect both solid bodies (cubes/plates) AND grab-only bodies
		# (emitter/portal/bubble on layer 2).
		handler.collision_mask = LAYER_SOLID | LAYER_GRAB_ONLY

		var cs := CollisionShape3D.new()
		cs.name = "CollisionShape3D"
		var sphere := SphereShape3D.new()
		sphere.radius = 0.3
		cs.shape = sphere
		handler.add_child(cs)

		controller.add_child(handler)
		xr_origin.add_child(controller)
		_hand_handlers[side] = handler

		var tracker_path := "/user/hand_tracker/" + ("left" if side == "left_hand" else "right")
		var driver := HandMeshDriver3D.new()
		driver.tracker_name = tracker_path
		driver.is_left = (side == "left_hand")
		xr_origin.add_child(driver)
		_hand_drivers.append(driver)

# Small billboarded title/version panel floating to the user's upper-left. Added to
# self (not _world_root) so it stays fixed and doesn't move/scale with the handle.
func _build_info_panel() -> void:
	# Grabbable like everything else: a layer-2 (cubes pass through) PickupAbleBody3D
	# that stays where you place it on release. Faces +Z (toward the user) at rest.
	var root := PickupAbleBody3D.new()
	root.name = "InfoPanel"
	root.position = Vector3(-0.5, 1.55, -0.7)
	root.collision_layer = LAYER_GRAB_ONLY
	root.collision_mask = 0
	root.freeze = true
	root.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	root.freeze_on_release = true
	add_child(root)
	_info_panel_root = root

	# Text stack — title (white), handle (brand orange), version (dim). Rigid (no
	# per-element billboard); the whole panel faces the camera in _update_info_panel.
	var title := _panel_label("A Godot Sample", 46, Color(1.0, 1.0, 1.0, 1.0), 10)
	title.position = Vector3(0.0, 0.034, 0.006)
	root.add_child(title)
	var handle := _panel_label("by @ibrews", 40, Color(1.0, 0.55, 0.10, 1.0), 9)
	handle.position = Vector3(0.0, -0.010, 0.006)
	root.add_child(handle)
	var ver := _panel_label(APP_VERSION, 24, Color(0.70, 0.80, 0.92, 0.85), 6)
	ver.position = Vector3(0.0, -0.044, 0.006)
	root.add_child(ver)

	# Auto-size the backing to enclose ALL text + padding (no more clipping).
	var bounds := _union_child_aabb(root)
	var size_x: float = bounds.size.x + 0.06
	var size_y: float = bounds.size.y + 0.045
	var center_y: float = bounds.position.y + bounds.size.y * 0.5

	# Warm accent plate, slightly larger → glowing border around the dark panel.
	_info_accent_mat = StandardMaterial3D.new()
	_info_accent_mat.albedo_color = Color(1.0, 0.55, 0.10, 0.32)
	_info_accent_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_info_accent_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_info_accent_mat.emission_enabled = true
	_info_accent_mat.emission = Color(1.0, 0.55, 0.10)
	_info_accent_mat.emission_energy_multiplier = 1.2
	var accent := MeshInstance3D.new()
	var aq := QuadMesh.new()
	aq.size = Vector2(size_x + 0.016, size_y + 0.016)
	accent.mesh = aq
	accent.material_override = _info_accent_mat
	accent.position = Vector3(0.0, center_y, -0.004)
	root.add_child(accent)
	_info_accent = accent

	# Dark translucent panel in front of the accent (its margin shows as a border).
	var bg := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(size_x, size_y)
	bg.mesh = quad
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.03, 0.03, 0.05, 0.82)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bg.material_override = mat
	bg.position = Vector3(0.0, center_y, 0.0)
	root.add_child(bg)

	# Grab collider covering the panel face (thin box). Layer set on the body above.
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(size_x, size_y, 0.03)
	cs.shape = box
	cs.position = Vector3(0.0, center_y, 0.0)
	root.add_child(cs)
	_register_grabbable(root)
	_attach_destruct_button(root, Vector3(0.0, center_y - size_y * 0.5 - 0.045, 0.0))

# A billboard-free Label3D for the info panel (the panel faces the camera as a unit).
func _panel_label(txt: String, fsize: int, col: Color, outline: int) -> Label3D:
	var l := Label3D.new()
	l.text = txt
	l.font_size = fsize
	l.outline_size = outline
	l.modulate = col
	l.outline_modulate = Color(0.0, 0.0, 0.0, 0.9)
	l.pixel_size = 0.0005
	l.shaded = false
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return l

# Union of the local AABBs (offset by their positions) of a node's VisualInstance3D
# children — used to size the panel backing to exactly cover the text.
func _union_child_aabb(parent: Node3D) -> AABB:
	var acc := AABB()
	var first := true
	for child in parent.get_children():
		if child is VisualInstance3D:
			var a: AABB = (child as VisualInstance3D).get_aabb()
			a.position += child.position
			if first:
				acc = a
				first = false
			else:
				acc = acc.merge(a)
	return acc

# Pulse the accent border (subtle delight). The panel itself is now a grabbable
# placeable object, so we no longer force it to face the camera.
func _update_info_panel(delta: float) -> void:
	if _info_accent_mat == null:
		return
	_info_panel_t += delta
	_info_accent_mat.emission_energy_multiplier = 1.0 + 0.5 * (0.5 + 0.5 * sin(_info_panel_t * 2.0))

func _physics_process(_delta: float) -> void:
	_phys_frame_count += 1

func _process(delta: float):
	_frame_count += 1
	_log_timer += delta
	_spawn_timer += delta
	_gesture_cooldown = max(0.0, _gesture_cooldown - delta)

	if _gesture_cooldown <= 0.0:
		# Joint indices: middle tip=15, ring tip=20, pinky/little tip=25 (raw
		# OpenXR ints — the enum name for the pinky differs between the 4.6.3
		# editor (LITTLE) and 4.6.2.rc runtime (PINKY), so never use the name).
		for side in ["left_hand", "right_hand"]:
			# Never evaluate a gesture on a hand that isn't confidently tracked —
			# a half-visible hand was firing spurious resets mid-grab.
			if not _hand_confident(side):
				continue
			var pinched := _which_finger_pinch(side)  # -1, or 15/20/25
			if pinched == 20:        # ring → reset
				_reset_sandbox()
				_gesture_cooldown = 1.0
				break
			elif pinched == 15:      # middle → toggle hand mesh
				_hand_mesh_visible = not _hand_mesh_visible
				for d in _hand_drivers:
					d.set_shown(_hand_mesh_visible)
				# Dissolve whoosh: descending on hide, ascending on show.
				_push_sweep(900.0, 300.0, 0.22) if not _hand_mesh_visible else _push_sweep(300.0, 900.0, 0.22)
				_gesture_cooldown = 0.8
				break
			elif pinched == 25:      # pinky → toggle immersion / passthrough
				_toggle_immersion()
				_gesture_cooldown = 0.8
				break

	_update_info_panel(delta)
	_update_timer(delta)
	_update_arms_button(delta)
	_update_leaderboard(delta)
	_update_destruct(delta)
	_update_two_hand_scale()  # both hands pinch → scale world (handle) or held object
	_update_scene_handle()  # World handle now drags the XROrigin (the user), not the
	# world — zero physics bodies move, so no freeze and no jitter. World-scale (scaling
	# the origin about the pinch midpoint) is the next step; per-object scale stays off.

	if _spawn_timer >= SPAWN_INTERVAL:
		_spawn_timer = 0.0
		if _active_cubes.size() < MAX_CUBES:
			_spawn_cube()
	if _log_timer >= 5.0:
		_log_timer = 0.0
		_append_log(_grab_diag())
	if _flash_energy > 0.0:
		_flash_energy = move_toward(_flash_energy, 0.0, delta * 22.0)
		_flash_light.light_energy = _flash_energy

func _spawn_cube():
	var size: float = randf_range(0.06, 0.12)
	var color: Color = CUBE_PALETTE[randi() % CUBE_PALETTE.size()]
	var emission_e: float = randf_range(1.2, 3.5)

	var cube := PickupAbleBody3D.new()
	cube.collision_layer = LAYER_SOLID
	cube.collision_mask = LAYER_SOLID
	cube.physics_material_override = _physics_material
	cube.mass = max(0.08, size * size * size * 400.0)
	cube.linear_damp = 0.12
	cube.angular_damp = 0.30
	cube.contact_monitor = true
	cube.max_contacts_reported = 4

	# Per-cube scoring state.
	cube.set_meta("birth_ms", Time.get_ticks_msec())
	cube.set_meta("size", size)
	cube.set_meta("score_acc", 0)        # accumulated surface points (with chain)
	cube.set_meta("hit_ids", {})         # instance_id → true (distinct surfaces)
	cube.set_meta("chain", 0)
	cube.set_meta("last_chain_ms", 0)

	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	var bm := BoxMesh.new()
	bm.size = Vector3(size, size, size)
	mi.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = emission_e
	mi.material_override = mat
	cube.add_child(mi)

	var cs := CollisionShape3D.new()
	cs.name = "Shape"
	var sh := BoxShape3D.new()
	sh.size = Vector3(size, size, size)
	cs.shape = sh
	cube.add_child(cs)
	_ensure_min_grab_collider(cube)  # #5: small cubes get a grab-friendly collider

	# Per-cube particle trail.
	var pmat := StandardMaterial3D.new()
	pmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	pmat.albedo_color = Color(color.r, color.g, color.b, 0.85)
	pmat.emission_enabled = true
	pmat.emission = color
	pmat.emission_energy_multiplier = 2.2
	pmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var pquad := QuadMesh.new()
	pquad.size = Vector2(0.022, 0.022)
	pquad.material = pmat

	var proc_mat := ParticleProcessMaterial.new()
	proc_mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	proc_mat.emission_sphere_radius = size * 0.18
	proc_mat.initial_velocity_min = 0.06
	proc_mat.initial_velocity_max = 0.32
	proc_mat.gravity = Vector3(0.0, -0.35, 0.0)
	proc_mat.scale_min = 0.25
	proc_mat.scale_max = 0.90

	var particles := GPUParticles3D.new()
	particles.amount = 12
	particles.lifetime = 0.4
	particles.explosiveness = 0.0
	particles.process_material = proc_mat
	particles.draw_pass_1 = pquad
	particles.visibility_aabb = AABB(Vector3(-1.0, -1.0, -1.0), Vector3(2.0, 2.0, 2.0))
	cube.add_child(particles)

	# Emit from the (grabbable) emitter's current position.
	var spawn_pos := _emitter.global_position if is_instance_valid(_emitter) \
		else Vector3(0.0, SPAWN_HEIGHT, FORWARD_Z)
	cube.angular_velocity = Vector3(
		randf_range(-2.5, 2.5), randf_range(-2.5, 2.5), randf_range(-2.5, 2.5))
	cube.add_to_group("cube")
	cube.body_entered.connect(_on_cube_collision.bind(cube))
	_world_root.add_child(cube)
	cube.global_position = spawn_pos + Vector3(randf_range(-0.04, 0.04), -0.05, randf_range(-0.04, 0.04))
	_active_cubes.append(cube)
	if is_instance_valid(_emitter):
		_emitter.pulse()

func _on_cube_collision(other_body: Node3D, cube: RigidBody3D):
	_collision_count += 1
	if not is_instance_valid(cube):
		return
	var now := Time.get_ticks_msec()

	# --- Scoring: only NEW distinct surfaces/obstacles count ---
	var is_scorable := other_body.is_in_group("surface") or other_body.is_in_group("obstacle")
	if is_scorable:
		var hit_ids: Dictionary = cube.get_meta("hit_ids")
		var oid := other_body.get_instance_id()
		if not hit_ids.has(oid):
			hit_ids[oid] = true  # dict is a ref; meta stays updated
			# Chain: new surface within window grows the multiplier.
			var chain: int = cube.get_meta("chain")
			var last_ms: int = cube.get_meta("last_chain_ms")
			if last_ms != 0 and (now - last_ms) <= CHAIN_WINDOW_MS:
				chain = min(chain + 1, CHAIN_MAX)
			else:
				chain = 1
			cube.set_meta("chain", chain)
			cube.set_meta("last_chain_ms", now)
			var pts := SURFACE_BASE * chain
			cube.set_meta("score_acc", int(cube.get_meta("score_acc")) + pts)
			# Inline popup at the impact point.
			var label := ("+%d" % pts) if chain == 1 else ("x%d  +%d" % [chain, pts])
			ScorePopup3D.spawn(self, cube.global_position, label, _chain_color(chain), false)

	# --- Audio (rate-limited) ---
	if now / 1000.0 - _last_global_audio < 1.0 / GLOBAL_AUDIO_RATE_HZ:
		return
	_last_global_audio = now / 1000.0
	_shared_audio.position = cube.global_position
	_flash_light.position = cube.global_position
	_flash_energy = 3.5
	var is_sphere := cube.is_in_group("sphere")
	if other_body.is_in_group("cube"):
		_push_chime(randf_range(700.0, 1500.0), 0.036, false)
	elif is_sphere:
		# Transmuted spheres: hollow, woody knock (lower, longer, detuned harmonic).
		_push_chime(randf_range(180.0, 420.0), 0.14, true)
	else:
		_push_chime(randf_range(260.0, 700.0), 0.10, true)

func _on_bubble_passed(cube: Node3D, at: Vector3):
	if not is_instance_valid(cube) or cube.is_in_group("sphere"):
		return
	cube.add_to_group("sphere")
	var size: float = cube.get_meta("size", 0.09)
	# Swap box mesh → sphere mesh (keep the material/emission).
	var mi := cube.get_node_or_null("Mesh")
	if mi and mi is MeshInstance3D:
		var sm := SphereMesh.new()
		sm.radius = size * 0.5
		sm.height = size
		mi.mesh = sm
	# Swap box shape → sphere shape so it rolls.
	var cs := cube.get_node_or_null("Shape")
	if cs and cs is CollisionShape3D:
		var ss := SphereShape3D.new()
		ss.radius = size * 0.5
		cs.shape = ss
	# A soft "bloop" to mark the transmutation.
	_shared_audio.position = at
	_push_chime(520.0, 0.12, true)

func _on_portal_entered(cube: Node3D, at: Vector3):
	if not is_instance_valid(cube):
		return
	if not cube.is_in_group("cube"):
		return
	# Final score = time-alive trickle + accumulated chained surface points.
	var birth: int = cube.get_meta("birth_ms", Time.get_ticks_msec())
	var alive_s := float(Time.get_ticks_msec() - birth) / 1000.0
	var surface_pts: int = cube.get_meta("score_acc", 0)
	var total := int(round(alive_s * TIME_POINTS_PER_SEC)) + surface_pts
	total = max(total, 1)

	# Time-attack: tally toward the active round.
	if _timer_active:
		_round_score += total

	# Despawn the cube.
	_active_cubes.erase(cube)
	cube.queue_free()

	# Running total + big popup arcing out of the portal mouth.
	if is_instance_valid(_portal):
		_portal.add_to_total(total)
	# Big cash-out uses the volumetric (extruded, non-billboard) popup so it
	# stands apart from the flat multiplier popups. Small +N / xN stay flat.
	BigScorePopup3D.spawn(self, at + Vector3(0, 0.05, 0), str(total), Color(0.55, 0.95, 1.0))
	_spawn_burst(at, Color(0.40, 0.90, 1.0))
	_push_score_fanfare()

# Celebratory fireworks at the portal: a big multicolor burst, a layer of fast
# bright sparks, and an expanding shockwave ring flash.
func _spawn_burst(pos: Vector3, color: Color):
	# Layer 1 — main colorful burst (color ramp through warm tones into the accent).
	var ramp := _make_gradient([
		Color(1.0, 1.0, 0.95, 1.0),   # hot white core
		Color(1.0, 0.80, 0.20, 1.0),  # gold
		Color(1.0, 0.40, 0.10, 1.0),  # orange
		Color(color.r, color.g, color.b, 0.9),
		Color(color.r, color.g, color.b, 0.0),  # fade out
	])
	_emit_burst_layer(pos, 110, 0.032, 1.1, 0.8, 2.6, -1.3, 0.4, 1.3, ramp, color)
	# Layer 2 — fast, tiny, very bright sparks that streak out and die quickly.
	_emit_burst_layer(pos, 60, 0.014, 0.55, 2.2, 4.4, -1.8, 0.3, 0.8, null, Color(1.0, 0.97, 0.85))
	# Layer 3 — expanding shockwave ring.
	_spawn_shockwave(pos, color)

# One GPUParticles3D one-shot burst layer.
func _emit_burst_layer(pos: Vector3, amount: int, quad_size: float, lifetime: float,
		vmin: float, vmax: float, gravity_y: float, smin: float, smax: float,
		ramp: GradientTexture1D, base_color: Color) -> void:
	var pmat := StandardMaterial3D.new()
	pmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	pmat.albedo_color = Color(base_color.r, base_color.g, base_color.b, 0.95)
	pmat.emission_enabled = true
	pmat.emission = base_color
	pmat.emission_energy_multiplier = 4.0
	pmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	pmat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	var quad := QuadMesh.new()
	quad.size = Vector2(quad_size, quad_size)
	quad.material = pmat
	var proc := ParticleProcessMaterial.new()
	proc.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	proc.emission_sphere_radius = 0.02
	proc.direction = Vector3(0, 1, 0)
	proc.spread = 180.0
	proc.initial_velocity_min = vmin
	proc.initial_velocity_max = vmax
	proc.gravity = Vector3(0, gravity_y, 0)
	proc.scale_min = smin
	proc.scale_max = smax
	if ramp != null:
		proc.color_ramp = ramp
	var burst := GPUParticles3D.new()
	burst.amount = amount
	burst.lifetime = lifetime
	burst.one_shot = true
	burst.explosiveness = 1.0
	burst.process_material = proc
	burst.draw_pass_1 = quad
	burst.visibility_aabb = AABB(Vector3(-1.5, -1.5, -1.5), Vector3(3, 3, 3))
	burst.position = pos
	add_child(burst)
	burst.emitting = true
	get_tree().create_timer(lifetime + 0.5).timeout.connect(func():
		if is_instance_valid(burst): burst.queue_free())

# Expanding, fading emissive ring that punches outward from the score point.
func _spawn_shockwave(pos: Vector3, color: Color) -> void:
	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.05
	torus.outer_radius = 0.07
	ring.mesh = torus
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(color.r, color.g, color.b, 0.85)
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = 3.5
	ring.material_override = m
	ring.position = pos
	# Face the user so the ring reads as a flat expanding flash.
	var cam := get_viewport().get_camera_3d()
	if cam != null and not cam.global_position.is_equal_approx(pos):
		ring.look_at(cam.global_position, Vector3.UP)
	add_child(ring)
	var tw := create_tween().set_parallel(true)
	tw.tween_property(ring, "scale", Vector3.ONE * 9.0, 0.45).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(m, "albedo_color:a", 0.0, 0.45)
	tw.tween_property(m, "emission_energy_multiplier", 0.0, 0.45)
	tw.chain().tween_callback(ring.queue_free)

# Build a GradientTexture1D from a list of colors (evenly spaced) for particle ramps.
func _make_gradient(colors: Array) -> GradientTexture1D:
	var g := Gradient.new()
	var offsets := PackedFloat32Array()
	var cols := PackedColorArray()
	var n := colors.size()
	for i in range(n):
		offsets.append(float(i) / float(maxi(1, n - 1)))
		cols.append(colors[i])
	g.offsets = offsets
	g.colors = cols
	var tex := GradientTexture1D.new()
	tex.gradient = g
	return tex

func _chain_color(chain: int) -> Color:
	if chain >= 6:
		return Color(1.0, 0.3, 1.0)   # magenta
	elif chain >= 4:
		return Color(1.0, 0.55, 0.1)  # orange
	elif chain >= 2:
		return Color(1.0, 0.95, 0.25) # yellow
	return Color(1.0, 1.0, 1.0)       # white

func _reset_sandbox():
	# Restore the world transform (legacy; the handle no longer moves it) and the
	# XROrigin — the world handle now drags the user, so reset must re-center them.
	if is_instance_valid(_world_root):
		_world_root.transform = _world_home
	if has_node("XROrigin3D"):
		$XROrigin3D.transform = _origin_home
	_handle_prev_pinch = null
	_world_scale_start_dist = 0.0
	# Despawn all cubes.
	for c in _active_cubes:
		if is_instance_valid(c):
			c.queue_free()
	_active_cubes.clear()
	# Return every grabbable to its home transform.
	for b in _grabbables:
		if is_instance_valid(b):
			var home: Transform3D = _home_transforms.get(b.get_instance_id(), b.transform)
			b.transform = home
			if b is RigidBody3D:
				b.linear_velocity = Vector3.ZERO
				b.angular_velocity = Vector3.ZERO
	# Bring back any self-destructed panels.
	for entry in _panels:
		var p: Node3D = entry["panel"]
		if is_instance_valid(p):
			p.visible = true
			if p is CollisionObject3D:
				(p as CollisionObject3D).collision_layer = LAYER_GRAB_ONLY
	if is_instance_valid(_portal):
		_portal.reset_total()
	_write_log("Sandbox reset")
	# Confirmation chime.
	_push_chime(660.0, 0.10, true)

func _push_chime(freq: float, duration: float, harmonic: bool):
	if _audio_playback == null:
		return
	var n := int(SAMPLE_RATE * duration)
	var to_fill: int = min(n, _audio_playback.get_frames_available())
	for i in range(to_fill):
		var t := float(i) / SAMPLE_RATE
		var env := sin(PI * t / duration)
		var s: float
		if harmonic:
			s = (sin(TAU * freq * t) * 0.50 + sin(TAU * freq * 2.0 * t) * 0.18) * env
		else:
			s = sin(TAU * freq * t) * env * 0.42
		_audio_playback.push_frame(Vector2(s, s))

# Frequency sweep from f0→f1 over `dur` — used for toggle whooshes.
func _push_sweep(f0: float, f1: float, dur: float):
	if _audio_playback == null:
		return
	var n := int(SAMPLE_RATE * dur)
	var to_fill: int = min(n, _audio_playback.get_frames_available())
	var phase := 0.0
	for i in range(to_fill):
		var u := float(i) / float(n)
		var freq: float = lerp(f0, f1, u)
		phase += TAU * freq / SAMPLE_RATE
		var env := sin(PI * u)  # fade in/out
		var s := sin(phase) * env * 0.38
		_audio_playback.push_frame(Vector2(s, s))

# Powerful score sound to match the fireworks: a deep pitch-dropping boom + a
# noise crack + a sparkle shimmer tail, with the rising C-E-G arpeggio layered on
# top. Mixed into ONE buffer fill (needs buffer_length >= ~0.55s).
func _push_score_fanfare():
	if _audio_playback == null:
		return
	var dur := 0.55
	var n := int(SAMPLE_RATE * dur)
	var to_fill: int = min(n, _audio_playback.get_frames_available())
	var arp := [523.25, 659.25, 783.99]  # C5, E5, G5
	var note_dur := 0.07
	for i in range(to_fill):
		var t := float(i) / SAMPLE_RATE
		var u := t / dur
		# Sub boom: pitch drops 95→40 Hz with a fast exponential decay.
		var f: float = lerp(95.0, 40.0, sqrt(u))
		var s := sin(TAU * f * t) * exp(-3.6 * u) * 0.85
		# Explosion crack: white-noise burst, very fast decay.
		s += (randf() * 2.0 - 1.0) * exp(-10.0 * u) * 0.33
		# Sparkle shimmer that lingers a touch.
		s += sin(TAU * 1300.0 * t) * exp(-4.5 * u) * 0.10 * (0.5 + 0.5 * sin(TAU * 9.0 * t))
		# Rising arpeggio layered over the first three note slots.
		var ni := int(t / note_dur)
		if ni < arp.size():
			var nt := t - float(ni) * note_dur
			var nenv := sin(PI * nt / note_dur)
			s += (sin(TAU * arp[ni] * t) * 0.30 + sin(TAU * arp[ni] * 2.0 * t) * 0.08) * nenv
		s = clampf(s, -1.0, 1.0)
		_audio_playback.push_frame(Vector2(s, s))

# Returns which finger tip (15=middle, 20=ring, 25=pinky) is pinching the thumb,
# or -1 if none. "Closest wins": only the single finger nearest the thumb counts,
# so adjacent fingers (ring vs pinky) can't cross-trigger. Index must be extended
# so a normal grab never fires a gesture. Raw int indices avoid the LITTLE/PINKY
# enum-name divergence between the 4.6.3 editor and 4.6.2.rc runtime.
# Confidence gate: a hand counts as confidently tracked only when its tracker
# has data AND the wrist plus all five fingertips are POSITION_TRACKED. If a hand
# isn't confident we assume NO gesture/pinch is happening (per request — never
# guess from a half-visible hand). Used by every gesture and pinch-point reader.
func _hand_confident(side: String) -> bool:
	var tname := "/user/hand_tracker/" + ("left" if side == "left_hand" else "right")
	var tracker := XRServer.get_tracker(tname)
	if not tracker is XRHandTracker:
		return false
	var ht := tracker as XRHandTracker
	if not ht.get_has_tracking_data():
		return false
	const TRACKED := 8  # HAND_JOINT_FLAG_POSITION_TRACKED
	# wrist=1, thumb tip=5, index=10, middle=15, ring=20, pinky=25
	for j in [1, 5, 10, 15, 20, 25]:
		if not (int(ht.get_hand_joint_flags(j)) & TRACKED):
			return false
	return true

func _which_finger_pinch(side: String) -> int:
	var tname := "/user/hand_tracker/" + ("left" if side == "left_hand" else "right")
	var tracker := XRServer.get_tracker(tname)
	if not tracker is XRHandTracker:
		return -1
	var ht := tracker as XRHandTracker
	if not ht.get_has_tracking_data():
		return -1
	const THUMB := 5
	const INDEX := 10
	const TRACKED := 8  # HAND_JOINT_FLAG_POSITION_TRACKED
	for j in [THUMB, INDEX, 15, 20, 25]:
		if not (int(ht.get_hand_joint_flags(j)) & TRACKED):
			return -1
	var thumb_pos := ht.get_hand_joint_transform(THUMB).origin
	# Index must be extended (so grabs never trigger gestures).
	if ht.get_hand_joint_transform(INDEX).origin.distance_to(thumb_pos) <= 0.045:
		return -1
	# Find the closest of middle/ring/pinky tips to the thumb.
	var best := -1
	var best_dist := 1e9
	for tip in [15, 20, 25]:
		var d := ht.get_hand_joint_transform(tip).origin.distance_to(thumb_pos)
		if d < best_dist:
			best_dist = d
			best = tip
	# Only count it as a pinch if the closest is actually touching.
	if best_dist >= 0.025:
		return -1
	return best

# True INDEX pinch with hysteresis + "index is the closest finger to the thumb".
# Returns the index-thumb midpoint while pinching, else null. The closest-finger
# test means a MIDDLE pinch (where the index also curls near the thumb) does NOT
# count as an index pinch — fixing handle-grab firing on middle pinch. Hysteresis
# (PINCH_START to begin, PINCH_END to release) kills the grab/release flicker.
func _index_pinch_point(side: String):
	if not _hand_confident(side):
		_index_pinch_state[side] = false
		return null
	var tname := "/user/hand_tracker/" + ("left" if side == "left_hand" else "right")
	var ht := XRServer.get_tracker(tname) as XRHandTracker
	if ht == null or not ht.get_has_tracking_data():
		_index_pinch_state[side] = false
		return null
	var thumb := ht.get_hand_joint_transform(5).origin
	var index := ht.get_hand_joint_transform(10).origin
	var d_index := index.distance_to(thumb)
	var was: bool = _index_pinch_state[side]
	var active: bool
	if was:
		# Stay pinched until the gap clearly opens.
		active = d_index < PINCH_END
	else:
		# To BEGIN, index must be closest finger to thumb AND within start dist.
		var d_mid := ht.get_hand_joint_transform(15).origin.distance_to(thumb)
		var d_ring := ht.get_hand_joint_transform(20).origin.distance_to(thumb)
		var d_pinky := ht.get_hand_joint_transform(25).origin.distance_to(thumb)
		var index_closest := d_index <= d_mid and d_index <= d_ring and d_index <= d_pinky
		active = index_closest and d_index < PINCH_START
	_index_pinch_state[side] = active
	if not active:
		return null
	return (index + thumb) * 0.5

# Toggle a giant inward-facing skybox sphere that fully blocks the real world.
# We stay in mixed immersion (CompositorServices style is launch-bound); the
# skybox is just opaque geometry surrounding the user. background_mode stays
# BG_COLOR/alpha-0 so the compositor compositing rule isn't violated — only the
# sphere geometry occludes passthrough.
func _toggle_immersion() -> void:
	_immersive = not _immersive
	var center := Vector3(0.0, 1.4, 0.0)
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		center = cam.global_position
	# Opaque sky snaps on/off (so it actually occludes); shards carry the transition.
	if _skybox != null:
		_skybox.visible = _immersive
	if _immersive:
		_shard_burst(center, 2.4, Color(0.45, 0.65, 1.0), false, 40)  # converge
		_push_sweep(300.0, 900.0, 0.30)                               # rising (hand "show")
	else:
		_shard_burst(center, 2.4, Color(0.80, 0.88, 1.0), true, 40)   # outward
		_push_sweep(900.0, 300.0, 0.30)                               # falling (hand "hide")

# Shared shard effect — small emissive cubes that fly outward (dissolve) or
# converge inward (materialize) around a center. Used by the immersion toggle and
# the panel self-destruct buttons; same spirit as the hand-mesh dissolve.
func _shard_burst(center: Vector3, spread: float, color: Color, outward: bool, count: int = 28) -> void:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(color.r, color.g, color.b, 0.95)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 2.4
	var shard := BoxMesh.new()
	shard.size = Vector3(0.02, 0.02, 0.02)
	shard.material = mat
	for i in range(count):
		var dir := Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1))
		if dir.length() < 0.01:
			dir = Vector3.UP
		dir = dir.normalized()
		var mi := MeshInstance3D.new()
		mi.mesh = shard
		add_child(mi)
		var edge := center + dir * spread + Vector3(0, -0.1, 0)
		var tw := create_tween().set_parallel(true)
		if outward:
			mi.global_position = center + dir * (spread * 0.25)
			tw.tween_property(mi, "global_position", edge, 0.5).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
			tw.tween_property(mi, "scale", Vector3.ZERO, 0.5)
		else:
			mi.global_position = edge
			mi.scale = Vector3.ONE * 1.3
			tw.tween_property(mi, "global_position", center + dir * (spread * 0.25), 0.45).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
			tw.tween_property(mi, "scale", Vector3.ONE * 0.3, 0.45)
		tw.chain().tween_callback(mi.queue_free)

# --- Time-attack mode -------------------------------------------------------

# Build the pokable START button (reachable, near the world handle).
func _build_start_button() -> void:
	_start_button = Node3D.new()
	_start_button.name = "StartButton"
	_start_button.position = Vector3(0.42, 1.20, -0.45)
	add_child(_start_button)

	# Mesh + label live on a face container that depresses on press; the label is
	# NOT billboarded so it stays fixed on the button face (faces +Z toward the user).
	_btn_face = Node3D.new()
	_start_button.add_child(_btn_face)

	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.17, 0.085, 0.03)
	mi.mesh = bm
	_start_button_mat = StandardMaterial3D.new()
	_start_button_mat.albedo_color = Color(0.10, 0.42, 0.24)
	_start_button_mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	_start_button_mat.emission_enabled = true
	_start_button_mat.emission = Color(0.20, 0.95, 0.45)
	_start_button_mat.emission_energy_multiplier = 1.2
	mi.material_override = _start_button_mat
	_btn_face.add_child(mi)

	_start_button_label = Label3D.new()
	_start_button_label.font_size = 34
	_start_button_label.outline_size = 8
	_start_button_label.modulate = Color.WHITE
	_start_button_label.outline_modulate = Color(0, 0, 0, 0.9)
	_start_button_label.pixel_size = 0.0005
	_start_button_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_start_button_label.position = Vector3(0, 0, 0.017)   # sits just proud of the face
	_btn_face.add_child(_start_button_label)
	_refresh_button_label()

# Tick the active round, and watch for a finger poke to start OR restart one.
func _update_timer(delta: float) -> void:
	_start_cooldown = max(0.0, _start_cooldown - delta)
	if _timer_active:
		_timer_remaining -= delta
		# Pulse the button red as time runs low.
		var urgency := 1.0 - clampf(_timer_remaining / ROUND_SECONDS, 0.0, 1.0)
		_start_button_mat.emission = Color(0.2 + urgency * 0.8, 0.9 - urgency * 0.7, 0.45 - urgency * 0.3)
		_refresh_button_label()
		if _timer_remaining <= 0.0:
			_end_round()

	# Poke (start when idle, restart when active) — gated by a short cooldown.
	if _start_cooldown > 0.0 or _start_button == null:
		return
	for side in ["left_hand", "right_hand"]:
		var tip = _index_tip_world(side)
		if tip != null and (tip as Vector3).distance_to(_start_button.global_position) <= 0.08:
			_press_button()
			if _timer_active:
				_cancel_round()   # abort to neutral; a SECOND press restarts the 30s
			else:
				_start_round()
			break

# Satisfying click: depress the button face and play a crisp tick.
func _press_button() -> void:
	_push_click()
	if _btn_face != null:
		var tw := create_tween()
		tw.tween_property(_btn_face, "position:z", -0.018, 0.05).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tw.tween_property(_btn_face, "position:z", 0.0, 0.11).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

# Short percussive UI tick (two fast blips) for the button press.
func _push_click() -> void:
	if _audio_playback == null:
		return
	var dur := 0.045
	var n := int(SAMPLE_RATE * dur)
	var to_fill: int = min(n, _audio_playback.get_frames_available())
	for i in range(to_fill):
		var t := float(i) / SAMPLE_RATE
		var u := t / dur
		var s := (sin(TAU * 1500.0 * t) * 0.5 + sin(TAU * 2300.0 * t) * 0.3) * exp(-26.0 * u)
		_audio_playback.push_frame(Vector2(s, s))

# Index fingertip in WORLD space (tracking-space joint rendered through XROrigin,
# same compensation as the hand mesh — so the poke matches where the finger looks).
func _index_tip_world(side: String):
	var tname := "/user/hand_tracker/" + ("left" if side == "left_hand" else "right")
	var ht := XRServer.get_tracker(tname) as XRHandTracker
	if ht == null or not ht.get_has_tracking_data():
		return null
	var idx := XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP
	if not (int(ht.get_hand_joint_flags(idx)) & 8):  # POSITION_TRACKED
		return null
	var origin := $XROrigin3D as Node3D
	return origin.global_transform * ht.get_hand_joint_transform(idx).origin

# Abort an in-progress round: flash the button red, settle back to neutral green,
# and do NOT restart. The player must press again to begin a fresh 30 s.
func _cancel_round() -> void:
	_timer_active = false
	_timer_remaining = 0.0
	_round_score = 0
	_start_cooldown = 0.8   # ignore the lingering finger so it doesn't instantly restart
	_refresh_button_label()
	_start_button_mat.emission = Color(1.0, 0.15, 0.15)
	var tw := create_tween()
	tw.tween_property(_start_button_mat, "emission", Color(0.20, 0.95, 0.45), 0.45)

func _start_round() -> void:
	_timer_active = true
	_timer_remaining = ROUND_SECONDS
	_round_score = 0
	_start_cooldown = 1.0
	_push_sweep(300.0, 900.0, 0.25)  # start chirp
	_refresh_button_label()

func _end_round() -> void:
	_timer_active = false
	_timer_remaining = 0.0
	var final_score := _round_score
	if final_score > _best_score:
		_best_score = final_score
		_save_best()
	_start_button_mat.emission = Color(0.20, 0.95, 0.45)
	# Celebrate above the button: volumetric score + fireworks + fanfare.
	var burst_at := _start_button.global_position + Vector3(0, 0.18, 0)
	BigScorePopup3D.spawn(self, burst_at, str(final_score))
	_spawn_burst(burst_at, Color(0.30, 1.0, 0.55))
	_push_score_fanfare()
	_submit_score(final_score)
	_start_cooldown = 2.5
	_refresh_button_label()

func _refresh_button_label() -> void:
	if _start_button_label == null:
		return
	if _timer_active:
		_start_button_label.text = "%d\n%d pts" % [int(ceil(_timer_remaining)), _round_score]
	else:
		_start_button_label.text = "START\n30s  ·  best %d" % _best_score

# --- Real Persona-arm (upper-limb passthrough) toggle ----------------------
# Distinct from the virtual GLTF hand mesh (middle-pinch). This pokable button
# writes a preference the recompiled engine polls and applies to the SwiftUI
# .upperLimbVisibility — the real arms fade in/out live, no relaunch needed.

# Sync the button state with any preference persisted from a prior session, so the
# label matches what the engine will actually show at launch.
func _load_arms_pref() -> void:
	if not FileAccess.file_exists("user://upper_limb.txt"):
		return
	var f := FileAccess.open("user://upper_limb.txt", FileAccess.READ)
	if f == null:
		return
	var v := f.get_as_text().strip_edges().to_lower()
	f.close()
	_real_arms_visible = (v == "visible")

# Build the pokable ARMS button (mirror of START, on the left).
func _build_arms_button() -> void:
	_arms_button = Node3D.new()
	_arms_button.name = "ArmsButton"
	_arms_button.position = Vector3(-0.42, 1.20, -0.45)
	add_child(_arms_button)

	_arms_btn_face = Node3D.new()
	_arms_button.add_child(_arms_btn_face)

	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.17, 0.085, 0.03)
	mi.mesh = bm
	_arms_button_mat = StandardMaterial3D.new()
	_arms_button_mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	_arms_button_mat.emission_enabled = true
	mi.material_override = _arms_button_mat
	_arms_btn_face.add_child(mi)

	_arms_button_label = Label3D.new()
	_arms_button_label.font_size = 30
	_arms_button_label.outline_size = 8
	_arms_button_label.modulate = Color.WHITE
	_arms_button_label.outline_modulate = Color(0, 0, 0, 0.9)
	_arms_button_label.pixel_size = 0.0005
	_arms_button_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_arms_button_label.position = Vector3(0, 0, 0.017)
	_arms_btn_face.add_child(_arms_button_label)
	_refresh_arms_label()

func _refresh_arms_label() -> void:
	if _arms_button_label == null or _arms_button_mat == null:
		return
	if _real_arms_visible:
		_arms_button_label.text = "REAL ARMS\nON"
		_arms_button_mat.albedo_color = Color(0.12, 0.34, 0.50)
		_arms_button_mat.emission = Color(0.30, 0.75, 1.0)
		_arms_button_mat.emission_energy_multiplier = 1.2
	else:
		_arms_button_label.text = "REAL ARMS\nOFF"
		_arms_button_mat.albedo_color = Color(0.30, 0.22, 0.10)
		_arms_button_mat.emission = Color(0.95, 0.62, 0.20)
		_arms_button_mat.emission_energy_multiplier = 1.0

# Watch for a finger poke on the ARMS button; toggle the real-limb preference.
func _update_arms_button(delta: float) -> void:
	_arms_cooldown = max(0.0, _arms_cooldown - delta)
	if _arms_cooldown > 0.0 or _arms_button == null:
		return
	for side in ["left_hand", "right_hand"]:
		var tip = _index_tip_world(side)
		if tip != null and (tip as Vector3).distance_to(_arms_button.global_position) <= 0.08:
			_toggle_real_arms()
			break

func _toggle_real_arms() -> void:
	_real_arms_visible = not _real_arms_visible
	_arms_cooldown = 0.8
	# user://upper_limb.txt maps to Documents/upper_limb.txt; the engine reads it.
	var f := FileAccess.open("user://upper_limb.txt", FileAccess.WRITE)
	if f != null:
		f.store_string("visible" if _real_arms_visible else "hidden")
		f.close()
	_press_arms_button()
	_refresh_arms_label()
	# Ascending sweep = arms appearing, descending = arms hiding.
	_push_sweep(300.0, 900.0, 0.22) if _real_arms_visible else _push_sweep(900.0, 300.0, 0.22)

func _press_arms_button() -> void:
	_push_click()
	if _arms_btn_face != null:
		var tw := create_tween()
		tw.tween_property(_arms_btn_face, "position:z", -0.018, 0.05).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tw.tween_property(_arms_btn_face, "position:z", 0.0, 0.11).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

# Fire-and-forget GET submit (survives Apps Script's POST→GET redirect).
func _submit_score(score: int) -> void:
	if _http == null or LEADERBOARD_URL == "":
		return
	var url := "%s?submit=1&name=%s&score=%d&key=%s" % [
		LEADERBOARD_URL, PLAYER_INITIALS.uri_encode(), score, LEADERBOARD_KEY.uri_encode()]
	_http.request(url)

# Grabbable in-world leaderboard panel (top scores, auto-refreshing). Movable +
# scalable like the info panel (PickupAbleBody3D, layer 2, stays where placed).
func _build_leaderboard_panel() -> void:
	var root := PickupAbleBody3D.new()
	root.name = "LeaderboardPanel"
	root.position = Vector3(0.5, 1.55, -0.7)   # mirror of the info panel (right side)
	root.collision_layer = LAYER_GRAB_ONLY
	root.collision_mask = 0
	root.freeze = true
	root.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	root.freeze_on_release = true
	add_child(root)

	var size_x := 0.34
	var size_y := 0.40

	# Accent + dark backing (same look as the info panel).
	var accent_mat := StandardMaterial3D.new()
	accent_mat.albedo_color = Color(0.30, 0.80, 1.0, 0.30)
	accent_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	accent_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	accent_mat.emission_enabled = true
	accent_mat.emission = Color(0.30, 0.80, 1.0)
	var accent := MeshInstance3D.new()
	var aq := QuadMesh.new()
	aq.size = Vector2(size_x + 0.016, size_y + 0.016)
	accent.mesh = aq
	accent.material_override = accent_mat
	accent.position = Vector3(0, 0, -0.004)
	root.add_child(accent)

	var bg := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(size_x, size_y)
	bg.mesh = quad
	var bgmat := StandardMaterial3D.new()
	bgmat.albedo_color = Color(0.03, 0.03, 0.05, 0.82)
	bgmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	bgmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bg.material_override = bgmat
	root.add_child(bg)

	var title := _panel_label("◆ LEADERBOARD ◆", 30, Color(0.40, 0.90, 1.0, 1.0), 7)
	title.position = Vector3(0, size_y * 0.5 - 0.035, 0.006)
	root.add_child(title)

	_lb_rows_label = _panel_label("loading…", 24, Color(1, 1, 1, 0.96), 5)
	_lb_rows_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_lb_rows_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_lb_rows_label.position = Vector3(-size_x * 0.5 + 0.03, size_y * 0.5 - 0.085, 0.006)
	root.add_child(_lb_rows_label)

	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(size_x, size_y, 0.03)
	cs.shape = box
	root.add_child(cs)
	_register_grabbable(root)
	_attach_destruct_button(root, Vector3(0.0, -size_y * 0.5 - 0.045, 0.0))

func _update_leaderboard(delta: float) -> void:
	_lb_refresh_t -= delta
	if _lb_refresh_t <= 0.0:
		_lb_refresh_t = LB_REFRESH_SEC
		_fetch_leaderboard()

func _fetch_leaderboard() -> void:
	if _lb_http == null or LEADERBOARD_URL == "":
		return
	_lb_http.request("%s?top=%d" % [LEADERBOARD_URL, LB_ROWS])

func _on_lb_completed(_result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if _lb_rows_label == null:
		return
	if code != 200:
		_lb_rows_label.text = "offline"
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("scores"):
		_lb_rows_label.text = "offline"
		return
	var scores: Array = parsed["scores"]
	if scores.is_empty():
		_lb_rows_label.text = "no scores yet —\nbe the first!"
		return
	var lines := PackedStringArray()
	var i := 1
	for s in scores:
		var nm := str(s.get("name", "AAA"))
		if nm.length() > 8:
			nm = nm.substr(0, 8)
		lines.append("%2d  %-8s %5d" % [i, nm, int(s.get("score", 0))])
		i += 1
	_lb_rows_label.text = "\n".join(lines)

func _load_best() -> void:
	if FileAccess.file_exists("user://best.txt"):
		var f := FileAccess.open("user://best.txt", FileAccess.READ)
		if f != null:
			_best_score = int(f.get_line())
			f.close()

func _save_best() -> void:
	var f := FileAccess.open("user://best.txt", FileAccess.WRITE)
	if f != null:
		f.store_line(str(_best_score))
		f.close()

# Floating cold-open explainer: goal of the game + control map, with small 3D
# icon "diagrams". Grabbable/movable like the other panels (and self-destructible).
func _build_instructions_panel() -> void:
	var root := PickupAbleBody3D.new()
	root.name = "InstructionsPanel"
	root.position = Vector3(0.0, 2.05, -1.0)   # prominent + centered for a cold open
	root.collision_layer = LAYER_GRAB_ONLY
	root.collision_mask = 0
	root.freeze = true
	root.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	root.freeze_on_release = true
	add_child(root)

	var size_x := 0.52
	var size_y := 0.46

	# Accent + dark backing.
	var accent_mat := StandardMaterial3D.new()
	accent_mat.albedo_color = Color(1.0, 0.55, 0.10, 0.30)
	accent_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	accent_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	accent_mat.emission_enabled = true
	accent_mat.emission = Color(1.0, 0.55, 0.10)
	var accent := MeshInstance3D.new()
	var aq := QuadMesh.new()
	aq.size = Vector2(size_x + 0.016, size_y + 0.016)
	accent.mesh = aq
	accent.material_override = accent_mat
	accent.position = Vector3(0, 0, -0.004)
	root.add_child(accent)

	var bg := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(size_x, size_y)
	bg.mesh = quad
	var bgmat := StandardMaterial3D.new()
	bgmat.albedo_color = Color(0.03, 0.03, 0.05, 0.85)
	bgmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	bgmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bg.material_override = bgmat
	root.add_child(bg)

	var title := _panel_label("HOW TO PLAY", 36, Color(1.0, 0.80, 0.30, 1.0), 8)
	title.position = Vector3(0, size_y * 0.5 - 0.04, 0.006)
	root.add_child(title)

	var goal := _panel_label(
		"Cubes cascade from the emitter.\nGrab & arrange the plates, ramps,\nbubble and goal ring to route\nthem in. Most points in 30s wins!",
		22, Color(0.92, 0.95, 1.0, 1.0), 5)
	goal.position = Vector3(0, size_y * 0.5 - 0.135, 0.006)
	root.add_child(goal)

	var controls := _panel_label(
		"index pinch    grab & move\nmiddle pinch   show / hide hand mesh\nring pinch     reset everything\npinky pinch    immersive sky\npoke START     30s time attack\npoke ARMS      real arms on / off\ngrab the bar   move the world",
		20, Color(0.62, 0.92, 1.0, 1.0), 5)
	controls.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	controls.position = Vector3(0, -size_y * 0.5 + 0.10, 0.006)
	root.add_child(controls)

	# Tiny 3D "diagram" icons flanking the title: a goal ring + a cube.
	var ring_icon := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.012
	tm.outer_radius = 0.022
	ring_icon.mesh = tm
	var rmat := StandardMaterial3D.new()
	rmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rmat.albedo_color = Color(0.30, 0.85, 1.0)
	rmat.emission_enabled = true
	rmat.emission = Color(0.30, 0.85, 1.0)
	ring_icon.material_override = rmat
	ring_icon.position = Vector3(-size_x * 0.5 + 0.05, size_y * 0.5 - 0.04, 0.01)
	root.add_child(ring_icon)

	var cube_icon := MeshInstance3D.new()
	var cbm := BoxMesh.new()
	cbm.size = Vector3(0.03, 0.03, 0.03)
	cube_icon.mesh = cbm
	var cmat := StandardMaterial3D.new()
	cmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	cmat.albedo_color = Color(1.0, 0.55, 0.10)
	cmat.emission_enabled = true
	cmat.emission = Color(1.0, 0.55, 0.10)
	cube_icon.material_override = cmat
	cube_icon.position = Vector3(size_x * 0.5 - 0.05, size_y * 0.5 - 0.04, 0.01)
	cube_icon.rotation_degrees = Vector3(20, 35, 0)
	root.add_child(cube_icon)

	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(size_x, size_y, 0.03)
	cs.shape = box
	root.add_child(cs)
	_register_grabbable(root)
	_attach_destruct_button(root, Vector3(0.0, -size_y * 0.5 - 0.05, 0.0))

# Attach a small red self-destruct button beneath a panel (child, so it rides the
# panel when moved). Poke it to dissolve the panel; reset brings it back.
func _attach_destruct_button(panel: Node3D, local_pos: Vector3) -> void:
	var btn := Node3D.new()
	btn.name = "Destruct"
	btn.position = local_pos
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.022
	sm.height = 0.044
	mi.mesh = sm
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.85, 0.06, 0.06)
	m.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	m.emission_enabled = true
	m.emission = Color(1.0, 0.12, 0.12)
	m.emission_energy_multiplier = 1.6
	mi.material_override = m
	btn.add_child(mi)
	panel.add_child(btn)
	_panels.append({"panel": panel, "button": btn})

# Watch for a finger poke on any panel's destruct button.
func _update_destruct(delta: float) -> void:
	_destruct_cooldown = maxf(0.0, _destruct_cooldown - delta)
	if _destruct_cooldown > 0.0:
		return
	for entry in _panels:
		var panel: Node3D = entry["panel"]
		var btn: Node3D = entry["button"]
		if panel == null or not is_instance_valid(panel) or not panel.visible:
			continue
		for side in ["left_hand", "right_hand"]:
			var tip = _index_tip_world(side)
			if tip != null and (tip as Vector3).distance_to(btn.global_position) <= 0.05:
				_dissolve_panel(panel)
				_destruct_cooldown = 0.6
				return

# Explode a panel into shards and hide it (un-grabbable until a reset restores it).
func _dissolve_panel(panel: Node3D) -> void:
	_shard_burst(panel.global_position, 0.28, Color(1.0, 0.30, 0.20), true, 32)
	panel.visible = false
	if panel is CollisionObject3D:
		(panel as CollisionObject3D).collision_layer = 0
	_push_sweep(900.0, 240.0, 0.32)

# Scene handle: grab the chrome bar to drag the whole world. Standard VR world-grab —
# instead of translating the course (which dragged every physics body through the
# solver and caused jitter), we move the XROrigin3D (the user) the OPPOSITE way. The
# world stays bit-for-bit fixed in space; only the user's frame moves → identical look,
# zero physics objects touched. The handle bar and course are both world-fixed, so the
# hand stays glued to the bar during a drag (its world position is held constant).
func _update_scene_handle() -> void:
	if _scene_handle == null or _world_root == null:
		return
	if _two_hand_world_active:
		return  # two-hand glued transform owns the origin this frame

	var origin := $XROrigin3D as Node3D

	# --- Acquire: the handle is grabbed manually (it is NOT a pickup body) so it can
	# only be held by an INDEX pinch that STARTS near the bar. ---
	if _handle_held_side == "":
		for side in ["left_hand", "right_hand"]:
			var pp: Variant = _index_pinch_point(side)  # TRACKING space
			if pp == null:
				continue
			# Don't steal a hand that is holding OR about to grab a course object
			# (closest_body set = a grabbable is in pickup range). This is what kept
			# the handle from being grabbed spuriously during every cube grab.
			var h = _hand_handlers.get(side)
			if h != null and (h.picked_up_body != null or h.closest_body != null):
				continue
			# Pinch is tracking-space; the handle bar lives in world space. Convert via
			# the origin transform so the on-bar test still holds after a prior drag has
			# displaced the origin (tracking and world only coincide at origin identity).
			var pp_world: Vector3 = origin.global_transform * (pp as Vector3)
			if pp_world.distance_to(_scene_handle.global_position) <= HANDLE_GRAB_DIST:
				_handle_held_side = side
				_handle_prev_pinch = pp  # remember TRACKING-space pinch for the delta
				_scene_handle.set_held(true)
				_append_log("handle grabbed by %s" % side)
				break
		return

	# --- Held: confirm the holder still index-pinches, else release. ---
	var hold_pinch: Variant = _index_pinch_point(_handle_held_side)  # TRACKING space
	if hold_pinch == null:
		_release_handle()
		return
	# If that hand ended up grabbing a course object, yield the handle to the grab.
	var holder_h = _hand_handlers.get(_handle_held_side)
	if holder_h != null and holder_h.picked_up_body != null:
		_release_handle()
		return

	# --- Translate by moving the USER, not the world. The pinch is in tracking space
	# (origin-invariant), so the delta is pure physical hand motion; moving the origin
	# the opposite way slides the whole world with the hand. No feedback: T_cur never
	# depends on the origin we're changing. ---
	var cur: Vector3 = hold_pinch
	if _handle_prev_pinch != null:
		var d_track: Vector3 = cur - (_handle_prev_pinch as Vector3)
		origin.global_position -= origin.global_transform.basis * d_track
	_handle_prev_pinch = cur

func _release_handle() -> void:
	_handle_held_side = ""
	_handle_prev_pinch = null
	_world_scale_start_dist = 0.0
	if _scene_handle != null:
		_scene_handle.set_held(false)

# Two-hand "glued anchor" transform: BOTH hands index-pinch two points and those
# points stay locked to the same world spots, so scale + rotation + translation all
# fall out of how the two anchors move (standard VR two-hand manipulation):
#   • Both pinches near the world handle → transform the XROrigin so the grabbed
#     world points stay under the hands (hands apart ⇒ world bigger; rotate the
#     inter-hand axis ⇒ world rotates). Worked in tracking space ⇒ no feedback.
#   • Both pinches near a grabbable → apply the same similarity to THAT object; the
#     two pinched points stay glued to it. Outline turns BLUE while active.
func _update_two_hand_scale() -> void:
	_two_hand_world_active = false
	var pL: Variant = _index_pinch_point("left_hand")    # tracking space
	var pR: Variant = _index_pinch_point("right_hand")
	if pL == null or pR == null:
		_end_scale()
		return
	var origin := $XROrigin3D as Node3D
	var PA: Vector3 = origin.global_transform * (pL as Vector3)   # current world pinch L
	var PB: Vector3 = origin.global_transform * (pR as Vector3)   # current world pinch R
	var mid := (PA + PB) * 0.5

	# --- Engage: pick a target the first frame both pinches are down near something. ---
	if not _scale_active:
		var is_world := _scene_handle != null and mid.distance_to(_scene_handle.global_position) <= 0.28
		var obj: Node3D = null
		if not is_world:
			var best := 0.24
			for b in _grabbables:
				if is_instance_valid(b) and (b as Node3D).visible:
					var d := mid.distance_to((b as Node3D).global_position)
					if d < best:
						best = d
						obj = b as Node3D
		if not is_world and obj == null:
			return
		_scale_active = true
		_scale_is_world = is_world
		_scale_A0 = PA
		_scale_B0 = PB
		if is_world:
			_scale_WA = PA   # world points under the pinches, frozen at engage
			_scale_WB = PB
			_release_handle()  # take over from any single-hand handle drag
		else:
			_scale_target = obj
			_scale_T0 = obj.global_transform
			if obj.has_method("set_two_hand"):
				obj.set_two_hand(true)

	# --- Apply. ---
	if _scale_is_world:
		_two_hand_world_active = true
		var vt: Vector3 = (pR as Vector3) - (pL as Vector3)          # tracking (current)
		var vw: Vector3 = _scale_WB - _scale_WA                      # world (frozen)
		if vt.length() < 0.01 or vw.length() < 0.001:
			return
		var s: float = clampf(vw.length() / vt.length(), SCALE_MIN, SCALE_MAX)
		var rot := Basis(Quaternion(vt.normalized(), vw.normalized()))
		var lin := rot * s
		# O1*pL = WA exactly (left pinch glued); pR≈WB when unclamped.
		origin.global_transform = Transform3D(lin, _scale_WA - lin * (pL as Vector3))
	else:
		if not is_instance_valid(_scale_target):
			_end_scale()
			return
		var v0: Vector3 = _scale_B0 - _scale_A0
		var v1: Vector3 = PB - PA
		if v0.length() < 0.001 or v1.length() < 0.001:
			return
		var s: float = clampf(v1.length() / v0.length(), SCALE_MIN, SCALE_MAX)
		var rot := Basis(Quaternion(v0.normalized(), v1.normalized()))
		var lin := rot * s
		_scale_target.global_transform = Transform3D(lin * _scale_T0.basis, PA + lin * (_scale_T0.origin - _scale_A0))

func _end_scale() -> void:
	if _scale_active and _scale_target != null and is_instance_valid(_scale_target):
		if _scale_target.has_method("set_two_hand"):
			_scale_target.set_two_hand(false)
	_scale_active = false
	_scale_is_world = false
	_scale_target = null
	_scaling_body = null

# Midpoint of index+thumb tips for a hand, or null if not pinching/tracked.
# Requires full-hand confidence so scaling never engages off a half-seen hand.
func _pinch_point(side: String):
	if not _hand_confident(side):
		return null
	var tname := "/user/hand_tracker/" + ("left" if side == "left_hand" else "right")
	var tracker := XRServer.get_tracker(tname)
	if not tracker is XRHandTracker:
		return null
	var ht := tracker as XRHandTracker
	if not ht.get_has_tracking_data():
		return null
	var idx := XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP
	var thumb := XRHandTracker.HAND_JOINT_THUMB_TIP
	var tracked := XRHandTracker.HAND_JOINT_FLAG_POSITION_TRACKED
	if not ((int(ht.get_hand_joint_flags(idx)) & tracked) and (int(ht.get_hand_joint_flags(thumb)) & tracked)):
		return null
	var ip := ht.get_hand_joint_transform(idx).origin
	var tp := ht.get_hand_joint_transform(thumb).origin
	if ip.distance_to(tp) > 0.04:  # not pinching
		return null
	return (ip + tp) * 0.5

func _on_kill_entered(body: Node3D):
	# Falling cubes despawn silently — score 0.
	if body.is_in_group("cube"):
		_active_cubes.erase(body)
		body.queue_free()

# Per-window grab diagnostics. proc≈450 & phys≈300 per 5s confirms the 90/60
# render-vs-physics beat (held body follows in PickupHandler._physics_process).
# follow_off = distance from the holding handler to its parent controller origin
# (how far the 90 Hz controller drags the body between 60 Hz re-pins).
func _grab_diag() -> String:
	var proc_d := _frame_count - _last_proc_log
	var phys_d := _phys_frame_count - _last_phys_log
	_last_proc_log = _frame_count
	_last_phys_log = _phys_frame_count
	var lh = _hand_handlers.get("left_hand")
	var rh = _hand_handlers.get("right_hand")
	var l_held: bool = lh != null and lh.picked_up_body != null
	var r_held: bool = rh != null and rh.picked_up_body != null
	var held_side := ("L" if l_held else "") + ("R" if r_held else "")
	if held_side == "":
		held_side = "none"
	var both_same: bool = l_held and r_held and lh.picked_up_body == rh.picked_up_body
	var follow_off := 0.0
	var hh = lh if l_held else (rh if r_held else null)
	if hh != null:
		var ctrl = hh.get_parent()
		if ctrl is Node3D:
			follow_off = hh.global_position.distance_to((ctrl as Node3D).global_position)
	return "proc=%d phys=%d held=%s both_same=%s paused=%s follow_off=%.3f active=%d collisions=%d" % [
		proc_d, phys_d, held_side, str(both_same), str(_sim_paused), follow_off, _active_cubes.size(), _collision_count]

func _write_log(msg: String):
	var f := FileAccess.open("user://xr_diag.txt", FileAccess.WRITE)
	if f:
		f.store_string(msg + "\n")
		f.close()
		print("[Sandbox] " + msg)

func _append_log(msg: String):
	var f := FileAccess.open("user://xr_diag.txt", FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open("user://xr_diag.txt", FileAccess.WRITE)
	if f:
		f.seek_end(0)
		f.store_string(msg + "\n")
		f.close()
		print("[Sandbox] " + msg)
