class_name SkyAtmosphere
extends Node
## THE PHYSICAL ATMOSPHERE (R27).
##
## Replaces Sky3D's artistic scatter and its AtmFog quad with one physically based atmosphere
## (Hillaire 2020): a transmittance, a multiple-scattering, a sky-ambient,
## a sky-view and an aerial-perspective table, baked on the GPU (AtmosphereBakeGlsl) and published
## as global shader parameters (atmosphere.gdshaderinc documents the API). Sky3D keeps the time of
## day, the sun and moon discs, the stars and the lights; the lights take their colour from here.
##
## ONE SWITCH: `enabled`. Off, the sky draws Sky3D's scatter and the fog quad is AtmFog again,
## exactly as before.
##
## QUIET: nothing is baked unless an input moved past a step nobody can see (the sun 0.03 deg, the
## camera's altitude 2 %, the haze 1 %), and only then is the sky's reflection map told to redraw
## (`atm_epoch` on the sky material: the tables are globals, which never dirty it on their own).
##
## MULTIPLAYER: every input is shared state or the local camera: the sun and the moon from the
## synced clock (TimeOfDay), the haze and the deck from the synced weather fields (set_weather), the
## altitude from this peer's camera (visual only).
##
## Add it at runtime as a child of Sky3D's SkyDome with `dome` set (demo/cloud_demo.gd does); it works
## next to an unmodified Sky3D. Never in the editor, whose sky stays Sky3D's.

const Glsl := preload("res://src/sky/atmosphere/atmosphere_bake_glsl.gd")
const Model := preload("res://src/sky/atmosphere/atmosphere_model.gd")
const AtmosphereGlobalsRef := preload("res://src/sky/atmosphere/atmosphere_globals.gd")
const AP_MUL_SHADER := "res://src/sky/atmosphere/atmosphere_ap_mul.gdshader"
const AP_ADD_SHADER := "res://src/sky/atmosphere/atmosphere_ap_add.gdshader"
const AP_ONE_SHADER := "res://src/sky/atmosphere/atmosphere_ap_one.gdshader"

const FORMAT := RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
const TRANS_SIZE := Vector2i(256, 64)
const MS_SIZE := Vector2i(32, 32)
const SKYVIEW_SIZE := Vector2i(256, 128)
const AERIAL_SIZE := Vector3i(64, 32, 32)
const BAKE_STATIC := 1
const BAKE_VIEW := 2

## The switch (R27). Off = Sky3D's scatter and AtmFog, as before.
@export var enabled := true:
	set(v):
		if enabled == v:
			return
		enabled = v
		_switch_dirty = true

@export_group("Look")
## The haze of a clear day: a multiplier on Hillaire's clear-air aerosol. Hachijo is maritime and
## humid: ridges 10-20 km off are visibly blue-grey on a fine day (5: ~70 km visibility at sea level).
@export var base_haze := 3.5
## The sky's light against the sun's. It sits where Sky3D's sky was (zenith 0.10, the horizon 0.9 at a 38 deg sun, a
## white surface facing that sun 1.1), so the ambient the game was tuned with (Environment
## ambient_light_energy, SDFGI, both fed by the sky) keeps its balance: 2.3.
@export var sky_gain := 2.3
## The moon's light on the sky, as a share of the sun's above the atmosphere, at full moon. The real
## ratio is 2.5e-6; a game night needs a visible moonlit sky.
@export var moon_sky_ratio := 0.02
## The night sky's own light (airglow, scattered starlight, the towns' glow on the haze).
@export var night_sky := Color(0.0024, 0.0038, 0.0072)
## THE TOWNS' GLOW (TODO 47, NIGHT/NOTES.md): their lights scattered back down by the haze
## (SKYGLOW), a band low over the horizon (exp(-20 el)), in the haze in front of far geometry and so in the night's
## ambient (the sky lights the scene). Its luminance at the horizon on a clear night (scene units; the
## airglow's there is ~0.03), its colour (sodium and warm LED), x (1 + the closed deck: clouds send it back
## down). Fades in as the street lights come on (sun_y 0.05 .. -0.12). 0 = none (A/B:
## n.SkyAtmosphere.town_glow_level=0).
@export var town_glow_level := 0.0
@export var town_glow := Color(1.0, 0.62, 0.36)
## Sun disc radiance in units of the sun's illuminance (600).
@export var sun_disc_gain := 600.0
## THE AUREOLE (TODO 45): the aerosol's forward light round the
## sun as a two-term phase (a narrow diffraction peak on a broad lobe, atmosphere_math's
## atm_phase_aureole), the sun's part evaluated per pixel by the sky (the sky-view table's right half).
## false = one Cornette-Shanks lobe (g 0.85) baked into the tables, as before (A/B:
## n.SkyAtmosphere.aureole=false).
@export var aureole := true:
	set(v):
		if aureole == v:
			return
		aureole = v
		_aureole_dirty = true
## THE EYE'S ADAPTATION. The game's camera exposure is nearly fixed (auto exposure between ISO 190
## and 250), while daylight falls by orders of magnitude from noon to dusk. Physically lit, golden
## hour went dark and the twilight sky black. So the sun AND the sky are scaled together by
## (E_noon / E)^adapt_pow, capped at adapt_max, where E is the light on level ground (the sun through
## the air, plus the sky: the ambient table, read back from the GPU): the sky-to-sun ratio stays
## physical, the scene dims monotonically with the sun, less than the bare physics. Daylight adapts
## gently (0.35: a wall facing a 20 deg sun stays at its noon brightness instead of overshooting it);
## below adapt_knee (5 % of noon's light: the sun a degree or two up) the eye adapts harder
## (adapt_pow_dusk), so the blue hour stays readable. The moon's light is not adapted (its level,
## moon_sky_ratio, is already a game's). adapt_pow 0 turns it off.
@export var adapt_pow := 0.35
@export var adapt_pow_dusk := 0.6
@export var adapt_knee := 0.05
@export var adapt_max := 40.0
## The noon the adaptation is measured against (sun elevation, deg).
const ADAPT_REF_EL := 60.0

## The aerial perspective's passes: 0 = the mul + add pair (writes no colour alpha: FSR2-safe), 1 = one
## premultiplied pass (ALPHA = 1 - what the air lets through: FSR2 would read that as its reactive mask;
## nothing else reads the colour buffer's alpha), 2 = one pass unless the main viewport upscales with FSR2.
## The same picture (stills differ less than two frames of the pair do); one pass saves 0.15-0.7 ms at
## 1080p (NIGHT/NOTES.md run N3: -0.37 ms over 5 views, 4 pairs each). A/B: n.SkyAtmosphere.ap_single_pass=0.
@export var ap_single_pass := 2

@export_group("Quiet")
## Re-bake the view tables when the sun turned by this much (deg).
@export var sun_step_deg := 0.03
## ...or the camera's altitude moved by max(this, ALT_REL x altitude) (m): the sky from 30 m and from
## 40 m is the same sky (PlanetHorizon's cam_altitude rides the same steps).
@export var alt_step_m := 5.0
const ALT_REL := 0.03

## Set by SkyDome when it creates this node.
var dome: SkyDome = null

# ---- inputs (main thread) ----
var _weather_haze := 1.0      # x base_haze
var _closed := 0.0
var _switch_dirty := true
var _applied_on := false

# ---- what was baked (main thread) ----
var _baked_static := Vector3(-1.0, -1.0, -1.0)   # haze, closed, gain
var _aureole_dirty := true
var _baked_sun := Vector3.ZERO
var _baked_moon := Vector3.ZERO
var _baked_moon_e := -1.0
var _baked_alt := -1.0e9
var _baked_reach := -1.0
var _baked_e0 := -1.0
var _have_view := false
var _epoch := 0
var _light_alt := -1.0e9
var _baked_adapt := 1.0
var _baked_amb_version := 0
## The ambient table's sea-level row (32 sun zenith cosines), luminance per unit sun: render thread
## writes (an async read-back after every static bake), main thread reads, under _mutex.
var _amb_row := PackedFloat32Array()
var _amb_version := 0

# ---- textures, created on the render thread, wrapped here ----
var _mutex := Mutex.new()
var _rt_ready := 0      # 0 = not started, 1 = building, 2 = ready, -1 = failed
var _rt_error := ""
var _rt_tex := {}       # name -> RID (render thread)
var _wrapped := false
var _wrappers: Array = []

# ---- render thread ----
var _rd: RenderingDevice = null
var _shaders := {}
var _pipes := {}
var _sets := {}
var _sampler := RID()

var _ap_mul_shader: Shader = null
var _ap_add_shader: Shader = null
var _ap_add_mat: ShaderMaterial = null
var _ap_one_shader: Shader = null
var _ap_single_applied := false
var _town_pub := Vector3(-1.0, -1.0, -1.0)
var _atmfog_shader: Shader = null


func _ready() -> void:
	set_process(true)
	# After SkyDome, whose own light update would otherwise have the last word on the sun's colour.
	process_priority = 100
	_stats_on = OS.get_environment("ATM_STATS") == "1"
	RenderingServer.call_on_render_thread(_rt_build)


# ---------------------------------------------------------------------------------------------
# ATM_STATS=1 (env): one line every 10 s: the bakes, the sky-material writes and the frames on which
# the sun's or the moon's DirectionalLight changed (each dirties the sky's reflection map), and the
# froxel fog's state. Diagnostics only.

var _stats_on := false
var _st_t := 0.0
var _st_bake_s := 0
var _st_bake_v := 0
var _st_light := 0
var _st_frames := 0
var _st_writes0 := 0
var _st_sig: Array = []


func _stats_tick(delta: float) -> void:
	_st_t += delta
	_st_frames += 1
	var sig: Array = []
	for l: DirectionalLight3D in [dome._sun_light_node, dome._moon_light_node]:
		if l != null:
			sig.append_array([l.global_transform, l.light_energy, l.light_color, l.shadow_enabled, l.visible])
	if sig != _st_sig:
		_st_sig = sig
		_st_light += 1
	if _st_t < 10.0:
		return
	var env: Environment = null
	var w := get_viewport().find_world_3d() if is_inside_tree() else null
	if w != null:
		env = w.environment
	var sun := _sun_dir()
	var moon := _moon_dir()
	print("[atm] stats %.1f s %d frames: on %s bakes static %d view %d light-change frames %d sky writes %d sun_y %.3f moon_y %.3f adapt %.2f alt %.0f volfog %s %.6f" % [
			_st_t, _st_frames, is_active(), _st_bake_s, _st_bake_v, _st_light, 0,
			sun.y, moon.y, _baked_adapt, _baked_alt, env.volumetric_fog_enabled if env != null else false,
			env.volumetric_fog_density if env != null else -1.0])
	_st_t = 0.0
	_st_frames = 0
	_st_bake_s = 0
	_st_bake_v = 0
	_st_light = 0


func _exit_tree() -> void:
	_apply_switch(false)
	_set_globals_enabled(false)
	if _wrapped:
		# Hand the globals placeholders before the wrappers go: a material that still declares them
		# (the next map's sky) must not meet a freed texture.
		for name: String in WRAPPED:
			var t3 := name == "atm_aerial_lut"
			RenderingServer.global_shader_parameter_set(StringName(name), AtmosphereGlobalsRef.placeholder(
					RenderingServer.GLOBAL_VAR_TYPE_SAMPLER3D if t3 else RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D))
		_wrapped = false
	for w in _wrappers:
		if w is Texture2DRD:
			(w as Texture2DRD).texture_rd_rid = RID()
		elif w is Texture3DRD:
			(w as Texture3DRD).texture_rd_rid = RID()
	_wrappers.clear()
	if _rd != null:
		# A static callable with the RIDs bound: this node may be gone before the render thread runs it.
		var rids: Array[RID] = []
		for k in _pipes:
			rids.append(_pipes[k])
		for k in _shaders:
			rids.append(_shaders[k])
		for k in _rt_tex:
			rids.append(_rt_tex[k])
		rids.append(_sampler)
		RenderingServer.call_on_render_thread(SkyAtmosphere._rt_free_rids.bind(_rd, rids))
		_rd = null


## The weather's share: haze_mult x base_haze is the aerosol, closed 0..1 the
## deck (0 = open sky, 1 = a closed overcast).
func set_weather(haze_mult: float, closed: float) -> void:
	_weather_haze = maxf(haze_mult, 0.0)
	_closed = clampf(closed, 0.0, 1.0)


## True when the physical atmosphere is what the game draws (the switch, and the tables exist).
func is_active() -> bool:
	return enabled and _applied_on


## The sun's illuminance above the atmosphere, in scene units: the authored noon light (SkyDome's
## base sun_light_energy, before the weather dims it) at the reference transmittance.
func sun_e0() -> float:
	var base := 1.2
	if dome != null:
		base = dome.sun_light_energy
	return PI * base / maxf(Model.luminance(_t_ref()), 1e-3)


func haze() -> float:
	return base_haze * _weather_haze


## The sun's DirectionalLight from the atmosphere: [color (sRGB, max channel 1), energy factor] for a
## sun whose direction is `to_sun`, seen from altitude h_m. energy factor x SkyDome's sun_light_energy
## is the light's energy: 1 at the reference (sea level, zenith sun, the clear-day haze).
func sun_light(to_sun: Vector3, h_m: float) -> Array:
	var key := Vector4(to_sun.y, h_m, haze(), base_haze * 1000.0 + _baked_adapt)
	if key == _light_key:
		return _light_val
	_light_key = key
	var t := Model.transmittance(maxf(h_m, 0.0) * 0.001, to_sun.y, haze())
	var m := maxf(t.x, maxf(t.y, t.z))
	if m <= 1e-6:
		_light_val = [Color.BLACK, 0.0]
		return _light_val
	var c := Color(t.x / m, t.y / m, t.z / m)
	var lum_c := Model.luminance(Vector3(c.r, c.g, c.b))
	var ratio := Model.luminance(t) / maxf(Model.luminance(_t_ref()), 1e-3)
	var e := ratio * _baked_adapt / maxf(lum_c, 1e-3)
	_light_val = [c.linear_to_srgb(), e]
	return _light_val


## The light on level ground from a sun of zenith cosine mu, per unit of the sun's illuminance above
## the air: the direct sun through the air, and the sky (pi x the ambient table's mean radiance,
## read back per unit sun: _amb_row). 0 before the first read-back has landed.
func ground_light(mu: float, h_m: float) -> float:
	_mutex.lock()
	var row := _amb_row
	_mutex.unlock()
	if row.size() < 32:
		return 0.0
	var t := Model.transmittance(maxf(h_m, 0.0) * 0.001, mu, haze())
	var x := clampf((mu * 0.5 + 0.5) * 31.0, 0.0, 31.0)
	var i := mini(int(x), 30)
	var sky := lerpf(row[i], row[i + 1], x - float(i))
	return Model.luminance(t) * maxf(mu, 0.0) + PI * sky


## The adaptation for the sun as it stands now (adapt_pow); 1 until the ambient table is read back.
func adaptation_now(to_sun: Vector3, h_m: float) -> float:
	if adapt_pow <= 0.0:
		return 1.0
	var e := ground_light(to_sun.y, h_m)
	var e_ref := ground_light(sin(deg_to_rad(ADAPT_REF_EL)), h_m)
	if e_ref <= 0.0:
		return 1.0
	var x := maxf(e / e_ref, 1e-6)
	var a := pow(maxf(x, adapt_knee), -adapt_pow) * pow(minf(x / adapt_knee, 1.0), -adapt_pow_dusk)
	return clampf(a, 1.0, adapt_max)


## The adaptation the light and the tables were last baked with.
func adaptation() -> float:
	return _baked_adapt


var _light_key := Vector4(INF, INF, INF, INF)
var _light_val: Array = [Color.WHITE, 1.0]


## The altitude the sun's light is evaluated at: the main camera's, as last baked.
func light_altitude() -> float:
	return _baked_alt if _have_view else 2.0


var _t_ref_cache := Vector3.ZERO
var _t_ref_haze := -1.0


func _t_ref() -> Vector3:
	# The reference stays the CLEAR day's, so the weather's haze dims the light instead of moving
	# the reference with it.
	if _t_ref_haze != base_haze:
		_t_ref_haze = base_haze
		_t_ref_cache = Model.transmittance(0.0, 1.0, base_haze)
	return _t_ref_cache


# ---------------------------------------------------------------------------------------------
# Main thread, every frame: what moved, what to bake, what to publish.

func _process(_delta: float) -> void:
	if dome == null or not is_instance_valid(dome) or not dome.is_scene_built:
		return
	if _stats_on:
		_stats_tick(_delta)
	_mutex.lock()
	var state := _rt_ready
	_mutex.unlock()
	if state == -1:
		if _rt_error != "":
			push_warning("[SkyAtmosphere] the bake failed (%s): Sky3D's sky stays" % _rt_error)
			_rt_error = ""
		if _applied_on:
			_apply_switch(false)
		return
	if state != 2:
		return
	if not _wrapped and not _wrap_textures():
		return
	var on := enabled
	if not on:
		if _applied_on or _switch_dirty:
			_switch_dirty = false
			_apply_switch(false)
			_set_globals_enabled(false)
		return

	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	var alt := 2.0
	var reach := 32000.0
	if cam != null:
		alt = maxf(cam.global_position.y, 0.0)
		# The view tables reach past the far plane (PlanetHorizon grows it with altitude), in steps.
		reach = maxf(32000.0, pow(2.0, ceil(log(cam.far * 1.1) / log(2.0))))
	var sun := _sun_dir()
	var moon := _moon_dir()
	var hz := haze()
	var e0_base := sun_e0()
	var phase := clampf((1.0 - sun.dot(moon)) * 0.5, 0.0, 1.0)
	var moon_up := smoothstep(-0.05, 0.05, moon.y)
	var moon_base := e0_base * moon_sky_ratio * phase * moon_up
	var gain := sky_gain

	var bake := 0
	var st := Vector3(hz, _closed, gain)
	if _baked_static.x < 0.0 or absf(st.x - _baked_static.x) > 0.01 * maxf(_baked_static.x, 0.1) \
			or absf(st.y - _baked_static.y) > 0.005 or st.z != _baked_static.z or _aureole_dirty:
		bake |= BAKE_STATIC | BAKE_VIEW
		_aureole_dirty = false
	var cos_step := cos(deg_to_rad(sun_step_deg))
	_mutex.lock()
	var amb_v := _amb_version
	_mutex.unlock()
	if amb_v != _baked_amb_version:
		bake |= BAKE_VIEW
	if not _have_view or sun.dot(_baked_sun) < cos_step \
			or absf(alt - _baked_alt) > maxf(alt_step_m, ALT_REL * _baked_alt) \
			or reach != _baked_reach or absf(e0_base - _baked_e0) > 0.002 * _baked_e0 \
			or absf(moon_base - _baked_moon_e) > 0.01 * maxf(_baked_moon_e, 1e-5) \
			or (moon_base > 0.0 and moon.dot(_baked_moon) < cos(deg_to_rad(0.1))):
		bake |= BAKE_VIEW
	if bake != 0:
		if bake & BAKE_STATIC:
			_st_bake_s += 1
		_st_bake_v += 1
		if bake & BAKE_STATIC:
			_baked_static = st
		_baked_sun = sun
		_baked_moon = moon
		_baked_moon_e = moon_base
		_baked_alt = alt
		_baked_reach = reach
		_baked_e0 = e0_base
		_have_view = true
		# Everything the adaptation depends on (the sun, the altitude, the haze, the ambient table's
		# read-back) re-bakes: here only.
		_baked_amb_version = amb_v
		var adapt := adaptation_now(sun, alt)
		var e0 := e0_base * adapt
		var moon_e := moon_base
		var p := PackedFloat32Array([
			sun.x, sun.y, sun.z, e0 * gain,
			moon.x, moon.y, moon.z, moon_e * gain,
			_rg_km(), _baked_static.x, _baked_static.y, alt * 0.001,
			reach * 0.001, 1.0 if aureole else 0.0, 0.0, 0.0])
		# The ambient table is per the UNADAPTED sun (it does not follow the sun's direction, only its
		# zenith angle): the lookup multiplies the adaptation back in (atm_cam.w).
		var ps := p.duplicate()
		ps[3] = e0_base * gain
		var light_moved := (bake & BAKE_STATIC) != 0 or absf(alt - _light_alt) > maxf(alt_step_m, ALT_REL * _light_alt) \
				or absf(adapt - _baked_adapt) > 0.002 * _baked_adapt
		RenderingServer.call_on_render_thread(_rt_bake.bind(p, ps, bake))
		_baked_adapt = adapt
		_publish(sun, e0, moon, moon_e, alt, reach, hz)
		_epoch += 1
		_sky_param(&"atm_epoch", float(_epoch % 4096))
		if light_moved and _applied_on:
			_light_alt = alt
			_apply_sun_light()
	if _switch_dirty or not _applied_on:
		_switch_dirty = false
		_light_alt = alt
		_apply_switch(true)
	elif _ap_single_now() != _ap_single_applied and dome.fog_material is ShaderMaterial:
		_apply_ap_passes(dome.fog_material as ShaderMaterial, not _ap_single_applied)
	# The towns' glow: on its own steps (1 %), a sky write when it moved (the reflection map, the ambient).
	var town := town_glow_now(sun.y)
	if (town - _town_pub).length() > 0.01 * maxf(_town_pub.length(), 1e-4):
		_town_pub = town
		RenderingServer.global_shader_parameter_set(&"atm_town", Vector4(town.x, town.y, town.z, 0.0))
		_epoch += 1
		_sky_param(&"atm_epoch", float(_epoch % 4096))
	sync_add_pass()
	# Stock SkyDome rewrites the sun light on its own ticks: the atmosphere's colour goes back on after it.
	_apply_sun_light()


## The towns' glow at the horizon (scene units, rgb) for a sun of height sun_y: town_glow at
## town_glow_level luminance, as dark falls (sun_y 0.05 .. -0.12), x (1 + the closed deck). Shared state only.
func town_glow_now(sun_y: float) -> Vector3:
	var c := Vector3(town_glow.r, town_glow.g, town_glow.b)
	var l := Model.luminance(c)
	if l <= 0.0 or town_glow_level <= 0.0:
		return Vector3.ZERO
	var dark := smoothstep(0.05, -0.12, sun_y)
	return c * (town_glow_level / l * dark * (1.0 + _closed))


## One aerial-perspective pass or the pair (ap_single_pass).
func _ap_single_now() -> bool:
	if ap_single_pass == 1:
		return true
	if ap_single_pass == 2 and is_inside_tree():
		return not _uses_temporal_upscaler(get_viewport())
	return false


func _apply_ap_passes(fm: ShaderMaterial, single: bool) -> void:
	_ap_single_applied = single
	var want := _ap_one_shader if single else _ap_mul_shader
	if fm.shader != want:
		fm.shader = want
	fm.next_pass = null if single else _ap_add_mat


func _rg_km() -> float:
	return 6371.0


func _publish(sun: Vector3, e0: float, moon: Vector3, moon_e: float, alt: float, reach: float,
		hz: float) -> void:
	RenderingServer.global_shader_parameter_set(&"atm_sun", Vector4(sun.x, sun.y, sun.z, e0))
	RenderingServer.global_shader_parameter_set(&"atm_moon", Vector4(moon.x, moon.y, moon.z, moon_e))
	RenderingServer.global_shader_parameter_set(&"atm_cam", Vector4(alt, reach, _rg_km() * 1000.0, _baked_adapt))
	RenderingServer.global_shader_parameter_set(&"atm_medium", Vector4(hz, _baked_static.y, sky_gain, 1.0))
	RenderingServer.global_shader_parameter_set(&"atm_night",
			Vector4(night_sky.r, night_sky.g, night_sky.b, sun_disc_gain))


func _set_globals_enabled(on: bool) -> void:
	RenderingServer.global_shader_parameter_set(&"atm_medium",
			Vector4(haze(), _closed, sky_gain, 1.0 if on else 0.0))
	if not on:
		_town_pub = Vector3.ZERO
		RenderingServer.global_shader_parameter_set(&"atm_town", Vector4.ZERO)


## The sky shader's branch, the fog quad's shader pair, the sun's light: all one way or the other.
func _apply_switch(on: bool) -> void:
	_applied_on = on
	if dome == null or not is_instance_valid(dome) or not dome.is_scene_built:
		return
	var fm := dome.fog_material as ShaderMaterial
	if fm != null:
		if on:
			if _ap_mul_shader == null:
				_ap_mul_shader = load(AP_MUL_SHADER)
				_ap_add_shader = load(AP_ADD_SHADER)
				_ap_one_shader = load(AP_ONE_SHADER)
			if fm.shader != _ap_mul_shader and fm.shader != _ap_one_shader:
				_atmfog_shader = fm.shader
			if _ap_add_mat == null:
				_ap_add_mat = ShaderMaterial.new()
				_ap_add_mat.shader = _ap_add_shader
			_apply_ap_passes(fm, _ap_single_now())
		else:
			if _atmfog_shader != null and fm.shader != _atmfog_shader:
				fm.shader = _atmfog_shader
			fm.next_pass = null
	if on:
		_set_globals_enabled(true)
	else:
		_set_globals_enabled(false)
	# The branch is a buffer global, which never marks the sky dirty: the reflection map would keep
	# the other sky until something else redrew it.
	_epoch += 1
	_sky_param(&"atm_epoch", float(_epoch % 4096))
	_apply_sun_light()


## The add pass mirrors the fog material's parameters (it is a material of its own: next_pass).
## SkyDome calls this after every fog-material write it makes; the others push rarely, so this
## also runs on a slow timer.
func sync_add_pass() -> void:
	if _ap_add_mat == null or dome == null or dome.fog_material == null:
		return
	var fm := dome.fog_material as ShaderMaterial
	for p in [&"fog_density", &"fog_falloff", &"fog_start", &"fog_end", &"sea_plane_enabled",
			&"sea_plane_y", &"cloud_view_tex", &"cloud_view_live", &"cloud_view_size",
			&"weather_filter", &"weather_tint"]:
		var v: Variant = fm.get_shader_parameter(p)
		if v != null and _ap_add_mat.get_shader_parameter(p) != v:
			_ap_add_mat.set_shader_parameter(p, v)
	_ap_add_mat.render_priority = fm.render_priority + 1


## Texture2DRD / Texture3DRD take their RD texture on the RENDER thread (a call_on_render_thread
## inside the setter), and a wrapper handed to a global before that has happened hands out a 2D
## placeholder in its place (Texture3DRD::get_rid): the aerial volume then broke every material that
## declares it ("expected: 3D, actual: 2D"). So: wrap, and publish only once every wrapper is live.
func _wrap_textures() -> bool:
	if _wrappers.is_empty():
		_mutex.lock()
		var tex := _rt_tex.duplicate()
		_mutex.unlock()
		for name: String in WRAPPED:
			var t: Variant = Texture3DRD.new() if name == "atm_aerial_lut" else Texture2DRD.new()
			t.texture_rd_rid = tex[name]
			t.set_meta(&"global", name)
			_wrappers.append(t)
		return false
	for t in _wrappers:
		if not (t.texture_rd_rid as RID).is_valid():
			return false
		# texture_rd_rid is set a moment BEFORE the wrapper's own texture exists (same render-thread
		# call): only Texture3DRD's format, written last, says the wrapper is complete.
		if t is Texture3DRD and (t as Texture3DRD).get_format() == Image.FORMAT_MAX:
			return false
	for t in _wrappers:
		RenderingServer.global_shader_parameter_set(StringName(t.get_meta(&"global")), t)
	_wrapped = true
	return true


const WRAPPED: PackedStringArray = ["atm_transmittance_lut", "atm_multiscatter_lut", "atm_skyview_lut",
		"atm_ambient_lut", "atm_aerial_lut"]


# ---------------------------------------------------------------------------------------------
# Debug: the sky-view table read back to the CPU (tools/sky/atmosphere_shot.gd's exposure lines).

var _dbg_sky := PackedByteArray()
var _dbg_ready := false


## Ask for a read-back of the sky-view table; debug_sky() answers once it has landed.
func debug_request() -> void:
	_dbg_ready = false
	RenderingServer.call_on_render_thread(_rt_readback)


func debug_ready() -> bool:
	return _dbg_ready


## The baked sky radiance (scene units) toward dir, nearest texel; alpha = the ray's transmittance.
func debug_sky(dir: Vector3) -> Color:
	if _dbg_sky.is_empty():
		return Color(0, 0, 0, 0)
	var x := Model.dir_unit(dir.normalized(), light_altitude() * 0.001)
	var px := clampi(roundi(x.x * (SKYVIEW_SIZE.x - 1)), 0, SKYVIEW_SIZE.x - 1)
	var py := clampi(roundi(x.y * (SKYVIEW_SIZE.y - 1)), 0, SKYVIEW_SIZE.y - 1)
	var o := (py * SKYVIEW_SIZE.x * 2 + px) * 8
	var om := o + SKYVIEW_SIZE.x * 8
	var ph := Model.phase_aureole(dir.normalized().dot(_sun_dir())) if dome != null else 0.0
	return Color(_dbg_sky.decode_half(o) + _dbg_sky.decode_half(om) * ph,
			_dbg_sky.decode_half(o + 2) + _dbg_sky.decode_half(om + 2) * ph,
			_dbg_sky.decode_half(o + 4) + _dbg_sky.decode_half(om + 4) * ph, _dbg_sky.decode_half(o + 6))


func _rt_readback() -> void:
	if _rd == null or not _rt_tex.has("atm_skyview_lut"):
		return
	var data := _rd.texture_get_data(_rt_tex["atm_skyview_lut"], 0)
	_mutex.lock()
	_dbg_sky = data
	_dbg_ready = true
	_mutex.unlock()


# ---------------------------------------------------------------------------------------------
# Render thread.

func _rt_build() -> void:
	_mutex.lock()
	_rt_ready = 1
	_mutex.unlock()
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		_rt_fail("no RenderingDevice")
		return
	for k in Glsl.KERNELS:
		var src := RDShaderSource.new()
		src.language = RenderingDevice.SHADER_LANGUAGE_GLSL
		src.source_compute = Glsl.source(k)
		var spirv: RDShaderSPIRV = _rd.shader_compile_spirv_from_source(src)
		var err := spirv.compile_error_compute
		if err != "":
			_rt_fail("%s: %s" % [k, err])
			return
		var sh := _rd.shader_create_from_spirv(spirv, "atm_" + k)
		if not sh.is_valid():
			_rt_fail("%s: shader_create_from_spirv" % k)
			return
		_shaders[k] = sh
		_pipes[k] = _rd.compute_pipeline_create(sh)
	var tex := {
		"atm_transmittance_lut": _rt_tex2d(TRANS_SIZE),
		"atm_multiscatter_lut": _rt_tex2d(MS_SIZE),
		"atm_ambient_lut": _rt_tex2d(MS_SIZE),
		# Two halves side by side: the sky, and the sun's unphased aerosol light (the aureole).
		"atm_skyview_lut": _rt_tex2d(Vector2i(SKYVIEW_SIZE.x * 2, SKYVIEW_SIZE.y)),
		"atm_aerial_lut": _rt_tex3d(AERIAL_SIZE),
	}
	var ss := RDSamplerState.new()
	ss.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	ss.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	ss.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = _rd.sampler_create(ss)
	var outs := {"TRANS": "atm_transmittance_lut", "MS": "atm_multiscatter_lut",
			"AMBIENT": "atm_ambient_lut", "SKYVIEW": "atm_skyview_lut", "AERIAL": "atm_aerial_lut"}
	for k in Glsl.KERNELS:
		var us: Array[RDUniform] = []
		var u0 := RDUniform.new()
		u0.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		u0.binding = 0
		u0.add_id(tex[outs[k]])
		us.append(u0)
		if k != "TRANS":
			us.append(_rt_sampled(1, tex["atm_transmittance_lut"]))
		if k == "AMBIENT" or k == "SKYVIEW" or k == "AERIAL":
			us.append(_rt_sampled(2, tex["atm_multiscatter_lut"]))
		_sets[k] = _rd.uniform_set_create(us, _shaders[k], 0)
	_mutex.lock()
	_rt_tex = tex
	_rt_ready = 2
	_mutex.unlock()


func _rt_fail(why: String) -> void:
	_mutex.lock()
	_rt_ready = -1
	_rt_error = why
	_mutex.unlock()


func _rt_sampled(binding: int, tex: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u.binding = binding
	u.add_id(_sampler)
	u.add_id(tex)
	return u


func _rt_tex2d(size: Vector2i) -> RID:
	var f := RDTextureFormat.new()
	f.format = FORMAT
	f.width = size.x
	f.height = size.y
	f.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	var t := _rd.texture_create(f, RDTextureView.new())
	_rd.texture_clear(t, Color(0, 0, 0, 1), 0, 1, 0, 1)
	return t


func _rt_tex3d(size: Vector3i) -> RID:
	var f := RDTextureFormat.new()
	f.format = FORMAT
	f.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	f.width = size.x
	f.height = size.y
	f.depth = size.z
	f.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	var t := _rd.texture_create(f, RDTextureView.new())
	_rd.texture_clear(t, Color(0, 0, 0, 1), 0, 1, 0, 1)
	return t


func _rt_bake(params: PackedFloat32Array, params_static: PackedFloat32Array, which: int) -> void:
	if _rd == null or _pipes.is_empty():
		return
	var bytes := params.to_byte_array()
	var bytes_s := params_static.to_byte_array()
	var cl := _rd.compute_list_begin()
	if which & BAKE_STATIC:
		_rt_dispatch(cl, "TRANS", bytes_s, Vector3i(TRANS_SIZE.x, TRANS_SIZE.y, 1))
		_rd.compute_list_add_barrier(cl)
		_rt_dispatch(cl, "MS", bytes_s, Vector3i(MS_SIZE.x, MS_SIZE.y, 1))
		_rd.compute_list_add_barrier(cl)
		_rt_dispatch(cl, "AMBIENT", bytes_s, Vector3i(MS_SIZE.x, MS_SIZE.y, 1))
		_rd.compute_list_add_barrier(cl)
		# Per unit sun, the sky's gain kept in (the adaptation weighs the sky as it is drawn).
		_amb_scale = params_static[3] / maxf(sky_gain, 1e-6)
	if which & BAKE_VIEW:
		_rt_dispatch(cl, "SKYVIEW", bytes, Vector3i(SKYVIEW_SIZE.x, SKYVIEW_SIZE.y, 1))
		_rt_dispatch(cl, "AERIAL", bytes, Vector3i(AERIAL_SIZE.x, AERIAL_SIZE.y, 1))
	_rd.compute_list_end()
	if which & BAKE_STATIC:
		_rd.texture_get_data_async(_rt_tex["atm_ambient_lut"], 0, _rt_amb_landed)


var _amb_scale := 1.0


## Render thread: the ambient table's sea-level row, per unit sun (the bake scaled it by _amb_scale).
func _rt_amb_landed(data: PackedByteArray) -> void:
	var row := PackedFloat32Array()
	row.resize(MS_SIZE.x)
	var k := 1.0 / maxf(_amb_scale, 1e-6)
	for i in MS_SIZE.x:
		var o := i * 8
		row[i] = (0.2126 * data.decode_half(o) + 0.7152 * data.decode_half(o + 2)
				+ 0.0722 * data.decode_half(o + 4)) * k
	_mutex.lock()
	_amb_row = row
	_amb_version += 1
	_mutex.unlock()


func _rt_dispatch(cl: int, k: String, bytes: PackedByteArray, size: Vector3i) -> void:
	_rd.compute_list_bind_compute_pipeline(cl, _pipes[k])
	_rd.compute_list_bind_uniform_set(cl, _sets[k], 0)
	_rd.compute_list_set_push_constant(cl, bytes, bytes.size())
	_rd.compute_list_dispatch(cl, (size.x + 7) / 8, (size.y + 7) / 8, 1)


## Pipelines first: freeing a shader frees its pipelines, and a second free is an invalid-RID error.
static func _rt_free_rids(rd: RenderingDevice, rids: Array[RID]) -> void:
	for r in rids:
		if r.is_valid():
			rd.free_rid(r)


## FSR2 or the engine's DLSS: a temporal upscaler on the viewport.
static func _uses_temporal_upscaler(vp: Viewport) -> bool:
	if vp == null:
		return false
	if vp.scaling_3d_mode == Viewport.SCALING_3D_MODE_FSR2:
		return true
	return ClassDB.class_has_integer_constant(&"Viewport", &"SCALING_3D_MODE_DLSS") \
			and vp.scaling_3d_mode == ClassDB.class_get_integer_constant(&"Viewport", &"SCALING_3D_MODE_DLSS")

# --- Sky3D (stock) -----------------------------------------------------------------------------
# This node works next to an unmodified SkyDome: it reads the dome's sun and moon and writes the sky
# material and the sun light itself.

## Unit, toward the sun / the moon (SkyDome's lights on the unit sphere).
func _sun_dir() -> Vector3:
	return dome._sun_transform.origin.normalized()


func _moon_dir() -> Vector3:
	return dome._moon_transform.origin.normalized()


## A sky-material parameter, written only when it changes (a write marks the sky dirty).
func _sky_param(param: StringName, value: Variant) -> void:
	var sm := dome.sky_material as ShaderMaterial
	if sm != null and sm.get_shader_parameter(param) != value:
		sm.set_shader_parameter(param, value)


var _sun_applied := []

## The sun light's colour and strength: while the atmosphere is on, the air's transmittance along the
## sun's ray (a low sun is redder and dimmer); off, Sky3D's own (its update functions, once).
func _apply_sun_light() -> void:
	var sun := dome._sun_light_node as DirectionalLight3D
	if sun == null or not dome.sun_light_enabled:
		return
	if not is_active():
		if not _sun_applied.is_empty():
			_sun_applied = []
			dome._update_sun_light_color()
			dome._update_sun_light_energy()
		return
	var to_sun := _sun_dir()
	var sl: Array = sun_light(to_sun, light_altitude())
	var disc := clampf((to_sun.y + dome.sun_disk_size) / (2.0 * dome.sun_disk_size), 0.0, 1.0)
	var c: Color = sl[0]
	var e := lerpf(0.0, dome.sun_light_energy, disc * float(sl[1]))
	if _sun_applied == [c, e] and sun.light_color == c and is_equal_approx(sun.light_energy, e):
		return
	_sun_applied = [c, e]
	sun.light_color = c
	sun.light_energy = e
	_sky_param(&"sun_light_color", c)
