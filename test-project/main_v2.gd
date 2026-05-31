extends Node3D

# Physics Sandbox — arrange a course in mixed-immersion and route falling cubes
# from a grabbable spawn emitter, through grabbable obstacles, into a grabbable
# goal portal that scores them. All geometry built procedurally in _ready().
# Hand tracking pickup/throw courtesy of Marshall Nowak (Nocxr).
#
# Gestures: index→thumb = grab | middle→thumb = toggle hand mesh | ring→thumb = reset

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

# Per-hand index-pinch hysteresis (true once pinched, stays true until clearly
# released — kills the grab/release flicker that made grabbing stutter).
var _index_pinch_state := {"left_hand": false, "right_hand": false}
const PINCH_START := 0.032   # must close to here to BEGIN an index pinch
const PINCH_END := 0.060     # must open past here to END it (hysteresis gap)

# Simulation pause while the world handle is held, so physics doesn't fight the
# world transform. Cubes freeze in place; pickup handlers are disabled.
var _sim_paused := false

# Scene handle: grab the chrome handlebar to move/scale the whole course.
# Manual grab (the handle is a plain Node3D, NOT a pickup body) so the
# PickupHandler can never auto-grab it by proximity near the face.
const HANDLE_GRAB_DIST := 0.18   # pinch must start this close to the handle
var _world_root: Node3D            # all course objects + spawned cubes live here
var _scene_handle: SceneHandle3D
var _handle_held_side := ""        # "", "left_hand", or "right_hand"
var _handle_prev_pinch = null      # Vector3 or null; holder hand's last pinch pos
var _world_scale_start_dist := 0.0
var _world_scale_start_scale := Vector3.ONE
var _world_scale_pivot := Vector3.ZERO  # captured ONCE at scale engage (stable)
var _world_home: Transform3D = Transform3D.IDENTITY

# Immersion toggle (pinky→thumb pinch). Mixed = transparent bg (passthrough);
# "immersive" = opaque sky drawn by Godot, occluding passthrough. NOTE: this does
# NOT change the real CompositorServices immersion style (that's launch-bound in
# SwiftUI) — it just fills the background so it LOOKS fully immersive, and also
# makes reflections obvious. Doubles as a diagnostic for the alpha halo.
var _world_env: WorldEnvironment
var _immersive := false
var _skybox: MeshInstance3D    # giant inward sphere; toggled to block passthrough

func _ready():
	var interface = XRServer.find_interface("visionOS")
	if interface and interface.initialize():
		print("[Sandbox] visionOS XR initialized OK")
		_xr_ok = true
		var viewport = get_viewport()
		viewport.use_xr = true
		viewport.vrs_mode = Viewport.VRS_XR
	else:
		print("[Sandbox] visionOS XR init FAILED")
	_write_log("Sandbox boot — XR=%s" % ("OK" if _xr_ok else "FAILED"))
	_world_env = $WorldEnvironment
	_build_resources()
	_build_static_scene()
	_setup_audio()
	_setup_hands()
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
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(1.6, 0.04, 1.2)
	mi.mesh = bm
	var plate_mat := StandardMaterial3D.new()
	plate_mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	plate_mat.albedo_color = Color(0.35, 0.40, 0.55, 1.0)
	mi.material_override = plate_mat
	plate.add_child(mi)
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(1.6, 0.04, 1.2)
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
	var sky_mat := StandardMaterial3D.new()
	sky_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sky_mat.cull_mode = BaseMaterial3D.CULL_FRONT  # render inside faces
	# Vertical gradient via a simple emissive deep-space blue; bright enough to lift
	# the previously-black scene and give metals something to reflect.
	sky_mat.albedo_color = Color(0.06, 0.09, 0.18)
	sky_mat.emission_enabled = true
	sky_mat.emission = Color(0.10, 0.16, 0.32)
	sky_mat.emission_energy_multiplier = 0.8
	_skybox.mesh.surface_set_material(0, sky_mat)
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
	_portal.position = Vector3(-0.55, PLATE_HEIGHT + 0.10, FORWARD_Z)
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
	gen.buffer_length = 0.3
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
		handler.detect_range = 0.3
		handler.follow_fingertips = true
		handler.hold_while_hand_tracking_uncertain = true
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

	_update_scene_handle()
	# _update_two_hand_scale()  # DISABLED for A/B test — suspected to fight PickupHandler on held objects

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

	# Despawn the cube.
	_active_cubes.erase(cube)
	cube.queue_free()

	# Running total + big popup arcing out of the portal mouth.
	if is_instance_valid(_portal):
		_portal.add_to_total(total)
	ScorePopup3D.spawn(self, at + Vector3(0, 0.05, 0), str(total), Color(0.55, 0.95, 1.0), true)
	_spawn_burst(at, Color(0.40, 0.90, 1.0))
	_push_score_arpeggio()

# Celebratory one-shot particle burst at the portal.
func _spawn_burst(pos: Vector3, color: Color):
	var pmat := StandardMaterial3D.new()
	pmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	pmat.albedo_color = Color(color.r, color.g, color.b, 0.9)
	pmat.emission_enabled = true
	pmat.emission = color
	pmat.emission_energy_multiplier = 3.0
	pmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var quad := QuadMesh.new()
	quad.size = Vector2(0.03, 0.03)
	quad.material = pmat
	var proc := ParticleProcessMaterial.new()
	proc.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	proc.emission_sphere_radius = 0.02
	proc.direction = Vector3(0, 1, 0)
	proc.spread = 180.0
	proc.initial_velocity_min = 0.6
	proc.initial_velocity_max = 1.6
	proc.gravity = Vector3(0, -0.8, 0)
	proc.scale_min = 0.4
	proc.scale_max = 1.1
	var burst := GPUParticles3D.new()
	burst.amount = 36
	burst.lifetime = 0.7
	burst.one_shot = true
	burst.explosiveness = 1.0
	burst.process_material = proc
	burst.draw_pass_1 = quad
	burst.visibility_aabb = AABB(Vector3(-1, -1, -1), Vector3(2, 2, 2))
	burst.position = pos
	add_child(burst)
	burst.emitting = true
	# Free after it finishes.
	get_tree().create_timer(1.2).timeout.connect(func():
		if is_instance_valid(burst): burst.queue_free())

func _chain_color(chain: int) -> Color:
	if chain >= 6:
		return Color(1.0, 0.3, 1.0)   # magenta
	elif chain >= 4:
		return Color(1.0, 0.55, 0.1)  # orange
	elif chain >= 2:
		return Color(1.0, 0.95, 0.25) # yellow
	return Color(1.0, 1.0, 1.0)       # white

func _reset_sandbox():
	# Restore the world transform (handle may have moved/scaled it).
	if is_instance_valid(_world_root):
		_world_root.transform = _world_home
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

# Rising 3-note arpeggio for a scored cube.
func _push_score_arpeggio():
	if _audio_playback == null:
		return
	var freqs := [523.25, 659.25, 783.99]  # C5, E5, G5
	var note_dur := 0.07
	for f in freqs:
		var n := int(SAMPLE_RATE * note_dur)
		var avail := _audio_playback.get_frames_available()
		var to_fill: int = min(n, avail)
		for i in range(to_fill):
			var t := float(i) / SAMPLE_RATE
			var env := sin(PI * t / note_dur)
			var s := (sin(TAU * f * t) * 0.45 + sin(TAU * f * 2.0 * t) * 0.12) * env
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
	if _skybox != null:
		_skybox.visible = _immersive
	# Immersion = deep rising sweep (world closing in); mixed = airy falling sweep.
	if _immersive:
		_push_sweep(220.0, 660.0, 0.35)
	else:
		_push_sweep(660.0, 220.0, 0.30)

# Scene handle: grab the chrome bar to translate the whole WorldRoot; hold it +
# pinch the other hand to scale the whole world about the handle.
func _update_scene_handle() -> void:
	if _scene_handle == null or _world_root == null:
		return

	# --- Acquire / release: the handle is grabbed manually (it is NOT a pickup
	# body) so it can only be held by an INDEX pinch that STARTS near the bar. ---
	if _handle_held_side == "":
		for side in ["left_hand", "right_hand"]:
			var pp: Variant = _index_pinch_point(side)
			if pp == null:
				continue
			# Don't steal a hand that is busy holding a course object.
			var h = _hand_handlers.get(side)
			if h != null and h.picked_up_body != null:
				continue
			if (pp as Vector3).distance_to(_scene_handle.global_position) <= HANDLE_GRAB_DIST:
				_handle_held_side = side
				_handle_prev_pinch = pp
				_world_scale_start_dist = 0.0
				_scene_handle.set_held(true)
				_pause_sim()  # freeze physics so it doesn't fight the world move
				_append_log("handle grabbed by %s" % side)
				break
		return

	# --- Held: confirm the holder still index-pinches, else release. ---
	var hold_pinch: Variant = _index_pinch_point(_handle_held_side)
	if hold_pinch == null:
		_release_handle()
		return

	# --- Optional scale: other hand index-pinches → scale world about handle. ---
	var other_side := "right_hand" if _handle_held_side == "left_hand" else "left_hand"
	var scaling := false
	if true:
		var other_pinch: Variant = _index_pinch_point(other_side)
		if other_pinch != null:
			var pinch_vec: Vector3 = other_pinch
			if _world_scale_start_dist <= 0.0:
				# Capture engage state ONCE; pivot frozen at the handle position.
				_world_scale_pivot = _scene_handle.global_position
				_world_scale_start_dist = max(pinch_vec.distance_to(_world_scale_pivot), 0.02)
				_world_scale_start_scale = _world_root.scale
			var d: float = pinch_vec.distance_to(_world_scale_pivot)
			var factor: float = d / _world_scale_start_dist
			var target: float = clampf(_world_scale_start_scale.x * factor, SCALE_MIN, SCALE_MAX)
			_scale_world_about(_world_scale_pivot, target)
			scaling = true
		else:
			_world_scale_start_dist = 0.0
	else:
		_world_scale_start_dist = 0.0

	# --- Translate: move BOTH handle and world by the holder pinch's delta. ---
	var cur: Vector3 = hold_pinch
	if scaling:
		_handle_prev_pinch = cur  # don't translate while scaling
	else:
		if _handle_prev_pinch != null:
			var delta: Vector3 = cur - (_handle_prev_pinch as Vector3)
			_scene_handle.global_position += delta
			_world_root.global_position += delta
		_handle_prev_pinch = cur

func _release_handle() -> void:
	_handle_held_side = ""
	_handle_prev_pinch = null
	_world_scale_start_dist = 0.0
	if _scene_handle != null:
		_scene_handle.set_held(false)
	_resume_sim()

# Freeze the simulation while the world handle is held: stop spawning, freeze
# every active cube in place (saving its velocity), and disable both pickup
# handlers so a stray pinch can't grab a course object mid-move.
func _pause_sim() -> void:
	if _sim_paused:
		return
	_sim_paused = true
	for c in _active_cubes:
		if is_instance_valid(c):
			c.set_meta("saved_lin", c.linear_velocity)
			c.set_meta("saved_ang", c.angular_velocity)
			c.freeze = true
	for side in _hand_handlers:
		_hand_handlers[side].process_mode = Node.PROCESS_MODE_DISABLED

func _resume_sim() -> void:
	if not _sim_paused:
		return
	_sim_paused = false
	for c in _active_cubes:
		if is_instance_valid(c):
			c.freeze = false
			c.linear_velocity = c.get_meta("saved_lin", Vector3.ZERO)
			c.angular_velocity = c.get_meta("saved_ang", Vector3.ZERO)
	for side in _hand_handlers:
		_hand_handlers[side].process_mode = Node.PROCESS_MODE_INHERIT

# Uniformly scale WorldRoot to `target` while keeping `pivot` fixed in space.
func _scale_world_about(pivot: Vector3, target: float) -> void:
	var cur: float = _world_root.scale.x
	if abs(cur) < 0.0001:
		return
	var ratio: float = target / cur
	var origin: Vector3 = _world_root.global_position
	_world_root.global_position = pivot + (origin - pivot) * ratio
	_world_root.scale = Vector3(target, target, target)

# Two-hand scaling: one hand holds a body (PickupHandler3D.picked_up_body),
# the other hand pinches. While both hold, inter-pinch distance scales the body.
func _update_two_hand_scale() -> void:
	var left_handler = _hand_handlers.get("left_hand")
	var right_handler = _hand_handlers.get("right_hand")
	if left_handler == null or right_handler == null:
		_end_scale()
		return

	# Identify which hand holds a scalable body and whether the other is pinching.
	var held: Node3D = null
	var holder_side := ""
	if left_handler.picked_up_body != null:
		held = left_handler.picked_up_body
		holder_side = "left_hand"
	elif right_handler.picked_up_body != null:
		held = right_handler.picked_up_body
		holder_side = "right_hand"

	if held == null:
		_end_scale()
		return

	# The scene handle is scaled by _update_scene_handle (scales the world, not
	# the handle itself) — don't let the per-object scaler grab it.
	if held == _scene_handle:
		_end_scale()
		return

	var other_side := "right_hand" if holder_side == "left_hand" else "left_hand"
	# Only an INDEX→thumb pinch on the free hand drives scaling.
	var other_pinch_pos: Variant = _index_pinch_point(other_side)
	if other_pinch_pos == null:
		_end_scale()
		return

	var pinch_vec: Vector3 = other_pinch_pos

	if _scaling_body != held:
		# Engage only if the free pinch starts near the held object. Capture the
		# reference distance ONCE (held object's position at engage), so a moving
		# held hand doesn't create a runaway feedback loop.
		var engage_dist: float = pinch_vec.distance_to(held.global_position)
		if engage_dist > SCALE_ENGAGE_DIST:
			_end_scale()
			return
		_scaling_body = held
		_scale_start_dist = max(engage_dist, 0.02)
		_scale_start_scale = held.scale
		_scale_pivot = held.global_position

	# Measure against the FROZEN pivot, not the live held position.
	var dist: float = pinch_vec.distance_to(_scale_pivot)
	var factor: float = dist / _scale_start_dist
	var target: float = clampf(_scale_start_scale.x * factor, SCALE_MIN, SCALE_MAX)
	held.scale = Vector3(target, target, target)

func _end_scale() -> void:
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
