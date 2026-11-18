class_name CloudBridge
extends Node
## Render glue for the volumetric clouds. WeatherManager creates it (never a
## scene node — hachijojima.scn is a lossy-repack risk) and skips it on a
## dedicated server and headless. It reads CloudModel, pushes the cloud_*
## globals through CloudUniforms and swaps the sky material's shader by tier.
## It computes no weather of its own.

enum CloudMode {
	## Sky3D's 2D dome cumulus (planet_sky.gdshader). Today's look.
	LEGACY,
	## The volumetric march (planet_sky_volumetric.gdshader: the main view from the temporal pass).
	VOLUMETRIC,
	## No cumulus. Cirrus still renders.
	OFF,
}

const LOW_SHADER := "res://addons/sky_3d/shaders/SkyMaterial.gdshader"
const VOLUMETRIC_SHADER := "res://src/sky/shaders/planet_sky_volumetric.gdshader"
const FLIGHT_SHADER := "res://src/sky/clouds/shaders/cloud_flight.gdshader"
## The flight pass's multiply quad (A2): dst * T before the add quad adds the colour, so
## neither writes alpha (FSR2's reactive mask). cloud_flight.gdshaderinc has the story.
const FLIGHT_MUL_SHADER := "res://src/sky/clouds/shaders/cloud_flight_mul.gdshader"


## The sky material's uniforms the flight pass reads through the SAME includes
## (sky_scatter's atmosphere, the planet frame, the photo tonemap, the altitude
## fade), mirrored every frame: SkyDome and PlanetHorizon keep changing them.
const MIRRORED_SKY_UNIFORMS: Array[StringName] = [
	&"cam_altitude", &"planet_radius", &"planet_enabled", &"horizon_offset", &"color_correction",
	&"cloud_fade_start", &"cloud_fade_end",
	&"atm_darkness", &"atm_sun_intensity", &"atm_day_tint", &"atm_horizon_light_tint",
	&"atm_night_tint", &"atm_level_params", &"atm_thickness", &"atm_beta_ray", &"atm_beta_mie",
	&"atm_sun_mie_tint", &"atm_sun_mie_intensity", &"atm_sun_partial_mie_phase",
	&"atm_moon_mie_tint", &"atm_moon_mie_intensity", &"atm_moon_partial_mie_phase",
	# The weather colour filter (WeatherLookDriver pushes it on the sky material).
	&"weather_filter", &"weather_tint",
]
## Among its priority the flight quad draws FIRST: AtmFog shares ocean + 1, and
## its fog must land on the clouds, not under them — at the CLOUD's distance
## (the cloud_view uniforms pushed to AtmFog, _push_atm_fog_view).
const FLIGHT_SORTING_OFFSET := -1.0e7
## The multiply quad draws before the add quad (a larger sort depth: depth - offset).
const FLIGHT_MUL_SORTING_OFFSET := -2.0e7


## The terrain/flight pass rides with the volumetric march when the tier
## asks for it.
static func flight_wanted(mode: int, tier: Dictionary) -> bool:
	return mode == CloudMode.VOLUMETRIC and bool(tier.get("flight", false))


## Right after the water: the ocean is TRANSPARENT (render_priority -1), so the
## clouds in front of it must paint after it — the sky pass painted before it,
## which is why the sea hid the deck. 0 when there is no water.
static func flight_priority(water_priorities: Array) -> int:
	if water_priorities.is_empty():
		return 0
	var hi := int(water_priorities[0])
	for p in water_priorities:
		hi = maxi(hi, int(p))
	return mini(hi + 1, Material.RENDER_PRIORITY_MAX)


## A clip-space fullscreen quad (the HeatHazePass pattern): never frustum- or
## occlusion-culled, no shadow, no GI.
static func build_flight_quad(shader: Shader, priority: int, sorting_offset := FLIGHT_SORTING_OFFSET,
		quad_name := "CloudFlightPass") -> MeshInstance3D:
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.render_priority = priority
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	quad.material = mat
	var q := MeshInstance3D.new()
	q.name = quad_name
	q.mesh = quad
	q.custom_aabb = AABB(Vector3(-1e6, -1e6, -1e6), Vector3(2e6, 2e6, 2e6))
	q.ignore_occlusion_culling = true
	q.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	q.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	q.sorting_offset = sorting_offset
	# Off the ground cloud-shadow decal: it would take one point's shadow over the whole screen.
	CloudShadowReceiver.exclude(q)
	return q


static func mirror_sky_uniforms(sky: ShaderMaterial, flight: ShaderMaterial) -> void:
	for n in MIRRORED_SKY_UNIFORMS:
		var v: Variant = sky.get_shader_parameter(n)
		if v != null:
			flight.set_shader_parameter(n, v)


## cloud_flags bit 2: the temporal pass's history (the global cloud_view) is live
## for the main viewport. LOCKSTEP with CLOUD_FLAG_TEMPORAL in cloud_march.
const FLAG_TEMPORAL := 4
## DRAWN frames without a new published() frame before the history counts as stale
## (a detached compositor, a viewport that stopped rendering). Counted in draws, not process frames (CLOUDS5): the
## pass publishes once per draw, and a process frame that draws nothing (a minimized or covered window, a wait
## between forced draws) is no stall. Counted in process frames, five such frames flipped the sky to its per-pixel
## fallback march for the next draw: the grain in the shimmer probe's first still after a setup change.
const TEMPORAL_STALL_FRAMES := 5


## cloud_flags: bit 0 = the flight pass is live (CloudPartition: the sky then
## keeps only mu >= 0), bit 1 = TAA is on (the per-pixel fallback march then
## holds its dither still), bit 2 = the temporal pass owns the main view.
static func frame_flags(taa: bool, flight_on: bool, temporal_live := false) -> int:
	return (2 if taa else 0) | (CloudPartition.FLAG_FLIGHT if flight_on else 0) \
			| (FLAG_TEMPORAL if temporal_live else 0)


## The temporal pass rides with the volumetric march when the tier asks for it.
static func temporal_wanted(mode: int, tier: Dictionary) -> bool:
	return mode == CloudMode.VOLUMETRIC and bool(tier.get("temporal", false))


## The ground's cloud shadows (CloudShadowReceiver) when the tier asks for them: from the volumetric
## field on HIGH (#760), from the dome cumulus on LOW (#761). An override of 0 / 1 forces them off / on.
## OFF draws no cumulus, so it casts none. `tier` is the tier as set (LOW's own table on LEGACY).
static func ground_shadows_wanted(mode: int, tier: Dictionary, override: int) -> bool:
	if mode == CloudMode.OFF:
		return false
	return override == 1 if override >= 0 else bool(tier.get("ground_shadows", false))



## Moonlight only. Sky3D's moon energy lights the terrain plausibly and is far
## too strong for cloud (real moonlight ~1/400000 of sun). Tune by eye.
@export_range(0.0, 1.0, 0.01) var moon_light_scale: float = 0.12
## -1 = follow the cloud_quality setting. sky_shot / diagnostics override.
var mode_override: int = -1
## A tier of CLOUD_QUALITY_PARAMS in place of the cloud_quality setting ("" = the setting), applied at
## once: the shimmer probe's A/B of a tier table (n.CloudBridge.quality_override=<tier>).
var quality_override := "":
	set(v):
		quality_override = v
		_apply_mode()
## mode_override for the shimmer probe (n.CloudBridge.mode_switch=0 is LOW, =1 HIGH, =-1 the setting):
## a float the probe can set, applied at once.
var mode_switch: float = -1.0:
	set(v):
		mode_switch = v
		set_mode_override(int(v))
## The terrain/flight pass: -1 = follow the tier, 0 = off, 1 = on (cost probe A/B). Applied at once (CLOUDS5: set
## alone from the shimmer probe, n.CloudBridge.flight_override=0, it did nothing until the next _apply_mode).
var flight_override: int = -1:
	set(v):
		flight_override = v
		_apply_mode()
## A2's A/B switch (shimmer probe: n.CloudBridge.flight_alpha_legacy=true): the flight pass's
## old single premultiplied quad, which wrote the clouds' opacity into the colour buffer's
## alpha (FSR2's reactive mask), instead of the multiply + add pair that writes none.
var flight_alpha_legacy := false:
	set(v):
		flight_alpha_legacy = v
		_push_flight_alpha()
## The temporal pass: -1 = follow the tier, 0 = off, 1 = on (sky_shot A/B).
var temporal_override: int = -1:
	set(v):
		temporal_override = v
		_apply_mode()
## The ground's cloud shadows: -1 = follow the tier, 0 = off, 1 = on (cloud_shadow_shot A/B). Applied at once.
var ground_shadow_override: int = -1:
	set(v):
		ground_shadow_override = v
		_apply_mode()
## B1's A/B switches (shimmer probe: n.CloudBridge.lighting_override=0): -1 = the tier's, else the
## lighting model (0 the Nubis dual-lobe terms, 1 the four-lobe terms), and the key light's gain at the
## resolve (the over-bright tops' dial).
var lighting_override: float = -1.0
var key_gain_override: float = -1.0
## The long light ray's sample count (the four-lobe model), -1 = the tier's: its cost A/B.
var light_ff_override: float = -1.0
## The ambient's pull toward grey (the four-lobe model), -1 = the tier's.
var amb_grey_override: float = -1.0
## The physical atmosphere's sun as the key colour pushed to cloud_key_color (the lead's request: the
## clouds' CPU key agrees with the sky). The march resolves with the atmosphere's own tables when it is
## on; this colour is the shaders' fallback and every CPU reader's. Its reference altitude (m):
const KEY_REF_ALT_M := 2000.0
## Look-dev (CLOUDS3): raise it (shimmer probe: n.CloudBridge.trace_stamps=1) and the temporal pass's trace and resolve
## are timed on the GPU (CloudTemporal.capture_stamps); every TRACE_STAMP_FRAMES frames their means print as
## `[clouds] trace_ms <trace> resolve_ms <resolve> n <frames>`: the march's own cost, well under the
## whole frame's noise. Off: nothing is captured.
var trace_stamps: float = 0.0:
	set(v):
		trace_stamps = v
		CloudTemporal.capture_stamps = v > 0.0
		_ts_sum = Vector2.ZERO
		_ts_n = 0
const TRACE_STAMP_FRAMES := 16
## Look-dev (CLOUDS3): raise it (n.CloudBridge.storm_cells_off=1) and the procedural field lists no storm cells.
var storm_cells_off: float = 0.0
var _ts_sum := Vector2.ZERO
var _ts_n := 0
## _main_render_target()'s cache.
var _rt := RID()
var _rt_viewport := RID()
## Tier keys to override (temporal_lattice / _retain / _jitter, max_steps, light_samples,
## step_*, flight_*): sky_shot --tune and cloud_cost_probe --tune, for A/B look-dev and cost.
## They reach every march (push_frame's cloud_q_*) and the temporal pass's trace.
## temporal_tuning from the shimmer probe, which sets strings: "key:value;key:value" (n.CloudBridge.tune=pf_light:4).
var tune: String = "":
	set(v):
		tune = v
		var d := {}
		for kv in v.split(";", false):
			var p := kv.split(":")
			if p.size() == 2:
				d[p[0].strip_edges()] = float(p[1])
		temporal_tuning = d
var temporal_tuning: Dictionary = {}

var _sky3d: Sky3D = null
var _model: CloudModel = null
var _mode: int = CloudMode.LEGACY
var _frame := 0
var _vol_shader: Shader = null
var _warned := false
## The scene's authored dome-cumulus visibility, restored on unbind.
var _authored_cumulus := true
## The scene's authored 2D cirrus visibility: the procedural field draws its own cirrus in the march, and the
## sky's 2D one goes (its drift written every frame kept the reflection map re-rendering), restored on unbind.
var _authored_cirrus := true
## The procedural field could not make its noise (no device): the baked field stands in.
var _pf_failed := false
## The procedural field's storm cells (CloudStorms): the global cloud_storms and what it lists.
var _storm_img: Image = null
var _storm_tex: ImageTexture = null
var _storm_key := ""
var _storm_cells: Array[Vector4] = []
var _storm_n_pushed := -1
## The terrain/flight pass quads (under the root viewport) while they are live: the add
## quad, and the multiply quad that draws before it (A2).
var _flight: MeshInstance3D = null
var _flight_mul: MeshInstance3D = null
var _flight_mul_shader: Shader = null
var _flight_shader: Shader = null
## The temporal pass (a CompositorEffect on the Sky3D WorldEnvironment) and the
## Texture2DRD that exposes its history as the global cloud_view.
var _temporal: CloudTemporal = null
var _view_tex: Texture2DRD = null
## Whether the temporal history is live for the main view this frame (_push_atm_fog_view).
var _post_view_live := false


## The temporal history (key_w, amb_w, T, depth km) for the screen post FX while it is live for the main view,
## else null: the sun's and the moon's glows fade by its T at their discs (owner prompts/41).
func post_cloud_view() -> Texture2DRD:
	return _view_tex if _post_view_live else null
## Frames to wait after giving _view_tex a new RD texture before the cloud_view global takes it (_temporal_poll).
const VIEW_BIND_FRAMES := 2
var _view_bind_wait := 0
## Sampled while no history exists: T = 1, no cloud.
var _view_empty: ImageTexture = null
var _temporal_frame := -1
var _temporal_stall := 0
## A/B switch (shimmer probe: n.CloudBridge.stall_in_draws=false): the stall counted in process frames, as before.
var stall_in_draws := true
## RenderingServer draws (frame_pre_draw: the main loop's and forced ones alike) and the count at the last poll.
var _draws := 0
var _temporal_draws := 0
var _temporal_live_dbg := false
## Bumped on every mode/tier application: the pass drops its history.
var _temporal_reset := 0
var _temporal_error_logged := false
## The main camera's own compositor the temporal pass rides (CameraCompositorFollow), or null.
var _temporal_cam_comp: Compositor = null
## The ground's cloud shadows while they are live, and the fog quad's authored layers they moved.
var _ground: CloudShadowReceiver = null
## The weather the clouds are drawn for (the ground shadows read its cover); set by whoever ticks the model.
var weather: WeatherFields = null
## The ground's height under the camera (world Y): the eye veil stands only near it.
var ground_y := 0.0
var _authored_fog_layers := -1


static func resolve_mode(tier_volumetric: bool, assets_ok: bool, frame_identity: bool,
		override: int) -> int:
	var wanted := override if override >= 0 else (CloudMode.VOLUMETRIC if tier_volumetric else CloudMode.LEGACY)
	if wanted == CloudMode.VOLUMETRIC and not (assets_ok and frame_identity):
		return CloudMode.LEGACY
	return wanted


## The parameters the march runs with. A mode override can force VOLUMETRIC while
## the setting says LOW (sky_shot, perf probes); LOW carries no march parameters,
## so the volumetric default (HIGH) is used. Pushing LOW's table errored every frame.
static func effective_tier(tier: Dictionary, table: Dictionary) -> Dictionary:
	if bool(tier.get("volumetric", false)):
		return tier
	return table.get(&"high", tier)


static func shader_for_mode(mode: int, vol: Shader) -> Shader:
	return vol if mode == CloudMode.VOLUMETRIC else load(LOW_SHADER)


## Godot's sky template applies these to the half-res RGB; the encoding
## (lighting weights + depth code) survives only if they are neutral.
static func invariant_problems(env: Environment) -> PackedStringArray:
	var p := PackedStringArray()
	if env == null:
		return p
	if not is_equal_approx(env.background_energy_multiplier, 1.0):
		p.append("background_energy_multiplier != 1")
	if env.fog_enabled and not is_equal_approx(env.fog_aerial_perspective, 1.0):
		p.append("fog_aerial_perspective != 1 (fog would paint a flat colour into the cloud buffer)")
	if env.fog_enabled and env.fog_sun_scatter > 0.0:
		p.append("fog_sun_scatter > 0")
	if env.volumetric_fog_enabled and env.volumetric_fog_sky_affect > 0.0:
		p.append("volumetric_fog_sky_affect > 0")
	if env.sky_rotation != Vector3.ZERO:
		p.append("sky_rotation != 0")
	if not is_zero_approx(env.sky_custom_fov):
		p.append("sky_custom_fov != 0")
	return p


func _ready() -> void:
	CloudGlobals.ensure()
	if not RenderingServer.frame_pre_draw.is_connected(_on_pre_draw):
		RenderingServer.frame_pre_draw.connect(_on_pre_draw)


func _exit_tree() -> void:
	if RenderingServer.frame_pre_draw.is_connected(_on_pre_draw):
		RenderingServer.frame_pre_draw.disconnect(_on_pre_draw)


func _enter_tree() -> void:
	if is_node_ready() and not RenderingServer.frame_pre_draw.is_connected(_on_pre_draw):
		RenderingServer.frame_pre_draw.connect(_on_pre_draw)


func _on_pre_draw() -> void:
	_draws += 1


func bind(sky3d: Sky3D, model: CloudModel) -> void:
	if sky3d != _sky3d:
		_drop_ground_shadow() # it moved the OLD sky's fog quad; the new one gets moved on build
	_sky3d = sky3d
	_model = model
	_warned = false
	_authored_cumulus = sky3d.sky.cumulus_visible if sky3d.sky != null else true
	_authored_cirrus = sky3d.sky.cirrus_visible if sky3d.sky != null else true
	_apply_mode()


## A no-op when never bound: WeatherManager._silence() calls this for every
## suspended scene, and a probe that drives the globals itself must not be reset.
func unbind() -> void:
	if _sky3d == null:
		return
	var mat := _material()
	if mat != null:
		mat.shader = load(LOW_SHADER)
	if is_instance_valid(_sky3d) and _sky3d.sky != null:
		_sky3d.sky.cumulus_visible = _authored_cumulus
		_sky3d.sky.cirrus_visible = _authored_cirrus
	_drop_flight()
	_drop_temporal()
	_drop_ground_shadow()
	CloudUniforms.push_mode(false)
	_mode = CloudMode.LEGACY
	_sky3d = null
	_model = null


func set_mode_override(m: int) -> void:
	mode_override = m
	_apply_mode()


## The three below apply through their properties' setters.
func set_flight_override(v: int) -> void:
	flight_override = v


func set_temporal_override(v: int) -> void:
	temporal_override = v


func set_ground_shadow_override(v: int) -> void:
	ground_shadow_override = v


## The live ground receiver, or null (not HIGH, overridden off, unbound, no cloud textures).
func get_ground_shadow() -> CloudShadowReceiver:
	return _ground


func get_mode() -> int:
	return _mode


## Re-reads the tier (CloudQuality.quality) and rebuilds the passes it asks for.
func reapply() -> void:
	_apply_mode()


func _material() -> ShaderMaterial:
	if _sky3d == null or not is_instance_valid(_sky3d) or _sky3d.environment == null:
		return null
	var sky := _sky3d.environment.sky
	return sky.sky_material as ShaderMaterial if sky != null else null


func _tier() -> Dictionary:
	var q := CloudQuality.quality
	if quality_override != "" and CloudQuality.PARAMS.has(StringName(quality_override)):
		q = StringName(quality_override)
	return CloudQuality.PARAMS.get(q, CloudQuality.PARAMS[&"off"])


func _apply_mode() -> void:
	var mat := _material()
	if mat == null or _model == null:
		return
	var tier := _tier()
	var wants := bool(tier.get("volumetric", false)) or mode_override == CloudMode.VOLUMETRIC
	var assets_ok := false
	if wants:
		var a := CloudAssets.shared()
		# The procedural field's noise is generated the first time it is wanted; without it Sky3D's sky stays.
		assets_ok = a.ok and a.textures_ok and a.ensure_pf()
		if a.ok and a.textures_ok and not assets_ok and not _pf_failed:
			push_warning("[clouds] the procedural field's noise could not be made: Sky3D's sky stays")
			_pf_failed = true
		if assets_ok:
			CloudUniforms.push_textures(a)
			CloudUniforms.push_constants(_model.manifest)
	var basis = mat.get_shader_parameter("sky_frame_basis")
	var identity: bool = basis == null or basis == Basis.IDENTITY
	_mode = resolve_mode(bool(tier.get("volumetric", false)), assets_ok, identity, mode_override)
	if _mode == CloudMode.VOLUMETRIC and _vol_shader == null:
		_vol_shader = load(VOLUMETRIC_SHADER)
	mat.shader = shader_for_mode(_mode, _vol_shader)
	_sky3d.sky.cumulus_visible = _mode == CloudMode.LEGACY
	# The procedural field's march draws the cirrus (B2): the sky's 2D sheet goes while it does.
	var pf_cirrus := _mode == CloudMode.VOLUMETRIC \
			and bool(effective_tier(tier, CloudQuality.PARAMS).get("pf_cirrus", true))
	if _sky3d.sky.cirrus_visible != (_authored_cirrus and not pf_cirrus):
		_sky3d.sky.cirrus_visible = _authored_cirrus and not pf_cirrus
	CloudUniforms.push_mode(_mode == CloudMode.VOLUMETRIC)
	var table: Dictionary = CloudQuality.PARAMS
	var fly := flight_wanted(_mode, effective_tier(tier, table)) if flight_override < 0 \
			else (_mode == CloudMode.VOLUMETRIC and flight_override == 1)
	if fly:
		_ensure_flight()
	else:
		_drop_flight()
	var tempo := temporal_wanted(_mode, effective_tier(tier, table)) if temporal_override < 0 \
			else (_mode == CloudMode.VOLUMETRIC and temporal_override == 1)
	_temporal_reset += 1
	if tempo:
		_ensure_temporal()
	else:
		_drop_temporal()
	var shadow_tier := effective_tier(tier, table)
	if ground_shadows_wanted(_mode, shadow_tier, ground_shadow_override):
		_ensure_ground_shadow()
	else:
		_drop_ground_shadow()
	if _mode == CloudMode.VOLUMETRIC and not _warned:
		_warned = true
		for problem in invariant_problems(_sky3d.environment):
			push_warning("[clouds] environment breaks the half-res cloud encoding: " + problem)


## The sun's NOON colour: SkyDome's sun_light_color export, the daylight end of
## Sky3D's lerp. Since 2026-09-28 the shader reddens it per cloud by the real air
## path to the sun (cloud_sun_tint). The live SunLight colour was an art-directed
## SEA-LEVEL lerp — (1, 0.66, 0.43) at a 1.6 deg sun against a physical
## ~(1, 0.36, 0.02) — and golden-hour clouds read beige-brown; before that, the
## export with no reddening at all had left sunset clouds white.
static func sun_color(sky3d: Sky3D) -> Color:
	if sky3d.sky != null:
		return sky3d.sky.sun_light_color
	var sun := sky3d.get_node_or_null("SunLight") as DirectionalLight3D
	return sun.light_color if sun != null else Color.WHITE


func _process(delta: float) -> void:
	if _model == null or _sky3d == null or not is_instance_valid(_sky3d):
		return
	if _mode != CloudMode.VOLUMETRIC:
		if _ground != null:
			_drop_ground_shadow()
		return
	_frame += 1
	var sun := _sky3d.get_node_or_null("SunLight") as DirectionalLight3D
	var moon := _sky3d.get_node_or_null("MoonLight") as DirectionalLight3D
	# DirectionalLight3D shines along -Z; the direction TO the light is +Z.
	var sun_dir := sun.global_transform.basis.z if sun != null else Vector3.UP
	var moon_dir := moon.global_transform.basis.z if moon != null else Vector3.UP
	var key := _atmosphere_key(CloudUniforms.key_light(sun_dir, sun_color(_sky3d), moon_dir,
			moon.light_color if moon != null else Color.WHITE,
			moon.light_energy if moon != null else 0.0, moon_light_scale), sun_dir)
	var table: Dictionary = CloudQuality.PARAMS
	var tier := effective_tier(_tier(), table)
	# The look-dev / cost overrides reach every march (sky, flight quad, radiance map, mirrors), not
	# only the temporal pass's trace.
	if not temporal_tuning.is_empty():
		tier = tier.merged(temporal_tuning, true)
	tier = _look_overrides(tier)
	_tick_storms()
	var live := _temporal_poll()
	# Bit 1 (TAA) holds the fallback march's dither still; bit 2 hands the main
	# view to the temporal pass.
	var flags := frame_flags(get_viewport().use_taa, _flight != null, live)
	CloudUniforms.eye_ground_y = _eye_ground_y()
	CloudUniforms.push_frame(_model, tier, key, _frame, flags)
	if _temporal != null:
		_tick_temporal_host()
		_temporal.submit(_temporal_snapshot(tier))
	if trace_stamps > 0.0:
		_tick_trace_stamps()
	if _ground != null:
		_tick_ground_shadow(delta, sun_dir)
	if _flight != null:
		var sm := _material()
		# The ocean can register after the bind (streaming, scene order).
		var pr := flight_priority(_water_priorities())
		for q in [_flight, _flight_mul]:
			if not is_instance_valid(q):
				continue
			var fm := (q as MeshInstance3D).mesh.surface_get_material(0) as ShaderMaterial
			if sm != null:
				mirror_sky_uniforms(sm, fm)
			fm.set_shader_parameter(&"sun_dir", sun_dir)
			fm.set_shader_parameter(&"moon_dir", moon_dir)
			if fm.render_priority != pr:
				fm.render_priority = pr


## CloudHdrDump on the main camera's compositor (or the environment's), and its request once the
## countdown ends (the history has settled on whatever the setup just changed).
## trace_stamps: the trace's and the resolve's GPU time from the device's newest readable frame (read on the render
## thread: the device answers only there), their means printed every TRACE_STAMP_FRAMES frames.
func _tick_trace_stamps() -> void:
	RenderingServer.call_on_render_thread(_collect_trace_stamps)


func _collect_trace_stamps() -> void:
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		return
	var at := {}
	for j in rd.get_captured_timestamps_count():
		var nm := rd.get_captured_timestamp_name(j)
		if nm.begins_with("ct:"):
			at[nm] = float(rd.get_captured_timestamp_gpu_time(j)) / 1e6
	if not (at.has("ct:trace") and at.has("ct:resolve") and at.has("ct:done")):
		return
	_ts_sum += Vector2(at["ct:resolve"] - at["ct:trace"], at["ct:done"] - at["ct:resolve"])
	_ts_n += 1
	if _ts_n >= TRACE_STAMP_FRAMES:
		print("[clouds] trace_ms %.3f resolve_ms %.3f n %d" % [_ts_sum.x / _ts_n, _ts_sum.y / _ts_n, _ts_n])
		_ts_sum = Vector2.ZERO
		_ts_n = 0




## The key light from the physical atmosphere when it is what the game draws (the lead's request, via
## ATMOSPHERE): the sun's illuminance at KEY_REF_ALT_M, the same table the shaders' cloud_key_at() reads
## per cloud there. "sun" stays set (the shaders pick the sun's tables by it). The moon keeps its own.
func _atmosphere_key(key: Dictionary, sun_dir: Vector3) -> Dictionary:
	if not bool(key.get("sun", false)) or _sky3d == null or _sky3d.sky == null:
		return key
	var atm: Node = _sky3d.sky.get_node_or_null("SkyAtmosphere")
	if atm == null or not atm.has_method("is_active") or not atm.is_active():
		return key
	var sl: Array = atm.sun_light(sun_dir, KEY_REF_ALT_M)
	var base_e := float(_sky3d.sky.sun_light_energy)
	var col: Color = (sl[0] as Color).srgb_to_linear() * (PI * base_e * float(sl[1]))
	return {"dir": key["dir"], "color": col, "sun": true}


## The procedural field's storm cells (B2): CloudStorms picks them in cloud space round the camera's grid
## cell (again only when that cell, the storm amount or the cover moves past a 1/256 step: the same on every
## peer), and every frame they are written at their world positions (cloud space plus the synced drift)
## into the global cloud_storms (16 x 1 RGBAF: world x, z, radius, maturity).
func _tick_storms() -> void:
	if _storm_tex == null:
		_storm_img = Image.create(CloudStorms.MAX_CELLS, 1, false, Image.FORMAT_RGBAF)
		_storm_tex = ImageTexture.create_from_image(_storm_img)
		CloudUniforms.push_storms(_storm_tex)
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var c := _model.clock
	var st := _model.state
	var cp := cam.global_position
	var gx := floori((cp.x - c.x) / CloudStorms.GRID_M)
	var gz := floori((cp.z - c.z) / CloudStorms.GRID_M)
	var qs := roundi(st.storms * 256.0)
	var qc := roundi(st.cover * 256.0)
	var k := "%d,%d,%d,%d" % [gx, gz, qs, qc]
	if k != _storm_key:
		_storm_key = k
		_storm_cells = CloudStorms.pick(qs / 256.0, qc / 256.0,
				(Vector2(gx, gz) + Vector2(0.5, 0.5)) * CloudStorms.GRID_M)
	var n := _storm_cells.size() if storm_cells_off <= 0.0 else 0
	if n == 0 and _storm_n_pushed == 0:
		CloudUniforms.pf_storm_count = 0
		return
	for i in CloudStorms.MAX_CELLS:
		if i < n:
			var v: Vector4 = _storm_cells[i]
			_storm_img.set_pixel(i, 0, Color(v.x + c.x, v.y + c.z, v.z, v.w))
		else:
			_storm_img.set_pixel(i, 0, Color(0.0, 0.0, 0.0, 0.0))
	_storm_tex.update(_storm_img)
	_storm_n_pushed = n
	CloudUniforms.pf_storm_count = n


## The cells the procedural field lists this frame (cloud space: tools and tests).
func storm_cells() -> Array[Vector4]:
	return _storm_cells


func cloud_flags_live() -> bool:
	return (int(CloudUniforms.values.get(&"cloud_flags", 0)) & FLAG_TEMPORAL) != 0


static func _v4(v: Variant) -> Array:
	return [v.x, v.y, v.z, v.w] if v is Vector4 else []


func _hour() -> float:
	var tod := _sky3d.get_node_or_null("TimeOfDay") if is_instance_valid(_sky3d) else null
	if tod != null and "current_time" in tod:
		return float(tod.get("current_time"))
	return -1.0




## The tier with B1's A/B switches applied (a copy: the tier tables are constants).
func _look_overrides(tier: Dictionary) -> Dictionary:
	if lighting_override < 0.0 and key_gain_override < 0.0 and light_ff_override < 0.0 and amb_grey_override < 0.0:
		return tier
	var t := tier.duplicate()
	if amb_grey_override >= 0.0:
		t["amb_grey"] = amb_grey_override
	if light_ff_override >= 0.0:
		t["light_samples_ff"] = int(light_ff_override)
	if lighting_override >= 0.0:
		t["lighting"] = int(lighting_override)
	if key_gain_override >= 0.0:
		t["key_gain"] = key_gain_override
	return t


func _ensure_flight() -> void:
	if _flight != null and is_instance_valid(_flight):
		return
	if _flight_shader == null:
		_flight_shader = load(FLIGHT_SHADER)
	if _flight_mul_shader == null:
		_flight_mul_shader = load(FLIGHT_MUL_SHADER)
	var pr := flight_priority(_water_priorities())
	_flight = build_flight_quad(_flight_shader, pr)
	_flight_mul = build_flight_quad(_flight_mul_shader, pr, FLIGHT_MUL_SORTING_OFFSET, "CloudFlightMulPass")
	_push_flight_alpha()
	_attach_flight.call_deferred(_flight)
	_attach_flight.call_deferred(_flight_mul)


## alpha_mode on both quads (the multiply quad discards everywhere in the legacy mode).
func _push_flight_alpha() -> void:
	for q in [_flight, _flight_mul]:
		if is_instance_valid(q):
			var m := (q as MeshInstance3D).mesh.surface_get_material(0) as ShaderMaterial
			m.set_shader_parameter(&"alpha_mode", 1 if flight_alpha_legacy else 0)


## Deferred (the root may be busy setting up children); an unbind in between
## has already dropped — and freed — it. UNTYPED on purpose: a typed parameter
## rejects the freed instance before the guard runs and logs an engine error on
## every main-menu entry at HIGH (bind, then _silence() unbinds in the same call).
func _attach_flight(q) -> void:
	if not is_instance_valid(q) or (q != _flight and q != _flight_mul):
		return
	if not q.is_queued_for_deletion() and not q.is_inside_tree():
		get_tree().root.add_child(q)


## AtmFog (Sky3D's fullscreen haze) fogs a pixel by the distance BEHIND it: the
## far plane over the sky, the sea plane over water. The same cloud got two
## different fogs either side of the sky/flight split — a hard horizontal line
## across every cloud (bisected 2026-09-28: AtmFog off removes it; env fog,
## volumetric fog, the flight quad and the draw order do not). With the temporal
## history live, the physical atmosphere's fog passes (atmosphere_ap.gdshaderinc) move their fog depth to
## the cloud's own by the cloud's opacity; Sky3D's stock AtmFog ignores these. Plain material uniforms, not
## the cloud_* globals: the fog quad is bound in the editor, where those do not exist.
func _push_atm_fog_view(live: bool, size: Vector2i) -> void:
	_post_view_live = live and _view_tex != null
	if _sky3d == null or not is_instance_valid(_sky3d) or _sky3d.sky == null:
		return
	var fm := _sky3d.sky.get("fog_material") as ShaderMaterial
	if fm == null:
		return
	fm.set_shader_parameter(&"cloud_view_live", live and _view_tex != null)
	if live and _view_tex != null:
		# Re-set every frame ON PURPOSE: _view_tex is a Texture2DRD whose RD texture the temporal pass swaps, and
		# nothing else rebuilds the fog material's uniform set after a swap (the checker-sky incident). Cheap: the
		# material has 2 instances (ENGINE_PERF 2026-11-17).
		fm.set_shader_parameter(&"cloud_view_tex", _view_tex)
		fm.set_shader_parameter(&"cloud_view_size", Vector2(size))


## The receiver, and Sky3D's fog quad off its layers (a fullscreen POSITION-trick quad would take
## one point's shadow over the whole screen), restored when it goes.
func _ensure_ground_shadow(bake := CloudShadowReceiver.BAKE_SHADER) -> void:
	if _ground != null and _ground.bake_shader_path == bake:
		return
	_drop_ground_shadow() # the other tier's source: a fresh receiver, never a re-pointed one
	var g := CloudShadowReceiver.new()
	g.name = "CloudShadowReceiver"
	add_child(g)
	if not g.setup(bake, CloudShadowReceiver.K_TABLE):
		g.queue_free()
		return
	_ground = g
	if is_instance_valid(_sky3d) and _sky3d.sky != null:
		_authored_fog_layers = _sky3d.sky.fog_layers
		_sky3d.sky.fog_layers = CloudShadowReceiver.NO_SHADOW_LAYERS


func _drop_ground_shadow() -> void:
	if _ground == null:
		return
	# Its decal and bake stop at once; the node goes at the end of the frame (this can run inside a
	# scene change, where removing a child errors).
	if is_instance_valid(_ground):
		_ground.shutdown()
		_ground.queue_free()
	_ground = null
	if _authored_fog_layers >= 0 and is_instance_valid(_sky3d) and _sky3d.sky != null:
		_sky3d.sky.fog_layers = _authored_fog_layers
	_authored_fog_layers = -1


func _tick_ground_shadow(delta: float, sun_dir: Vector3) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var cover := weather.cloud_cover if weather != null else 0.0
	var c := _model.clock
	_ground.tick(delta, cam.get_camera_transform().origin, sun_dir, Vector2(c.x, c.z), cover)






func _drop_flight() -> void:
	for q in [_flight, _flight_mul]:
		if is_instance_valid(q):
			if (q as Node).is_inside_tree():
				(q as Node).queue_free()
			else:
				(q as Node).free()
	_flight = null
	_flight_mul = null


## Attach the temporal pass to the Sky3D WorldEnvironment's compositor
## (duplicate -> append -> reassign: it coexists with SenseOfSpeed's blur and
## perf_capture). No RenderingDevice (headless, Compatibility) = no pass.
func _ensure_temporal() -> void:
	if _temporal != null or _sky3d == null or not is_instance_valid(_sky3d):
		return
	if RenderingServer.get_rendering_device() == null:
		return
	_temporal = CloudTemporal.new()
	var comp := _sky3d.compositor
	if comp == null:
		comp = Compositor.new()
		_sky3d.compositor = comp
	var fx: Array[CompositorEffect] = comp.compositor_effects.duplicate()
	fx.append(_temporal)
	comp.compositor_effects = fx
	if _view_tex == null:
		_view_tex = Texture2DRD.new()
	_temporal_frame = -1
	_temporal_stall = 0
	_temporal_error_logged = false


## The main camera's own compositor, when it has one, carries the pass too: it REPLACES the Sky3D
## one for that camera, and ZgUnderwater gives every current camera one. Without this the pass
## never ran on the live map (#770: published frame 0, every HIGH frame on the full-res per-pixel
## march). Checked every frame: cameras change, and ZgUnderwater dresses a new one a frame or so
## after it becomes current.
func _tick_temporal_host() -> void:
	var home: Compositor = _sky3d.compositor if is_instance_valid(_sky3d) else null
	_temporal_cam_comp = CameraCompositorFollow.follow(_temporal, _temporal_cam_comp,
			CameraCompositorFollow.own_compositor(get_viewport().get_camera_3d(), home))


## Consumers first: nothing may sample the history once the pass frees it.
func _drop_temporal() -> void:
	if _temporal == null:
		return
	_temporal_cam_comp = CameraCompositorFollow.follow(_temporal, _temporal_cam_comp, null)
	RenderingServer.global_shader_parameter_set(&"cloud_view", _empty_view())
	_push_atm_fog_view(false, Vector2i.ZERO)
	if _view_tex != null:
		_view_tex.texture_rd_rid = RID()
	if is_instance_valid(_sky3d) and _sky3d.compositor != null:
		var fx: Array[CompositorEffect] = _sky3d.compositor.compositor_effects.duplicate()
		fx.erase(_temporal)
		_sky3d.compositor.compositor_effects = fx
	_temporal = null
	_temporal_frame = -1


func _empty_view() -> ImageTexture:
	if _view_empty == null:
		var img := Image.create(1, 1, false, Image.FORMAT_RGBAH)
		img.fill(Color(0.0, 0.0, 1.0, 0.0))
		_view_empty = ImageTexture.create_from_image(img)
	return _view_empty


## Whether the main view can read cloud_view THIS frame: the pass published a
## history within the last few frames, the global points at it, and
## cloud_view_size says which target it belongs to. Swaps the Texture2DRD when
## the pass rebuilt its output (a resize).
func _temporal_poll() -> bool:
	if _temporal == null:
		return false
	var pub := _temporal.published()
	var err: String = pub["error"]
	if err != "" and not _temporal_error_logged:
		_temporal_error_logged = true
		push_warning("[clouds] temporal pass unavailable (%s); the per-pixel march stays" % err.get_slice("\n", 0))
	var out: RID = pub["out"]
	var size: Vector2i = pub["size"]
	if not out.is_valid() or size.x <= 0:
		return false
	if _view_tex.texture_rd_rid != out:
		_view_tex.texture_rd_rid = out
		_view_bind_wait = VIEW_BIND_FRAMES
		if trace_stamps > 0.0:
			print("[clouds] temporal view rebind at frame %d (%s)" % [_frame, size])
	if _view_bind_wait > 0:
		# BIND THE HISTORY ONLY ONCE ITS SWAP HAS RUN. Texture2DRD swaps its RD texture on the render thread; until
		# then get_rid() is Godot's 2D placeholder (a magenta / black 4 x 4 checker), and a global set then holds it.
		# Nothing re-built the sky material's uniform set afterwards once the sky was quiet (no material write every
		# frame), so the sky drew the checker as clouds: white, with dark crosses at the black texels. Not live (the
		# per-pixel march) until bound.
		_view_bind_wait -= 1
		if _view_bind_wait > 0 or _view_tex.get_width() <= 0:
			_view_bind_wait = maxi(_view_bind_wait, 1)
			return false
		RenderingServer.global_shader_parameter_set(&"cloud_view", _view_tex)
	var f: int = pub["frame"]
	if f != _temporal_frame:
		_temporal_frame = f
		_temporal_stall = 0
	elif _draws != _temporal_draws or not stall_in_draws:
		_temporal_stall += 1
	_temporal_draws = _draws
	CloudUniforms.push_view_size(size)
	var live := _temporal_stall < TEMPORAL_STALL_FRAMES
	if trace_stamps > 0.0 and live != _temporal_live_dbg:
		# Look-dev (CLOUDS4): when the sky hands the clouds to / takes them back from the temporal pass.
		print("[clouds] temporal live=%s at frame %d (published %d, stall %d, drawn %d)" % [live, _frame, f, _temporal_stall,
				Engine.get_frames_drawn()])
	_temporal_live_dbg = live
	_push_atm_fog_view(live, size)
	return live


## Everything the render thread needs for one trace, taken AFTER push_frame so
## the compute march reads this frame's globals.
func _temporal_snapshot(tier_in: Dictionary) -> Dictionary:
	var tier := tier_in
	if not temporal_tuning.is_empty():
		tier = tier_in.merged(temporal_tuning, true)
	var texs: Array = []
	for n in CloudTemporalGlsl.sampler_names():
		var t: Variant = CloudUniforms.values.get(StringName(n))
		if not (t is Texture):
			# Never pushed (the other field model's texture): the placeholder the global holds.
			t = CloudGlobals.placeholder(StringName(n))
		texs.append((t as Texture).get_rid() if t is Texture else RID())
	var c := CloudUniforms.drawn_clock(_model)
	return {
		"main_rt": _main_render_target(),
		"globals": CloudTemporalMath.pack_globals(CloudUniforms.values),
		"textures": texs,
		"clock": PackedFloat64Array([c.x, c.z]),
		"lattice": int(tier.get("temporal_lattice", 2)),
		"retain": float(tier.get("temporal_retain", 0.8)),
		"jitter": float(tier.get("temporal_jitter", 0.5)),
		"max_steps": int(CloudUniforms.march_keys(tier)["max_steps"]),
		"light_n": int(CloudUniforms.march_keys(tier)["light_samples"]),
		"reset": _temporal_reset,
		# The clouds' motion vectors for TAA (#775); --tune temporal_velocity=0 for an A/B.
		"velocity": float(tier.get("temporal_velocity", 1.0)) > 0.5,
		# Under DLSS a surface keeps its own motion vector (the velocity kernel, prompts/85); look-dev key
		# `temporal_velocity_geometry` (1 = the cloud's motion over geometry anyway, 0 = never).
		"keep_geometry_motion": float(tier.get("temporal_velocity_geometry", 0.0 if uses_dlss(get_viewport()) else 1.0)) < 0.5,
	}


## True while the viewport's 3D scaling mode is the engine's DLSS (the NVIDIA-RTX fork; looked up by name: the
## official engine has no such constant). VideoApply.uses_dlss's test.
static func uses_dlss(vp: Viewport) -> bool:
	return vp != null and ClassDB.class_has_integer_constant(&"Viewport", &"SCALING_3D_MODE_DLSS") \
			and int(vp.scaling_3d_mode) == ClassDB.class_get_integer_constant(&"Viewport", &"SCALING_3D_MODE_DLSS")


## The main viewport's render target, asked once per viewport: viewport_get_render_target is a
## SYNCHRONOUS call into the render thread (FUNC1RC), and asked every frame it made the main thread
## wait for the render thread every frame on HIGH ("causing RenderingServer synchronizations on
## every frame", 9,672 times in one bench run). The target lives as long as its viewport.
func _main_render_target() -> RID:
	var vp := get_viewport().get_viewport_rid()
	if vp != _rt_viewport or not _rt.is_valid():
		_rt_viewport = vp
		_rt = RenderingServer.viewport_get_render_target(vp)
	return _rt


static func _water_priorities() -> Array:
	var out: Array = []
	for p in Engine.get_main_loop().get_nodes_in_group(&"cloud_water"):
		var m: Variant = p.get("ocean_material") if is_instance_valid(p) else null
		if m is Material:
			out.append((m as Material).render_priority)
	return out


## The ground under the main camera (world Y): the terrain's height there, or the sea's level (0) off the terrain and
## over the seabed. The eye veil (cloud_march.gdshaderinc) stands only near it: a camera floating under a cloud base over
## the sea, or flying, is in clear air (owner prompts/45).
func _eye_ground_y() -> float:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return -1.0e6
	return ground_y

