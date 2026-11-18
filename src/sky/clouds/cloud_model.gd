class_name CloudModel
extends RefCounted
## The cloud layer's state and drift, ticked by WeatherManager on EVERY peer —
## the dedicated server included, so its WeatherSync packets carry a live clock.
## Render-free: CloudBridge reads this and computes no weather of its own.

## The steering level: where the visible cumulus field is advected. Same wind
## profile (speed-up + Ekman veer) the flight model feels at that height.
const STEERING_ALT_M := 1200.0
## A dead-calm field still creeps; frozen clouds read as a paused game.
const MIN_DRIFT_MPS := 1.0

var clock := CloudClock.new()
var state := CloudWeather.CloudState.new()
var manifest: CloudManifest
## Last steering wind (world XZ, m/s), for shear and diagnostics.
var wind := Vector3.ZERO
## The current lightning strike's light in the cloud (#774): started and aged by ThunderSystem on
## every peer from the synced strike, pushed by CloudUniforms.
var flash := CloudFlash.new()
var _primed := false


func _init(m: CloudManifest = null) -> void:
	manifest = m if m != null else CloudManifest.load_default()


func tick(dt: float, f: WeatherFields, hour: float, t_sea_c: float) -> void:
	wind = cloud_steering_wind(f, hour)
	clock.advance(wind, dt)
	var target := CloudWeather.state_from(f, t_sea_c, manifest)
	state = CloudWeather.limit_rate(state, target, dt, manifest) if _primed else target
	_primed = true


## The next tick takes its state as-is, not rate-limited: an MP late join
## (WeatherManager.catch_up_to_remote). One-shot.
func reprime() -> void:
	_primed = false


## Canonical frame (-dy, dx) — the SAME mapping as WeatherManager.get_wind_world_xz,
## rain, snow and the flight model. The dormant 07-27 bridge fed wind_dir straight
## in and drifted clouds 90 deg off everything else.
static func cloud_steering_wind(f: WeatherFields, hour: float) -> Vector3:
	var d := f.wind_dir if f.wind_dir.length_squared() > 1e-6 else Vector2.RIGHT
	d = d.normalized()
	var surf := Vector3(-d.y, 0.0, d.x) * maxf(f.wind_speed, 0.0)
	var v := WindProfile.at_altitude(surf, STEERING_ALT_M)
	var depth := clampf(0.25 + 0.75 * maxf(clampf(f.wind_speed / 14.0, 0.0, 1.0),
			clampf(f.storm_energy, 0.0, 1.0)), 0.0, 1.0)
	var t := hour * 60.0
	var meander := 0.20 * sin(t * 0.11 + 0.4) + 0.10 * sin(t * 0.037)
	v = v.rotated(Vector3.UP, -meander * 0.5 * depth)
	v *= clampf(1.0 + 0.5 * (WeatherTurbulence.turb(t, 0.5) - 0.5) * depth, 0.6, 1.5)
	if v.length() < MIN_DRIFT_MPS:
		v = Vector3(-d.y, 0.0, d.x) * MIN_DRIFT_MPS
	return v
