// THE PHYSICAL ATMOSPHERE, material side.
//
// One atmosphere (Hillaire 2020 LUTs: transmittance, multiple scattering, sky view, an aerial
// perspective volume and a sky-ambient table) lights the sky, the sun, the haze on geometry, and
// whatever else includes this file: the clouds' key light and ambient, the sea. SkyAtmosphere
// (src/sky/atmosphere/sky_atmosphere.gd) bakes the tables on the GPU, only when an input moved, and
// publishes them as GLOBAL shader parameters (project.godot [shader_globals], registered again at
// runtime by AtmosphereGlobals.ensure() should the editor ever drop them).
//
// ===================================== API =====================================================
// Frame: WORLD space, +Y up, sea level at y = 0 (the flat map; the planet's curvature is inside the
// tables). Lengths in METRES. Radiances in SCENE units, the same as the sky's COLOR and as Godot's
// lights: a white Lambertian surface lit by an illuminance E reads E * N.L / PI.
//
//   bool  atm_enabled()                      the switch (SkyAtmosphere.enabled): false = Sky3D's
//                                            old scatter is what the game draws; these functions
//                                            still answer, from whatever was baked last
//   vec3  atm_sun_dir(), atm_moon_dir()      unit, toward the body
//   vec3  atm_transmittance(h_m, mu)         sunlight transmittance from altitude h_m along a ray
//                                            whose zenith cosine is mu, to space (0 under the horizon)
//   vec3  atm_sun_illuminance(h_m)           sunlight arriving at altitude h_m (transmittance x
//                                            the sun's illuminance): the clouds' KEY light
//   vec3  atm_moon_illuminance(h_m)          the same for the moon (its phase included)
//   vec3  atm_night_sky(dir)                 the night sky's own glow toward dir (in atm_sky_radiance's
//                                            callers' hands: the sky shader adds it), the towns' glow
//                                            on the haze included (atm_town)
//   vec3  atm_sky_ambient(h_m)               mean radiance of the sky hemisphere above altitude h_m
//                                            (sun + moon + the night floor): the clouds' AMBIENT.
//                                            A Lambertian upward surface gets ~PI x this.
//   vec3  atm_sky_radiance(dir)              the sky the CAMERA sees along dir, in-scatter only
//                                            (no sun disc, moon, stars or clouds); below the
//                                            horizon, the air in front of the sea
//   float atm_sky_transmittance(dir)         the mean transmittance of that same ray
//   vec4  atm_aerial(dir, dist_m)            aerial perspective from the CAMERA along dir over
//                                            dist_m: rgb = in-scattered radiance, a = mean
//                                            transmittance. Composite: col * a + rgb
//   vec3  atm_apply_aerial(col, dir, dist_m) that composite
//   float atm_phase_rayleigh(c), atm_phase_mie(c, g)  (atmosphere_math.gdshaderinc)
// The camera-relative ones (sky radiance, aerial) are baked for the MAIN camera's altitude; the
// cubemap pass and a mirror sit close enough to it.
// ===============================================================================================

#ifndef ATMOSPHERE_INC
#define ATMOSPHERE_INC

#include "res://src/sky/atmosphere/atmosphere_math.gdshaderinc"

global uniform sampler2D atm_transmittance_lut : filter_linear, repeat_disable;
global uniform sampler2D atm_multiscatter_lut : filter_linear, repeat_disable;
global uniform sampler2D atm_skyview_lut : filter_linear, repeat_disable;
global uniform sampler3D atm_aerial_lut : filter_linear, repeat_disable;
global uniform sampler2D atm_ambient_lut : filter_linear, repeat_disable;
// xyz: toward the sun, w: its illuminance above the atmosphere (scene units).
global uniform vec4 atm_sun;
// xyz: toward the moon, w: its illuminance above the atmosphere, phase included.
global uniform vec4 atm_moon;
// x: the main camera's altitude (m) the view tables were baked for, y: the aerial volume's reach
// (m), z: the planet radius (m), w: the eye adaptation already in atm_sun.w and the view tables
// (SkyAtmosphere.adapt_pow; the moon is not adapted).
global uniform vec4 atm_cam;
// x: haze (Mie density multiplier), y: closed deck 0..1, z: the sky's gain, w: 1 = enabled.
global uniform vec4 atm_medium;
// rgb: the night sky's own light (airglow, starlight, the town's glow on the haze), w: the sun disc's
// radiance per unit of the sun's illuminance.
global uniform vec4 atm_night;
// rgb: the towns' light scattered back by the haze (light pollution), at the horizon, scene units; 0 by day
// (SkyAtmosphere.town_glow: SKYGLOW). w: unused.
global uniform vec4 atm_town;

bool atm_enabled() {
	return atm_medium.w > 0.5;
}

vec3 atm_sun_dir() {
	return atm_sun.xyz;
}

vec3 atm_moon_dir() {
	return atm_moon.xyz;
}

float atm_rg_km() {
	return atm_cam.z * 0.001;
}

vec3 atm_transmittance(float h_m, float mu) {
	float h = max(h_m, 0.0) * 0.001;
	float rg = atm_rg_km();
	float mu_h = atm_horizon_mu(h, rg);
	float vis = smoothstep(mu_h - 0.006, mu_h + 0.006, mu);
	return textureLod(atm_transmittance_lut, atm_trans_uv(h, mu, rg), 0.0).rgb * vis;
}

vec3 atm_sun_illuminance(float h_m) {
	return atm_transmittance(h_m, atm_sun.y) * atm_sun.w;
}

vec3 atm_moon_illuminance(float h_m) {
	return atm_transmittance(h_m, atm_moon.y) * atm_moon.w;
}

// The night sky's own light toward dir (airglow, starlight, the towns' glow on the haze): brighter
// toward the horizon, a longer path through the airglow layer (~13x, as Sky3D's night had).
vec3 atm_night_sky(vec3 dir) {
	float y = clamp(dir.y, 0.0, 1.0);
	// + the towns' glow on the haze, a band low over the horizon (exp(-20 el); a longer exp(-9 el) tail greyed the whole night sky).
	return atm_night.rgb * (0.6 + 7.4 * pow(1.0 - y, 6.0)) + atm_town.rgb * exp(-20.0 * y);
}

vec3 atm_sky_ambient(float h_m) {
	float h = max(h_m, 0.0) * 0.001;
	// The table is baked per the UNADAPTED sun (atm_cam.w is SkyAtmosphere's eye adaptation, already in
	// atm_sun.w); the moon's sky is the same sky, at the moon's (unadapted) illuminance.
	float e0_base = atm_sun.w / max(atm_cam.w, 1e-6);
	vec3 a = textureLod(atm_ambient_lut, atm_ms_uv(h, atm_sun.y), 0.0).rgb * atm_cam.w;
	a += textureLod(atm_ambient_lut, atm_ms_uv(h, atm_moon.y), 0.0).rgb * (atm_moon.w / max(e0_base, 1e-6));
	// + atm_night_sky's mean over the upper hemisphere (y uniform in solid angle: 0.6 + 7.4 / 7, and the
	// towns' glow (1 - e^-20) / 20).
	return a + atm_night.rgb * 1.657 + atm_town.rgb * 0.05;
}

// The sky-view table is two halves side by side (SkyAtmosphere): the sky as baked (left) and the sun's
// single-scattered aerosol light, UNPHASED (right), whose phase is applied here, per pixel: the aureole
// keeps its narrow peak at any table resolution (TODO 45). The right half is black with the aureole off.
vec4 atm_skyview(vec3 dir) {
	vec2 x = atm_dir_unit(dir, atm_cam.x * 0.001, atm_rg_km());
	vec2 uv = atm_unit_to_uv(x, ATM_SKYVIEW_SIZE) * vec2(0.5, 1.0);
	vec4 sv = textureLod(atm_skyview_lut, uv, 0.0);
	vec3 mie = textureLod(atm_skyview_lut, uv + vec2(0.5, 0.0), 0.0).rgb;
	sv.rgb += mie * atm_phase_aureole(dot(dir, atm_sun.xyz));
	return sv;
}

vec3 atm_sky_radiance(vec3 dir) {
	return atm_skyview(dir).rgb;
}

float atm_sky_transmittance(vec3 dir) {
	return atm_skyview(dir).a;
}

vec4 atm_aerial(vec3 dir, float dist_m) {
	float reach = max(atm_cam.y, 1.0);
	float z = sqrt(clamp(dist_m / reach, 0.0, 1.0)) * ATM_AERIAL_SIZE.z;   // slices from the camera
	vec2 x = atm_dir_unit(dir, atm_cam.x * 0.001, atm_rg_km());
	vec2 uv = atm_unit_to_uv(x, ATM_AERIAL_SIZE.xy);
	// Slice k sits at z = k + 1; nearer than the first slice the medium grows from nothing.
	float w = (clamp(z, 1.0, ATM_AERIAL_SIZE.z) - 0.5) / ATM_AERIAL_SIZE.z;
	vec4 ap = textureLod(atm_aerial_lut, vec3(uv, w), 0.0);
	float near = clamp(z, 0.0, 1.0);
	return vec4(ap.rgb * near, mix(1.0, ap.a, near));
}

vec3 atm_apply_aerial(vec3 col, vec3 dir, float dist_m) {
	vec4 ap = atm_aerial(dir, dist_m);
	return col * ap.a + ap.rgb;
}

#endif
