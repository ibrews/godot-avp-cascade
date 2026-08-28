# Two-instance headless test driver for the multiplayer race (HOST/JOIN,
# 3-2-1 countdown, live score exchange, final standings). Run TWO separate
# Godot processes against this same project — one per role — since that's
# what actually exercises two independent ENet/relay endpoints:
#
#   ROLE=host  Godot.app/Contents/MacOS/Godot --headless --path test-project --script tools/race_test_driver.gd
#   ROLE=client Godot.app/Contents/MacOS/Godot --headless --path test-project --script tools/race_test_driver.gd
#
# FORCE_RELAY=1 skips ENet/LAN entirely and drives the Cloudflare relay path
# directly (the WAN fallback), instead of the default LAN beacon/discovery.
#
# Loads main_v2.tscn standalone (bypassing --script's normal main-scene skip)
# and pokes the same _race_* functions a real poke-button press would call —
# no mock objects, this is the real host()/join()/RPC/relay code path. Fakes
# score increments during the race (no hand-tracking in headless) so the wire
# protocol carries real changing numbers to compare between the two logs.
extends SceneTree

var main: Node3D
var role := ""
var force_relay := false
var t := 0.0
var acted := false
var start_sent := false
var score_accum_t := 0.0
var status_t := 0.0
const TEST_TIMEOUT := 55.0

func _initialize() -> void:
	role = OS.get_environment("ROLE")
	if role == "":
		role = "host"
	force_relay = OS.get_environment("FORCE_RELAY") == "1"
	var packed: PackedScene = load("res://main_v2.tscn")
	main = packed.instantiate()
	root.add_child(main)
	var tag := OS.get_environment("TAG")
	if tag != "":
		main._apply_initials(tag)
	print("[TEST %s] instantiated main scene (force_relay=%s tag=%s)" % [role, str(force_relay), main._player_initials])

func _process(delta: float) -> bool:
	t += delta

	if not acted and t > 1.0:
		acted = true
		if role == "host":
			if force_relay:
				main._race_hosting = true
				main._race_relay_connect()
			else:
				main._race_gp_host()
			print("[TEST host] hosting started")
		else:
			if force_relay:
				main._race_client = true
				main._race_relay_connect()
			else:
				main._race_gp_join()
			print("[TEST client] join/search started")

	if role == "host" and acted and not start_sent and main._race_has_any_peer():
		start_sent = true
		print("[TEST host] peer detected @ t=%.1f — triggering START RACE" % t)
		main._race_gp_start_race()

	if main._race_mode:
		score_accum_t += delta
		if score_accum_t > 0.7:
			score_accum_t = 0.0
			main._round_score += (11 if role == "host" else 7)

	status_t += delta
	if status_t > 1.0:
		status_t = 0.0
		var status_txt: String = str(main._race_status_label.text) if main._race_status_label != null else "?"
		print("[TEST %s] t=%.1f status='%s' round_score=%d race_mode=%s countdown=%s scores=%s" % [
			role, t, status_txt, main._round_score, str(main._race_mode),
			str(main._race_countdown_active), str(main._race_scores)])

	if t > TEST_TIMEOUT:
		print("[TEST %s] FINAL round_score=%d scores=%s" % [role, main._round_score, str(main._race_scores)])
		return true
	return false
