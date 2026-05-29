extends Node3D

# Falling Cascade — physics-driven self-running demo for AVP/Godot immersive.
# All physics geometry built procedurally in _ready() to keep the .tscn minimal.
# Hand tracking pickup/throw courtesy of Marshall Nowak (Nocxr) — visionosxr_hand_tracking.

const SPAWN_INTERVAL := 0.35
const KILL_Y := -2.0
const MAX_CUBES := 25
const GLOBAL_AUDIO_RATE_HZ := 8.0
const SAMPLE_RATE := 44100.0
const FORWARD_Z := -1.3
const SPAWN_HEIGHT := 1.6
const PLATE_HEIGHT := 0.55

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

func _ready():
	var interface = XRServer.find_interface("visionOS")
	if interface and interface.initialize():
		print("[Cascade] visionOS XR initialized OK")
		_xr_ok = true
		var viewport = get_viewport()
		viewport.use_xr = true
		viewport.vrs_mode = Viewport.VRS_XR
	else:
		print("[Cascade] visionOS XR init FAILED")
	_write_log("Cascade boot — XR=%s" % ("OK" if _xr_ok else "FAILED"))
	_build_resources()
	_build_static_scene()
	_setup_audio()
	_setup_hands()
	_write_log("Static scene built; audio ready; hand tracking active")

func _build_resources():
	_physics_material = PhysicsMaterial.new()
	_physics_material.bounce = 0.38
	_physics_material.friction = 0.22

	# Collision flash light — warm-white point light repositioned on each impact.
	# Illuminates the plates/wall (PER_PIXEL shading); doesn't affect UNSHADED cubes.
	_flash_light = OmniLight3D.new()
	_flash_light.light_color = Color(1.0, 0.90, 0.60)
	_flash_light.light_energy = 0.0
	_flash_light.omni_range = 1.2
	_flash_light.omni_attenuation = 2.0
	add_child(_flash_light)

func _build_plate(y: float, z: float, x_rot_deg: float) -> void:
	# Grabbable surface: a frozen kinematic body that stays put on release.
	# Acts exactly like the old StaticBody3D for the cascade, but can be picked up.
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
	add_child(plate)

func _build_static_scene():
	# Tier 1 — main catch plate.
	_build_plate(PLATE_HEIGHT, FORWARD_Z, -22.0)
	# Tier 2 — below and slightly forward; catches overflow for coin-pusher feel.
	_build_plate(PLATE_HEIGHT - 0.6, FORWARD_Z - 0.35, 15.0)

	# Side deflector — vertical wall to the right, deflects cubes leftward.
	# Also grabbable (frozen kinematic, stays put on release).
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
	add_child(wall)

	# Kill plane — Area3D that despawns escaped cubes.
	var killer := Area3D.new()
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

# Build one XRController3D + PickupHandler3D for each hand and attach to XROrigin3D.
# PickupHandler3D (from Marshall Nowak / Nocxr) handles pinch detection, finger-tip
# anchoring, and the pick-up/throw lifecycle via XRHandTracker joint data.
func _setup_hands() -> void:
	var xr_origin := $XROrigin3D
	for side in ["left_hand", "right_hand"]:
		var controller := XRController3D.new()
		controller.tracker = side

		# CollisionShape3D must be added as a child BEFORE the handler enters the tree
		# so PickupHandler3D._ready() can call _update_detect_range() successfully.
		var handler := PickupHandler3D.new()
		handler.detect_range = 0.3   # Marshall's proven value — forgiving enough to grab fast-moving cubes
		handler.follow_fingertips = true
		handler.hold_while_hand_tracking_uncertain = true

		var cs := CollisionShape3D.new()
		cs.name = "CollisionShape3D"  # PickupHandler3D looks up $CollisionShape3D by this exact name
		var sphere := SphereShape3D.new()
		sphere.radius = 0.3
		cs.shape = sphere
		handler.add_child(cs)

		controller.add_child(handler)
		xr_origin.add_child(controller)

func _process(delta: float):
	_frame_count += 1
	_log_timer += delta
	_spawn_timer += delta
	if _spawn_timer >= SPAWN_INTERVAL:
		_spawn_timer = 0.0
		if _active_cubes.size() < MAX_CUBES:
			_spawn_cube()
	if _log_timer >= 5.0:
		_log_timer = 0.0
		_append_log("frames=%d active=%d collisions=%d" % [_frame_count, _active_cubes.size(), _collision_count])
	# Decay collision flash light.
	if _flash_energy > 0.0:
		_flash_energy = move_toward(_flash_energy, 0.0, delta * 22.0)
		_flash_light.light_energy = _flash_energy

func _spawn_cube():
	var size: float = randf_range(0.06, 0.12)
	var color: Color = CUBE_PALETTE[randi() % CUBE_PALETTE.size()]
	var emission_e: float = randf_range(1.2, 3.5)

	# PickupAbleBody3D extends RigidBody3D — all existing physics properties still apply.
	# The class adds pinch-grab detection, snap-to-hand, and throw-velocity on release.
	var cube := PickupAbleBody3D.new()
	cube.physics_material_override = _physics_material
	# Scale mass with volume so small cubes are bouncier, big ones feel heavy.
	cube.mass = max(0.08, size * size * size * 400.0)
	cube.linear_damp = 0.12
	cube.angular_damp = 0.30
	cube.contact_monitor = true
	cube.max_contacts_reported = 3

	# Per-cube mesh + material (unique size and colour).
	var mi := MeshInstance3D.new()
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

	# Per-cube collision shape matching mesh size.
	var cs := CollisionShape3D.new()
	var sh := BoxShape3D.new()
	sh.size = Vector3(size, size, size)
	cs.shape = sh
	cube.add_child(cs)

	# Per-cube particle trail — colour-matched, 12 quads, 0.4 s lifetime.
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

	cube.position = Vector3(
		randf_range(-0.15, 0.15),
		SPAWN_HEIGHT,
		FORWARD_Z + randf_range(-0.05, 0.05)
	)
	cube.angular_velocity = Vector3(
		randf_range(-2.5, 2.5),
		randf_range(-2.5, 2.5),
		randf_range(-2.5, 2.5)
	)
	cube.add_to_group("cube")
	cube.body_entered.connect(_on_cube_collision.bind(cube))
	add_child(cube)
	_active_cubes.append(cube)

func _on_cube_collision(other_body: Node3D, cube: RigidBody3D):
	_collision_count += 1
	var t := Time.get_ticks_msec() / 1000.0
	if t - _last_global_audio < 1.0 / GLOBAL_AUDIO_RATE_HZ:
		return
	_last_global_audio = t
	_shared_audio.position = cube.global_position
	# Flash light at impact point — illuminates plates/wall (PER_PIXEL shading only).
	_flash_light.position = cube.global_position
	_flash_energy = 3.5
	if other_body.is_in_group("cube"):
		# Cube-on-cube: high-frequency bright tink.
		_push_chime(randf_range(700.0, 1500.0), 0.036, false)
	else:
		# Cube-on-plate/wall (group "surface"): resonant chime with octave harmonic.
		_push_chime(randf_range(260.0, 700.0), 0.10, true)

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
			# Plate hit: fundamental + octave for a richer, resonant chime.
			s = (sin(TAU * freq * t) * 0.50 + sin(TAU * freq * 2.0 * t) * 0.18) * env
		else:
			# Cube hit: clean sine tink — short, bright, higher register.
			s = sin(TAU * freq * t) * env * 0.42
		_audio_playback.push_frame(Vector2(s, s))

func _on_kill_entered(body: Node3D):
	# Only despawn falling cubes — never the grabbable plates/wall.
	if body.is_in_group("cube"):
		_active_cubes.erase(body)
		body.queue_free()

func _write_log(msg: String):
	var f := FileAccess.open("user://xr_diag.txt", FileAccess.WRITE)
	if f:
		f.store_string(msg + "\n")
		f.close()
		print("[Cascade] " + msg)

func _append_log(msg: String):
	var f := FileAccess.open("user://xr_diag.txt", FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open("user://xr_diag.txt", FileAccess.WRITE)
	if f:
		f.seek_end(0)
		f.store_string(msg + "\n")
		f.close()
		print("[Cascade] " + msg)
