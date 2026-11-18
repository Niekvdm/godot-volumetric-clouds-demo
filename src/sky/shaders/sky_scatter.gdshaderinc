// Sky3D atmosphere: uniforms + scatter, shared by planet_sky (both wrappers)
// and, from Phase 3, the cloud flight pass. MOVED verbatim out of
// planet_sky.gdshader; uniform NAMES are unchanged so SkyDome keeps driving them.
// Needs Common.gdshaderinc (clamp_*, calc_*_phase, calc_simple_optical_depth)
// and planet_atmosphere.gdshaderinc included first.
#ifndef SKY_SCATTER_INC
#define SKY_SCATTER_INC
// The physical atmosphere (R27): sky_ambient_for_clouds answers from it when it is on.
#include "res://src/sky/atmosphere/atmosphere.gdshaderinc"

group_uniforms atmosphere;
uniform float atm_darkness = 0.5;
uniform float atm_sun_intensity = 18.0;
uniform vec4 atm_day_tint: source_color = vec4(0.808, 0.91, 1.0, 1.0);
uniform vec4 atm_horizon_light_tint: source_color = vec4(0.98, 0.635, 0.463, 1.0);
uniform vec4 atm_night_tint: source_color = vec4 (0.041, 0.049, 0.061, 0.245);
uniform vec3 atm_level_params = vec3(1.0, 0.0, 0.0);
uniform float atm_thickness = 0.7;
uniform vec3 atm_beta_ray = vec3(0.00001, 0.00001, 0.00003);
uniform vec3 atm_beta_mie = vec3(0.00000003038); // Value computed by multiplying Mie, turbidity, and 0.000434.

group_uniforms sun_mie;
uniform vec4 atm_sun_mie_tint: source_color = vec4(1.0);
uniform float atm_sun_mie_intensity = 1.0;
uniform vec3 atm_sun_partial_mie_phase = vec3(0.36, 1.64, 1.6);

group_uniforms moon_mie;
uniform vec4 atm_moon_mie_tint: source_color = vec4(0.137, 0.184, 0.292, 1.0);
uniform float atm_moon_mie_intensity = 0.17152;
uniform vec3 atm_moon_partial_mie_phase = vec3(0.36, 1.64, 1.6);

vec3 calc_atmospheric_scatter(float sr, float sm, vec2 mu, vec3 mult) {
	vec3 beta_mie = atm_beta_mie;
	vec3 beta_ray = atm_beta_ray * atm_thickness;

	vec3 extc_factor = clamp_rgb_to_unit(exp(-(beta_ray * sr + beta_mie * sm)));

	float extc_ff = mix(clamp_to_unit(atm_thickness * 0.5), 1.0, mult.x);
	vec3 final_extc_factor = mix(1.0 - extc_factor, (1.0 - extc_factor) * extc_factor, extc_ff);
	float rayleigh_phase = calc_rayleigh_phase(mu.x);
	vec3 BRT = beta_ray * rayleigh_phase;
	vec3 BMT = beta_mie * calc_mie_phase(mu.x, atm_sun_partial_mie_phase);
	BMT *= atm_sun_mie_intensity * atm_sun_mie_tint.rgb;

	vec3 BRMT = (BRT + BMT) / (beta_ray + beta_mie);
	vec3 scatter = atm_sun_intensity * (BRMT * final_extc_factor) * atm_day_tint.rgb * mult.y;
	scatter = mix(scatter, scatter * (1.0 - extc_factor), atm_darkness);

	vec3 lcol =  mix(atm_day_tint.rgb, atm_horizon_light_tint.rgb, mult.x);
	vec3 nscatter = (1.0 - extc_factor) * atm_night_tint.rgb;
	nscatter += calc_mie_phase(mu.y, atm_moon_partial_mie_phase) *
		atm_moon_mie_tint.rgb * atm_moon_mie_intensity * 0.005;

	return (scatter * lcol) + nscatter;
}

// The atmosphere colour for one view direction — the scatter block that used to
// be inline in render_sky, extracted with the SAME operation order so LOW
// renders byte-identically (tools/sky/sky_identity_probe.gd).
struct SkyHaze {
	vec3 scatter;
	vec3 scatter_flat;
	float sr;
	float sm;
	vec2 planet_od;
};

SkyHaze sky_haze(float local_up_raw, vec2 mu, vec3 mult, float cam_alt,
		float planet_blend, float radius, float horizon_off) {
	SkyHaze o;
	calc_simple_optical_depth(local_up_raw + atm_level_params.z - horizon_off,
			o.sr, o.sm, atm_level_params.xy);
	float up = local_up_raw - horizon_off;
	o.planet_od = planet_optical_depth_pair(cam_alt, up, PLANET_OD_STEPS, radius);
	o.scatter_flat = calc_atmospheric_scatter(o.sr, o.sm, mu, mult);
	o.scatter = o.scatter_flat;
	if (planet_blend > 0.0) {
		vec3 sph = calc_atmospheric_scatter(o.planet_od.x, o.planet_od.y, mu, mult);
		o.scatter = mix(o.scatter_flat, sph, planet_blend);
	}
	return o;
}

// Ambient light on the clouds = the sky's OWN scatter (reference design), evaluated
// in-shader so it follows the sky. #773:
//   * The sky hemisphere's MEAN radiance, which is what lights a cloud's skin (its
//     droplets take light from every direction): a 2-point Gauss rule in
//     sin(elevation), nodes 12.2 and 52.1 deg, equal weights, both 90 deg in azimuth
//     from the sun (off the Mie peak). It was 0.6 x the zenith + 0.4 x a sample at
//     2.9 deg: the brightest, most extinct band of the sky (at 17:18 ten times the
//     zenith, and orange) set the ambient's colour.
//   * Without Sky3D's sunset light tint (atm_horizon_light_tint, (1, 0.7, 0.5) by
//     `warmth`), which Sky3D lays over its WHOLE sky as the sun goes down. The real
//     zenith and the sky away from the sun stay blue at sunset (ozone's Chappuis band,
//     which Sky3D does not model), and that blue is what lights a cumulus' shadowed
//     side: with the tint the 17:18 ambient was brown (54, 40, 23 on screen) and the
//     shadowed sides read brown. Noon (warmth ~0.2) moves a little toward blue; night
//     (warmth 0) not at all by this.
// PHYSICAL ATMOSPHERE (R27): with SkyAtmosphere on, the same quantity from the same atmosphere the
// sky is drawn from: the mean radiance of the sky hemisphere at the cloud layer's base (1.5 km),
// sun, moon and the night floor (atmosphere.gdshaderinc, atm_sky_ambient).
const float SKY_AMBIENT_CLOUD_ALT_M = 1500.0;

vec3 sky_ambient_for_clouds(vec3 sun_dir, vec3 moon_dir, vec3 mult, float cam_alt,
		float planet_blend, float radius, float horizon_off) {
	if (atm_enabled()) {
		return atm_sky_ambient(SKY_AMBIENT_CLOUD_ALT_M);
	}
	vec3 side = normalize(cross(vec3(0.0, 1.0, 0.0), sun_dir + vec3(1e-4, 0.0, 0.0)));
	vec3 lo = side * 0.977416 + vec3(0.0, 0.211325, 0.0);   // 12.2 deg: sin = (1 - 1/sqrt(3)) / 2
	vec3 hi = side * 0.614810 + vec3(0.0, 0.788675, 0.0);   // 52.1 deg: sin = (1 + 1/sqrt(3)) / 2
	vec3 a = sky_haze(lo.y, vec2(dot(sun_dir, lo), dot(moon_dir, lo)), mult, cam_alt,
			planet_blend, radius, horizon_off).scatter;
	vec3 b = sky_haze(hi.y, vec2(dot(sun_dir, hi), dot(moon_dir, hi)), mult, cam_alt,
			planet_blend, radius, horizon_off).scatter;
	vec3 untint = atm_day_tint.rgb / max(mix(atm_day_tint.rgb, atm_horizon_light_tint.rgb, mult.x), vec3(1e-3));
	return 0.5 * (a + b) * untint;
}

#endif
