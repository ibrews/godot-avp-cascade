class_name SceneHandle3D
extends Node3D

# A highly reflective chrome handlebar floating in the air. PURELY VISUAL — it is
# NOT a pickup body, so the PickupHandler can never auto-grab it by proximity
# (that was throwing the whole world when any pinch happened near the face).
# main_v2 implements the grab manually: when a confident hand index-pinches near
# this handle, the world (and this handle) follow the hand 1:1; a second-hand
# pinch scales the world about the handle.

const BAR_LENGTH := 0.26
const BAR_RADIUS := 0.022

var _ring_mat: StandardMaterial3D

func _ready() -> void:
	var chrome := StandardMaterial3D.new()
	chrome.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	chrome.albedo_color = Color(0.95, 0.96, 1.0)
	chrome.metallic = 1.0
	chrome.metallic_specular = 1.0
	chrome.roughness = 0.02
	chrome.rim_enabled = true
	chrome.rim = 0.6

	# Chrome bar — horizontal capsule.
	var bar := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = BAR_RADIUS
	cap.height = BAR_LENGTH
	bar.mesh = cap
	bar.rotation_degrees = Vector3(0.0, 0.0, 90.0)  # lay horizontal (along X)
	bar.material_override = chrome
	add_child(bar)

	# Two end-knobs.
	for sx in [-1.0, 1.0]:
		var knob := MeshInstance3D.new()
		var sph := SphereMesh.new()
		sph.radius = BAR_RADIUS * 1.6
		sph.height = BAR_RADIUS * 3.2
		knob.mesh = sph
		knob.position = Vector3(sx * BAR_LENGTH * 0.5, 0.0, 0.0)
		knob.material_override = chrome
		add_child(knob)

	# Emissive halo ring so it's easy to spot; brightens while held.
	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.05
	torus.outer_radius = 0.062
	ring.mesh = torus
	_ring_mat = StandardMaterial3D.new()
	_ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ring_mat.albedo_color = Color(0.7, 0.9, 1.0, 0.6)
	_ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ring_mat.emission_enabled = true
	_ring_mat.emission = Color(0.6, 0.85, 1.0)
	_ring_mat.emission_energy_multiplier = 1.6
	ring.material_override = _ring_mat
	add_child(ring)

# Brighten the halo when grabbed (called by main_v2).
func set_held(held: bool) -> void:
	if _ring_mat:
		_ring_mat.emission_energy_multiplier = 4.0 if held else 1.6
		_ring_mat.emission = Color(0.5, 1.0, 0.6) if held else Color(0.6, 0.85, 1.0)

# Blue while two-hand scaling/rotating the world (mirrors the object scale outline).
func set_scaling(on: bool) -> void:
	if _ring_mat == null:
		return
	if on:
		_ring_mat.emission = Color(0.20, 0.50, 1.0)
		_ring_mat.emission_energy_multiplier = 6.0
	else:
		_ring_mat.emission = Color(0.6, 0.85, 1.0)
		_ring_mat.emission_energy_multiplier = 1.6
