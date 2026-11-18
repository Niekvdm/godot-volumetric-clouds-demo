class_name CloudUniforms
extends RefCounted
## SOLE per-frame writer of the cloud_* globals (CloudGlobals.TABLE). One writer
## means the sky pass and (Phase 3) the flight pass read the same values in the
## same frame. Packing: see CloudGlobals / cloud_params.gdshaderinc.

## Direct sun scale against sky radiance: the DirectionalLight's energy is a
## scene-lighting number, only ~1.5x the mean sky; a real sun is ~15-20x, and at
## 1.5x noon clouds sat in a flat grey band.
## The field's wind shear (the tops lean downwind), LOCKSTEP with cloud_field.gdshaderinc.
const FIELD_SHEAR := 0.12
const SUN_SCALE := 16.0
const CURL_M := 342.0
const CORE_THRESHOLD := 0.32
const CORE_PROTECT := 1.0
const CORE_FILL := 0.88
const OCTAVE := 0.5
const HG_FWD := 0.7
const HG_BACK := -0.3
const HG_MIX := 0.3
const POWDER := 1.0
const DEPTH_DARK := 0.48
const AMBIENT_SCALE := 1.0
## Sky ambient reaches full strength this far above the cloud base (m) and keeps
## AMBIENT_FLOOR of it at the base.
const AMBIENT_HEIGHT_M := 1000.0
const AMBIENT_FLOOR := 0.3
## The procedural field rains from this cloud shape (0-1, its density over the layer's) and fully from PF_RAIN_FULL
## (the shafts' column ramp; tier keys pf_rain_on / pf_rain_full), sampled PF_RAIN_PROBE_M (x the depth scale) over
## the base (pf_rain_probe_m). CLOUDS5 (R29): 250 m sat above its stratus slab (~0.11 of the layer), so a steady rain
## deck drew no shafts at all (sky band L 133-148 against the baked field's 65); 120 m with the ramp 0.43-0.68 reads
## like the baked field's rain sky. Was 0.1 / 0.75 / 250.
const PF_RAIN_ON := 0.43
const PF_RAIN_FULL := 0.68
const PF_RAIN_PROBE_M := 120.0
## THE PROCEDURAL CUMULUS' DEFINITION (CLOUDS6, R34). Tier keys of the same
## names override them (A/B: n.CloudBridge.tune=pf_proxy:0;pf_core_k:1;pf_cu_dens:1;pf_proxy_shadow:0 = before).
## PF_PROXY (cloud_pf_c.w bit 256; pf_proxy_cheap bit 512, pf_proxy_shadow bit 2048): the probes that skip the
## erosion (the light ray past its first sample, the up-probe; the cheap march = the reflection cubemap; the ground
## shadows and the far field) take its mean instead of the uneroded envelope. That envelope filled 84-98 % of the
## lower layer at a half-covered sky, so every drawn puff sat in the shadow of cloud nobody draws: the lit flanks got
## a fifth of their key light and the cumulus read flat (CLOUDS5's "flat white-grey"). The rain's column probes keep
## the envelope (R29's tuning).
## PF_CORE_K (cloud_q_flight.z): the cumulus' cover remap steepened before the erosion, so the
## erosion carves a billowed skin round a solid core instead of a porous puff (and the sky is less sparse).
## PF_CU_DENS (cloud_q_flight.w): the cumulus' extinction in the march x this, on top of the tier's pf_density_k
## (0.5: CLOUDS3 halved it against the envelope's false shade), so 0.85 x CloudWeather's 0.6: dark bases and shaded
## cores against the sunlit billows (the a4 run's spread matched the baked field's at 1.7; 1.4 was softer).
const PF_CORE_K := 1.5
const PF_CU_DENS := 1.7
const PF_PROXY := true
const REFLECTION_SUN := 0.2
## Start at 1.0, not the reference's 1.29: AtmFog also fogs sky pixels here.
const AP_STRENGTH := 1.0
const FAR_FADE_FRAC := 0.75
## SEA BOUNCE: sunlight off the ocean lighting cloud undersides —
## direct-beam, shadowed by the own column, quadratic fade to nothing by
## mid-height. Pushed as cloud_fade.z.
const SEA_BOUNCE := 0.05


## THE PROCEDURAL FIELD'S DRIFT (B2): every one of its tiles divides one of these periods (cloud_pf_field's
## PF_* and cloud_pf_march's), so the offsets wrap with no seam. 65536 m keeps the small tiles' offsets
## precise in float32 (4 mm); 2^21 m the weather's (0.25 m against tiles of 1.5 km and more).
const PF_P_SMALL := 65536.0
const PF_P_BIG := 2097152.0
## How fast each part of the procedural field drifts against the steering wind: the
## erosion's warp 1.15x, the erosion 1.3x, the mid-level layer 1.5x, the cirrus 2.2x.
const PF_K_WARP := 1.15
const PF_K_DETAIL := 1.3
const PF_K_ALTO := 1.5
const PF_K_CIRRUS := 2.2
## The listed storm cells (CloudStorms in the global cloud_storms; CloudBridge sets it).
static var pf_storm_count := 0


## Every value pushed, by global name: the temporal pass (CloudTemporal) packs
## the same numbers into its compute UBO, so the sky, the flight quad and the
## compute march read one set per frame. Globals cannot be read back cheaply at
## runtime (global_shader_parameter_get is editor-grade).
static var values: Dictionary = {}
## Look-dev key `freeze_clock` (CLOUDS6): the field's drift held where it was when the key was first seen, so an A/B
## run's setups draw the same clouds (the shaders' offsets only; the model, its shadows and the dome keep moving).
static var _frozen: CloudClock = null


## The clock the shaders' offsets follow (the model's, or the frozen look-dev one): the temporal pass reprojects by it.
static func drawn_clock(model: CloudModel) -> CloudClock:
	return _frozen if _frozen != null else model.clock


## Not `_set`: that name is Object._set (a virtual with another signature).
static func _put(n: StringName, v: Variant) -> void:
	values[n] = v
	RenderingServer.global_shader_parameter_set(n, v)


static func push_constants(m: CloudManifest) -> void:
	var f := m.field
	var mac: Dictionary = m.assets.get("macro", {})
	_put(&"cloud_field_a", Vector4(float(f["birth_band"]), float(f["birth_m"]), float(f["erode_m"]), float(f["inflate_m"])))
	_put(&"cloud_field_b", Vector4(float(f["edge_m"]), float(f["erosion"]),
			float(mac.get("sdf_range_m", 1024.0)), float(mac.get("height_m", 9600.0))))
	_put(&"cloud_field_c", Vector4(float(f.get("billow_m", 0.0)), float(f.get("base_round_m", 0.0)),
			float(f.get("base_round_h", 1.0)), float(f.get("detail_m", 0.0))))
	_put(&"cloud_periods", Vector4(m.period("macro"), m.period("base"), m.period("detail"), m.period("curl")))
	var dims: Array = mac.get("dims", [256, 256, 64])
	_put(&"cloud_periods2", Vector4(m.period("scatter"), float(dims[2]), 0.0, 0.0))
	_put(&"cloud_light_a", Vector4(CloudOptics.SIGMA_EXT, OCTAVE, OCTAVE, OCTAVE))
	_put(&"cloud_light_b", Vector4(HG_FWD, HG_BACK, HG_MIX, POWDER))
	_put(&"cloud_light_c", Vector4(SUN_SCALE, DEPTH_DARK, AMBIENT_SCALE, REFLECTION_SUN))
	_put(&"cloud_light_d", Vector4(CloudOptics.MS_STRENGTH, CloudOptics.MS_K, AMBIENT_HEIGHT_M, AMBIENT_FLOOR))
	var ab := CloudOptics.aerosol_beta(CloudOptics.AEROSOL_AOD, CloudOptics.AEROSOL_ANGSTROM)
	_put(&"cloud_light_e", Vector4(ab.x, ab.y, ab.z, 0.0))
	_put(&"cloud_fade", Vector4(AP_STRENGTH, FAR_FADE_FRAC, SEA_BOUNCE, CloudPartition.SPLIT_MARGIN))


static func push_textures(a: CloudAssets) -> void:
	# A texture not made yet keeps whatever the global holds (CloudGlobals' placeholder): a texture global
	# write re-dirties the sky too.
	for pair in [[&"cloud_base_noise", a.base_tex], [&"cloud_blue_noise", a.blue_tex], [&"cloud_pf_noise", a.pf_tex]]:
		if pair[1] != null and values.get(pair[0]) != pair[1]:
			_put(pair[0], pair[1])


## The procedural field's storm cells (CloudBridge: a 16 x 1 RGBAF it updates in place; set once, as a
## texture global write re-dirties the sky).
static func push_storms(tex: Texture2D) -> void:
	if values.get(&"cloud_storms") != tex:
		_put(&"cloud_storms", tex)


## The 2D cirrus drift on the volumetric sky (a buffer global: the quiet sky; CloudBridge._push_cirrus_drift).
static func push_cirrus(pos: Vector2) -> void:
	_put(&"cloud_cirrus", Vector4(pos.x, pos.y, 0.0, 0.0))


## The procedural field's drift offsets: (k x the clock) wrapped by its period, in float64 before the
## float32 the GPU gets. [cloud_pf_off_a, _b, _c] (CloudGlobals: their packing).
static func pf_offsets(c: CloudClock) -> Array[Vector4]:
	var w := func(k: float, p: float) -> Vector2:
		return Vector2(fposmod(c.x * k, p), fposmod(c.z * k, p))
	var a1: Vector2 = w.call(1.0, PF_P_SMALL)
	var a2: Vector2 = w.call(1.0, PF_P_BIG)
	var b1: Vector2 = w.call(PF_K_WARP, PF_P_SMALL)
	var b2: Vector2 = w.call(PF_K_DETAIL, PF_P_SMALL)
	var c1: Vector2 = w.call(PF_K_ALTO, PF_P_BIG)
	var c2: Vector2 = w.call(PF_K_CIRRUS, PF_P_BIG)
	return [Vector4(a1.x, a1.y, a2.x, a2.y), Vector4(b1.x, b1.y, b2.x, b2.y), Vector4(c1.x, c1.y, c2.x, c2.y)]




## The march budget for the tier's field: the procedural field has its own keys (pf_*).
static func march_keys(tier: Dictionary) -> Dictionary:
	return {"step_base_m": float(tier.get("pf_step_base_m", 40.0)), "step_growth": float(tier.get("pf_step_growth", 0.016)),
			"step_max_m": float(tier.get("pf_step_max_m", 2000.0)), "max_steps": int(tier.get("pf_max_steps", 160)),
			"light_samples": int(tier.get("pf_light", 6))}


## The temporal pass's view: the main viewport's internal size and its
## reciprocal (CloudBridge reads it from CloudTemporal.published()).
static func push_view_size(size: Vector2i) -> void:
	_put(&"cloud_view_size", Vector4(size.x, size.y, 1.0 / maxf(size.x, 1.0), 1.0 / maxf(size.y, 1.0)))


static func push_mode(mode_on: bool) -> void:
	_put(&"cloud_mode", 1 if mode_on else 0)
	if not mode_on:
		# No flight pass without the march: the sky composites every direction again.
		_put(&"cloud_flags", 0)


## The ground (terrain, or the sea surface) under the main camera, world Y: CloudBridge sets it every frame; pushed as
## cloud_key_color.w (the eye veil stands only on the ground, cloud_march's cloud_eye_veil_sigma). Very low = unknown.
static var eye_ground_y := -1.0e6


static func push_frame(model: CloudModel, tier: Dictionary, key: Dictionary, frame: int, flags: int) -> void:
	var s := model.state
	var c := model.clock
	if float(tier.get("freeze_clock", 0.0)) > 0.0:
		if _frozen == null:
			_frozen = CloudClock.new()
			_frozen.load_dict(c.to_dict())
		c = _frozen
	else:
		_frozen = null
	var m := model.manifest
	_put(&"cloud_flags", flags)
	_put(&"cloud_frame", frame)
	# The procedural field's shell reaches its ceiling (the storm towers' when there are storms).
	# .z with the procedural field: times the tier's pf_density_k (its extinction: lower lets the key into the cumulus).
	_put(&"cloud_layer", Vector4(s.base_m, s.pf_ceiling_m,
			s.density * float(tier.get("pf_density_k", 1.0)), s.cloud_type))
	# .z = the field's vertical depth scale (CloudWeather.depth_scale_for).
	_put(&"cloud_shape", Vector4(s.coverage, s.scatter_amp, s.depth_scale, CURL_M))
	_put(&"cloud_shape2", Vector4(CORE_THRESHOLD, CORE_PROTECT, CORE_FILL, FIELD_SHEAR))
	# .w = the rain shafts' reach below the base (m; 0 = dry: no shaft march), #772.
	# Look-dev key `rain_shafts` (n.CloudBridge.tune=rain_shafts:0): no shaft march (CLOUDS4's rain-grain A/B).
	_put(&"cloud_weather", Vector4(s.rain, s.storm, c.wrapped_time(),
			s.rain_reach_m * float(tier.get("rain_shafts", 1.0))))
	var wd := Vector2(model.wind.x, model.wind.z)
	var sp := wd.length()
	wd = wd / sp if sp > 1e-6 else Vector2.RIGHT
	# .w = the procedural field's rain probe height over the base (m, x the depth scale; CLOUDS5).
	_put(&"cloud_wind", Vector4(wd.x, wd.y, sp, float(tier.get("pf_rain_probe_m", PF_RAIN_PROBE_M))))
	var om := c.wrapped(m.period("macro"))
	var ob := c.wrapped(m.period("base"))
	var od := c.wrapped(m.period("detail"))
	var oc := c.wrapped(m.period("curl"))
	var os := c.wrapped(m.period("scatter"))
	_put(&"cloud_offset_a", Vector4(om.x, om.y, ob.x, ob.y))
	_put(&"cloud_offset_b", Vector4(od.x, od.y, oc.x, oc.y))
	# .zw = the procedural field's rain onset / full rain over its cloud shape (the shafts' column ramp; CLOUDS5, R29).
	_put(&"cloud_offset_c", Vector4(os.x, os.y, float(tier.get("pf_rain_on", PF_RAIN_ON)),
			float(tier.get("pf_rain_full", PF_RAIN_FULL))))
	var kd: Vector3 = key["dir"]
	var kc: Color = key["color"]
	# w = 1: the key is the sun, which the shader reddens per cloud (cloud_sun_tint).
	_put(&"cloud_key_dir", Vector4(kd.x, kd.y, kd.z, 1.0 if key.get("sun", false) else 0.0))
	# .w = the ground under the eye (world Y, eye_ground_y): the eye veil's height-above-ground gate (prompts/45).
	_put(&"cloud_key_color", Vector4(kc.r, kc.g, kc.b, eye_ground_y))
	var fade: Vector2 = tier["detail_fade"]
	var mk := march_keys(tier)
	_put(&"cloud_q_view", Vector4(mk["step_base_m"], mk["step_growth"], mk["step_max_m"], float(mk["max_steps"])))
	_put(&"cloud_q_light", Vector4(float(mk["light_samples"]), float(tier["cut_m"]), fade.x, fade.y))
	_put(&"cloud_q_flight", Vector4(float(tier.get("flight_steps", 64)),
			float(mk["light_samples"]), float(tier.get("pf_core_k", PF_CORE_K)),
			float(tier.get("pf_cu_dens", PF_CU_DENS))))
	# Look-dev key `debug_view` (CLOUDS6): cloud_debug from the tier (1 key share, 2 ambient share; sky_shot --debug).
	if tier.has("debug_view"):
		_put(&"cloud_debug", int(tier["debug_view"]))
	# The procedural field (B2): its layer, ceiling, amounts and switches (cloud_pf_field's header).
	var pflags := (1 if bool(tier.get("pf_alto", true)) else 0) | (2 if bool(tier.get("pf_cirrus", true)) else 0) \
			| (4 if bool(tier.get("pf_fine", true)) else 0) | (8 if bool(tier.get("pf_skip", true)) else 0) \
			| (64 if bool(tier.get("rain_rim", true)) else 0) | (128 if float(tier.get("debug_fallback", 0.0)) > 0.0 else 0) \
			| (256 if bool(tier.get("pf_proxy", PF_PROXY)) else 0) \
			| (512 if bool(tier.get("pf_proxy_cheap", tier.get("pf_proxy", PF_PROXY))) else 0) \
			| (2048 if bool(tier.get("pf_proxy_shadow", tier.get("pf_proxy", PF_PROXY))) else 0) \
			| (4096 if bool(tier.get("near_rim", true)) else 0) \
			| (1024 if bool(tier.get("far_below", true)) else 0) \
			| (16 if bool(tier.get("eye_veil", true)) else 0) | (32 if bool(tier.get("veil_rag", true)) else 0) \
			| (8192 if bool(tier.get("pf_top_stop", true)) else 0) | (16384 if bool(tier.get("pf_untile", true)) else 0)
	var var_k := maxf(2.0 * s.scatter_amp, 0.35 * (1.0 - CloudWeather.stratus_weight(s.cloud_type)))
	_put(&"cloud_pf", Vector4(1.0, s.pf_layer_m, s.storms, s.alto))
	# Look-dev key `pf_cover_add` (CLOUDS5): the field's cover slider moved by that much.
	_put(&"cloud_pf_b", Vector4(s.pf_ceiling_m, s.alto_m, clampf(s.pf_cover + float(tier.get("pf_cover_add", 0.0)), 0.0, 1.0),
			float(pf_storm_count)))
	_put(&"cloud_pf_c", Vector4(clampf(2.0 * s.cloud_type, 0.0, 1.0), clampf(var_k, 0.0, 1.0), s.cirrus, float(pflags)))
	var off := pf_offsets(c)
	_put(&"cloud_pf_off_a", off[0])
	_put(&"cloud_pf_off_b", off[1])
	_put(&"cloud_pf_off_c", off[2])
	# The lighting model (B1): the four-lobe terms (1) or the Nubis dual-lobe ones (0), the key's gain
	# at the resolve, the ambient's pull toward grey, the long light ray's samples.
	# The gain and the grey pull belong to the four-lobe model: the Nubis one keeps 1 and 0, as before.
	var ff := int(tier.get("lighting", 0)) == 1
	_put(&"cloud_look", Vector4(1.0 if ff else 0.0, float(tier.get("key_gain", 1.0)) if ff else 1.0,
			float(tier.get("amb_grey", 0.0)) if ff else 0.0, float(tier.get("light_samples_ff", 6))))
	# .w = the raining column's optical depth at the base (#774, CloudOptics.column_tau: 0 when dry).
	var ab := CloudOptics.aerosol_beta(CloudOptics.AEROSOL_AOD, CloudOptics.AEROSOL_ANGSTROM)
	_put(&"cloud_light_e", Vector4(ab.x, ab.y, ab.z, CloudOptics.column_tau(s.rain, s.storm, s.cloud_type)))
	push_flash(model.flash)


## The current strike's light (#774, CloudFlash): its line source, radiance and spread.
static func push_flash(fl: CloudFlash) -> void:
	var i := fl.intensity() if fl != null else 0.0
	if fl == null or i <= 0.0:
		_put(&"cloud_flash_a", Vector4.ZERO)
		return
	_put(&"cloud_flash_a", Vector4(fl.a.x, fl.a.y, fl.a.z, i))
	_put(&"cloud_flash_b", Vector4(fl.b.x, fl.b.y, fl.b.z, fl.radius))


## Mirror of sky_twilight_factors() (src/sky/shaders/twilight.gdshaderinc):
## (warmth, daylight, stars, night) from sin(solar elevation).
static func twilight_factors(sun_up: float) -> Vector4:
	var warmth := clampf(1.0 - sun_up, 0.0, 1.0) * smoothstep(-0.104528, 0.0, sun_up)
	var daylight := clampf(sun_up + 0.45, 0.0, 1.0) * smoothstep(-0.309017, 0.0, sun_up)
	var stars := 1.0 - smoothstep(-0.207912, 0.0, sun_up)
	var night := 1.0 - smoothstep(-0.104528, 0.104528, sun_up)
	return Vector4(warmth, daylight, stars, night)


## sin(-8 deg): the sun hands the key to the moon here (#773). Both are OFF there, so the
## switch cannot show: the sun has lit no cloud under the 9 km layer cap since -3.4 deg (the
## horizon dips sqrt(2h/R) at altitude h, 3.0 deg at CloudWeather.TOP_MAX, plus the march's
## 0.34 deg earth-shadow gate), and Sky3D's MoonLight stays dark until -13.6 deg
## (SunMoonLightFade is 0 below fade (1 - sin(sun)) / 2 = 0.618), then comes up along that curve.
## The handover used to be where the daylight curve ends (-18 deg): the moon came in at once at
## ~45 % of its light (the curve's value there), a pop on every moonlit evening.
const KEY_HANDOVER_SIN := -0.139173


## The key light: the sun until KEY_HANDOVER_SIN, then the moon (colour x energy x moon_scale
## x 16). The sun is its NOON colour x the sky's own twilight daylight curve x 16, with "sun"
## set (pushed as cloud_key_dir.w): the shader REDDENS it by the air between each cloud and the
## sun (cloud_sun_tint: the sky's betas plus a maritime aerosol, #773). Colour and the low sun's
## dimming from the physics, the day's overall level from the sky's curve (the sky's own scatter
## carries the same curve, so the key-to-sky ratio is the physics'). Not the DirectionalLight
## energy, which weather dims.
static func key_light(sun_dir: Vector3, sun_color: Color, moon_dir: Vector3,
		moon_color: Color, moon_energy: float, moon_scale: float) -> Dictionary:
	var tw := twilight_factors(sun_dir.y)
	if sun_dir.y > KEY_HANDOVER_SIN:
		return {"dir": sun_dir, "color": sun_color * (tw.y * SUN_SCALE), "sun": true}
	return {"dir": moon_dir, "color": moon_color * (moon_energy * moon_scale * SUN_SCALE * tw.w), "sun": false}
