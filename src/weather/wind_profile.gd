class_name WindProfile
extends RefCounted

## Atmospheric boundary-layer wind profile: how the shared weather wind changes
## with height. WeatherManager publishes the standard METEOROLOGICAL wind — the
## 10 m reference — which is NOT what an airframe sees at wing height or at
## cruise. Without this the flight model got the same vector on the deck as at
## 3 km, so a parked aeroplane read the full free-stream on its ASI.
##
## Three effects, all pure functions of height so they stay unit-testable and
## identical on every peer (no state, no RNG → MP-deterministic):
##
##  1. SPEED — power law up to the gradient height, gentle free-atmosphere growth
##     above it. Surface friction slows the air near the ground; aloft it
##     approaches the geostrophic wind and keeps strengthening toward the jet.
##  2. VEER — the Ekman spiral. In the northern hemisphere the wind turns
##     CLOCKWISE with height as friction releases, ~17° by the gradient level.
##  3. TURBULENCE TAPER — mechanical (shear-driven) chop lives in the boundary
##     layer and dies out above the mixed layer. Convective/storm chop does NOT
##     taper (that is handled by the caller) — a cumulus is rough at altitude.
##
## `altitude_m` is world Y (height above sea level). Over the ocean — the case
## this was written for — that is exactly height above the surface. Over terrain
## it reads as height above sea level, which is a deliberate simplification:
## elevated ground genuinely sits higher in the boundary layer and is windier.

## Height the published weather wind refers to (m). The WMO standard anemometer.
const REF_HEIGHT := 10.0
## Lowest height the profile is evaluated at (m) — roughly wing/float height, so
## a parked aeroplane samples the air its wings are actually in rather than a
## degenerate z→0 (the power law goes to zero at the ground).
const MIN_HEIGHT := 1.5
## Power-law exponent. 0.11 open water, 0.15 open country — 0.13 is the coastal
## mix this map (Hachijojima) sits in.
const SHEAR_EXPONENT := 0.13
## Gradient height (m): top of the surface layer, where friction has released
## and the power law stops.
const GRADIENT_HEIGHT := 400.0
## Free-atmosphere strengthening above the gradient height, per 1000 m. A 15 kt
## surface wind running ~35 kt at 10 000 ft is an ordinary sounding.
const ALOFT_GAIN_PER_KM := 0.30
## Ceiling on the total speed factor, so a storm-force surface wind cannot
## compound into something absurd at altitude.
const MAX_FACTOR := 2.5
## Ekman veer at the gradient height (rad, clockwise). Matches WeatherManager's
## ALOFT_VEER so the flight model and the visible cloud drift agree.
const VEER_MAX := 0.30
## Mechanical turbulence fades out across this band (m) — boundary-layer chop is
## gone by the time you are above the mixed layer.
const TURB_FADE_LO := 300.0
const TURB_FADE_HI := 900.0


## Speed multiplier on the 10 m reference wind at `altitude_m`.
static func speed_factor(altitude_m: float) -> float:
	var z := maxf(altitude_m, MIN_HEIGHT)
	if z <= GRADIENT_HEIGHT:
		return pow(z / REF_HEIGHT, SHEAR_EXPONENT)
	var at_gradient := pow(GRADIENT_HEIGHT / REF_HEIGHT, SHEAR_EXPONENT)
	var above_km := (z - GRADIENT_HEIGHT) * 0.001
	return minf(at_gradient + ALOFT_GAIN_PER_KM * above_km, MAX_FACTOR)


## Clockwise veer (rad) of the wind at `altitude_m` relative to the surface wind.
## Ekman turning is fastest low down, so the ramp is sqrt-shaped, not linear.
static func veer(altitude_m: float) -> float:
	var z := maxf(altitude_m, 0.0)
	return VEER_MAX * sqrt(clampf(z / GRADIENT_HEIGHT, 0.0, 1.0))


## Apply speed shear + veer to a surface wind vector in the canonical world-XZ
## frame (WeatherManager.get_wind_world_xz). Rotating about +Y by NEGATIVE veer
## is the clockwise-from-above sense the weather system uses for its aloft wind.
static func at_altitude(surface_wind: Vector3, altitude_m: float) -> Vector3:
	if surface_wind.length_squared() < 1e-12:
		return surface_wind
	return (surface_wind * speed_factor(altitude_m)).rotated(Vector3.UP, -veer(altitude_m))


## Multiplier on MECHANICAL (wind-shear) turbulence intensity at `altitude_m`:
## 1 in the boundary layer, 0 in the smooth free atmosphere above it.
static func turbulence_factor(altitude_m: float) -> float:
	return 1.0 - smoothstep(TURB_FADE_LO, TURB_FADE_HI, maxf(altitude_m, 0.0))
