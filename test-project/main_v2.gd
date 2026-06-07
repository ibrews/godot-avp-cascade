extends Node3D

# Cascade Countdown — a hand-tracked physics arcade for Apple Vision Pro. Route falling cubes
# from a grabbable spawn emitter, through grabbable obstacles, into a grabbable goal portal
# that scores them. ALL geometry is built procedurally in _ready() (the .tscn holds only the XR
# rig), so the whole game reads top-to-bottom in this one script. Section banners below divide it.
# Hand-tracking pickup/throw courtesy of Marshall Nowak (Nocxr) — see pickup/.
#
# Pinch gestures (each also a poke button on the control panel):
#   index→thumb  = grab / throw           middle→thumb = cycle hands (mesh / both / real arms)
#   ring→thumb   = reset everything       pinky→thumb  = toggle sky (immersion / passthrough)

# Shown on the in-world info panel; bump on meaningful releases. (Full changelog lives in git log.)
const APP_VERSION := "v0.9.34-polish"

# Sky materialize/dissolve transition length (seconds). The shader "dissolve" uniform
# tween AND the dissolve sound are BOTH driven from this one constant, so they always
# match — change it here and both follow. See _toggle_immersion / _push_dissolve_texture.
const SKY_DISSOLVE_SEC := 0.8

# --- Cube-spawn RHYTHM ------------------------------------------------------
# Cube spawns are quantised to a tempo grid so the cascade SOUNDS musical: each cube
# plays its note exactly on a beat subdivision, locked to the 60 BPM music bed
# (_bed_sample uses beat_dur = 1.0 s). At 60 BPM one beat = 1.000 s, so "N spawns per
# second" == N subdivisions per beat:
#   SPAWN_SUBDIV 1 → quarters (1/s)  2 → eighths (2/s)  3 → triplets (3/s)  4 → sixteenths (4/s)
# All are subdivisions of the SAME beat, so any value stays locked in 4/4 at one tempo.
# Default 2 = a steady eighth-note pulse (musical; ~matches the old 0.55 s cadence).
const SPAWN_BPM := 60.0
const SPAWN_BEAT_SEC := 60.0 / SPAWN_BPM   # 1.0 s per beat at 60 BPM
const BEATS_PER_BAR := 4                    # 4/4
const SPAWN_SUBDIV := 2                      # spawns per beat → 1..4 = 1..4 spawns/sec at 60 BPM

# --- SONG (deterministic music-generator) -----------------------------------
# A "song" plays the SAME every run: a fixed sequencer drives cube spawns on the beat grid,
# and each cube's note is fixed by the tables below (notes play ON SPAWN, so the music is
# reproducible no matter where cubes physically land). SONG_ARRANGEMENT names sections in
# order (intro/verse/chorus/…/outro); each section is a list of bars; each bar is
# SONG_STEPS_PER_BAR steps. A step is: -1 = rest, an int = one cube on that scale degree, or
# an Array of ints = a chord (that many cubes at once → "how many come out at once"). Degrees
# index C-minor-pentatonic (0=C,1=Eb,2=F,3=G,4=Bb,5=C′…; _bass_freq wraps octaves), raised
# SONG_LEAD_DEGREE_OFFSET into a lead register. Edit freely to compose a song.
# SONG_ENABLED=false → fall back to the plain SPAWN_SUBDIV pulse.
const SONG_ENABLED := true
const SONG_STEPS_PER_BEAT := 4               # grid resolution: 4 = sixteenth-note steps
const SONG_STEPS_PER_BAR := SONG_STEPS_PER_BEAT * BEATS_PER_BAR   # 16 at 4×4/4
const SONG_LEAD_DEGREE_OFFSET := 10          # +2 pentatonic octaves → melodic lead register
# When true, the random collision chimes are silenced so ONLY the deterministic song sounds
# (fully reproducible "concert" mode). Default false keeps the lively impact texture too.
const SONG_PURE_MODE := false
# Each section is an Array of bars; each bar is SONG_STEPS_PER_BAR (16) steps (see above).
const SONG_SECTIONS := {
	"intro": [
		[0,-1,-1,-1,  2,-1,-1,-1,  3,-1,-1,-1,  4,-1,-1,-1],
	],
	"verse": [
		[0,-1,2,-1,  3,-1,2,-1,  4,-1,3,-1,  2,-1,0,-1],
		[0,-1,2,-1,  3,-1,4,-1,  5,-1,4,-1,  3,-1,2,-1],
	],
	"chorus": [
		[[0,3],-1,4,-1,  3,-1,4,-1,  [2,5],-1,4,-1,  3,-1,2,-1],
		[[0,4],-1,4,3,  4,-1,5,-1,  [3,5],-1,4,-1,  2,-1,0,-1],
	],
	"bridge": [
		[3,-1,-1,4,  -1,-1,5,-1,  4,-1,-1,3,  -1,-1,2,-1],
	],
	"outro": [
		[4,-1,-1,-1,  3,-1,-1,-1,  2,-1,-1,-1,  0,-1,-1,-1],
	],
}
const SONG_ARRANGEMENT := ["intro", "verse", "chorus", "verse", "chorus", "bridge", "chorus", "outro"]
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
# Longevity is rewarded SUPERLINEARLY so the obvious "tight funnel → straight shot to
# the goal" strategy (a cube that lives ~1 s) scores far less than a cube kept alive
# and bouncing around the course. The per-second rate ramps up the longer a cube
# survives; LONGEVITY_RAMP_SEC is roughly the age at which the rate doubles, and
# LONGEVITY_MAX_SEC caps the effective age so a single trapped cube can't run away
# with the whole round. See _on_portal_entered for the curve.
const LONGEVITY_RAMP_SEC := 6.0
const LONGEVITY_MAX_SEC := 15.0
const SURFACE_BASE := 5
const CHAIN_WINDOW_MS := 1500
const CHAIN_MAX := 8
# Mix bonus: scoring a goal of the OPPOSITE type to the last one (cube after sphere, or
# sphere after cube) adds this flat bonus. Encourages landing BOTH cubes and spheres
# rather than funneling everything through the bubble transmuter into spheres.
const MIX_BONUS := 25

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
var sim_cursor_world: Variant = null  # set by simulator_input.gd; replaces right-hand index tip
var _log_timer := 0.0
var _beat_clock := 0.0       # seconds on the spawn tempo grid; reset to 0 at round start to lock to the bed
var _last_spawn_step := -1   # last grid subdivision index we spawned on (edge-detect)
var _song_bars: Array = []   # SONG_ARRANGEMENT flattened to an ordered list of bars (built at startup)
var _last_global_audio := 0.0
var _physics_material: PhysicsMaterial
var _shared_audio: AudioStreamPlayer3D
var _audio_playback: AudioStreamGeneratorPlayback
# Music bed (active only during a 30 s round). DEDICATED player + generator, NOT the
# shared 3D one: the bed is a continuous loop fed every frame, and time-slicing the
# 0.6 s shared buffer would starve the falling-cube chimes (and the bed shouldn't be
# spatialised at the last cube-collision point). So music gets its own non-positional
# AudioStreamPlayer with its own generator/playback. See KB godot-avp-procedural-audio.
var _bed_audio: AudioStreamPlayer
var _bed_playback: AudioStreamGeneratorPlayback
var _bed_time := 0.0
# ONE key for everything melodic — C minor pentatonic. The bass riff, the urgency
# tones AND the random cube-collision chimes all snap to these notes so the chaotic
# impacts harmonise into a tune over the bed instead of clashing.
var _scale_freqs: Array = []   # sorted scale frequencies (octaves 2..6) for snapping
# 8-beat looping bass riff as pentatonic scale-degree indices (0=C 1=Eb 2=F 3=G 4=Bb,
# 5=C up an octave …). Catchy + a little goofy so the cube hits land on top of it.
const BASS_PATTERN := [0, 0, 2, 4, 3, 4, 1, 0]
var _flash_light: OmniLight3D
var _flash_energy := 0.0
var _active_cubes: Array = []
var _collision_count := 0
var _hand_drivers: Array = []
var _hand_mesh_visible := true
var _gesture_cooldown := 0.0
# Master switch for the pinch GESTURES (middle=hands, ring=reset, pinky=sky). When a
# user keeps triggering them by accident they can turn recognition off via the gesture
# panel's "Gestures" button. Index-pinch grab is NEVER gated by this.
var _gestures_enabled := true
# Generic poke-button registry for the gesture panel: each entry
# {node, face, mat, label, cb (Callable), cooldown}. _update_poke_buttons drives them.
var _poke_buttons: Array = []
var _gesture_panel: Node3D
var _gestures_toggle_label: Label3D
var _gestures_toggle_mat: StandardMaterial3D
var _best_panel_label: Label3D   # bigger "BEST" readout on the gesture panel
# FPS / grab diagnostics: count physics vs render frames to confirm the 90 Hz display /
# 60 Hz physics beat, and log held / double-grab state per 5 s window (see _grab_diag).
var _phys_frame_count := 0
var _last_proc_log := 0
var _last_phys_log := 0

# --- Sandbox state ---
var _emitter: SpawnEmitter3D
var _portal: GoalPortal3D
var _spinners: Array = []      # [{node: PickupAbleBody3D, axis: Vector3, rate: float}] — spun in _physics_process when not held
var _grabbables: Array = []            # everything reset() returns home
var _home_transforms: Dictionary = {}  # instance_id → Transform3D
var _hand_handlers: Dictionary = {}    # side → PickupHandler3D

# Two-hand scaling state (glued-pinch: both index pinches lock to world points, so scale +
# rotation + translation all fall out of how the two anchors move; see _update_two_hand_scale).
var _scale_active := false
var _scale_is_world := false
var _scale_target: Node3D = null
var _scale_lost_frames := 0   # debounce: brief one-pinch flicker shouldn't end a scale
const SCALE_END_GRACE := 8    # frames a pinch may be missing before the scale truly ends (was 4; bumped for occlusion robustness)
var _scale_A0 := Vector3.ZERO   # world pinch points (L,R) at engage — object case
var _scale_B0 := Vector3.ZERO
var _scale_WA := Vector3.ZERO   # world points under the pinches at engage — world case
var _scale_WB := Vector3.ZERO
var _scale_T0: Transform3D = Transform3D.IDENTITY  # target object transform at engage
# Object-scale smoothing/spike-rejection. The object branch writes the transform raw
# from the live pinches every frame, and its position term is multiplied by the scale
# factor — so a single bad pinch sample (or jittery rotation) gets AMPLIFIED once the
# object is much bigger, snapping it for a frame. Mirror the held-body fix: low-pass
# the applied transform and clamp the per-frame origin step to reject spikes.
var _scale_filt_ready := false
var _scale_filt_origin := Vector3.ZERO
var _scale_filt_basis := Basis.IDENTITY
const SCALE_FOLLOW_ALPHA := 0.5        # 0..1 per frame ease toward the raw target (1 = no smoothing)
const SCALE_MAX_ORIGIN_STEP := 0.6     # metres/frame cap — real moves pass, teleports clamped
var _two_hand_world_active := false  # suppress single-hand handle drag while two-handing the world
var _prev_grabbed := {"left_hand": false, "right_hand": false}  # for the grab "thunk" SFX

# Per-hand index-pinch hysteresis (true once pinched, stays true until clearly
# released — kills the grab/release flicker that made grabbing stutter).
var _index_pinch_state := {"left_hand": false, "right_hand": false}
const PINCH_START := 0.024   # must close to here to BEGIN an index pinch (firm pinch)
const PINCH_END := 0.052     # must open past here to END it (hysteresis gap)

# Scene handle: grab the chrome handlebar to move/scale the whole course.
# Manual grab (the handle is a plain Node3D, NOT a pickup body) so the
# PickupHandler can never auto-grab it by proximity near the face.
const HANDLE_GRAB_DIST := 0.09   # pinch must start this close to the handle (on-bar only)
var _world_root: Node3D            # all course objects + spawned cubes live here
var _scene_handle: SceneHandle3D
var _handle_held_side := ""        # "", "left_hand", or "right_hand"
var _handle_prev_pinch = null      # Vector3 or null; holder hand's last pinch pos
var _handle_filt_delta := Vector3.ZERO   # smoothed world-drag delta (a little dampening)
const HANDLE_DAMP_ALPHA := 0.45    # 0..1 — lower = more dampening on the world-handle drag
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
var _sky_mat: ShaderMaterial  # dissolve shader; "dissolve" param 0→1 = mixed→immersive
var _glow_tex: GradientTexture2D  # cached soft radial gradient for cube bloom halos

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
# Type of the last object scored in the goal: -1 none yet, 0 cube, 1 sphere. Drives the
# MIX_BONUS (awarded when the next goal is the opposite type). Reset at round start.
var _last_goal_sphere := -1
# All six buttons now live on the unified control panel (_build_control_panel) and share
# the poke-button registry. These handles point at the relevant registry entries' label/
# material/node so the bespoke per-frame logic (round countdown/pulse + label refreshers)
# keeps working. The START node handle is also used for the round-end burst position.
var _start_button: Node3D
var _start_button_label: Label3D
var _start_button_mat: StandardMaterial3D
var _start_cooldown := 0.0
var _http: HTTPRequest

# HANDS-mode button (virtual GLTF mesh ↔ real Persona arms). Writes user://upper_limb.txt
# ("visible"/"hidden"); the recompiled visionOS engine polls that file (~0.5s) and applies
# it to SwiftUI .upperLimbVisibility live — no relaunch.
var _arms_button_label: Label3D
var _arms_button_mat: StandardMaterial3D

# Mute toggle (sound on/off).
var _muted := false
var _mute_button_label: Label3D
var _mute_button_mat: StandardMaterial3D
var _real_arms_visible := false

# --- In-world live leaderboard panel (grabbable, like the info panel) ---
const LB_REFRESH_SEC := 15.0
const LB_ROWS := 8
var _lb_rows_label: Label3D
var _lb_http: HTTPRequest
var _lb_refresh_t := 0.0
# Top online score from the last leaderboard fetch (0 if unknown/offline). Used at
# round end to decide the BIGGER "you beat the WORLD" celebration vs the personal best.
var _lb_top_score := 0

# Self-destruct buttons: each entry {panel, button}. Poking a panel's red button
# dissolves the panel (shard burst); a reset (ring-pinch) brings them all back.
var _panels: Array = []
var _destruct_cooldown := 0.0
# #5: smallest grab collider edge — tiny objects get an inflated grab box so they
# stay easy to pick up (visual mesh unchanged).
const MIN_GRAB_SIDE := 0.10

# ============================================================================
# LIFECYCLE & XR INIT
# ============================================================================
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
		# Mixed-mode alpha-edge blockiness is UNRESOLVED. Ruled out from GDScript:
		# MSAA/SSAA crash boot, VRS_DISABLED renders nothing, FXAA does nothing, no glow.
		# Engine recompile with isFoveationEnabled=false DISPROVED foveation as the cause
		# (halos unchanged). Parked pending an Epic conversation; immersive mode is the
		# practical workaround (opaque sky ⇒ no passthrough composite). See KB.
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
	_load_arms_pref()
	_build_control_panel()   # ONE panel: HANDS/START/MUTE/GESTURES/SKY/RESET + BEST readout
	_build_leaderboard_panel()
	_build_instructions_panel()
	_fetch_leaderboard()
	# Launch into immersive (opaque sky) by default, not mixed.
	_immersive = true
	if _skybox != null:
		_skybox.visible = true
	if _sky_mat != null:
		_sky_mat.set_shader_parameter("dissolve", 1.0)  # fully resolved = occludes
	_write_log("Sandbox built; audio ready; hand tracking active")
	var sim_input := preload("res://simulator_input.gd").new()
	sim_input.name = "SimulatorInput"
	add_child(sim_input)

# ============================================================================
# SCENE CONSTRUCTION — all geometry built procedurally here (no .tscn content)
# ============================================================================
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

# A continuously-spinning bar bumper, built as a grabbable PickupAbleBody3D. It spins in
# _physics_process (so the kinematic move is solver-aligned and bats cubes cleanly, not the
# render-frame teleport that flung them before) but ONLY while NOT held — grab it and it
# freezes in your hand, release it and it resumes. The bar's long axis (X) is perpendicular
# to its spin axis so it actually sweeps. No decorative hub: place it so it rotates from the
# centre of existing geometry (a blue peg) and that cylinder reads as the axle. Group
# "obstacle" so cube hits score; LAYER_SOLID so cubes bounce off it and the hand can grab it.
func _build_spinner(pos: Vector3, axis: Vector3, rate: float, color: Color) -> void:
	var bar := PickupAbleBody3D.new()
	bar.collision_layer = LAYER_SOLID
	bar.collision_mask = LAYER_SOLID
	bar.freeze = true
	bar.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	bar.freeze_on_release = true
	bar.add_to_group("obstacle")
	bar.physics_material_override = _physics_material
	bar.position = pos
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 1.0
	# Paddle bar (long axis = X, perpendicular to the spin axis so it actually sweeps).
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.40, 0.03, 0.05)
	mi.mesh = bm
	mi.material_override = mat
	bar.add_child(mi)
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(0.40, 0.03, 0.05)
	cs.shape = bs
	bar.add_child(cs)
	# No decorative axle — the spinner is meant to be placed so it rotates from the centre
	# of EXISTING course geometry (e.g. a blue peg cylinder), which reads as the axle.
	_world_root.add_child(bar)
	_register_grabbable(bar)
	_spinners.append({"node": bar, "axis": axis.normalized(), "rate": rate})

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
	# DISSOLVE shader: OPAQUE pipeline (no transparency render_mode) so at dissolve=1 it
	# writes solid pixels and FULLY OCCLUDES passthrough (= real immersive). The animated
	# "dissolve" uniform discards a growing fraction of blocky cells, so the sky cells in
	# (resolve) / out (dissolve) gradually — like the hand shards — without ever being a
	# translucent material (which does NOT occlude on the visionOS composite).
	var sky_shader := Shader.new()
	sky_shader.code = """
shader_type spatial;
render_mode unshaded, cull_front;
uniform float dissolve : hint_range(0.0, 1.0) = 1.0;
uniform vec3 sky_color : source_color = vec3(0.06, 0.09, 0.18);
uniform vec3 sky_emis : source_color = vec3(0.10, 0.16, 0.32);
float hash(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }
void fragment() {
	float n = hash(floor(UV * 56.0));
	if (n > dissolve) discard;
	ALBEDO = sky_color;
	EMISSION = sky_emis * 0.8;
}
"""
	_sky_mat = ShaderMaterial.new()
	_sky_mat.shader = sky_shader
	_sky_mat.set_shader_parameter("dissolve", 1.0)
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

	# Two spinning bar bumpers — paddles on axle hubs that rotate continuously, batting
	# cubes around and keeping them in play (longevity ↑, anti-funnel). Each spins on a
	# DIFFERENT axis, and the bar's long axis (X) is perpendicular to its spin axis so it
	# actually sweeps. Grabbable: freeze in your hand, resume on release (see _build_spinner).
	# Orange paddle mounted on the LEFT blue peg (same centre) so it rotates from inside that
	# cylinder — the peg reads as its axle (spins about Z, the peg's own axis). Meaningful
	# intersection with existing geometry, per request.
	_build_spinner(Vector3(-0.2, SPAWN_HEIGHT - 0.45, FORWARD_Z), Vector3(0, 0, 1), 2.0,
		Color(0.95, 0.45, 0.20))   # vertical paddle, sweeps the XY plane (faces user)
	# Pink blade sits directly under the bubble transmuter (same x,z as the bubble at 0.25 /
	# FORWARD_Z; height unchanged) so cubes dropping out of the bubble meet it.
	_build_spinner(Vector3(0.25, PLATE_HEIGHT + 0.28, FORWARD_Z), Vector3(0, 1, 0), 2.4,
		Color(0.95, 0.30, 0.55))   # horizontal blade, sweeps the XZ plane (helicopter-style)

	# Prism wedge splitter — a triangular ridge high-centre that splits the falling
	# stream left/right so cubes scatter instead of dropping in a single column.
	var prism_mesh := PrismMesh.new()
	prism_mesh.size = Vector3(0.34, 0.18, 0.22)
	var prism_shape := ConvexPolygonShape3D.new()
	prism_shape.points = PackedVector3Array([
		Vector3(-0.17, -0.09, -0.11), Vector3(0.17, -0.09, -0.11),
		Vector3(-0.17, -0.09, 0.11), Vector3(0.17, -0.09, 0.11),
		Vector3(0.0, 0.09, -0.11), Vector3(0.0, 0.09, 0.11),
	])
	_build_obstacle(prism_mesh, prism_shape,
		Transform3D(Basis(), Vector3(-0.05, SPAWN_HEIGHT - 0.75, FORWARD_Z)),
		Color(0.40, 0.75, 0.55))

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

# ============================================================================
# SETUP — audio, hand tracking, info panel
# ============================================================================
func _setup_audio():
	_shared_audio = AudioStreamPlayer3D.new()
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = SAMPLE_RATE
	gen.buffer_length = 1.0  # room for the one-shot score fanfare (~0.55s) AND the high-score crowd cheer (up to ~0.95s)
	_shared_audio.stream = gen
	_shared_audio.volume_db = -3.0
	_shared_audio.max_distance = 5.0
	_shared_audio.unit_size = 1.0
	add_child(_shared_audio)
	_shared_audio.play()
	_audio_playback = _shared_audio.get_stream_playback()

	# Dedicated music-bed player (see _bed_audio note). Non-positional so the loop sits
	# evenly in both ears; fed every frame from _update_music_bed only while a round runs.
	_bed_audio = AudioStreamPlayer.new()
	var bed_gen := AudioStreamGenerator.new()
	bed_gen.mix_rate = SAMPLE_RATE
	bed_gen.buffer_length = 0.5
	_bed_audio.stream = bed_gen
	_bed_audio.volume_db = -10.0
	add_child(_bed_audio)
	_bed_audio.play()
	_bed_playback = _bed_audio.get_stream_playback()
	_build_scale_freqs()
	_build_song()

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
	var title := _panel_label("Cascade Countdown", 46, Color(1.0, 1.0, 1.0, 1.0), 10)
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
	_attach_destruct_button(root, Vector3(0.0, center_y - size_y * 0.5 - 0.018, 0.0))

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

# ============================================================================
# MAIN LOOP
# ============================================================================
func _physics_process(delta: float) -> void:
	_phys_frame_count += 1
	# Spin the bar bumpers in the physics step (solver-aligned kinematic move → cubes are
	# batted cleanly). Skip any spinner that's currently GRABBED: the pickup handler owns its
	# transform then, so it freezes in the hand and resumes spinning on release.
	for s in _spinners:
		var bar: PickupAbleBody3D = s["node"]
		if is_instance_valid(bar) and not bar.is_picked_up():
			bar.rotate(s["axis"], s["rate"] * delta)

func _process(delta: float):
	_frame_count += 1
	_log_timer += delta
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
			# Master switch: when gestures are disabled (panel toggle), middle/ring/
			# pinky no-op. Index-pinch grab is unaffected (it's not in this block).
			if not _gestures_enabled:
				continue
			if pinched == 20:        # ring → reset
				_reset_sandbox()
				_gesture_cooldown = 1.0
				break
			elif pinched == 15:      # middle → cycle hand visibility (mesh → both → real)
				# Was a raw toggle of the mesh, which could leave BOTH mesh and real arms
				# off → empty space (playtesters kept hitting this). Now shares the same
				# 3-state cycle as the HANDS button, which can never show nothing.
				_cycle_hands_mode()
				_gesture_cooldown = 0.8
				break
			elif pinched == 25:      # pinky → toggle immersion / passthrough
				_toggle_immersion()
				_gesture_cooldown = 0.8
				break

	_update_info_panel(delta)
	_update_timer(delta)
	_update_music_bed(delta)
	_update_poke_buttons(delta)
	_update_leaderboard(delta)
	_update_destruct(delta)
	_update_grab_sound()
	_update_two_hand_scale()  # both hands pinch → scale world (handle) or held object
	_update_scene_handle()  # World handle now drags the XROrigin (the user), not the
	# world — zero physics bodies move, so no freeze and no jitter. World-scale (scaling
	# the origin about the pinch midpoint) is the next step; per-object scale stays off.

	# Beat-locked spawning on the tempo grid (locked to the 60 BPM bed). SONG_ENABLED → a
	# deterministic sequencer reads the SONG_* tables and spawns per step (the music
	# generator); else → the plain SPAWN_SUBDIV pulse. Either way the note plays on spawn.
	_beat_clock += delta
	var grid_res: int = SONG_STEPS_PER_BEAT if SONG_ENABLED else SPAWN_SUBDIV
	var step_dur: float = SPAWN_BEAT_SEC / float(max(grid_res, 1))
	var grid_step: int = int(floor(_beat_clock / step_dur))
	if grid_step != _last_spawn_step:
		_last_spawn_step = grid_step
		if SONG_ENABLED:
			_play_song_step(grid_step)
		elif _active_cubes.size() < MAX_CUBES:
			_spawn_cube(grid_step)
	if _log_timer >= 5.0:
		_log_timer = 0.0
		_append_log(_grab_diag())
	if _flash_energy > 0.0:
		_flash_energy = move_toward(_flash_energy, 0.0, delta * 22.0)
		_flash_light.light_energy = _flash_energy

# ============================================================================
# CUBES — spawn · collision · scoring · goal
# ============================================================================
func _spawn_cube(step: int = 0, note_degree: int = -1, accent: bool = false):
	var size: float = randf_range(0.06, 0.12)
	var color: Color = CUBE_PALETTE[randi() % CUBE_PALETTE.size()]
	var emission_e: float = randf_range(0.6, 1.75)  # 50% of prior glow (user request)

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

	# Soft additive bloom halo (sells "this is emitting light") — billboarded radial
	# gradient tinted to the cube; softer + more diffuse than the grab outline.
	var halo := MeshInstance3D.new()
	halo.name = "Halo"
	var hq := QuadMesh.new()
	hq.size = Vector2(size * 4.5, size * 4.5)
	halo.mesh = hq
	var hmat := StandardMaterial3D.new()
	hmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	hmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	hmat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	hmat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	hmat.albedo_texture = _get_glow_tex()
	hmat.albedo_color = Color(color.r, color.g, color.b, 0.28)  # 50% of prior bloom (user request)
	halo.material_override = hmat
	cube.add_child(halo)

	# Interior light, same colour as the cube, so it actually casts its hue around.
	var lite := OmniLight3D.new()
	lite.light_color = color
	lite.light_energy = 0.9
	lite.omni_range = size * 4.0
	lite.omni_attenuation = 1.6
	cube.add_child(lite)

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
	# Play this cube's note ON the beat — the lead voice. In song mode the note is the song's
	# fixed degree (deterministic); in pulse mode it's derived from the grid step.
	if note_degree >= 0:
		_play_note_for_degree(note_degree + SONG_LEAD_DEGREE_OFFSET, spawn_pos, accent)
	else:
		_play_spawn_note(step, spawn_pos)

# Flatten SONG_ARRANGEMENT → an ordered list of bars the sequencer walks (and loops).
func _build_song() -> void:
	_song_bars.clear()
	for sect_name in SONG_ARRANGEMENT:
		if SONG_SECTIONS.has(sect_name):
			for bar in SONG_SECTIONS[sect_name]:
				_song_bars.append(bar)

# Deterministic sequencer: read the song step at this grid position and spawn its note(s).
# `step` is the absolute grid index; the song loops over its flattened bars, so it plays the
# SAME intro→…→outro every run (and restarts from the top on round start via _beat_clock=0).
func _play_song_step(step: int) -> void:
	if _song_bars.is_empty():
		return
	var nbars: int = _song_bars.size()
	var bar_idx: int = (int(floor(float(step) / float(SONG_STEPS_PER_BAR))) % nbars + nbars) % nbars
	var step_in_bar: int = ((step % SONG_STEPS_PER_BAR) + SONG_STEPS_PER_BAR) % SONG_STEPS_PER_BAR
	var bar: Array = _song_bars[bar_idx]
	if step_in_bar >= bar.size():
		return
	var val = bar[step_in_bar]              # -1 (rest) | int (one note) | Array (chord)
	var accent: bool = step_in_bar == 0     # bar downbeat
	match typeof(val):
		TYPE_INT:
			if int(val) >= 0:
				_emit_song_note(int(val), step, accent)
		TYPE_ARRAY:
			for d in val:
				_emit_song_note(int(d), step, accent)

# Spawn one cube on `degree`, OR — if we're at the cube cap — still play the note (no cube)
# so the SONG stays reproducible regardless of how fast cubes clear the floor.
func _emit_song_note(degree: int, step: int, accent: bool) -> void:
	if _active_cubes.size() < MAX_CUBES:
		_spawn_cube(step, degree, accent)
	else:
		var at: Vector3 = _emitter.global_position if is_instance_valid(_emitter) \
			else Vector3(0.0, SPAWN_HEIGHT, FORWARD_Z)
		_play_note_for_degree(degree + SONG_LEAD_DEGREE_OFFSET, at, accent)

# Pulse-mode note (SONG_ENABLED=false): derive a melodic degree from the grid step so the
# plain SPAWN_SUBDIV cadence still sounds like an in-key tune over the bed.
func _play_spawn_note(step: int, at: Vector3) -> void:
	var subdiv: int = max(SPAWN_SUBDIV, 1)
	var sub: int = ((step % subdiv) + subdiv) % subdiv
	var beat: int = int(floor(float(step) / float(subdiv)))
	var bar_beat: int = ((beat % BEATS_PER_BAR) + BEATS_PER_BAR) % BEATS_PER_BAR
	var accent: bool = sub == 0 and bar_beat == 0
	var degree: int = int(BASS_PATTERN[beat % BASS_PATTERN.size()]) + SONG_LEAD_DEGREE_OFFSET + sub
	_play_note_for_degree(degree, at, accent)

# Play one scale-degree note (already in lead register) at `at`, on the shared 3D player so it
# inherits mute via volume_db. The bar downbeat rings fuller (harmonic) and a touch longer.
func _play_note_for_degree(degree: int, at: Vector3, accent: bool) -> void:
	if _audio_playback == null:
		return
	_shared_audio.position = at
	var dur: float = 0.075 if accent else 0.05
	_push_chime(_bass_freq(degree), dur, accent)

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
	# Pure-song mode silences the random impact chimes so ONLY the deterministic song sounds
	# (fully reproducible). The impact flash light below also rides this branch.
	if SONG_PURE_MODE:
		return
	if now / 1000.0 - _last_global_audio < 1.0 / GLOBAL_AUDIO_RATE_HZ:
		return
	_last_global_audio = now / 1000.0
	_shared_audio.position = cube.global_position
	_flash_light.position = cube.global_position
	_flash_energy = 3.5
	var is_sphere := cube.is_in_group("sphere")
	# Snap every impact pitch to the C-minor-pentatonic scale so the random cube hits
	# harmonise with the music bed (and each other) into a tune instead of clashing.
	if other_body.is_in_group("cube"):
		_push_chime(_snap_to_scale(randf_range(700.0, 1500.0)), 0.036, false)
	elif is_sphere:
		# Transmuted spheres: hollow, woody knock (lower, longer, detuned harmonic).
		_push_chime(_snap_to_scale(randf_range(180.0, 420.0)), 0.14, true)
	else:
		_push_chime(_snap_to_scale(randf_range(260.0, 700.0)), 0.10, true)

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
	# Final score = SUPERLINEAR time-alive bonus + accumulated chained surface points,
	# then scaled by how hard the goal is (smaller goal → bigger multiplier).
	var birth: int = cube.get_meta("birth_ms", Time.get_ticks_msec())
	var alive_s := float(Time.get_ticks_msec() - birth) / 1000.0
	# Accelerating curve: rate grows with age, so a long-lived bouncer is worth much
	# more than a quick straight-shot. Capped at LONGEVITY_MAX_SEC of effective age.
	var eff_s := minf(alive_s, LONGEVITY_MAX_SEC)
	var time_pts := TIME_POINTS_PER_SEC * eff_s * (1.0 + eff_s / LONGEVITY_RAMP_SEC)
	var surface_pts: int = cube.get_meta("score_acc", 0)
	var base_total := int(round(time_pts)) + surface_pts
	# Goal-size difficulty multiplier (smaller = harder = more points).
	var mult := _portal.score_multiplier() if is_instance_valid(_portal) else 1.0
	var total := int(round(base_total * mult))
	total = max(total, 1)

	# Mix bonus: flip between cube and sphere goals to keep it. Discourages routing every
	# cube through the bubble (all-spheres) — you score more by landing BOTH types.
	var is_sphere := cube.is_in_group("sphere")
	var this_type := 1 if is_sphere else 0
	var mixed := _last_goal_sphere != -1 and this_type != _last_goal_sphere
	if mixed:
		total += MIX_BONUS
	_last_goal_sphere = this_type

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
	# Surface the goal-size multiplier in the popup when it isn't ~1.0 so the player
	# sees the payoff (or penalty) for resizing the goal.
	var popup_txt := str(total)
	if absf(mult - 1.0) > 0.05:
		popup_txt = "%d  (x%.1f)" % [total, mult]
	if mixed:
		popup_txt += "  MIX +%d" % MIX_BONUS
	BigScorePopup3D.spawn(self, at + Vector3(0, 0.05, 0), popup_txt, Color(0.55, 0.95, 1.0) if not mixed else Color(1.0, 0.85, 0.35))
	_spawn_burst(at, Color(0.40, 0.90, 1.0))
	_push_score_fanfare()

# ============================================================================
# VISUAL FX — fireworks, shockwaves, gradients
# ============================================================================
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

# ============================================================================
# RESET — return everything home
# ============================================================================
func _reset_sandbox():
	# Restore the world transform (legacy; the handle no longer moves it) and the
	# XROrigin — the world handle now drags the user, so reset must re-center them.
	if is_instance_valid(_world_root):
		_world_root.transform = _world_home
	if has_node("XROrigin3D"):
		$XROrigin3D.transform = _origin_home
	_handle_prev_pinch = null
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

# ============================================================================
# PROCEDURAL AUDIO — real-time synthesis (AudioStreamGenerator push_frame)
# ============================================================================
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

# Classic Space-Invaders-style explosion for the red destruct buttons: a downward
# square-wave warble (the "destroyed" buzz) layered with a short noise burst, then
# a fast decay. Retro and punchy without being a long fanfare.
func _push_invader_explosion():
	if _muted or _audio_playback == null:
		return
	var dur := 0.34
	var n := int(SAMPLE_RATE * dur)
	var to_fill: int = min(n, _audio_playback.get_frames_available())
	for i in range(to_fill):
		var t := float(i) / SAMPLE_RATE
		var u := t / dur
		# Warble: pitch steps DOWN (220→70 Hz) and the tone is a square wave (8-bit feel).
		var f: float = lerp(220.0, 70.0, u)
		var sq: float = 1.0 if sin(TAU * f * t) >= 0.0 else -1.0
		# Add a fast vibrato so it reads as the classic invader "blip" warble.
		sq *= 0.6 + 0.4 * sin(TAU * 28.0 * t)
		var s := sq * exp(-3.2 * u) * 0.5
		# Noise crack on top, very fast decay.
		s += (randf() * 2.0 - 1.0) * exp(-9.0 * u) * 0.4
		s = clampf(s, -1.0, 1.0)
		_audio_playback.push_frame(Vector2(s, s))

# --- Musical scale (C minor pentatonic) + 30 s music bed ---------------------

# Precompute scale frequencies across octaves 2..6 so any random impact pitch can be
# snapped to the nearest in-key note. C minor pentatonic pitch classes: C Eb F G Bb.
func _build_scale_freqs() -> void:
	var pcs: Array[int] = [0, 3, 5, 7, 10]
	_scale_freqs.clear()
	for octave in range(2, 7):
		for pc in pcs:
			var midi: int = 12 * (octave + 1) + pc   # C2 = MIDI 36
			_scale_freqs.append(440.0 * pow(2.0, (float(midi) - 69.0) / 12.0))
	_scale_freqs.sort()

# Snap an arbitrary frequency to the nearest scale note, so random collision chimes
# land in-key and harmonise with the bass bed instead of clashing.
func _snap_to_scale(freq: float) -> float:
	if _scale_freqs.is_empty():
		return freq
	var best: float = _scale_freqs[0]
	var best_d: float = absf(freq - best)
	for f in _scale_freqs:
		var d: float = absf(freq - f)
		if d < best_d:
			best_d = d
			best = f
	return best

# Frequency of a bass scale-degree (0=C2). Degrees beyond the 5-note pentatonic wrap
# up octaves, so the riff pattern can climb past Bb into the next C.
func _bass_freq(degree: int) -> float:
	var pcs: Array[int] = [0, 3, 5, 7, 10]
	var n := pcs.size()
	var d := ((degree % n) + n) % n
	var oct_bump := int(floor(float(degree) / float(n)))
	var midi: int = 12 * (2 + 1) + pcs[d] + 12 * oct_bump   # base octave 2
	return 440.0 * pow(2.0, (float(midi) - 69.0) / 12.0)

# Fill the dedicated bed generator each frame while a round is active. The bed is a
# 1-beat-per-second bass riff + kick + hats so the player can FEEL the clock; the
# final ~6 s ramp `urg` 0→1 (louder, faster hats, an octave-up bass, a tension tone)
# so the last seconds intensify audibly. Silent (unfed) when no round is running.
func _update_music_bed(_delta: float) -> void:
	if _bed_playback == null or not _timer_active:
		return
	var avail := _bed_playback.get_frames_available()
	if avail <= 0:
		return
	# Urgency ramps in only over the final 6 s — that's where it should feel frantic.
	var urg := clampf((6.0 - _timer_remaining) / 6.0, 0.0, 1.0)
	for i in range(avail):
		var s := _bed_sample(_bed_time, urg)
		_bed_playback.push_frame(Vector2(s, s))
		_bed_time += 1.0 / SAMPLE_RATE

# One bed sample at absolute bed-time t (seconds), with urgency 0..1.
func _bed_sample(t: float, urg: float) -> float:
	var beat_dur := 1.0
	var beat := int(t / beat_dur)
	var frac := t - float(beat) * beat_dur
	var out := 0.0

	# Bass riff — one pluck per beat from the looping pattern; jumps up an octave as
	# urgency rises so the tune lifts in the final seconds.
	var bfreq := _bass_freq(BASS_PATTERN[beat % BASS_PATTERN.size()])
	if urg > 0.5:
		bfreq *= 2.0
	var benv := exp(-2.2 * frac) * (1.0 - exp(-60.0 * frac))   # quick attack, beat-long decay
	out += (sin(TAU * bfreq * t) * 0.6 + sin(TAU * bfreq * 2.0 * t) * 0.2) * benv * 0.30

	# Kick on every beat (phase keyed to frac so each thump is clean).
	var kf: float = lerp(150.0, 50.0, clampf(frac / 0.12, 0.0, 1.0))
	out += sin(TAU * kf * frac) * exp(-16.0 * frac) * 0.5

	# Backbeat hat on the off-beat.
	var hp := frac - 0.5
	if hp >= 0.0 and hp < 0.06:
		out += (randf() * 2.0 - 1.0) * exp(-40.0 * hp) * 0.12

	# Urgency: extra 16th-note hats + a rising tension tone in the last seconds.
	if urg > 0.05:
		var q := fmod(frac, 0.25)
		if q < 0.04:
			out += (randf() * 2.0 - 1.0) * exp(-60.0 * q) * 0.10 * urg
		out += sin(TAU * (660.0 + 240.0 * urg) * t) * 0.06 * urg

	out *= 0.9 + 0.4 * urg
	return clampf(out, -1.0, 1.0)

# ============================================================================
# HAND TRACKING — gesture & pinch readers
# ============================================================================
# Confidence gate: a hand counts as confidently tracked only when its tracker has data AND the
# wrist plus all five fingertips are POSITION_TRACKED. If a hand isn't confident we assume NO
# gesture/pinch is happening (per request — never guess from a half-visible hand). Used by the
# gesture readers below.
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

# Returns which finger tip (15=middle, 20=ring, 25=pinky) is pinching the thumb, or -1 if none.
# "Closest wins": only the single finger nearest the thumb counts, so adjacent fingers (ring vs
# pinky) can't cross-trigger. Index must be extended so a normal grab never fires a gesture. Raw
# int indices avoid the LITTLE/PINKY enum-name divergence (4.6.3 editor vs 4.6.2.rc runtime).
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
	var tname := "/user/hand_tracker/" + ("left" if side == "left_hand" else "right")
	var ht := XRServer.get_tracker(tname) as XRHandTracker
	if ht == null or not ht.get_has_tracking_data():
		_index_pinch_state[side] = false
		return null
	# Pinch only needs the THUMB + INDEX to have a usable (VALID) position. The old gate
	# (_hand_confident = all five fingertips POSITION_TRACKED) made two-hand scale flicker: two
	# hands pinching close together occlude each other's fingers, dropping a tip to estimated-not-
	# tracked, which tore the gesture down every few frames (rapid SCALE_ENGAGE/SCALE_END in the
	# log). VALID holds through occlusion (occlusion drops TRACKED, keeps VALID), so scale stays put.
	if not ((int(ht.get_hand_joint_flags(5)) & XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID) and (int(ht.get_hand_joint_flags(10)) & XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID)):
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

# ============================================================================
# IMMERSION — sky (opaque) ↔ passthrough (mixed) toggle
# ============================================================================
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
	# Gradual cell-dissolve via the sky shader's "dissolve" uniform (0=mixed, 1=immersive
	# opaque/occluding), like the hand shards — never a translucent material.
	if _immersive:
		if _skybox != null:
			_skybox.visible = true
		if _sky_mat != null:
			_sky_mat.set_shader_parameter("dissolve", 0.0)
			var tw := create_tween()
			tw.tween_method(func(v: float): _sky_mat.set_shader_parameter("dissolve", v), 0.0, 1.0, SKY_DISSOLVE_SEC).set_trans(Tween.TRANS_SINE)
		_shard_burst(center, 2.6, Color(0.45, 0.65, 1.0), false, 48)  # converge / materialize
		_push_dissolve_texture(true)                                  # textured swell, rising pitch
	else:
		if _sky_mat != null:
			var tw := create_tween()
			tw.tween_method(func(v: float): _sky_mat.set_shader_parameter("dissolve", v), 1.0, 0.0, SKY_DISSOLVE_SEC).set_trans(Tween.TRANS_SINE)
			tw.tween_callback(func(): if _skybox != null: _skybox.visible = false)
		_shard_burst(center, 2.6, Color(0.80, 0.88, 1.0), true, 48)   # scatter / dissolve
		_push_dissolve_texture(false)                                 # textured swell, falling pitch

# Textured tonal SWELL spanning the WHOLE sky transition (length = SKY_DISSOLVE_SEC, so it
# always matches the shader tween). A handful of well-SPACED, VARIED in-key ticks — each with
# its own pitch, timbre and decay — so it reads as a pleasant shimmer rather than the old
# glitchy 30-drop burst. Pitch climbs on materialize / falls on dissolve, and the ticks bunch
# slightly toward the middle of the transition (swell) instead of a flat metronome. Each tick
# re-checks _muted at fire time so muting mid-transition silences the rest.
func _push_dissolve_texture(rising: bool) -> void:
	# Centre the shared 3D player on the user so the swell isn't stuck at the last
	# cube-collision point (which could be far/quiet).
	var cam := get_viewport().get_camera_3d()
	if _shared_audio != null and cam != null:
		_shared_audio.position = cam.global_position
	var span := SKY_DISSOLVE_SEC
	# ~13 ticks across the whole span = far fewer/slower than the old 30; spaced so adjacent
	# ticks don't blur into a buzz. Tied to span so a longer transition gets proportionally more.
	var ticks := int(round(span / 0.06))
	for i in range(ticks):
		var u := float(i) / float(maxi(1, ticks - 1))
		# Ease-in-out schedule: ticks bunch toward the middle (a swell), sparse at the ends.
		var sched := u - 0.18 * sin(TAU * u) / TAU
		var at: float = clampf(sched * span + randf_range(-0.012, 0.012), 0.0, span)
		var prog := u if rising else (1.0 - u)
		# Pitch ramps across the transition; widen the random spread so no two ticks share a note.
		var base: float = lerp(300.0, 1500.0, prog) * randf_range(0.78, 1.28)
		var freq := _snap_to_scale(base)
		# Per-tick timbre variety: 0=pure drop, 1=two-partial bell, 2=detuned/woody.
		var timbre := i % 3
		# Vary decay so some ticks ping short, others ring a touch longer (organic, not uniform).
		var decay: float = randf_range(28.0, 60.0)
		# Amplitude swells in the middle of the transition so it grows then settles.
		var amp: float = (0.18 + 0.22 * sin(PI * u)) * randf_range(0.85, 1.1)
		get_tree().create_timer(at).timeout.connect(_push_tick.bind(freq, timbre, decay, amp))

# One short in-key tick with per-call variety. `timbre` picks the spectral character,
# `decay` the ring length, `amp` the level — passed per tick so the stream is textured
# and varied rather than identical drops. Mute is checked here (not at schedule time) so
# it can stop mid-stream.
func _push_tick(freq: float, timbre: int, decay: float, amp: float) -> void:
	if _muted or _audio_playback == null:
		return
	# Longer-decaying ticks get a slightly longer buffer so the ring isn't clipped.
	var dur: float = clampf(3.0 / decay, 0.030, 0.075)
	var n := int(SAMPLE_RATE * dur)
	var to_fill: int = min(n, _audio_playback.get_frames_available())
	for i in range(to_fill):
		var t := float(i) / SAMPLE_RATE
		var u := t / dur
		var env := exp(-decay * u)
		var s: float
		match timbre:
			1:
				# Bell: fundamental + soft octave shimmer.
				s = (sin(TAU * freq * t) * 0.8 + sin(TAU * freq * 2.0 * t) * 0.28) * env
			2:
				# Woody: fundamental + a slightly detuned partial = gentle beating/warble.
				s = (sin(TAU * freq * t) + sin(TAU * freq * 1.005 * t) * 0.6) * 0.6 * env
			_:
				# Pure pitched drop with a soft click transient.
				s = sin(TAU * freq * t) * env
				s += (randf() * 2.0 - 1.0) * exp(-130.0 * u) * 0.08
		_audio_playback.push_frame(Vector2(s * amp, s * amp))

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

# Tick the active round (countdown + red urgency pulse). The START press itself is now
# handled by the shared poke registry (button callback = _gp_start), so there's no
# fingertip-poll here anymore — just the per-frame visuals while a round runs.
func _update_timer(delta: float) -> void:
	_start_cooldown = max(0.0, _start_cooldown - delta)
	if not _timer_active:
		return
	_timer_remaining -= delta
	# Pulse the button red as time runs low.
	if _start_button_mat != null:
		var urgency := 1.0 - clampf(_timer_remaining / ROUND_SECONDS, 0.0, 1.0)
		_start_button_mat.emission = Color(0.2 + urgency * 0.8, 0.9 - urgency * 0.7, 0.45 - urgency * 0.3)
	_refresh_button_label()
	if _timer_remaining <= 0.0:
		_end_round()

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
	if sim_cursor_world != null and side == "right_hand":
		return sim_cursor_world
	var tname := "/user/hand_tracker/" + ("left" if side == "left_hand" else "right")
	var ht := XRServer.get_tracker(tname) as XRHandTracker
	if ht == null or not ht.get_has_tracking_data():
		return null
	var idx := XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP
	if not (int(ht.get_hand_joint_flags(idx)) & 8):  # POSITION_TRACKED
		return null
	var origin := $XROrigin3D as Node3D
	return origin.global_transform * ht.get_hand_joint_transform(idx).origin

# Cached soft radial gradient (white core → transparent edge) for cube bloom halos.
func _get_glow_tex() -> GradientTexture2D:
	if _glow_tex != null:
		return _glow_tex
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 1.0])
	g.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0)])
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.width = 64
	tex.height = 64
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(0.5, 0.0)
	_glow_tex = tex
	return tex

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
	_last_goal_sphere = -1   # fresh mix-bonus chain each round
	_bed_time = 0.0   # restart the music bed at beat 0
	_beat_clock = 0.0   # lock the cube-spawn grid to the bed's beat 0
	_last_spawn_step = -1
	_start_cooldown = 1.0
	_push_sweep(300.0, 900.0, 0.25)  # start chirp
	_refresh_button_label()

func _end_round() -> void:
	_timer_active = false
	_timer_remaining = 0.0
	var final_score := _round_score
	# Decide the celebration tier BEFORE we overwrite _best_score: beating the online
	# leaderboard top = WORLD record (tier 2, biggest), beating only your own best =
	# personal best (tier 1, big), otherwise just the normal cash-out fanfare (tier 0).
	var beat_world := _lb_top_score > 0 and final_score > _lb_top_score
	var beat_personal := final_score > _best_score
	if beat_personal:
		_best_score = final_score
		_save_best()
		_refresh_best_panel()
	_start_button_mat.emission = Color(0.20, 0.95, 0.45)
	# Celebrate above the button: volumetric score + fireworks + fanfare.
	var burst_at := _start_button.global_position + Vector3(0, 0.18, 0)
	BigScorePopup3D.spawn(self, burst_at, str(final_score))
	if beat_world:
		_celebrate_high_score(2)
	elif beat_personal and _best_score > 0:
		_celebrate_high_score(1)
	else:
		_spawn_burst(burst_at, Color(0.30, 1.0, 0.55))
		_push_score_fanfare()
	_submit_score(final_score)
	_start_cooldown = 2.5
	_refresh_button_label()

# Big scene-spanning celebration for a new high score. tier 1 = personal best (warm/gold
# bursts + a crowd cheer); tier 2 = beat the WORLD leaderboard top (bigger, distinct cyan/
# magenta bursts, more of them, a longer/brighter cheer). Multiple bursts are scattered
# across the whole play volume around the player rather than one burst at the goal, so the
# room fills with fireworks. Respects _muted via the audio helpers.
func _celebrate_high_score(tier: int) -> void:
	var cam := get_viewport().get_camera_3d()
	var center := Vector3(0.0, 1.5, -0.6)
	if cam != null:
		center = cam.global_position + cam.global_transform.basis.z * -0.6   # ~0.6 m in front
	# tier 2 (world record) is bigger: more bursts, wider spread, cooler palette.
	var n_bursts := 9 if tier >= 2 else 6
	var spread := 1.7 if tier >= 2 else 1.3
	# Two distinct palettes so personal-best (warm/gold) vs world-record (electric cyan/
	# magenta) read as clearly different celebrations at a glance.
	var warm: Array[Color] = [Color(1.0, 0.85, 0.25), Color(1.0, 0.55, 0.12), Color(1.0, 0.95, 0.55)]
	var cool: Array[Color] = [Color(0.30, 0.90, 1.0), Color(1.0, 0.30, 0.95), Color(0.55, 0.70, 1.0)]
	var palette := cool if tier >= 2 else warm
	for i in range(n_bursts):
		# Scatter bursts around the player in a rough sphere, biased forward + upward so
		# they're in view. Stagger their timing so they pop in a cascade, not all at once.
		var dir := Vector3(randf_range(-1.0, 1.0), randf_range(-0.2, 1.0), randf_range(-1.0, 0.3))
		if dir.length() < 0.01:
			dir = Vector3.UP
		var at := center + dir.normalized() * randf_range(spread * 0.4, spread)
		var col: Color = palette[i % palette.size()]
		var delay := randf_range(0.0, 0.7 if tier >= 2 else 0.5)
		get_tree().create_timer(delay).timeout.connect(func():
			if is_instance_valid(self): _spawn_burst(at, col))
	# One bigger boom-fanfare for the moment, then the crowd cheer swells over it.
	_push_score_fanfare()
	_push_cheer(tier >= 2)

# Procedural crowd-cheer-ish swell: filtered white-noise (the "roar" of a crowd) that rises
# then falls, layered with a bright sustained in-key chord (C minor pentatonic) so it sits in
# the scene's musical world rather than clashing. `big` = the world-record cheer: longer,
# louder, a fuller chord and a higher roar. Mixed into ONE shared-player buffer fill, so it
# needs the shared 3D player's buffer to be long enough (~0.9 s); muting silences it.
func _push_cheer(big: bool) -> void:
	if _muted or _audio_playback == null:
		return
	# Recentre the (positional) shared player on the user so the cheer surrounds them.
	var cam := get_viewport().get_camera_3d()
	if _shared_audio != null and cam != null:
		_shared_audio.position = cam.global_position
	var dur := 0.95 if big else 0.7
	var n := int(SAMPLE_RATE * dur)
	var to_fill: int = min(n, _audio_playback.get_frames_available())
	# In-key chord: a fuller, brighter set for the world-record cheer. Snapped to scale so
	# it harmonises with the bed/chimes. (Roughly C-Eb-G-Bb-C / C-G triad.)
	var chord: Array = []
	if big:
		for f in [261.63, 311.13, 392.0, 466.16, 523.25]:
			chord.append(_snap_to_scale(f))
	else:
		for f in [261.63, 392.0, 523.25]:
			chord.append(_snap_to_scale(f))
	# Roar = band-passed noise: keep a running low-passed noise and high-pass it (subtract a
	# slower average) so it reads as a breathy crowd hiss, not white static. Swells in, out.
	var lp := 0.0
	var lp2 := 0.0
	var roar_gain := 0.34 if big else 0.26
	for i in range(to_fill):
		var t := float(i) / SAMPLE_RATE
		var u := t / dur
		# Swell envelope: quick rise, sustained, gentle fall (a crowd surging then settling).
		var swell := pow(sin(PI * u), 0.6)
		var white := randf() * 2.0 - 1.0
		lp = lerp(lp, white, 0.20)        # ~3 kHz-ish low-pass
		lp2 = lerp(lp2, lp, 0.012)        # slow average to subtract = high-pass the rumble out
		var roar := (lp - lp2)
		# A little amplitude flutter so the roar undulates like overlapping voices.
		roar *= 0.7 + 0.3 * sin(TAU * (6.0 + 3.0 * sin(TAU * 0.7 * t)) * t)
		var s := roar * roar_gain * swell
		# Bright sustained chord on top — equal-power, soft attack so it blooms with the roar.
		var chord_env := swell * (1.0 - exp(-8.0 * t))
		var cs := 0.0
		for f in chord:
			cs += sin(TAU * float(f) * t) + 0.25 * sin(TAU * float(f) * 2.0 * t)
		s += cs / float(maxi(1, chord.size())) * (0.22 if big else 0.18) * chord_env
		# Sparkle shimmer for the world record only — a glittery high tremolo tail.
		if big:
			s += sin(TAU * 1568.0 * t) * exp(-2.2 * u) * 0.06 * (0.5 + 0.5 * sin(TAU * 11.0 * t))
		_audio_playback.push_frame(Vector2(clampf(s, -1.0, 1.0), clampf(s, -1.0, 1.0)))

func _refresh_button_label() -> void:
	if _start_button_label == null:
		return
	# Compact label (the button is small on the grid; the BEST score is shown big on the
	# panel header instead of being crammed in here).
	if _timer_active:
		_start_button_label.text = "%d\n%d pts" % [int(ceil(_timer_remaining)), _round_score]
	else:
		_start_button_label.text = "START\n30s"

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
	# If a prior session left real arms on, default the virtual mesh off so we restore
	# REAL-only (not BOTH) — but _apply_hand_visibility still guarantees we never end up
	# with nothing showing.
	if _real_arms_visible:
		_hand_mesh_visible = false
	_apply_hand_visibility()

# The HANDS button is a HANDS-MODE selector: it switches between virtual MESH
# hands and real Persona ARMS (two different things, mutually exclusive) rather than
# just toggling real arms on/off. Label shows the mode you'll switch TO next.
func _refresh_arms_label() -> void:
	if _arms_button_label == null or _arms_button_mat == null:
		return
	# Three valid states (never "none"): MESH only / BOTH / REAL only. Label shows the
	# CURRENT mode; tapping advances the cycle.
	# HANDS stays in an ORANGE family across all three states (state shown by the label
	# text), so the button reads as one distinct colour and never collides with SKY's blue.
	if _hand_mesh_visible and _real_arms_visible:
		_arms_button_label.text = "HANDS\nBOTH"
		_arms_button_mat.albedo_color = Color(0.34, 0.26, 0.08)
		_arms_button_mat.emission = Color(1.0, 0.80, 0.25)
		_arms_button_mat.emission_energy_multiplier = 1.3
	elif _real_arms_visible:
		_arms_button_label.text = "HANDS\nREAL"
		_arms_button_mat.albedo_color = Color(0.34, 0.16, 0.05)
		_arms_button_mat.emission = Color(1.0, 0.45, 0.10)
		_arms_button_mat.emission_energy_multiplier = 1.2
	else:
		_arms_button_label.text = "HANDS\nMESH"
		_arms_button_mat.albedo_color = Color(0.30, 0.22, 0.10)
		_arms_button_mat.emission = Color(0.95, 0.62, 0.20)
		_arms_button_mat.emission_energy_multiplier = 1.0

func _refresh_mute_label() -> void:
	if _mute_button_label == null or _mute_button_mat == null:
		return
	if _muted:
		_mute_button_label.text = "SOUND\nOFF"
		_mute_button_mat.albedo_color = Color(0.32, 0.12, 0.12)
		_mute_button_mat.emission = Color(0.95, 0.30, 0.30)
		_mute_button_mat.emission_energy_multiplier = 1.0
	else:
		_mute_button_label.text = "SOUND\nON"
		# Cyan (distinct from START's green and GESTURES' violet).
		_mute_button_mat.albedo_color = Color(0.10, 0.30, 0.34)
		_mute_button_mat.emission = Color(0.20, 0.85, 0.95)
		_mute_button_mat.emission_energy_multiplier = 1.2

# Toggle sound on/off. Wired as the MUTE poke-button's callback (registry handles the
# poke detection + depress); also still callable directly.
func _toggle_mute() -> void:
	_muted = not _muted
	# Single mute point: drop the shared player to silence (cheaper + total than
	# gating every synth path). volume restored on unmute.
	if _shared_audio != null:
		_shared_audio.volume_db = -80.0 if _muted else -3.0
	if _bed_audio != null:
		_bed_audio.volume_db = -80.0 if _muted else -10.0
	_refresh_mute_label()
	# A confirming blip plays only when turning sound back ON (volume already restored).
	if not _muted:
		_push_chime(660.0, 0.10, true)

# Switch between the two mutually-exclusive hand visualisations: virtual MESH hands
# (hand_mesh_driver) and real Persona ARMS (the engine's upper-limb passthrough). One
# is always on, the other off — turning on mesh hands and turning on real arms are
# genuinely DIFFERENT things, so this is a mode toggle, not an on/off.
func _cycle_hands_mode() -> void:
	# 3-way cycle that can NEVER land on "no hands":
	#   MESH only → BOTH → REAL only → (wrap) MESH only
	if _hand_mesh_visible and not _real_arms_visible:
		_real_arms_visible = true            # MESH → BOTH
	elif _hand_mesh_visible and _real_arms_visible:
		_hand_mesh_visible = false           # BOTH → REAL only
	else:
		_hand_mesh_visible = true            # REAL only (or any empty state) → MESH only
		_real_arms_visible = false
	_apply_hand_visibility()
	_push_sweep(300.0, 900.0, 0.22)

# Apply the current hand-visibility state, ENFORCING the invariant that at least one of
# {virtual mesh hands, real Persona arms} is always visible. Playtesters kept toggling
# into a state with neither and seeing empty space — this guard makes that unreachable.
# Every path that changes hand visibility should end here.
func _apply_hand_visibility() -> void:
	if not _hand_mesh_visible and not _real_arms_visible:
		_hand_mesh_visible = true   # never show nothing
	for d in _hand_drivers:
		d.set_shown(_hand_mesh_visible)
	_write_arms_pref()
	_refresh_arms_label()

# Persist the real-arm preference; user://upper_limb.txt maps to Documents/upper_limb.txt,
# which the recompiled engine polls (~0.5s) and applies to SwiftUI .upperLimbVisibility.
func _write_arms_pref() -> void:
	var f := FileAccess.open("user://upper_limb.txt", FileAccess.WRITE)
	if f != null:
		f.store_string("visible" if _real_arms_visible else "hidden")
		f.close()

# --- Unified control panel --------------------------------------------------
# ONE grabbable panel holds all six buttons (NO destruct button). Each poke button is
# discoverable + usable even with pinch gestures disabled.

# Build one poke button as a child of `parent`, register it in _poke_buttons with a
# callback. BoxMesh face + Label3D, depress animation + cooldown handled centrally by
# _update_poke_buttons.
func _add_poke_button(parent: Node3D, local_pos: Vector3, text: String,
		base: Color, emis: Color, cb: Callable) -> Dictionary:
	var btn := Node3D.new()
	btn.position = local_pos
	parent.add_child(btn)
	var face := Node3D.new()
	btn.add_child(face)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.20, 0.075, 0.025)
	mi.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	mat.albedo_color = base
	mat.emission_enabled = true
	mat.emission = emis
	mat.emission_energy_multiplier = 1.1
	mi.material_override = mat
	face.add_child(mi)
	var lbl := Label3D.new()
	lbl.font_size = 22
	lbl.outline_size = 6
	lbl.modulate = Color.WHITE
	lbl.outline_modulate = Color(0, 0, 0, 0.9)
	lbl.pixel_size = 0.0005
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.text = text
	lbl.position = Vector3(0, 0, 0.015)
	face.add_child(lbl)
	var entry := {"node": btn, "face": face, "mat": mat, "label": lbl, "cb": cb, "cooldown": 0.0}
	_poke_buttons.append(entry)
	return entry

# ONE grabbable control panel holding ALL six buttons in a 2-column × 3-row grid,
# plus a big BEST readout up top. Replaces the old scattered layout (separate START
# near the world handle + an ARMS/MUTE column + a gesture panel). Each button reuses
# the shared poke-button registry (_poke_buttons / _update_poke_buttons), so poke
# detection uses world positions and keeps working after the panel is grabbed/moved.
# No destruct button on this panel (per request). Buttons, L→R / top→bottom:
#   row0: HANDS (mesh↔real cycle) | START (30s round)
#   row1: MUTE (sound)            | GESTURES (master toggle)
#   row2: SKY (immersion)         | RESET (everything)
func _build_control_panel() -> void:
	var root := PickupAbleBody3D.new()
	root.name = "ControlPanel"
	root.position = Vector3(-0.5, 1.30, -0.5)   # left of centre, reachable
	root.collision_layer = LAYER_GRAB_ONLY
	root.collision_mask = 0
	root.freeze = true
	root.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	root.freeze_on_release = true
	add_child(root)
	_gesture_panel = root

	var size_x := 0.50
	var size_y := 0.52

	var accent_mat := StandardMaterial3D.new()
	accent_mat.albedo_color = Color(0.55, 0.45, 1.0, 0.30)
	accent_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	accent_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	accent_mat.emission_enabled = true
	accent_mat.emission = Color(0.55, 0.45, 1.0)
	var accent := MeshInstance3D.new()
	var aq := QuadMesh.new()
	aq.size = Vector2(size_x + 0.016, size_y + 0.016)
	accent.mesh = aq
	accent.material_override = accent_mat
	accent.position = Vector3(0, 0, -0.006)
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
	bg.position = Vector3(0, 0, -0.003)
	root.add_child(bg)

	# Fancy BEST readout up top, spanning the width (bigger/fancier than a button label).
	var best_title := _panel_label("★ BEST ★", 26, Color(1.0, 0.85, 0.30, 1.0), 7)
	best_title.position = Vector3(0, size_y * 0.5 - 0.042, 0.004)
	root.add_child(best_title)
	_best_panel_label = _panel_label(str(_best_score), 54, Color(1.0, 0.95, 0.55, 1.0), 10)
	_best_panel_label.position = Vector3(0, size_y * 0.5 - 0.108, 0.004)
	root.add_child(_best_panel_label)

	# 2-column grid. col_x ±0.115 keeps a fingertip (0.045 poke radius) from crossing to
	# the neighbour column; row spacing 0.105 likewise. Buttons begin below the BEST block.
	var col_x := 0.115
	var row_y: Array[float] = [-0.045, -0.150, -0.255]

	# row0: HANDS | START
	var hands_e := _add_poke_button(root, Vector3(-col_x, row_y[0], 0.012), "HANDS\nMESH",
		Color(0.30, 0.22, 0.10), Color(0.95, 0.62, 0.20), _cycle_hands_mode)
	var start_e := _add_poke_button(root, Vector3(col_x, row_y[0], 0.012), "START\n30s",
		Color(0.10, 0.42, 0.24), Color(0.20, 0.95, 0.45), _gp_start)
	# row1: MUTE (cyan) | GESTURES (violet)
	var mute_e := _add_poke_button(root, Vector3(-col_x, row_y[1], 0.012), "SOUND\nON",
		Color(0.10, 0.30, 0.34), Color(0.20, 0.85, 0.95), _toggle_mute)
	var gest_e := _add_poke_button(root, Vector3(col_x, row_y[1], 0.012), "GESTURES\nON",
		Color(0.22, 0.16, 0.40), Color(0.62, 0.42, 1.0), _gp_toggle_gestures)
	# row2: SKY (blue) | RESET (magenta)
	_add_poke_button(root, Vector3(-col_x, row_y[2], 0.012), "SKY",
		Color(0.12, 0.20, 0.42), Color(0.35, 0.55, 1.0), _toggle_immersion)
	_add_poke_button(root, Vector3(col_x, row_y[2], 0.012), "RESET",
		Color(0.34, 0.10, 0.26), Color(1.0, 0.35, 0.75), _reset_sandbox)

	# Repoint the existing per-button handles at these registry buttons so the bespoke
	# per-frame logic (timer countdown/pulse, label refreshers) keeps working unchanged.
	_start_button = start_e["node"]
	_start_button_label = start_e["label"]; _start_button_mat = start_e["mat"]
	_arms_button_label = hands_e["label"]; _arms_button_mat = hands_e["mat"]
	_mute_button_label = mute_e["label"]; _mute_button_mat = mute_e["mat"]
	_gestures_toggle_label = gest_e["label"]; _gestures_toggle_mat = gest_e["mat"]
	_refresh_button_label()
	_refresh_arms_label()
	_refresh_mute_label()

	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(size_x, size_y, 0.04)
	cs.shape = box
	root.add_child(cs)
	_register_grabbable(root)
	# Deliberately NO destruct button on this panel (per request).

# START button callback: begin a round when idle, cancel to neutral when one is running
# (a SECOND press restarts). Mirrors the old _update_timer poke behaviour, now driven by
# the shared poke registry. The countdown label + red urgency pulse still tick in _update_timer.
func _gp_start() -> void:
	# Respect the post-round / post-cancel settle window so a lingering finger can't
	# instantly restart (the registry's own 0.6 s cooldown is shorter than this).
	if _start_cooldown > 0.0:
		return
	if _timer_active:
		_cancel_round()
	else:
		_start_round()

# Panel "Gestures" button — master switch for middle/ring/pinky pinch recognition.
func _gp_toggle_gestures() -> void:
	_gestures_enabled = not _gestures_enabled
	if _gestures_toggle_label != null:
		_gestures_toggle_label.text = "GESTURES\nON" if _gestures_enabled else "GESTURES\nOFF"
	if _gestures_toggle_mat != null:
		# Violet (distinct from the other five buttons); dim when off.
		if _gestures_enabled:
			_gestures_toggle_mat.albedo_color = Color(0.22, 0.16, 0.40)
			_gestures_toggle_mat.emission = Color(0.62, 0.42, 1.0)
		else:
			_gestures_toggle_mat.albedo_color = Color(0.14, 0.10, 0.22)
			_gestures_toggle_mat.emission = Color(0.34, 0.24, 0.52)
	_push_sweep(300.0, 900.0, 0.18) if _gestures_enabled else _push_sweep(900.0, 300.0, 0.18)

# Update the bigger BEST readout on the gesture panel (call after a new best is saved).
func _refresh_best_panel() -> void:
	if _best_panel_label != null:
		_best_panel_label.text = str(_best_score)

# True while ANY object is being manipulated by a hand — held by either hand, OR a
# two-hand scale/rotate is active, OR the world handle is grabbed. While this is true we
# suppress ALL button pokes: a held/scaled object (or a moved panel) sweeps through
# pokeable space and was firing buttons by accident (e.g. START — see the grab video).
# The grab pinch (index) is the same gesture as a poke, so a busy hand must not also poke.
func _manipulating() -> bool:
	if _scale_active:
		return true
	if _handle_held_side != "":
		return true
	for side in ["left_hand", "right_hand"]:
		var h = _hand_handlers.get(side)
		if h != null and h.picked_up_body != null:
			return true
	return false

# Drive every registered poke button. EDGE-TRIGGERED: a button fires only on an
# outside→inside transition of a fingertip, never while the finger merely rests inside.
# This is what makes release-from-a-grabbed-panel safe: at release your pinch fingers are
# sitting right on the buttons, so a level-triggered poke would fire instantly. We keep
# updating each button's per-side "inside" flag EVERY frame — including while manipulation
# suppresses firing — so a finger that's already inside at release is already flagged
# inside ⇒ no rising edge ⇒ no poke until you pull out and poke back in.
func _update_poke_buttons(delta: float) -> void:
	var suppress := _manipulating()
	for e in _poke_buttons:
		e["cooldown"] = maxf(0.0, float(e["cooldown"]) - delta)
		var btn: Node3D = e["node"]
		var visible_ok: bool = is_instance_valid(btn) and btn.visible
		if not e.has("inside"):
			e["inside"] = {"left_hand": false, "right_hand": false}
		var inside: Dictionary = e["inside"]
		for side in ["left_hand", "right_hand"]:
			var tip = _index_tip_world(side)
			var now_inside: bool = visible_ok and tip != null \
				and (tip as Vector3).distance_to(btn.global_position) <= 0.045
			var was_inside: bool = bool(inside[side])
			# Fire ONLY on the rising edge, and only when not suppressed + off cooldown.
			if now_inside and not was_inside and not suppress and float(e["cooldown"]) <= 0.0:
				e["cooldown"] = 0.6
				_depress(e["face"])
				_push_click()
				(e["cb"] as Callable).call()
			inside[side] = now_inside  # ALWAYS update, even while suppressed (the crux)

# Shared depress animation for poke buttons (the face dips in Z, then springs back).
func _depress(face: Node3D) -> void:
	if face == null:
		return
	var tw := create_tween()
	tw.tween_property(face, "position:z", -0.014, 0.05).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(face, "position:z", 0.0, 0.11).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

# ============================================================================
# LEADERBOARD — global high scores (Google Apps Script) + local best
# ============================================================================
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
	_attach_destruct_button(root, Vector3(0.0, -size_y * 0.5 - 0.018, 0.0))

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
		var sc := int(s.get("score", 0))
		# Row 1 is the highest (Apps Script returns sorted desc) — remember it so round
		# end can tell a world-record from a merely-personal best.
		if i == 1:
			_lb_top_score = sc
		lines.append("%2d  %-8s %5d" % [i, nm, sc])
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


# ============================================================================
# INSTRUCTIONS PANEL — the cold-open "HOW TO PLAY" board
# ============================================================================
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

	var size_x := 0.54
	var size_y := 0.46  # snug around the blurb + controls table + gesture footer (no dead space)

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

	var title := _panel_label("HOW TO PLAY", 38, Color(1.0, 0.80, 0.30, 1.0), 9)
	title.position = Vector3(0, size_y * 0.5 - 0.035, 0.006)
	root.add_child(title)

	# Blurb now also spells out the two bonuses (smaller goal = bigger multiplier; mixing
	# cubes & spheres into the goal = MIX bonus), which both fills the panel and teaches them.
	var goal := _panel_label(
		"Get the most points in 30 seconds — hit\ngreen START. Cubes pour from the emitter;\nland them in the goal ring. POINTS =\nseconds alive + surface hits, chained x8.\nSMALLER goal ring = bigger multiplier (x4).\nLand BOTH cubes AND spheres — alternating\nthem in the goal scores a MIX bonus!",
		20, Color(0.92, 0.95, 1.0, 1.0), 6)
	goal.position = Vector3(0, size_y * 0.5 - 0.13, 0.006)
	root.add_child(goal)

	# Controls as a 3-column table — BUTTON | GESTURE | ACTION — so it's unambiguous these
	# are the panel BUTTONS (and their optional pinch gesture), not "poke your own hands".
	# The table's own header row (+ dashed rule) IS the header — no separate floating
	# "CONTROLS" label (it read as detached). Monospace SystemFont + fixed-width columns
	# (every line padded to TABLE_COLS) make the block a centred rectangle; LEFT-align anchors
	# the text's left edge at node x, so x = -half-block-width centres it.
	var mono := SystemFont.new()
	mono.font_names = PackedStringArray(["Menlo", "Courier New", "Courier", "monospace"])
	var rows := [
		["BUTTON", "GESTURE", "ACTION"],
		["", "", ""],   # placeholder; replaced by a dashed rule below
		["HANDS", "middle pinch", "mesh/both/real"],
		["START", "-", "30s time attack"],
		["MUTE", "-", "sound on/off"],
		["GESTURES", "-", "toggle pinches"],
		["SKY", "pinky pinch", "sky/passthrough"],
		["RESET", "ring pinch", "reset all"],
	]
	const TABLE_COLS := 40
	var ctl_lines := PackedStringArray()
	for i in range(rows.size()):
		if i == 1:
			ctl_lines.append("".rpad(TABLE_COLS, "-"))   # header rule, full table width
		else:
			var r: Array = rows[i]
			ctl_lines.append(((r[0] as String).rpad(10) + (r[1] as String).rpad(14) + (r[2] as String)).rpad(TABLE_COLS))
	var table := Label3D.new()
	table.font = mono
	table.font_size = 22
	table.outline_size = 5
	table.modulate = Color(0.93, 0.97, 1.0, 1.0)
	table.outline_modulate = Color(0, 0, 0, 0.95)
	table.pixel_size = 0.00046
	table.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	table.shaded = false
	table.text = "\n".join(ctl_lines)
	# Centre the fixed-width block: glyph advance ≈ font_size * pixel_size * 0.6 (mono).
	var table_w := TABLE_COLS * table.font_size * table.pixel_size * 0.6
	table.position = Vector3(-table_w * 0.5, -0.05, 0.006)
	root.add_child(table)

	var footer := _panel_label(
		"Also: index-pinch = grab  •  both hands = scale / rotate\ngrab the chrome bar = move / scale the whole world",
		16, Color(0.78, 0.84, 0.95, 1.0), 5)
	footer.position = Vector3(0, -size_y * 0.5 + 0.04, 0.006)
	root.add_child(footer)

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
	_attach_destruct_button(root, Vector3(0.0, -size_y * 0.5 - 0.018, 0.0))

# ============================================================================
# SELF-DESTRUCT BUTTONS — poke a panel's red button to shatter it (reset restores)
# ============================================================================
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
	# Tiny "DO NOT PRESS" warning sitting over the sphere (billboarded so it always faces
	# the user). Slightly in front of the sphere so it reads clearly.
	var warn := Label3D.new()
	warn.text = "DO NOT\nPRESS"
	warn.font_size = 16
	warn.outline_size = 5
	warn.modulate = Color(1.0, 0.92, 0.45)
	warn.outline_modulate = Color(0, 0, 0, 0.95)
	warn.pixel_size = 0.00034
	warn.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	warn.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	warn.shaded = false
	warn.position = Vector3(0, 0, 0.03)
	btn.add_child(warn)
	panel.add_child(btn)
	_panels.append({"panel": panel, "button": btn})

# Watch for a finger poke on any panel's destruct button. EDGE-TRIGGERED (same rule as the
# control-panel buttons): fire only on an outside→inside transition, and keep tracking
# "inside" every frame even while manipulation suppresses firing — so releasing a grabbed
# panel with your fingers resting on its destruct button does NOT instantly explode it.
func _update_destruct(delta: float) -> void:
	_destruct_cooldown = maxf(0.0, _destruct_cooldown - delta)
	var suppress := _manipulating()
	for entry in _panels:
		var panel: Node3D = entry["panel"]
		var btn: Node3D = entry["button"]
		var visible_ok: bool = panel != null and is_instance_valid(panel) and panel.visible
		if not entry.has("inside"):
			entry["inside"] = {"left_hand": false, "right_hand": false}
		var inside: Dictionary = entry["inside"]
		for side in ["left_hand", "right_hand"]:
			var tip = _index_tip_world(side)
			var now_inside: bool = visible_ok and tip != null \
				and (tip as Vector3).distance_to(btn.global_position) <= 0.05
			var was_inside: bool = bool(inside[side])
			if now_inside and not was_inside and not suppress and _destruct_cooldown <= 0.0:
				_dissolve_panel(panel)
				_destruct_cooldown = 0.6
			inside[side] = now_inside  # ALWAYS update, even while suppressed

# Explode a panel into shards and hide it (un-grabbable until a reset restores it).
func _dissolve_panel(panel: Node3D) -> void:
	# Beefier burst: two waves of shards in warm explosion colours + a GPU spark puff.
	_shard_burst(panel.global_position, 0.40, Color(1.0, 0.55, 0.15), true, 56)
	_shard_burst(panel.global_position, 0.22, Color(1.0, 0.25, 0.10), true, 40)
	_spawn_burst(panel.global_position, Color(1.0, 0.45, 0.12))
	panel.visible = false
	if panel is CollisionObject3D:
		(panel as CollisionObject3D).collision_layer = 0
	_push_invader_explosion()

# ============================================================================
# WORLD MANIPULATION — scene handle (one-hand drag) + two-hand scale / rotate
# ============================================================================
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
			# Distance to the whole BAR SEGMENT (centre ± half-length along the handle's X),
			# not just its centre — so the sphere end-knobs are grabbable too, not only the
			# middle of the cylinder.
			var hc: Vector3 = _scene_handle.global_position
			var hx: Vector3 = _scene_handle.global_transform.basis.x.normalized()
			var hhalf: float = SceneHandle3D.BAR_LENGTH * 0.5
			var ht: float = clampf((pp_world - hc).dot(hx), -hhalf, hhalf)
			var nearest_on_bar: Vector3 = hc + hx * ht
			if pp_world.distance_to(nearest_on_bar) <= HANDLE_GRAB_DIST:
				_handle_held_side = side
				_handle_prev_pinch = pp  # remember TRACKING-space pinch for the delta
				_handle_filt_delta = Vector3.ZERO  # reset the drag-damping filter
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
		# A little dampening: low-pass the per-frame drag delta so fingertip jitter doesn't
		# make the whole world (origin) twitch. Lower HANDLE_DAMP_ALPHA = smoother/laggier.
		_handle_filt_delta = _handle_filt_delta.lerp(d_track, HANDLE_DAMP_ALPHA)
		origin.global_position -= origin.global_transform.basis * _handle_filt_delta
	_handle_prev_pinch = cur

func _release_handle() -> void:
	_handle_held_side = ""
	_handle_prev_pinch = null
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
		# Debounce: a 1-frame pinch dropout mid-scale shouldn't tear the gesture down (and,
		# with release-on-end below, would otherwise drop the object). Only end once a pinch
		# has been genuinely absent for SCALE_END_GRACE frames.
		if _scale_active:
			_scale_lost_frames += 1
			if _scale_lost_frames < SCALE_END_GRACE:
				_two_hand_world_active = _scale_is_world  # hold world-glue too during the grace
				return
		_end_scale()
		return
	_scale_lost_frames = 0
	var origin := $XROrigin3D as Node3D
	var PA: Vector3 = origin.global_transform * (pL as Vector3)   # current world pinch L
	var PB: Vector3 = origin.global_transform * (pR as Vector3)   # current world pinch R

	# --- Engage: BOTH pinches must be AT the target (a hand pinching by your side must
	# NOT put us in scale mode). World = both pinches on the handle; object = one hand
	# holds it AND the other pinch is inside/very close to it. ---
	if not _scale_active:
		var is_world := _scene_handle != null \
			and PA.distance_to(_scene_handle.global_position) <= 0.20 \
			and PB.distance_to(_scene_handle.global_position) <= 0.20
		var obj: Node3D = null
		if not is_world:
			var lh = _hand_handlers.get("left_hand")
			var rh = _hand_handlers.get("right_hand")
			var cand: Node3D = null
			var free_pt := Vector3.ZERO
			if lh != null and lh.picked_up_body != null and lh.picked_up_body != _scene_handle:
				cand = lh.picked_up_body
				free_pt = PB   # left holds → right is the free pinch
			elif rh != null and rh.picked_up_body != null and rh.picked_up_body != _scene_handle:
				cand = rh.picked_up_body
				free_pt = PA   # right holds → left is the free pinch
			if cand != null and free_pt.distance_to(cand.global_position) <= _obj_reach(cand):
				obj = cand
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
			if _scene_handle != null and _scene_handle.has_method("set_scaling"):
				_scene_handle.set_scaling(true)  # blue handle while scaling the world
		else:
			_scale_target = obj
			_scale_T0 = obj.global_transform
			_scale_filt_ready = false   # seed the scale smoothing filter fresh this gesture
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
		var raw_origin: Vector3 = PA + lin * (_scale_T0.origin - _scale_A0)
		var raw_basis: Basis = lin * _scale_T0.basis
		# Spike-reject + smooth (raw path amplifies pinch jitter by the scale factor).
		if not _scale_filt_ready:
			_scale_filt_origin = raw_origin
			_scale_filt_basis = raw_basis
			_scale_filt_ready = true
		else:
			# Clamp a superhuman one-frame jump in position, then ease toward the target.
			var step: Vector3 = raw_origin - _scale_filt_origin
			if step.length() > SCALE_MAX_ORIGIN_STEP:
				raw_origin = _scale_filt_origin + step.normalized() * SCALE_MAX_ORIGIN_STEP
			_scale_filt_origin = _scale_filt_origin.lerp(raw_origin, SCALE_FOLLOW_ALPHA)
			# Basis carries scale, so use a plain componentwise ease (slerp is rotation-only).
			_scale_filt_basis = Basis(
				_scale_filt_basis.x.lerp(raw_basis.x, SCALE_FOLLOW_ALPHA),
				_scale_filt_basis.y.lerp(raw_basis.y, SCALE_FOLLOW_ALPHA),
				_scale_filt_basis.z.lerp(raw_basis.z, SCALE_FOLLOW_ALPHA))
		_scale_target.global_transform = Transform3D(_scale_filt_basis, _scale_filt_origin)

func _end_scale() -> void:
	if _scale_active:
		if _scale_target != null and is_instance_valid(_scale_target) and _scale_target.has_method("set_two_hand"):
			_scale_target.set_two_hand(false)
			# Fully RELEASE the scaled object so it's placed in space and can be re-grabbed by
			# EITHER hand. Previously it stayed latched to whichever hand had been holding it,
			# so the other hand silently couldn't grab it after a scale (the "right pinch won't
			# grab but left does" report). Clear both handlers' latch + the body's own.
			for side in ["left_hand", "right_hand"]:
				var h = _hand_handlers.get(side)
				if h != null and h.picked_up_body == _scale_target:
					h.picked_up_body = null
					h.was_pickup_pressed = true   # require a fresh pinch edge before re-grab
			if _scale_target.has_method("let_go"):
				_scale_target.let_go()
		if _scale_is_world and _scene_handle != null and _scene_handle.has_method("set_scaling"):
			_scene_handle.set_scaling(false)
	_scale_active = false
	_scale_is_world = false
	_scale_target = null
	_scale_lost_frames = 0

# Approx world-space grab radius of an object (half AABB diagonal × scale + grace),
# so "free pinch near the object" scales with object size.
func _obj_reach(n: Node3D) -> float:
	var r := 0.10
	for c in n.get_children():
		if c is VisualInstance3D:
			var a: AABB = (c as VisualInstance3D).get_aabb()
			r = maxf(r, a.size.length() * 0.5 * maxf(n.scale.x, 0.2))
			break
	return r + 0.10

# ============================================================================
# GRAB SOUND + pinch helper
# ============================================================================
# Play a soft grounding "thunk" the frame a hand newly grabs a body.
func _update_grab_sound() -> void:
	for side in ["left_hand", "right_hand"]:
		var h = _hand_handlers.get(side)
		var now: bool = h != null and h.picked_up_body != null
		if now and not _prev_grabbed.get(side, false):
			_push_grab()
		_prev_grabbed[side] = now

func _push_grab() -> void:
	if _audio_playback == null:
		return
	var dur := 0.08
	var n := int(SAMPLE_RATE * dur)
	var to_fill: int = min(n, _audio_playback.get_frames_available())
	for i in range(to_fill):
		var t := float(i) / SAMPLE_RATE
		var u := t / dur
		var f: float = lerp(420.0, 230.0, u)   # quick downward pluck = "caught it"
		var s := (sin(TAU * f * t) * 0.5 + sin(TAU * f * 0.5 * t) * 0.2) * exp(-13.0 * u)
		_audio_playback.push_frame(Vector2(s, s))

func _on_kill_entered(body: Node3D):
	# Falling cubes despawn silently — score 0.
	if body.is_in_group("cube"):
		_active_cubes.erase(body)
		body.queue_free()

# ============================================================================
# DIAGNOSTICS — written to user://xr_diag.txt (pull with devicectl after a run)
# ============================================================================
# The one diagnostic kept for the shipped sample (grab telemetry was removed). _grab_diag()
# builds a status line appended every 5 s by _process: proc≈450 & phys≈300 per 5 s confirms the
# 90/60 render-vs-physics beat (the held body follows in PickupHandler._physics_process).
# follow_off = distance from the holding handler to its parent controller origin (how far the
# 90 Hz controller drags the body between 60 Hz re-pins).
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
	return "proc=%d phys=%d held=%s both_same=%s follow_off=%.3f active=%d collisions=%d" % [
		proc_d, phys_d, held_side, str(both_same), follow_off, _active_cubes.size(), _collision_count]

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
