class_name CloudShadowReceiver
extends Node
## Cloud shadows on everything the sun lights (#760).
## On LOW the same receiver bakes Sky3D's dome cumulus instead (DOME_BAKE_SHADER, DomeShadowFeed).
## One sun-aligned Decal (modulate black, albedo_mix = strength, alpha = 1 - T) over a SPAN cube round
## the ground under the camera, fed by a SUN-SPACE map of the volumetric macro field
## (cloud_shadow_sun_bake.gdshader: the sea's march from CloudShadowWindow, one texel per sun ray).
## Terrain, roads, grass, the forest, buildings, props and vehicles all receive it with no per-material
## code: Godot applies decals in every colour pass, filtered only by `cull_mask & layers`. What must not
## receive it (the oceans, which keep their own sun-term shadow, and every fullscreen spatial quad, which
## would take one point's value over the whole screen) sits on NO_SHADOW_LAYER (`exclude()`).
##
## The map refreshes at REFRESH_S into the BACK of two bake viewports (it draws ONCE), and the next
## frame the decal swaps to it. Godot's decal atlas copies a texture when it is ADDED and never follows
## a re-rendered one, so the swap is what makes it copy the new bake, on the GPU, with no
## readback and no blank frame. (One viewport behind two Texture2DRD wrappers would be cheaper, but a
## Decal refuses a Texture2DRD and texture_rd_create refuses a viewport's texture.) In between, the decal slides with the
## synced cloud clock (the field is world-anchored and moves +clock), so every peer sees the same
## shadows and nothing goes over the network. The map's centre snaps to the texel lattice in the
## clouds' own frame, so consecutive bakes sample the same rays and a refresh does not shimmer.
##
## The decal darkens albedo, i.e. direct AND ambient diffuse; `strength()` scales it by the sun's share
## of the lit light (k = D / (D + I), measured per sun elevation and cloud cover), so a full
## cloud takes off roughly the direct share only. The sun's energy is never touched (owner decision).
## Cosmetic only: CloudBridge builds it, and CloudBridge never exists on a dedicated server or headless.
## Known limits: cast shadows and back faces inside a cloud shadow stay a little too dark;
## metals lose part of their reflection under it; anything above the cloud deck (an aircraft) is
## shadowed by the clouds beneath it too.

const SPAN := 12000.0
const RES := 512
## How often the map is re-baked, s. The clouds' drift between bakes is the decal's slide.
const REFRESH_S := 1.0
## Render layer 6 (bit 5): visible to the default camera mask, outside the cockpit strip (bits 8-19)
## and the mirror-hidden bit (7). The receiver's cull_mask is every layer but this one.
const NO_SHADOW_LAYER_BIT := 5
const NO_SHADOW_LAYERS := 1 << NO_SHADOW_LAYER_BIT
const RECEIVER_MASK := ((1 << 30) - 1) & ~NO_SHADOW_LAYERS
## The sun fades the shadow in over its first ~2 degrees (sin), on top of the bake's own 0.02 cut.
const SUN_FADE_SIN := 0.035
## A jump this far from the map's centre (teleport, fast flight) re-bakes at once, m.
const RECENTRE_M := 1500.0
const BAKE_SHADER := "res://src/sky/clouds/shaders/cloud_shadow_sun_bake.gdshader"
## The LOW tier's bake (#761): the dome cumulus in the same sun-space layout (DomeShadowFeed's uniforms).

## k = D / (D + I), the sun's share of the light on lit ground, on HIGH: rows are sun elevation (deg),
## the two columns cloud cover 0.1 and 0.5 (clamped and interpolated between). Measured by
## tools/cloud_shadow_shot.gd --kcal (tonemap linear, the sun's cull mask 0 vs normal, p50 over the
## ground pixels, 2026-11-11, Hachijō from the spawn).
const K_TABLE := [
	[0.0, 0.0, 0.0],
	[4.0, 0.49, 0.28],
	[7.0, 0.52, 0.28],
	[12.0, 0.60, 0.30],
	[23.0, 0.67, 0.34],
	[35.0, 0.70, 0.36],
	[39.0, 0.73, 0.37],
	[60.0, 0.76, 0.39], # above Hachijō's November noon: extrapolated, not measured
	[90.0, 0.78, 0.40],
]
const K_COVER_LO := 0.1
const K_COVER_HI := 0.5

## The decal, on the RenderingServer (ServerDecal below), not a Decal node.
var decal: ServerDecal = null

## The two bake targets (ping-pong) and their materials; _front is the one the decal shows.
var _vps: Array[SubViewport] = []
var _mats: Array[ShaderMaterial] = []
var _front := -1
var _back := 0
## The map the decal shows: centre, basis, the clock (x, z) it was baked at. Empty before the first.
var _snap := {}
## Baked this frame, waiting for the swap.
var _pending := {}
var _since := INF
var _strength := 0.0
## The bake this receiver was built with (BAKE_SHADER on HIGH, DOME_BAKE_SHADER on LOW) and its k table.
var bake_shader_path := BAKE_SHADER
var k_table: Array = K_TABLE
## Extra uniforms set on the back target before each bake (LOW: DomeShadowFeed.uniforms(), refreshed by
## CloudBridge every frame so a bake sees the dome as it is drawn that frame).
var bake_uniforms := {}


## Puts `vi` on the layer the receiver skips (and only there: a decal reaches an instance when ANY of
## its layers is in the cull mask).
## Runtime only: in the editor it would be saved into the scene. Anything UNSHADED or self-lit belongs
## here too (screens, gauges, glints, holograms, race lines): Godot's decal loop runs for unshaded
## draws, and an unshaded output IS its albedo, so the black decal would dim all of it.
static func exclude(vi: VisualInstance3D) -> void:
	if vi != null and not Engine.is_editor_hint():
		vi.layers = NO_SHADOW_LAYERS


## exclude_tree() at the end of the frame: for a subtree that finishes building in its _ready.
static func exclude_tree_deferred(root: Node) -> void:
	if root == null or Engine.is_editor_hint():
		return
	(func() -> void:
		if is_instance_valid(root):
			exclude_tree(root)).call_deferred()


## Every geometry instance under `root` (in its viewport) onto NO_SHADOW_LAYER: the oceans, which keep
## their own sun-term shadow and must not be darkened twice. Their meshes are built at
## runtime (breakers, far field, handover), so the owners call this again now and then. Returns how many
## it moved.
static func exclude_tree(root: Node) -> int:
	var n := 0
	if root == null or not root.is_inside_tree():
		return 0
	var vp := root.get_viewport()
	for c in root.find_children("*", "GeometryInstance3D", true, false):
		var gi := c as GeometryInstance3D
		if gi.layers != NO_SHADOW_LAYERS and gi.get_viewport() == vp:
			gi.layers = NO_SHADOW_LAYERS
			n += 1
	if root is GeometryInstance3D and (root as GeometryInstance3D).layers != NO_SHADOW_LAYERS:
		(root as GeometryInstance3D).layers = NO_SHADOW_LAYERS
		n += 1
	return n


## Orthonormal, +Y along the sun (the decal projects along its local Y).
static func sun_basis(to_sun: Vector3) -> Basis:
	var y := to_sun.normalized()
	var x := Vector3.UP.cross(y)
	if x.length() < 1e-3:
		x = Vector3.RIGHT
	x = x.normalized()
	return Basis(x, y, x.cross(y).normalized())


## The ground under the camera, roughly: the cube holds everything within SPAN/2 of it along the sun.
static func ground_centre(cam_pos: Vector3) -> Vector3:
	return Vector3(cam_pos.x, clampf(cam_pos.y - 2.0, 0.0, 900.0), cam_pos.z)


## Snaps `centre` to the map's texel lattice in the clouds' frame (the field moves +clock), so two
## bakes at different times sample the same sun rays through the same clouds.
static func snap_centre(centre: Vector3, b: Basis, clock_xz: Vector2) -> Vector3:
	var texel := SPAN / float(RES)
	var c := Vector3(clock_xz.x, 0.0, clock_xz.y)
	var rel := centre - c
	var u := snappedf(rel.dot(b.x), texel)
	var v := snappedf(rel.dot(b.z), texel)
	return c + b.x * u + b.y * rel.dot(b.y) + b.z * v


## A world point's texel in a map baked at `centre` / `b` (u along local +X, v along local +Z).
static func world_to_uv(p: Vector3, centre: Vector3, b: Basis) -> Vector2:
	var d := p - centre
	return Vector2(d.dot(b.x) / SPAN + 0.5, d.dot(b.z) / SPAN + 0.5)


## Where the sun ray through `p` meets sea level (the march's start: every point of the ray below the
## cloud base has its transmittance).
static func sea_level_foot(p: Vector3, to_sun: Vector3) -> Vector2:
	var s := to_sun.normalized()
	var f := p - s * (p.y / s.y)
	return Vector2(f.x, f.z)


## The decal's albedo_mix: the sun's share of the light, faded in over the first degrees of sun.
## 0 at and below the horizon (the key light is the moon then).
static func strength(sin_elev: float, cover: float, table: Array = K_TABLE) -> float:
	if sin_elev <= 0.0:
		return 0.0
	var e := rad_to_deg(asin(clampf(sin_elev, 0.0, 1.0)))
	var lo := 0.0
	var hi := 0.0
	for i in range(1, table.size()):
		var r0: Array = table[i - 1]
		var r1: Array = table[i]
		if e <= float(r1[0]) or i == table.size() - 1:
			var t := clampf((e - float(r0[0])) / maxf(float(r1[0]) - float(r0[0]), 1e-6), 0.0, 1.0)
			lo = lerpf(float(r0[1]), float(r1[1]), t)
			hi = lerpf(float(r0[2]), float(r1[2]), t)
			break
	var c := clampf((cover - K_COVER_LO) / (K_COVER_HI - K_COVER_LO), 0.0, 1.0)
	return lerpf(lo, hi, c) * smoothstep(0.0, SUN_FADE_SIN, sin_elev)


## Builds the bake and the decal. On HIGH (`bake_shader`: BAKE_SHADER) the bake compiles against the
## cloud globals registered here; on LOW (DOME_BAKE_SHADER, K_TABLE_LOW) it reads `bake_uniforms`.
func setup(bake_shader := BAKE_SHADER, table: Array = K_TABLE) -> bool:
	CloudGlobals.ensure()
	bake_shader_path = bake_shader
	k_table = table
	var shader := load(bake_shader) as Shader
	for k in 2:
		var vp := SubViewport.new()
		vp.name = "SunMapBake%d" % k
		vp.size = Vector2i(RES, RES)
		vp.own_world_3d = true
		vp.transparent_bg = true
		vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
		vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
		add_child(vp)
		var cam := Camera3D.new()
		vp.add_child(cam)
		cam.current = true
		cam.projection = Camera3D.PROJECTION_ORTHOGONAL
		cam.size = 2.0
		cam.near = 0.1
		cam.far = 10.0
		cam.position = Vector3(0.0, 0.0, 1.0) # looks -Z, AT the quad (z = -1 sees nothing: #759)
		var quad := MeshInstance3D.new()
		vp.add_child(quad)
		quad.mesh = QuadMesh.new()
		(quad.mesh as QuadMesh).size = Vector2(2.0, 2.0)
		var mat := ShaderMaterial.new()
		mat.shader = shader
		mat.set_shader_parameter(&"map_span", SPAN)
		quad.material_override = mat
		_vps.append(vp)
		_mats.append(mat)
	decal = ServerDecal.new(get_viewport().find_world_3d().scenario)
	decal.size = Vector3(SPAN, SPAN, SPAN)
	decal.modulate = Color(0.0, 0.0, 0.0, 1.0)
	decal.albedo_mix = 0.0
	# Godot's default 0.3 fades along the local Y; in the sun-aligned cube that is a distance
	# falloff along the sun's azimuth with nothing to do with the clouds.
	decal.upper_fade = 0.0
	decal.lower_fade = 0.0
	decal.normal_fade = 0.0
	decal.cull_mask = RECEIVER_MASK
	decal.visible = false
	return true


## One frame: bake when due, swap the frame after, slide with the clock, set the strength.
## `clock_xz` is where the shadowing pattern has moved in world XZ (HIGH: the cloud clock's offset,
## CloudClock.x / .z; LOW: DomeShadowFeed.drift), `cover` the weather's cloud cover, `fade` a multiplier
## on the strength (LOW: the fade under the dome's assumed deck).
func tick(delta: float, cam_pos: Vector3, to_sun: Vector3, clock_xz: Vector2, cover: float, fade := 1.0) -> void:
	if _vps.is_empty() or decal == null:
		return
	_since += delta
	var sun := to_sun.normalized()
	_strength = strength(sun.y, cover, k_table) * clampf(fade, 0.0, 1.0)
	if not _pending.is_empty():
		_swap()
	elif sun.y > 0.02 and (_since >= REFRESH_S or _far_from_map(cam_pos, clock_xz)):
		_bake(cam_pos, sun, clock_xz)
	if _snap.is_empty():
		decal.visible = false
		return
	var c0: Vector2 = _snap["clock"]
	var drift := clock_xz - c0
	decal.global_transform = Transform3D(_snap["basis"], (_snap["centre"] as Vector3) + Vector3(drift.x, 0.0, drift.y))
	decal.albedo_mix = _strength
	decal.visible = _strength > 0.001


func _far_from_map(cam_pos: Vector3, clock_xz: Vector2) -> bool:
	if _snap.is_empty():
		return true
	var c0: Vector2 = _snap["clock"]
	var drift := clock_xz - c0
	var c: Vector3 = _snap["centre"]
	return Vector2(cam_pos.x - c.x - drift.x, cam_pos.z - c.z - drift.y).length() > RECENTRE_M


func _bake(cam_pos: Vector3, sun: Vector3, clock_xz: Vector2) -> void:
	var b := sun_basis(sun)
	var c := snap_centre(ground_centre(cam_pos), b, clock_xz)
	_back = 1 if _front == 0 else 0
	var m := _mats[_back]
	for k in bake_uniforms:
		m.set_shader_parameter(k, bake_uniforms[k])
	m.set_shader_parameter(&"map_center", c)
	m.set_shader_parameter(&"map_x", b.x)
	m.set_shader_parameter(&"map_z", b.z)
	m.set_shader_parameter(&"to_sun", b.y)
	_vps[_back].render_target_update_mode = SubViewport.UPDATE_ONCE
	_pending = {"centre": c, "basis": b, "clock": clock_xz}
	_since = 0.0


## The back bake drew last frame: show it, so the atlas copies it (and drops the front one).
func _swap() -> void:
	decal.set_albedo_texture(_vps[_back].get_texture().get_rid())
	_front = _back
	_snap = _pending
	_pending = {}


## Stops at once: the decal leaves the scene and the bakes stop (the node may be freed later).
func shutdown() -> void:
	if decal != null:
		decal.free_rids()
		decal = null
	for vp in _vps:
		vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_snap = {}
	_pending = {}


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and decal != null:
		decal.free_rids()
		decal = null


## Off: hides the decal and drops the map (the next tick bakes afresh). For A/B shots.
func reset() -> void:
	_snap = {}
	_pending = {}
	_since = INF
	if decal != null:
		decal.visible = false


func get_strength() -> float:
	return _strength


func has_map() -> bool:
	return not _snap.is_empty()


## The map's sun direction (+Y of its frame); Vector3.ZERO before the first map.
func map_sun() -> Vector3:
	return (_snap["basis"] as Basis).y if not _snap.is_empty() else Vector3.ZERO


## Diagnostics for rigs: the snapshot, the strength, the decal's state.
func describe() -> Dictionary:
	return {"has_map": has_map(), "strength": snappedf(_strength, 0.001),
		"centre": _snap.get("centre", Vector3.INF), "sun": map_sun(),
		"decal_visible": decal.visible if decal != null else false,
		"cull_mask": decal.cull_mask if decal != null else 0}


## Rig readback (slow: a GPU read): the map the decal shows, alpha = 1 - T; null before the first.
func map_image() -> Image:
	return _vps[_front].get_texture().get_image() if _front >= 0 else null


## Rig readback (slow: a GPU read): the transmittance the decal applies at world point `p` right
## now, 1 - alpha of the bake, bilinear; NAN outside the map or before the first.
func sample_map(p: Vector3) -> float:
	if _snap.is_empty() or decal == null:
		return NAN
	var img := _vps[_front].get_texture().get_image() if _front >= 0 else null
	if img == null:
		return NAN
	var uv := world_to_uv(p, decal.global_position, _snap["basis"])
	if uv.x < 0.0 or uv.y < 0.0 or uv.x > 1.0 or uv.y > 1.0:
		return NAN
	var x := uv.x * RES - 0.5
	var y := uv.y * RES - 0.5
	var x0 := clampi(int(floor(x)), 0, RES - 1)
	var y0 := clampi(int(floor(y)), 0, RES - 1)
	var x1 := mini(x0 + 1, RES - 1)
	var y1 := mini(y0 + 1, RES - 1)
	var fx := clampf(x - floor(x), 0.0, 1.0)
	var fy := clampf(y - floor(y), 0.0, 1.0)
	var a := lerpf(lerpf(img.get_pixel(x0, y0).a, img.get_pixel(x1, y0).a, fx),
			lerpf(img.get_pixel(x0, y1).a, img.get_pixel(x1, y1).a, fx), fy)
	return 1.0 - a


## A decal made on the RenderingServer, with the few properties the receiver sets. Not a Decal node:
## the node's texture setter warns on every ViewportTexture (a DEBUG check that it "cannot be used"),
## yet the server takes the RID, and the atlas copying it when it is assigned is exactly what the
## swap relies on. The node gives no way to reach its server decal (get_base() is not it: Decal sets
## the instance's base on the server directly), so the decal lives here whole.
class ServerDecal extends RefCounted:
	var rid: RID
	var instance: RID
	var size := Vector3.ONE:
		set(v):
			size = v
			RenderingServer.decal_set_size(rid, v)
	var modulate := Color.WHITE:
		set(v):
			modulate = v
			RenderingServer.decal_set_modulate(rid, v)
	var albedo_mix := 1.0:
		set(v):
			albedo_mix = v
			RenderingServer.decal_set_albedo_mix(rid, v)
	var upper_fade := 0.3:
		set(v):
			upper_fade = v
			RenderingServer.decal_set_fade(rid, upper_fade, lower_fade)
	var lower_fade := 0.3:
		set(v):
			lower_fade = v
			RenderingServer.decal_set_fade(rid, upper_fade, lower_fade)
	var normal_fade := 0.0:
		set(v):
			normal_fade = v
			RenderingServer.decal_set_normal_fade(rid, v)
	var cull_mask := 0xFFFFF:
		set(v):
			cull_mask = v
			RenderingServer.decal_set_cull_mask(rid, v)
	var visible := true:
		set(v):
			visible = v
			RenderingServer.instance_set_visible(instance, v)
	var global_transform := Transform3D.IDENTITY:
		set(v):
			global_transform = v
			RenderingServer.instance_set_transform(instance, v)
	var global_basis: Basis:
		get:
			return global_transform.basis
	var global_position: Vector3:
		get:
			return global_transform.origin

	func _init(scenario: RID) -> void:
		rid = RenderingServer.decal_create()
		instance = RenderingServer.instance_create2(rid, scenario)
		RenderingServer.decal_set_distance_fade(rid, false, 0.0, 0.0)

	func set_albedo_texture(tex: RID) -> void:
		RenderingServer.decal_set_texture(rid, RenderingServer.DECAL_TEXTURE_ALBEDO, tex)

	func free_rids() -> void:
		if instance.is_valid():
			RenderingServer.free_rid(instance)
		if rid.is_valid():
			RenderingServer.free_rid(rid)
		instance = RID()
		rid = RID()
