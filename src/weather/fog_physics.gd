class_name FogPhysics
extends RefCounted

## Pure meteorology for fog formation. No nodes, no state, no engine calls —
## every function is a total function of its arguments, so it is testable with
## zero scaffolding and safe to call from any context.
##
## The whole model rests on one idea: fog is not "humidity went up", it is air
## reaching its DEW POINT. Dew point is conserved through temperature changes,
## so a cold night closes the spread on its own and sunrise opens it again.
## That single mechanism replaces the eight-term bias stack this supersedes
## (precip drive, cold bias, dawn window, midday suppression, heat suppression,
## post-rain steam, humidity push, wind suppression).

## Magnus approximation coefficients (over water, -40..50 °C).
const MAGNUS_A := 17.625
const MAGNUS_B := 243.04

## Dew-point depression (T − Td, °C) at which fog potential reaches zero.
## Real fog forms in roughly the last 2 °C of spread.
const SPREAD_FOG_MAX := 2.5

## Dew-point lapse rate (°C per metre of ascent) in a well-mixed sub-cloud layer.
## The AIR temperature lapses at ~0.0065 (TemperatureSystem.LAPSE_RATE_PER_M);
## dew point lapses far more slowly because the mixing ratio is conserved while
## the parcel expands. The DIFFERENCE, ~4.7 °C/km, is what closes the spread with
## height and puts the cloud base at the LCL.
##
## This exists because the spread was previously computed against an
## altitude-INVARIANT dew point while the temperature carried the full
## environmental lapse. The spread then closed at 6.5 °C/km — 38 % too fast —
## and, worse, `spread()` clamps at 0, so above the crossing altitude saturation
## was pinned at 1.0 for every metre of further climb, forever. On la_gomera
## (settled night spread 1.4 °C) that crossing sat at 215 m, i.e. essentially the
## whole island was permanently at its dew point after dark.
const DEW_LAPSE_PER_M := 0.0018
## Environmental AIR lapse rate (°C/m). Must match TemperatureSystem.LAPSE_RATE_PER_M
## — it is duplicated here rather than read from the autoload so FogPhysics stays a
## pure function library with no tree dependency. Used to carry a temperature
## between two altitudes (observer ↔ drainage base).
const AIR_LAPSE_PER_M := 0.0065
## Espy's coefficient: cloud base (metres AGL) ≈ spread × this. It is just the
## algebraic consequence of the two lapse rates above (1 / (0.0065 − 0.0018) ≈
## 213); the classic 125 m/°C assumes a drier surface layer. Derived rather than
## quoted so the three numbers can never disagree.
const LCL_M_PER_DEGC := 1.0 / (AIR_LAPSE_PER_M - DEW_LAPSE_PER_M)


## Carry a temperature from `from_m` to `to_m` down the environmental lapse rate.
static func temp_at(temp_c: float, from_m: float, to_m: float) -> float:
	return temp_c - (to_m - from_m) * AIR_LAPSE_PER_M


## How completely the observer is INSIDE cloud, 0-1. 1 once the local spread has
## closed, i.e. at or above the LCL. Distinct from `saturation()`, which is fog
## POTENTIAL over a 2.5 °C band: this is the much tighter "the air here is
## actually condensing" test, and it is what separates driving through a stratus
## deck from a merely humid evening.
static func in_cloud(spread_c: float) -> float:
	return 1.0 - smoothstep(0.0, 0.3, maxf(spread_c, 0.0))

## Radiation fog: wind thresholds (m/s). Below CALM the surface inversion is
## intact; above MIX mechanical turbulence has destroyed it.
const RAD_WIND_CALM := 1.0
const RAD_WIND_MIX := 3.0

## Advection fog: wind thresholds (m/s). It is SUSTAINED by wind — mechanical
## mixing keeps the cooled layer deep — so calm air starves it and a gale
## disperses it.
const ADV_WIND_MIN := 1.5
const ADV_WIND_PEAK_LO := 4.0
const ADV_WIND_PEAK_HI := 10.0
const ADV_WIND_MAX := 16.0

## Inversion integrator rates, per GAME HOUR.
const INVERSION_BUILD_PER_H := 0.35
const INVERSION_SUN_DECAY_PER_H := 0.9
const INVERSION_MIX_DECAY_PER_H := 0.7


## Dew point (°C) from air temperature and relative humidity (0-1).
## Exactly invertible by rh_from_dew_point — see the round-trip test.
static func dew_point(temp_c: float, rh_01: float) -> float:
	var rh := clampf(rh_01, 0.01, 1.0)
	var gamma: float = (MAGNUS_A * temp_c) / (MAGNUS_B + temp_c) + log(rh)
	return (MAGNUS_B * gamma) / (MAGNUS_A - gamma)


## Relative humidity (0-1) from air temperature and dew point.
## This is the derived direction: dew point is what the sim stores.
static func rh_from_dew_point(temp_c: float, dew_c: float) -> float:
	var g_dew: float = (MAGNUS_A * dew_c) / (MAGNUS_B + dew_c)
	var g_temp: float = (MAGNUS_A * temp_c) / (MAGNUS_B + temp_c)
	return clampf(exp(g_dew - g_temp), 0.0, 1.0)


## Dew-point depression, clamped at 0 (supersaturation is not modelled).
static func spread(temp_c: float, dew_c: float) -> float:
	return maxf(temp_c - dew_c, 0.0)


## The air mass's dew point carried up to `altitude_m`. WeatherFields.dew_point is
## the SEA-LEVEL value of the air mass; every consumer that pairs it with a
## temperature already lapsed to the observer's altitude must lapse it too, or the
## spread closes at the wrong rate. See DEW_LAPSE_PER_M.
static func dew_point_at(dew_sea_c: float, altitude_m: float) -> float:
	return dew_sea_c - altitude_m * DEW_LAPSE_PER_M


## Height of the lifting condensation level above the OBSERVER, in metres, from
## the local temperature and the local dew point. This is the cloud base: below
## it the air is unsaturated, at it the air condenses. Returned unclamped —
## callers decide what an LCL of 3 km means for them.
static func lcl_height_m(temp_c: float, dew_local_c: float) -> float:
	return maxf(temp_c - dew_local_c, 0.0) * LCL_M_PER_DEGC


## Fog potential (0-1) from the spread. 1.0 exactly at saturation.
static func saturation(spread_c: float) -> float:
	return 1.0 - smoothstep(0.0, SPREAD_FOG_MAX, maxf(spread_c, 0.0))


## Radiation fog needs a CLEAR sky (so the surface can radiate heat away) and
## CALM air (so the cold surface layer is not mixed out). Both are hard
## requirements, hence a product rather than a sum: overcast OR windy = none.
##
## Note the sign. The bias stack this replaces raised fog with precip/storm,
## i.e. with CLOUD — backwards. Cloud re-radiates downward and is exactly what
## prevents a radiation fog night.
static func radiation_weight(cloud01: float, wind_ms: float) -> float:
	var clear := 1.0 - clampf(cloud01, 0.0, 1.0)
	var calm := 1.0 - smoothstep(RAD_WIND_CALM, RAD_WIND_MIX, wind_ms)
	return clear * calm


## Advection fog (warm moist air over a colder surface — sea fog is this) is
## the one type wind SUSTAINS. The old _update_sea_fog killed it above 5 m/s,
## which is why sea fog only ever appeared in dead calm.
static func advection_weight(wind_ms: float) -> float:
	var rise := smoothstep(ADV_WIND_MIN, ADV_WIND_PEAK_LO, wind_ms)
	var fall := 1.0 - smoothstep(ADV_WIND_PEAK_HI, ADV_WIND_MAX, wind_ms)
	return rise * fall


## How deep the CAMERA sits inside the fog layer, 0-1. 1 = well inside, 0 = out
## the top. `fade` is the softening band above the ceiling.
##
## The layer has to be gated on the camera, not per-fragment, because Godot's
## own height fog (fog_height / fog_height_density) has NO distance term — it is
## purely `1 - exp(min(0, (y - fog_height) * density))`, so every surface below
## the plane gets the same alpha whether it is 2 m or 200 m away. That renders as
## a flat opaque wash with no depth, which is what it did. Gating the DISTANCE
## fog by camera altitude instead keeps the depth cue and still lets you drive up
## out of the layer.
static func layer_immersion(cam_y: float, layer_top: float, fade: float = 12.0) -> float:
	return 1.0 - smoothstep(layer_top, layer_top + maxf(fade, 0.01), cam_y)


## Nocturnal inversion strength (0-1), integrated per game hour. Builds while
## the surface can radiate (clear + calm + sun down); decays under sun and
## mixing. Drives how THICK the fog layer is, not whether it forms.
static func inversion_step(current: float, delta_h: float, clear01: float,
		calm01: float, sun_up01: float) -> float:
	var build := clear01 * calm01 * (1.0 - sun_up01) * INVERSION_BUILD_PER_H
	var decay := sun_up01 * INVERSION_SUN_DECAY_PER_H \
			+ (1.0 - calm01) * INVERSION_MIX_DECAY_PER_H
	return clampf(current + (build - decay) * delta_h, 0.0, 1.0)
