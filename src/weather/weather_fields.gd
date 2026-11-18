class_name WeatherFields
extends RefCounted

## Continuous weather state fields — the single source of truth for weather.
## Precipitation PHASE (rain/sleet/snow) is derived from temperature, never stored.

## Per-second slew rates (fraction of full range). Visual transitions run in
## real time so high game-time-scale never snaps the sky.
const RATE_CLOUD := 1.0 / 120.0
const RATE_PRECIP := 1.0 / 45.0
const RATE_FOG := 1.0 / 60.0
const RATE_STORM := 1.0 / 30.0
## Dew point slews in °C per second. It represents an AIR MASS changing, which
## is a slower process than cloud or rain — a front brings different air with
## it rather than the same air moistening in place.
const RATE_DEW_POINT := 6.0 / 90.0
const RATE_WIND_SPEED := 0.15      # m/s per second
const RATE_WIND_DIR := 0.2         # rad per second

var cloud_cover: float = 0.0       # 0 = clear sky, 1 = full overcast
var precip: float = 0.0            # 0 = none, 1 = torrential
var fog: float = 0.0               # bias target fed into the fog drift layer
var wind_dir: Vector2 = Vector2.RIGHT
var wind_speed: float = 0.0        # m/s
var storm_energy: float = 0.0      # lightning gate; meaningful at precip > ~0.5
## Dew point (°C) — the CONSERVED moisture field, and the one that is stored,
## synced and saved. It changes only when the air mass changes (fronts), when
## rain moistens the column, or by evaporation. Temperature moves independently,
## so a cold night closes the spread and fogs without anything "deciding" to.
var dew_point: float = 6.0
## Relative humidity 0-1. DERIVED MIRROR, not an input — WeatherSim recomputes it
## every tick from (temperature, dew_point). Written here so the four existing
## consumers keep working unchanged: snow_phase_for_wet_bulb (weather_sim.gd),
## ocean_surface.gd far-field banks, prop_tip_vortex.gd, cloud_weather LCL.
## Assigning it directly has no lasting effect — the next tick overwrites it.
var humidity: float = 0.6


func to_dict() -> Dictionary:
	return {
		"cc": cloud_cover, "pr": precip, "fg": fog,
		"wd": wind_dir, "ws": wind_speed, "se": storm_energy,
		"dp": dew_point,
	}


static func from_dict(d: Dictionary) -> WeatherFields:
	var f := WeatherFields.new()
	f.cloud_cover = clampf(float(d.get("cc", 0.0)), 0.0, 1.0)
	f.precip = clampf(float(d.get("pr", 0.0)), 0.0, 1.0)
	f.fog = clampf(float(d.get("fg", 0.0)), 0.0, 1.0)
	var wd = d.get("wd", Vector2.RIGHT)
	if wd is Vector2 and wd.length_squared() > 0.0001:
		f.wind_dir = (wd as Vector2).normalized()
	f.wind_speed = maxf(float(d.get("ws", 0.0)), 0.0)
	f.storm_energy = clampf(float(d.get("se", 0.0)), 0.0, 1.0)
	# "hu" is the pre-dew-point key. Accepted for one release so an in-flight
	# save or a mid-upgrade peer does not land on 0 °C: convert it back through
	# Magnus at a nominal 15 °C. New writers only ever emit "dp".
	if d.has("dp"):
		f.dew_point = clampf(float(d["dp"]), -60.0, 60.0)
	elif d.has("hu"):
		f.dew_point = FogPhysics.dew_point(15.0, clampf(float(d["hu"]), 0.01, 1.0))
	return f


func copy_from(other: WeatherFields) -> void:
	cloud_cover = other.cloud_cover
	precip = other.precip
	fog = other.fog
	wind_dir = other.wind_dir
	wind_speed = other.wind_speed
	storm_energy = other.storm_energy
	dew_point = other.dew_point
	humidity = other.humidity


## Move every field toward `target` by its rate × speed_scale × delta.
func slew_toward(target: WeatherFields, delta: float, speed_scale: float = 1.0) -> void:
	var s := speed_scale * delta
	cloud_cover = move_toward(cloud_cover, target.cloud_cover, RATE_CLOUD * s)
	precip = move_toward(precip, target.precip, RATE_PRECIP * s)
	fog = move_toward(fog, target.fog, RATE_FOG * s)
	storm_energy = move_toward(storm_energy, target.storm_energy, RATE_STORM * s)
	dew_point = move_toward(dew_point, target.dew_point, RATE_DEW_POINT * s)
	wind_speed = move_toward(wind_speed, target.wind_speed, RATE_WIND_SPEED * s)
	var a := wind_dir.angle()
	var diff := wrapf(target.wind_dir.angle() - a, -PI, PI)
	var step := minf(absf(diff), RATE_WIND_DIR * s) * signf(diff)
	wind_dir = Vector2.from_angle(a + step)
