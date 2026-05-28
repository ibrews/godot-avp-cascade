extends Node3D

# Falling Cascade — physics-driven self-running demo for AVP/Godot immersive.
# All physics geometry built procedurally in _ready() to keep the .tscn minimal.

const SPAWN_INTERVAL := 0.35
const KILL_Y := -2.0
const MAX_CUBES := 25
const GLOBAL_AUDIO_RATE_HZ := 6.0
const SAMPLE_RATE := 44100.0
const FORWARD_Z := -1.3
const SPAWN_HEIGHT := 1.6
const PLATE_HEIGHT := 0.55

var _xr_ok := false
var _frame_count := 0
var _log_timer := 0.0
var _spawn_timer := 0.0
var _last_global_audio := 0.0
var _cube_mesh: BoxMesh
var _cube_material: StandardMaterial3D
var _physics_material: PhysicsMaterial
var _particle_material: ParticleProcessMaterial
var _particle_mesh: QuadMesh
var _shared_audio: AudioStreamPlayer3D
var _audio_playback: AudioStreamGeneratorPlayback
var _active_cubes: Array = []
var _collision_count := 0
var _music_player: AudioStreamPlayer
var _music_playback: AudioStreamGeneratorPlayback
var _music_phase := 0.0
var _lfo_phase := 0.0

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
	_write_log("Static scene built; audio ready")

func _build_resources():
	_cube_mesh = BoxMesh.new()
	_cube_mesh.size = Vector3(0.09, 0.09, 0.09)

	_cube_material = StandardMaterial3D.new()
	_cube_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_cube_material.albedo_color = Color(1.0, 0.55, 0.1, 1.0)
	_cube_material.emission_enabled = true
	_cube_material.emission = Color(1.0, 0.65, 0.15, 1.0)
	_cube_material.emission_energy_multiplier = 1.5

	_physics_material = PhysicsMaterial.new()
	_physics_material.bounce = 0.35
	_physics_material.friction = 0.25

	# Shared particle process material — all cube trails reference this instance.
	_particle_material = ParticleProcessMaterial.new()
	_particle_material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	_particle_material.emission_sphere_radius = 0.02
	_particle_material.initial_velocity_min = 0.05
	_particle_material.initial_velocity_max = 0.2
	_particle_material.gravity = Vector3(0.0, -0.3, 0.0)
	_particle_material.scale_min = 0.3
	_particle_material.scale_max = 0.7
	_particle_material.color = Color(1.0, 0.65, 0.15, 0.9)

	_particle_mesh = QuadMesh.new()
	_particle_mesh.size = Vector2(0.018, 0.018)
	var pm := StandardMaterial3D.new()
	pm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	pm.albedo_color = Color(1.0, 0.7, 0.2, 0.85)
	pm.emission_enabled = true
	pm.emission = Color(1.0, 0.6, 0.1, 1.0)
	pm.emission_energy_multiplier = 2.0
	pm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_particle_mesh.material = pm

func _build_plate(y: float, z: float, x_rot_deg: float) -> void:
	var plate := StaticBody3D.new()
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
	plate_mat.albedo_color = Color(0.35, 0.4, 0.55, 1.0)
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
	var wall := StaticBody3D.new()
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
	wmat.albedo_color = Color(0.25, 0.45, 0.7, 1.0)
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

	# Music bed — 180 Hz sine + 0.1 Hz LFO, −18 dB so chimes stay foreground.
	_music_player = AudioStreamPlayer.new()
	var music_gen := AudioStreamGenerator.new()
	music_gen.mix_rate = SAMPLE_RATE
	music_gen.buffer_length = 0.5
	_music_player.stream = music_gen
	_music_player.volume_db = -18.0
	add_child(_music_player)
	_music_player.play()
	_music_playback = _music_player.get_stream_playback()

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
	_push_music_frames()

func _spawn_cube():
	var cube := RigidBody3D.new()
	cube.physics_material_override = _physics_material
	cube.mass = 0.2
	cube.linear_damp = 0.15
	cube.angular_damp = 0.35
	cube.contact_monitor = true
	cube.max_contacts_reported = 2
	var mi := MeshInstance3D.new()
	mi.mesh = _cube_mesh
	mi.material_override = _cube_material
	cube.add_child(mi)
	var cs := CollisionShape3D.new()
	var sh := BoxShape3D.new()
	sh.size = Vector3(0.09, 0.09, 0.09)
	cs.shape = sh
	cube.add_child(cs)
	# Particle trail — 8 quads, 0.3s lifetime, shared material/mesh.
	var particles := GPUParticles3D.new()
	particles.amount = 8
	particles.lifetime = 0.3
	particles.explosiveness = 0.0
	particles.process_material = _particle_material
	particles.draw_pass_1 = _particle_mesh
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
	# Bind cube so the collision handler knows which node to position audio at.
	cube.body_entered.connect(_on_cube_collision.bind(cube))
	add_child(cube)
	_active_cubes.append(cube)

func _on_cube_collision(_other_body, cube: RigidBody3D):
	_collision_count += 1
	var t = Time.get_ticks_msec() / 1000.0
	if t - _last_global_audio < 1.0 / GLOBAL_AUDIO_RATE_HZ:
		return
	_last_global_audio = t
	_shared_audio.position = cube.global_position
	_push_chime(440.0 + randf_range(-60.0, 220.0), 0.08)

func _push_chime(freq: float, duration: float):
	if _audio_playback == null:
		return
	var n = int(SAMPLE_RATE * duration)
	var to_fill = min(n, _audio_playback.get_frames_available())
	for i in range(to_fill):
		var t = float(i) / SAMPLE_RATE
		var env = sin(PI * t / duration)
		var s = sin(TAU * freq * t) * env * 0.55
		_audio_playback.push_frame(Vector2(s, s))

func _push_music_frames():
	if _music_playback == null:
		return
	var to_fill = _music_playback.get_frames_available()
	for i in range(to_fill):
		var amp = 0.7 * (1.0 + 0.3 * sin(_lfo_phase))
		var s = amp * sin(_music_phase)
		_music_playback.push_frame(Vector2(s, s))
		_music_phase += TAU * 180.0 / SAMPLE_RATE
		_lfo_phase += TAU * 0.1 / SAMPLE_RATE

func _on_kill_entered(body):
	if body is RigidBody3D:
		_active_cubes.erase(body)
		body.queue_free()

func _write_log(msg: String):
	var f = FileAccess.open("user://xr_diag.txt", FileAccess.WRITE)
	if f:
		f.store_string(msg + "\n")
		f.close()
		print("[Cascade] " + msg)

func _append_log(msg: String):
	var f = FileAccess.open("user://xr_diag.txt", FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open("user://xr_diag.txt", FileAccess.WRITE)
	if f:
		f.seek_end(0)
		f.store_string(msg + "\n")
		f.close()
		print("[Cascade] " + msg)
