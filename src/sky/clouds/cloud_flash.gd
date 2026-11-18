class_name CloudFlash
extends RefCounted
## LIGHTNING THAT LIGHTS THE CLOUD FROM INSIDE (#774). One strike's light: a straight line
## source (the channel, or an intra-cloud discharge) and its brightness over time, built from
## nothing but what every peer already shares about the strike: the position and seed the host
## broadcasts (ThunderSystem.lightning_struck_net -> WeatherSync._receive_lightning ->
## ThunderSystem.trigger_remote_strike) and the synced cloud base (CloudModel; the bolt starts there
## too). No local random: two peers given the same strike light the same cloud the same way, offset
## only by the event's delivery. NOT the layer's top: each peer rate-limits the cloud type toward the
## synced fields on its own, so for up to ~2 minutes after a preset (or a join before a storm) one
## peer's 9 km Cb top is another's 2.7 km (test/run_mp_lightning_autotest.sh measured the light 3 km
## apart that way); the base matched to the metre.
##
## Owned by CloudModel (so it lives on every peer, the dedicated server included, render-free);
## ThunderSystem starts and ages it; CloudUniforms pushes it (cloud_flash_a / _b) for the shaders'
## cloud_flash_light, which adds it at the RESOLVE, from the sample's opacity and mean depth: the
## temporal history refreshes a pixel every 4 frames and blends over many, so a flash traced into
## it would lag and smear; at the resolve it is exact every frame and costs a few ALU a pixel.
##
## The world's flash light (ThunderSystem's DirectionalLight) and the drawn bolt follow the same
## timeline: the stepped leader, the return stroke at LEADER_S (LightningBolt.LEADER_TIME), the
## restrike at RESTRIKE_S (LightningBolt.RESTRIKE_AT) when the seed says so, then the tail.

## The light's colour (LOCKSTEP with CLOUD_FLASH_COLOR in cloud_march.gdshaderinc): a
## lightning channel is ~25 000-30 000 K, blue-white.
const COLOR := Color(0.86, 0.9, 1.0)
## The return stroke lands here (LightningBolt.LEADER_TIME); the restrike (double_flash).
const LEADER_S := 0.09
const RESTRIKE_S := 0.24
## The faint stepped leader before the stroke, as a share of the stroke's peak.
const LEADER_GLOW := 0.06
## Each stroke: a sharp peak (STROKE_TAU_S) and its continuing current (CURRENT_SHARE of it,
## CURRENT_TAU_S): the cloud stays lit for a few tenths of a second after the flash.
const STROKE_TAU_S := 0.045
const CURRENT_TAU_S := 0.16
const CURRENT_SHARE := 0.22
const RESTRIKE_AMP := 0.8
## The light is put out this long after the last pulse (exp(-TAIL_S / CURRENT_TAU_S) ~ 4 %).
const TAIL_S := 0.5
## Intra-cloud flashes: ThunderSystem's ic_pulses pulses, spaced IC_GAP_S apart, each IC_AMP of
## the peak (seeded), dimmer than a CG return stroke and spread wider.
const IC_GAP_S := Vector2(0.06, 0.16)
const IC_AMP := Vector2(0.5, 1.0)
## Peak in-scattered radiance next to the channel, in the clouds' light units (the sun key is
## CloudUniforms.SUN_SCALE = 16 at noon), times the strike's own seeded energy.
const CG_PEAK := 20.0
const IC_PEAK := 16.0
const ENERGY_RANGE := Vector2(0.7, 1.3)
## How far the light spreads through the cloud from the channel before it leaks out: the
## kernel's radius (CloudOptics.flash_kernel: 0.21 at r, 3 % at 2 r). Intra-cloud flashes run in
## the charge layers, deeper in, and spread wider.
const CG_RADIUS_M := 900.0
const IC_RADIUS_M := 1400.0
## The cloud-to-ground channel inside the cloud, up to the main negative charge (a Cb's -10 to
## -20 C level, 4-7 km up): this far over the bolt's cloud entry.
const CG_IN_CLOUD_M := Vector2(2000.0, 5000.0)
## Intra-cloud: a level discharge this far over the base (between the main negative charge and
## the upper positive one), this long. At 1.5-4 km a flash seen from over a 9 km top lit nothing
## (shot set row 78, night: the tops 5-6 km from it).
const IC_HEIGHT_M := Vector2(2500.0, 6000.0)
const IC_LENGTH_M := Vector2(1500.0, 5000.0)
## The cloud-entry headroom LightningBolt.cloud_base_for keeps over the strike's ground.
const MIN_HEADROOM_M := 300.0
## The salt for the flash's own draws: they come AFTER ThunderSystem.strike_params_from_seed's on
## a separate stream, so the strike's character (IC/CG, bolt, pitch) is unchanged.
const SALT := 0x6A09E667

var active := false
var seed := 0
var is_ic := false
## The source segment (world, m), its kernel radius (m) and its peak radiance.
var a := Vector3.ZERO
var b := Vector3.ZERO
var radius := 1.0
var peak := 0.0
## [[t (s since the strike), amp (0-1)], ...]
var pulses: Array = []
var age := 0.0
var end_s := 0.0
## How many strikes this flash has started (the MP test and the logs count them).
var started := 0
## Look-dev / cost probe: the light held at its peak (`hold_peak`), never aging out.
var hold := false


## Everything the light needs from the strike, pure: the source segment, kernel radius, peak and
## the pulses. `params` is ThunderSystem.strike_params_from_seed(seed) (ic, double_flash,
## ic_pulses, bolt_rot, bolt_scale). `pos` is the broadcast strike position (its y the host's
## target altitude: the same on every peer, unlike each peer's own ground raycast).
static func build(pos: Vector3, seed_value: int, params: Dictionary, base_m: float) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value ^ SALT
	var ic: bool = params.get("ic", false)
	var energy := rng.randf_range(ENERGY_RANGE.x, ENERGY_RANGE.y)
	var out := {"ic": ic}
	var pl: Array = []
	if ic:
		var h := base_m + rng.randf_range(IC_HEIGHT_M.x, IC_HEIGHT_M.y)
		var az := rng.randf() * TAU
		var half := 0.5 * rng.randf_range(IC_LENGTH_M.x, IC_LENGTH_M.y)
		var d := Vector3(cos(az), 0.0, sin(az))
		out["a"] = Vector3(pos.x, h, pos.z) - d * half
		out["b"] = Vector3(pos.x, h, pos.z) + d * half
		out["radius"] = IC_RADIUS_M
		out["peak"] = IC_PEAK * energy
		var t := 0.0
		for i in maxi(int(params.get("ic_pulses", 2)), 1):
			pl.append([t, rng.randf_range(IC_AMP.x, IC_AMP.y)])
			t += rng.randf_range(IC_GAP_S.x, IC_GAP_S.y)
	else:
		# Along the drawn bolt's mean line (LightningBolt.setup: it enters the cloud at
		# cloud_base_for(ground, bolt_scale, base), leaning 0.3 of its height toward bolt_rot),
		# continued up into the cloud to the charge region.
		var ground := Vector3(pos.x, maxf(pos.y, 0.0), pos.z)
		var entry_y := maxf(base_m * clampf(float(params.get("bolt_scale", 1.0)), 0.8, 1.4),
				ground.y + MIN_HEADROOM_M)
		var rot: float = params.get("bolt_rot", 0.0)
		var lean := Vector3(cos(rot), 0.0, sin(rot)) * 0.3
		var top := entry_y + rng.randf_range(CG_IN_CLOUD_M.x, CG_IN_CLOUD_M.y)
		out["a"] = ground
		out["b"] = ground + (lean + Vector3.UP) * (top - ground.y)
		out["radius"] = CG_RADIUS_M
		out["peak"] = CG_PEAK * energy
		pl.append([LEADER_S, 1.0])
		if params.get("double_flash", false):
			pl.append([RESTRIKE_S, RESTRIKE_AMP])
	out["pulses"] = pl
	out["end_s"] = float(pl[pl.size() - 1][0]) + TAIL_S
	return out


## The brightness at `t` seconds after the strike, 0-1 of the peak (pure). A CG flash glows
## faintly while its leader steps down (`leader`), then every pulse is a sharp stroke and its
## continuing current.
static func envelope(pulses: Array, t: float, leader: bool, end_s: float) -> float:
	if t < 0.0 or t >= end_s or pulses.is_empty():
		return 0.0
	var e := 0.0
	var t0: float = pulses[0][0]
	if leader and t < t0:
		e = LEADER_GLOW * t / maxf(t0, 1e-3)
	for p in pulses:
		var dt := t - float(p[0])
		if dt < 0.0:
			continue
		e += float(p[1]) * ((1.0 - CURRENT_SHARE) * exp(-dt / STROKE_TAU_S) + CURRENT_SHARE * exp(-dt / CURRENT_TAU_S))
	# Faded to nothing over the tail's last 0.1 s, so the light goes out without a step.
	e *= clampf((end_s - t) / 0.1, 0.0, 1.0)
	return clampf(e, 0.0, 1.0)


## A strike (ThunderSystem._spawn_strike, on every peer). The newest strike owns the light.
func start(pos: Vector3, seed_value: int, params: Dictionary, base_m: float) -> void:
	var s := build(pos, seed_value, params, base_m)
	seed = seed_value
	is_ic = s["ic"]
	a = s["a"]
	b = s["b"]
	radius = s["radius"]
	peak = s["peak"]
	pulses = s["pulses"]
	end_s = s["end_s"]
	age = 0.0
	active = true
	started += 1


func advance(delta: float) -> void:
	if not active or hold:
		return
	age += delta
	if age >= end_s:
		active = false


func clear() -> void:
	active = false
	hold = false


## Look-dev / the cost probe: hold the current strike at its first stroke's peak.
func hold_peak(on: bool) -> void:
	hold = on
	if on and active and not pulses.is_empty():
		age = float(pulses[0][0])


## 0-1 of the peak now: the world's flash light follows this.
func level() -> float:
	if not active:
		return 0.0
	return envelope(pulses, age, not is_ic, end_s)


## The in-cloud radiance next to the channel now (0 when dark).
func intensity() -> float:
	return peak * level()
