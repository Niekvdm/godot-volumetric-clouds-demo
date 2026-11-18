class_name CloudOptics
extends RefCounted
## Pure GDScript mirror of the cloud lighting maths (cloud_light.gdshaderinc)
## and the half-res buffer depth code (cloud_march.gdshaderinc). LOCKSTEP:
## change one, change both. Exists so the maths is unit-testable headless.

## Extinction per metre at density 1 (Hillaire 2016's cumulus range).
const SIGMA_EXT := 0.05
## In-cloud march step (LOCKSTEP with cloud_march.gdshaderinc): target optical
## depth per step, and the shortest step.
const TAU_STEP := 0.5
const DT_FINE := 10.0
## Diffusion (multiple scattering past the octaves), LOCKSTEP with cloud_light's
## cloud_ms_diffuse. Pushed as cloud_light_d.xy.
## 0.5 since 2026-09-28 (was 1.0, which is the two-stream figure: ~15 % of the
## lit side at od 40). At 1.0 the x16 sun blew the sunlit tops out and the photo
## tonemap compressed them down toward the bases, so every shadowed underside read
## light grey and the cloud flat (sky_shot --debug 1: the base nearly as bright as
## the flanks). Half of it puts a fair-weather base (od ~20) at ~14 % and a thick
## one (od 40) at ~8 %: the grey-base / white-top contrast of the photos. An
## art-direction step, not a physics claim.
const MS_STRENGTH := 0.5
const MS_K := 0.1125
const DEPTH_K := 64.0
const DEPTH_SPAN := 11.0      # log2(1 + 128 km / 64 m) ~= 11


static func hg(cos_t: float, g: float) -> float:
	var g2 := g * g
	return (1.0 - g2) / (4.0 * PI * pow(1.0 + g2 - 2.0 * g * cos_t, 1.5))


static func dual_lobe(cos_t: float, g_fwd: float, g_back: float, mix_w: float, g_scale: float) -> float:
	return lerpf(hg(cos_t, g_fwd * g_scale), hg(cos_t, g_back * g_scale), mix_w)


## Wrenninge multiple-scattering octaves: octave i attenuates by od*a^i, carries
## energy b^i and flattens the phase by c^i. h01 (0..1 layer height) scales the
## MS octaves (i >= 1) by the VERTICAL PROBABILITY ms_v — multiply-scattered
## light builds with height; defaults to 1.0 (unscaled) for callers measuring
## the lit top.
static func octave_sum(cos_t: float, od: float, a: float, b: float, c: float, n: int,
		g_fwd: float, g_back: float, mix_w: float, h01 := 1.0, prof := 1.0) -> float:
	var s := 0.0
	var ai := 1.0
	var bi := 1.0
	var ci := 1.0
	var msv := ms_v(h01) * ms_p(prof)
	for i in n:
		var w := 1.0 if i == 0 else msv
		s += w * bi * dual_lobe(cos_t, g_fwd, g_back, mix_w, ci) * exp(-od * ai)
		ai *= a
		bi *= b
		ci *= c
	return s


## Vertical multiple-scattering probability (Nubis
## clouds): MS light builds with height, bases see mostly their own shadow.
## LOCKSTEP with cloud_light's cloud_ms_v (CLOUD_MS_V_FLOOR/KNEE).
const MS_V_FLOOR := 0.35
const MS_V_KNEE := 0.45


static func ms_v(h01: float) -> float:
	return lerpf(MS_V_FLOOR, 1.0, smoothstep(0.0, MS_V_KNEE, h01))


## Nubis³ in-scatter probability: the MS octaves ride the dimensional profile
## (0 at the envelope, 1 CLOUD_PROFILE_M in); a bulge's skin keeps MS_SKIN of
## them. LOCKSTEP with cloud_light's cloud_ms_p / CLOUD_MS_SKIN.
const MS_SKIN := 0.35


static func ms_p(prof: float) -> float:
	return lerpf(MS_SKIN, 1.0, sqrt(clampf(prof, 0.0, 1.0)))


## HZD beer-powder on the optical depth TOWARD THE SUN (od_l), view dependent:
## none looking into the sun, full looking away; POWDER_FLOOR keeps a front-lit
## skin from going black. LOCKSTEP with cloud_light's cloud_powder.
const POWDER_FLOOR := 0.3


static func powder(od_l: float, cos_t: float, strength: float) -> float:
	var pw := lerpf(POWDER_FLOOR, 1.0, 1.0 - exp(-2.0 * od_l))
	return lerpf(1.0, lerpf(pw, 1.0, 0.5 + 0.5 * cos_t), strength)


## Diffuse reflection off the lit skin (golden hour): isotropic, fading over
## REFLECT_OD optical depths toward the sun. LOCKSTEP with cloud_light's
## cloud_ms_reflect / CLOUD_REFLECT_*.
const REFLECT_STRENGTH := 1.6
const REFLECT_OD := 2.0


static func ms_reflect(od_l: float) -> float:
	return REFLECT_STRENGTH / (4.0 * PI) * exp(-od_l / REFLECT_OD)


## The (Rayleigh, Mie) optical depth from altitude `h` toward a light at `dir_y`, to the top of
## the atmosphere: 12 samples spaced quadratically in distance (the low air is the first few tens
## of km of the path; 8 even steps made the Mie column toward an 8 deg sun 3.5x too small), and a
## light under the horizon taken at the grazing ray (the ground-hit path is SHORTER: the tint
## flashed back to white as the sun dipped under a cloud's horizon). LOCKSTEP with cloud_march's
## cloud_sun_od / CLOUD_SUN_OD_STEPS.
const SUN_OD_STEPS := 12


static func sun_od(h: float, dir_y: float) -> Vector2:
	var r := PlanetGeometry.EARTH_RADIUS_M
	var hh := maxf(h, 0.0)
	var graze := -sqrt(hh * (2.0 * r + hh)) / (r + hh)   # the horizon's dip at h
	var dy := maxf(dir_y, graze + 1e-4)
	var t_end := PlanetGeometry._atmosphere_exit(h, dy)
	var total := Vector2.ZERO
	for i in SUN_OD_STEPS:
		var u0 := float(i) / SUN_OD_STEPS
		var u1 := float(i + 1) / SUN_OD_STEPS
		var alt := maxf(PlanetGeometry.altitude_along_ray(h, dy, t_end * 0.5 * (u0 * u0 + u1 * u1)), 0.0)
		total += Vector2(exp(-alt / PlanetGeometry.RAYLEIGH_H), exp(-alt / PlanetGeometry.MIE_H)) \
				* (t_end * (u1 * u1 - u0 * u0))
	return total


## AEROSOL (#773): what reddens and dims a low sun most, and Sky3D's Mie beta (~3e-8 / m) all but
## leaves out. A maritime haze: optical depth AEROSOL_AOD at 550 nm (clean-to-typical over the
## north-west Pacific, 0.06-0.15) with Angstrom exponent AEROSOL_ANGSTROM (sea salt and sulphate,
## ~1), at Sky3D's wavelengths (SkyDome.atm_wavelengths 680 / 550 / 440 nm), spread over the Mie
## scale height. Pushed as cloud_light_e.xyz; only the sun's path to a cloud reads it.
const AEROSOL_AOD := 0.12
const AEROSOL_ANGSTROM := 1.0
const AEROSOL_LAMBDA_NM := Vector3(680.0, 550.0, 440.0)


static func aerosol_beta(aod: float, angstrom: float) -> Vector3:
	var b := aod / PlanetGeometry.MIE_H
	return Vector3(b * pow(AEROSOL_LAMBDA_NM.x / 550.0, -angstrom), b * pow(AEROSOL_LAMBDA_NM.y / 550.0, -angstrom),
			b * pow(AEROSOL_LAMBDA_NM.z / 550.0, -angstrom))


## The sun at a cloud of altitude `h`, relative to the zenith at that altitude:
## transmittance through the sky's raw betas plus the aerosol (`beta_aer`) along
## the real path to the sun. LOCKSTEP with cloud_march's cloud_sun_tint.
static func sun_tint(h: float, sun_y: float, beta_ray: Vector3, beta_mie: Vector3,
		beta_aer := Vector3.ZERO) -> Vector3:
	var hh := maxf(h, 0.0)
	var od := sun_od(hh, sun_y)
	var od0 := Vector2(PlanetGeometry.RAYLEIGH_H * exp(-hh / PlanetGeometry.RAYLEIGH_H),
			PlanetGeometry.MIE_H * exp(-hh / PlanetGeometry.MIE_H))
	var e := beta_ray * maxf(od.x - od0.x, 0.0) + (beta_mie + beta_aer) * maxf(od.y - od0.y, 0.0)
	return Vector3(exp(-e.x), exp(-e.y), exp(-e.z))


## THE SKY AMBIENT'S SAMPLES (#773), LOCKSTEP with sky_scatter's sky_ambient_for_clouds: the sky
## hemisphere's mean radiance (a cloud's skin takes light from every direction), by a 2-point
## Gauss rule in u = sin(elevation) on [0, 1] (solid angle is uniform in u): nodes (1 -+ 1/sqrt(3))
## / 2 (12.2 and 52.1 deg), equal weights, 90 deg in azimuth from the sun. Exact for any sky whose
## radiance is a cubic in sin(elevation). Was 0.6 x the zenith + 0.4 x a sample at 2.9 deg.
const AMBIENT_NODE_SIN := [0.211325, 0.788675]
const AMBIENT_NODE_W := [0.5, 0.5]


## Sky3D lays its sunset light tint (atm_horizon_light_tint, by `warmth`) over its whole sky; the
## clouds' ambient takes it back out (the real zenith and anti-solar sky stay blue at sunset: ozone,
## which Sky3D does not model). Per channel: day / mix(day, horizon, warmth). 1 at warmth 0 (night,
## and the sky's noon look). LOCKSTEP with sky_ambient_for_clouds' `untint`.
static func ambient_untint(day_tint: Color, horizon_tint: Color, warmth: float) -> Vector3:
	var m := day_tint.lerp(horizon_tint, warmth)
	return Vector3(day_tint.r / maxf(m.r, 1e-3), day_tint.g / maxf(m.g, 1e-3), day_tint.b / maxf(m.b, 1e-3))


## Nubis³ ambient probability: sky light only penetrates the skin. LOCKSTEP with
## cloud_light's cloud_amb_p.
static func amb_p(prof: float) -> float:
	return sqrt(1.0 - clampf(prof, 0.0, 1.0))


## One energy-conserving march step with albedo 1 (sigma_s = sigma_t):
## added = T * S * (1 - e^(-sigma dt)); T' = T * e^(-sigma dt).
static func step(T: float, S: float, sigma: float, dt: float) -> Vector2:
	var ts := exp(-sigma * dt)
	return Vector2(T * ts, T * S * (1.0 - ts))


static func encode_depth(m: float) -> float:
	return log(1.0 + maxf(m, 0.0) / DEPTH_K) / log(2.0) / DEPTH_SPAN


static func decode_depth(e: float) -> float:
	return (pow(2.0, e * DEPTH_SPAN) - 1.0) * DEPTH_K


## In-cloud step length: the step that adds TAU_STEP of optical depth, never
## shorter than DT_FINE nor longer than the coarse (empty-air) step.
static func march_step(dens: float, sigma: float, dt_coarse: float) -> float:
	return clampf(TAU_STEP / maxf(dens * sigma, 1e-6), DT_FINE, dt_coarse)


## Diffusely transmitted sunlight past what the octaves carry: the two-stream
## slab transmittance 1/(1 + 0.75(1-g) od) (g ~0.85 -> k 0.1125) minus the
## direct part, times the isotropic phase. Zero on the lit surface.
static func ms_diffuse(od: float, strength: float, k: float) -> float:
	return strength / (4.0 * PI) * maxf(1.0 / (1.0 + k * od) - exp(-od), 0.0)


## The march's in-cloud path for a camera INSIDE a uniform cloud, the segment
## ending at the scene (seg = [0, seg_len]) — LOCKSTEP with cloud_march_to:
## first sample, entry bisection (lands on seg.x inside a uniform cloud), in-cloud
## steps. Test hook for the start/clip policy.
static func march_uniform_T(seg_len: float, dens: float, sigma: float, dt_c: float, jit: float) -> float:
	var t := minf(dt_c, seg_len) * jit
	if t >= seg_len:
		return 1.0
	t = 0.0
	var tr := 1.0
	while t < seg_len and tr >= 0.03:
		var dt := minf(march_step(dens, sigma, dt_c), seg_len - t)
		tr *= exp(-dens * sigma * dt)
		t += dt
	return tr


## STORM DARKNESS (#774): the optical depth of the raining column the light ray cannot see, at
## the layer's base, from the synced rain, storm energy and cloud type (pushed as
## cloud_light_e.w). The light ray reaches ~700 m. A raining STRATIFORM sky (nimbostratus) is 2-5 km
## of cloud (tau ~50-150), but the deck channel draws only the layer's ~900 m, so a rain sky drew
## LIGHTER than fair-weather cumulus (mean 0.385 against 0.323 on screen): rain on the non-Cb
## share of the type takes COLUMN_TAU_RAIN. A cumulonimbus is drawn whole (a 9 km tower, its core
## already darkening its ambient), and its base already read 0.069 (5x the fair sky's darkness):
## storm energy adds only COLUMN_TAU_STORM. Zero when dry: fair weather and dry overcast are
## untouched. LOCKSTEP with cloud_light's cloud_column_od / cloud_column_amb.
const COLUMN_TAU_RAIN := 45.0
const COLUMN_TAU_STORM := 8.0


static func column_tau(rain: float, storm: float, cloud_type: float) -> float:
	var cb := CloudManifest.type_weights(cloud_type).z
	return COLUMN_TAU_RAIN * clampf(rain, 0.0, 1.0) * (1.0 - cb) + COLUMN_TAU_STORM * clampf(storm, 0.0, 1.0)


## In a broken sky the column continues only where the light ray is still deep in cloud at its end
## (the full march; the cheap one keeps it whole): a sunlit skin, a tower's flank or a top, has clear
## air toward the sun past it. A stratiform sheet is closed, so its stratus weight opens the gate
## whole. LOCKSTEP with cloud_light's cloud_column_gate.
const COLUMN_OD_LO := 3.0
const COLUMN_OD_HI := 12.0


static func column_gate(od_ray: float, cloud_type: float) -> float:
	return lerpf(smoothstep(COLUMN_OD_LO, COLUMN_OD_HI, od_ray), 1.0, CloudWeather.stratus_weight(cloud_type))


## Whole at the base (h01 = 0), gone at the layer's top: a sunlit top stays sunlit.
static func column_od(tau: float, h01: float) -> float:
	return tau * (1.0 - clampf(h01, 0.0, 1.0))


## The sky light that still reaches a point under that column: the two-stream diffuse
## transmittance through it (k = MS_K).
static func column_amb(od_c: float) -> float:
	return 1.0 / (1.0 + MS_K * od_c)


## LIGHTNING (#774): how a strike's light escapes the cloud at distance d from its channel, for a
## spread r, q = d / r: (1 + q^2)^-1.5, a point source's dipole shape, times e^(-q/2), the light
## leaking out through the base as it spreads (over about the slab's own depth): 0.21 at r, 3 % at
## 2 r. Without the leak, at 1/q^3, a CG strike 3.5 km off lit the base over the camera to ~10x the
## storm's own light (a white-out). LOCKSTEP with cloud_march's cloud_flash_light.
static func flash_kernel(d: float, r: float) -> float:
	var q := d / maxf(r, 1.0)
	return exp(-0.5 * q) / ((1.0 + q * q) * sqrt(1.0 + q * q))


## The distance from p to the segment a-b (the flash's line source), as cloud_flash_light has it.
static func segment_distance(p: Vector3, a: Vector3, b: Vector3) -> float:
	var ab := b - a
	var u := clampf((p - a).dot(ab) / maxf(ab.dot(ab), 1.0), 0.0, 1.0)
	return p.distance_to(a + ab * u)


## THE FOUR-LOBE LIGHTING (B1, 2026-11-15): the terms cloud_light.gdshaderinc's B1 section runs when
## cloud_look.x = 1. LOCKSTEP with cloud_ff_phase / cloud_ff_glow / cloud_ff_ms / cloud_ff_powder /
## cloud_ff_rim / cloud_ff_up_occlusion / cloud_ff_ground and the CLOUD_FF_* constants
## (test_cloud_optics reads them out of the shader).
const FF_MS_GAIN := 2.6
const FF_GLOW := 0.06
const FF_SILVER := 0.5
const FF_RIM := 1.5
const FF_LIGHT_D0 := 36.0
const FF_LIGHT_GROW := 1.85
const FF_TALL_M := 2500.0
const FF_UP_M := 450.0
const FF_GROUND_ALBEDO := 0.11
## The four lobes (g, weight): a sharp forward peak, the broad forward lobe that carries the silver
## lining out to ~45 deg, a weak back lobe, and the narrow diffraction peak. Weights sum to 1.
const FF_LOBES := [Vector2(0.86, 0.42), Vector2(0.5, 0.3), Vector2(-0.25, 0.2), Vector2(0.97, 0.08)]


static func ff_phase(c: float, k: float) -> float:
	var s := 0.0
	for l: Vector2 in FF_LOBES:
		s += hg(c, l.x * k) * l.y
	return s


static func ff_glow(c: float, od: float) -> float:
	return FF_GLOW * hg(c, 0.85) * (1.0 / (1.0 + 0.3 * od) + exp(-0.3 * od)) \
			+ FF_SILVER * hg(c, 0.9) * exp(-0.35 * od)


static func ff_ms(c: float, od: float) -> float:
	var ms := 0.0
	var a := 1.0
	var b := 1.0
	var k := 1.0
	for i in 4:
		ms += a * exp(-od * b) * ff_phase(c, k)
		a *= 0.55
		b *= 0.38
		k *= 0.5
	ms += 0.4 / (4.0 * PI) / (1.0 + 0.25 * od)
	ms += ff_glow(c, od)
	return ms * FF_MS_GAIN


static func _ff_remap(v: float, a: float, b: float, c: float, d: float) -> float:
	return c + (v - a) / (b - a) * (d - c)


static func ff_powder(d01: float, hn: float, c: float) -> float:
	var dprob := 0.08 + pow(maxf(d01, 0.0), _ff_remap(clampf(hn, 0.3, 0.85), 0.3, 0.85, 0.5, 2.0))
	var vprob := pow(clampf(_ff_remap(hn, 0.05, 0.2, 0.25, 1.0), 0.25, 1.0), 0.8)
	return lerpf(1.0, clampf(dprob * vprob * 1.25, 0.0, 1.0), 0.55 * (1.0 - smoothstep(0.0, 0.6, c)))


static func ff_rim(c: float, t: float, lit: float) -> float:
	if c <= 0.5:
		return 0.0
	var tau := -log(maxf(t, 1e-4))
	return FF_RIM * hg(c, 0.94) * tau * exp(-tau) * (1.0 - clampf(lit, 0.0, 1.0))


## The sky light that still reaches a sample under od_up of cloud straight above it.
static func ff_up_occlusion(od_up: float) -> float:
	return lerpf(1.0 / (1.0 + 0.15 * od_up), 1.0, 0.12)


static func ff_ground(sun_y: float, cover: float) -> float:
	return FF_GROUND_ALBEDO * maxf(sun_y, 0.0) / PI * lerpf(1.0, 0.45, clampf(cover, 0.0, 1.0))


## Where the long light ray's segments end: 36 m, x1.85 a step (6 samples: 1.66 km, 7: 3.1 km).
static func ff_light_reach(n: int) -> float:
	var ls := FF_LIGHT_D0
	var lt := 0.0
	for j in n:
		lt += ls
		ls *= FF_LIGHT_GROW
	return lt
