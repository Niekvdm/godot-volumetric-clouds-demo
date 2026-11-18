// THE ATMOSPHERE'S PURE MATH, shared word for word by two compilers:
//   * the material side (atmosphere.gdshaderinc includes this file), Godot's shading language;
//   * the LUT bake (atmosphere_bake_glsl.gd loads this file's text and pastes it into GLSL 450).
// So: no textures, no uniforms, no Godot built-ins except PI (the bake defines it), float literals
// everywhere, nothing either language lacks. Lengths are KILOMETRES, the planet radius `rg` is passed in.
//
// The model is Hillaire 2020 ("A Scalable and Production Ready Sky and Atmosphere Rendering
// Technique"), with two corrections:
// the Mie absorption is 0.444e-3 /km in Hillaire's table (a common misreading is 4.4e-3, ten times
// too much: a sooty haze) and ours is maritime (sea-salt aerosol scatters ~95 % of what it meets);
// and the haze is a multiplier on the Mie density, driven by the weather.

#ifndef ATMOSPHERE_MATH_INC
#define ATMOSPHERE_MATH_INC

const float ATM_TOP_KM = 100.0;
const float ATM_RAYLEIGH_H_KM = 8.0;
const float ATM_MIE_H_KM = 1.2;
// Per km at sea level.
const vec3 ATM_RAYLEIGH_S = vec3(5.802e-3, 13.558e-3, 33.1e-3);
const float ATM_MIE_S = 3.996e-3;
const float ATM_MIE_A = 0.21e-3;
// Ozone (Chappuis band): Hillaire's red 0.650e-3 is 0.35x the green; with it the blue hour went lilac
// (green absorbed, red and blue left). Chappuis cross-sections put 680 nm at ~0.5-0.6x of 550 nm: 1.05e-3.
const vec3 ATM_OZONE_A = vec3(1.050e-3, 1.881e-3, 0.085e-3);
// Sea-salt aerosol is coarse, so more forward than Hillaire's 0.8: at 0.8 a 7 deg sun's glow spread a
// white blob over a quarter of the sky; 0.85 keeps it round the sun (tools/sky/atmosphere_shot runs).
const float ATM_MIE_G = 0.85;
// What the ground under the air sends back up (multi-scatter LUT): Hachijo is mostly sea.
const float ATM_GROUND_ALBEDO = 0.1;
// Under a closed deck: what share of the direct sun still reaches the air below the cloud tops.
const float ATM_DECK_SUN = 0.08;
const float ATM_DECK_TOP_KM = 3.5;

// x = Rayleigh, y = Mie, z = ozone (a tent around 25 km).
vec3 atm_density(float h_km) {
	float hh = max(h_km, 0.0);
	return vec3(exp(-hh / ATM_RAYLEIGH_H_KM), exp(-hh / ATM_MIE_H_KM),
			max(0.0, 1.0 - abs(hh - 25.0) / 15.0));
}

vec3 atm_extinction(vec3 d, float haze) {
	return ATM_RAYLEIGH_S * d.x + vec3((ATM_MIE_S + ATM_MIE_A) * haze * d.y) + ATM_OZONE_A * d.z;
}

float atm_phase_rayleigh(float c) {
	return 3.0 / (16.0 * PI) * (1.0 + c * c);
}

// Cornette-Shanks.
float atm_phase_mie(float c, float g) {
	float g2 = g * g;
	return 3.0 / (8.0 * PI) * (1.0 - g2) * (1.0 + c * c)
			/ ((2.0 + g2) * pow(max(1.0 + g2 - 2.0 * g * c, 1e-6), 1.5));
}

float atm_phase_hg(float c, float g) {
	float g2 = g * g;
	return (1.0 - g2) / (4.0 * PI * pow(max(1.0 + g2 - 2.0 * g * c, 1e-6), 1.5));
}

// THE AUREOLE (TODO 45): the sun's single-scattered aerosol light,
// its phase evaluated PER PIXEL by the sky (the sky-view table keeps that light apart, unphased:
// atm_skyview). One Cornette-Shanks lobe (g 0.76-0.85, Bruneton / Hillaire) spreads a real aerosol's
// forward light too wide: the sky 10-30 deg off a low sun came out nearly as bright as 3 deg off it, a
// white blob ~25 deg across once exposed (g 0.8 per pixel: the widest of all, sky-only shots). A sea-salt
// aerosol has a narrow diffraction peak on a broad lobe; two terms reproduce that at a measured maritime
// asymmetry (mean cosine w g_peak + (1 - w) 3g(4 + g^2) / (5(2 + g^2)) = 0.79; measured 0.75-0.8).
// The baked tables (aerial volume, ambient, moon) take atm_phase_aureole_baked.
const float ATM_AUREOLE_W = 0.4;
const float ATM_AUREOLE_G_PEAK = 0.97;
const float ATM_AUREOLE_G_BROAD = 0.6;

// The baked tables' version: the peak widened to what their texels carry (half width ~7 deg against
// the aerial volume's 5.6 deg columns; the per-pixel peak's 1.3 deg would pulse as the sun crossed
// texel centres). Mean cosine 0.74.
const float ATM_AUREOLE_G_PEAK_BAKED = 0.85;

float atm_phase_aureole(float c) {
	return ATM_AUREOLE_W * atm_phase_hg(c, ATM_AUREOLE_G_PEAK)
			+ (1.0 - ATM_AUREOLE_W) * atm_phase_mie(c, ATM_AUREOLE_G_BROAD);
}

float atm_phase_aureole_baked(float c) {
	return ATM_AUREOLE_W * atm_phase_hg(c, ATM_AUREOLE_G_PEAK_BAKED)
			+ (1.0 - ATM_AUREOLE_W) * atm_phase_mie(c, ATM_AUREOLE_G_BROAD);
}

// Numerically careful ray/sphere (oc = origin - centre, rd unit). (-1, -1) on a miss.
vec2 atm_ray_sphere(vec3 oc, vec3 rd, float radius) {
	float b = dot(oc, rd);
	float dp = length(oc - rd * b);
	if (dp > radius) {
		return vec2(-1.0);
	}
	float s = sqrt((radius - dp) * (radius + dp));
	return vec2(-b - s, -b + s);
}

// Cosine of the zenith angle of the geometric horizon seen from altitude h (negative above 0 m).
float atm_horizon_mu(float h_km, float rg) {
	float hc = max(h_km, 0.0);
	return -sqrt(hc * (2.0 * rg + hc)) / (rg + hc);
}

// ---- transmittance LUT (256 x 64, Bruneton's parametrisation) --------------------------------------
const vec2 ATM_TRANS_SIZE = vec2(256.0, 64.0);

vec2 atm_trans_uv(float h_km, float mu, float rg) {
	float h = clamp(h_km, 0.0, ATM_TOP_KM);
	float rt = rg + ATM_TOP_KM;
	float hh = sqrt(ATM_TOP_KM * (2.0 * rg + ATM_TOP_KM));
	float rho = sqrt(h * (2.0 * rg + h));
	float r = rg + h;
	float disc = rt * rt - r * r * (1.0 - mu * mu);
	float d = max(0.0, -r * mu + sqrt(max(disc, 0.0)));
	float dmin = ATM_TOP_KM - h;
	float dmax = rho + hh;
	vec2 x = vec2(clamp((d - dmin) / max(dmax - dmin, 1e-4), 0.0, 1.0), rho / hh);
	return x * (ATM_TRANS_SIZE - 1.0) / ATM_TRANS_SIZE + 0.5 / ATM_TRANS_SIZE;
}

// The inverse, for the bake: texel uv -> (altitude km, mu).
vec2 atm_trans_from_uv(vec2 uv, float rg) {
	vec2 x = clamp((uv - 0.5 / ATM_TRANS_SIZE) * ATM_TRANS_SIZE / (ATM_TRANS_SIZE - 1.0), 0.0, 1.0);
	float hh = sqrt(ATM_TOP_KM * (2.0 * rg + ATM_TOP_KM));
	float rho = hh * x.y;
	float r = sqrt(rho * rho + rg * rg);
	float h = rho * rho / (r + rg);
	float dmin = ATM_TOP_KM - h;
	float dmax = rho + hh;
	float d = dmin + x.x * (dmax - dmin);
	float mu = 1.0;
	if (d > 0.0) {
		mu = clamp((hh * hh - rho * rho - d * d) / (2.0 * r * d), -1.0, 1.0);
	}
	return vec2(h, mu);
}

// ---- multi-scatter (32 x 32) and ambient (32 x 32) LUTs: (sun zenith cosine, altitude) --------------
const float ATM_MS_SIZE = 32.0;

vec2 atm_ms_uv(float h_km, float mu_s) {
	vec2 x = vec2(mu_s * 0.5 + 0.5, clamp(h_km / ATM_TOP_KM, 0.0, 1.0));
	return x * (ATM_MS_SIZE - 1.0) / ATM_MS_SIZE + 0.5 / ATM_MS_SIZE;
}

vec2 atm_ms_from_uv(vec2 uv) {
	vec2 x = clamp((uv - 0.5 / ATM_MS_SIZE) * ATM_MS_SIZE / (ATM_MS_SIZE - 1.0), 0.0, 1.0);
	return vec2(x.y * ATM_TOP_KM, x.x * 2.0 - 1.0);   // (h km, mu_s)
}

// ---- view-direction LUTs: sky view (256 x 128) and the aerial-perspective volume (64 x 32 x 32) ------
// u: the WORLD azimuth, the first and the last column both at -PI / +PI (sampled clamped: no seam);
// v: Hillaire's horizon-aware elevation (0 zenith, 0.5 the true horizon at this altitude, 1 nadir),
//    square-root packed toward the horizon, where the sky changes fastest.
// World frame: +Y up, azimuth = atan(z, x).
vec2 atm_dir_unit(vec3 dir, float h_km, float rg) {
	float hc = max(h_km, 0.0);
	float r = rg + hc;
	float vh = sqrt(hc * (2.0 * rg + hc));
	float beta = acos(clamp(vh / r, -1.0, 1.0));
	float zh = PI - beta;
	float vza = acos(clamp(dir.y, -1.0, 1.0));
	float v;
	if (vza < zh) {
		v = (1.0 - sqrt(max(1.0 - vza / zh, 0.0))) * 0.5;
	} else {
		v = sqrt(clamp((vza - zh) / max(beta, 1e-6), 0.0, 1.0)) * 0.5 + 0.5;
	}
	float u = atan(dir.z, dir.x) / (2.0 * PI) + 0.5;
	return vec2(u, v);
}

vec3 atm_dir_from_unit(vec2 x, float h_km, float rg) {
	float hc = max(h_km, 0.0);
	float r = rg + hc;
	float vh = sqrt(hc * (2.0 * rg + hc));
	float beta = acos(clamp(vh / r, -1.0, 1.0));
	float zh = PI - beta;
	float vza;
	if (x.y < 0.5) {
		float c = 1.0 - x.y * 2.0;
		vza = zh * (1.0 - c * c);
	} else {
		float c = x.y * 2.0 - 1.0;
		vza = zh + beta * c * c;
	}
	float az = (x.x - 0.5) * 2.0 * PI;
	float s = sin(vza);
	return vec3(s * cos(az), cos(vza), s * sin(az));
}

// Unit coordinates -> texel-centred uv for a size: u spans first..last column, v first..last row.
vec2 atm_unit_to_uv(vec2 x, vec2 size) {
	return (x * (size - 1.0) + 0.5) / size;
}

vec2 atm_uv_to_unit(vec2 uv, vec2 size) {
	return clamp((uv * size - 0.5) / (size - 1.0), 0.0, 1.0);
}

const vec2 ATM_SKYVIEW_SIZE = vec2(256.0, 128.0);
const vec3 ATM_AERIAL_SIZE = vec3(64.0, 32.0, 32.0);

// Aerial slices: slice k (0..N-1) holds the medium from the camera out to D * ((k + 1) / N)^2.
float atm_aerial_slice_dist(float k, float max_dist_km) {
	float w = (k + 1.0) / ATM_AERIAL_SIZE.z;
	return max_dist_km * w * w;
}

// Closed deck (0 = sky open, 1 = closed overcast): the sun's share of a sample at altitude h, seen
// by an eye at altitude eye_h. An eye UNDER the deck sees only air under it (what it sees past the
// deck's far edge, 200 km off and above it, is the deck's underside in reality, not a sunlit aureole);
// an eye above it sees sunlit air down to the deck's top.
float atm_deck_below(float h_km, float eye_h_km) {
	float hh = min(h_km, max(eye_h_km, 0.0));
	return 1.0 - smoothstep(ATM_DECK_TOP_KM - 1.0, ATM_DECK_TOP_KM, hh);
}

float atm_deck_sun(float h_km, float closed, float eye_h_km) {
	return 1.0 - closed * atm_deck_below(h_km, eye_h_km) * (1.0 - ATM_DECK_SUN);
}

// ...and the multiple-scattered light under it: greyed and dimmed.
vec3 atm_deck_ms(vec3 ms, float h_km, float closed, float eye_h_km) {
	float c = closed * atm_deck_below(h_km, eye_h_km);
	float l = dot(ms, vec3(0.2126, 0.7152, 0.0722));
	return mix(ms, vec3(l), c * 0.75) * (1.0 - 0.45 * c);
}

#endif
