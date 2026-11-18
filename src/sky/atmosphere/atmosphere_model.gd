class_name AtmosphereModel
extends RefCounted
## The atmosphere on the CPU: only what the sun's DirectionalLight needs (the transmittance along
## the sun's ray, a few times a second at most). LOCKSTEP with atmosphere_math.gdshaderinc: the same
## constants and the same density profile (test_atmosphere_model checks the numbers).

const TOP_KM := 100.0
const RAYLEIGH_H_KM := 8.0
const MIE_H_KM := 1.2
const RAYLEIGH_S := Vector3(5.802e-3, 13.558e-3, 33.1e-3)
const MIE_S := 3.996e-3
const MIE_A := 0.21e-3
const OZONE_A := Vector3(1.050e-3, 1.881e-3, 0.085e-3)
const EARTH_RADIUS_KM := 6371.0
const STEPS := 48


static func density(h_km: float) -> Vector3:
	var hh := maxf(h_km, 0.0)
	return Vector3(exp(-hh / RAYLEIGH_H_KM), exp(-hh / MIE_H_KM), maxf(0.0, 1.0 - absf(hh - 25.0) / 15.0))


static func extinction(d: Vector3, haze: float) -> Vector3:
	return RAYLEIGH_S * d.x + Vector3.ONE * ((MIE_S + MIE_A) * haze * d.y) + OZONE_A * d.z


## Cosine of the zenith angle of the geometric horizon from altitude h (negative above sea level).
static func horizon_mu(h_km: float, rg := EARTH_RADIUS_KM) -> float:
	var hc := maxf(h_km, 0.0)
	return -sqrt(hc * (2.0 * rg + hc)) / (rg + hc)


## Transmittance from altitude h_km along a ray of zenith cosine mu, out to space; faded to 0 across
## the horizon exactly as the shader's atm_transmittance (a 0.006 band of mu).
static func transmittance(h_km: float, mu: float, haze: float, rg := EARTH_RADIUS_KM) -> Vector3:
	var hc := clampf(h_km, 0.0, TOP_KM)
	var mu_h := horizon_mu(hc, rg)
	var vis := smoothstep(mu_h - 0.006, mu_h + 0.006, mu)
	if vis <= 0.0:
		return Vector3.ZERO
	# The ray as it would run without the ground (the LUT stores that, then fades it by vis).
	var mu_c := maxf(mu, mu_h)
	var r := rg + hc
	var rt := rg + TOP_KM
	var disc := rt * rt - r * r * (1.0 - mu_c * mu_c)
	var d := maxf(0.0, -r * mu_c + sqrt(maxf(disc, 0.0)))
	var od := Vector3.ZERO
	var st := sqrt(maxf(1.0 - mu_c * mu_c, 0.0))
	for i in STEPS:
		var t := d * (float(i) + 0.5) / float(STEPS)
		# Altitude at t along the ray, without cancellation: |(st t, r + mu t)| - rg.
		var x := st * t
		var y := r + mu_c * t
		var hp := (x * x + y * y - rg * rg) / (sqrt(x * x + y * y) + rg)
		od += extinction(density(hp), haze) * (d / float(STEPS))
	return Vector3(exp(-od.x), exp(-od.y), exp(-od.z)) * vis


## atmosphere_math's atm_phase_aureole (the sky's per-pixel aerosol phase, TODO 45).
const AUREOLE_W := 0.4
const AUREOLE_G_PEAK := 0.97
const AUREOLE_G_BROAD := 0.6


static func phase_hg(c: float, g: float) -> float:
	return (1.0 - g * g) / (4.0 * PI * pow(maxf(1.0 + g * g - 2.0 * g * c, 1e-6), 1.5))


static func phase_cs(c: float, g: float) -> float:
	var g2 := g * g
	return 3.0 / (8.0 * PI) * (1.0 - g2) * (1.0 + c * c) / ((2.0 + g2) * pow(maxf(1.0 + g2 - 2.0 * g * c, 1e-6), 1.5))


static func phase_aureole(c: float) -> float:
	return AUREOLE_W * phase_hg(c, AUREOLE_G_PEAK) + (1.0 - AUREOLE_W) * phase_cs(c, AUREOLE_G_BROAD)


static func luminance(v: Vector3) -> float:
	return 0.2126 * v.x + 0.7152 * v.y + 0.0722 * v.z


## The view tables' (u, v) for a direction from altitude h: atm_dir_unit in atmosphere_math.
static func dir_unit(dir: Vector3, h_km: float, rg := EARTH_RADIUS_KM) -> Vector2:
	var hc := maxf(h_km, 0.0)
	var r := rg + hc
	var vh := sqrt(hc * (2.0 * rg + hc))
	var beta := acos(clampf(vh / r, -1.0, 1.0))
	var zh := PI - beta
	var vza := acos(clampf(dir.y, -1.0, 1.0))
	var v: float
	if vza < zh:
		v = (1.0 - sqrt(maxf(1.0 - vza / zh, 0.0))) * 0.5
	else:
		v = sqrt(clampf((vza - zh) / maxf(beta, 1e-6), 0.0, 1.0)) * 0.5 + 0.5
	return Vector2(atan2(dir.z, dir.x) / TAU + 0.5, v)
