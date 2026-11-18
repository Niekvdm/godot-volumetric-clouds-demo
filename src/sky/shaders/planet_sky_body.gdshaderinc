// PROJECT-OWNED DERIVATIVE of addons/sky_3d/shaders/SkyMaterial.gdshader.
// Two localised changes, both no-ops at sea level:
//   1. the flat below-horizon `ground_color` cut becomes a real ray-sphere
//      intersection against the planet, shaded as open sea;
//   2. an additive limb term for the bright rim seen from altitude.
// Every original uniform NAME is preserved, so SkyDome.gd keeps driving this
// shader unchanged. When updating Sky3D, re-copy the addon file and re-apply
// these edits -- search for "PLANET:" to find them.
#include "res://src/sky/shaders/planet_atmosphere.gdshaderinc"
#include "res://src/sky/shaders/planet_earth.gdshaderinc"
#include "res://src/sky/shaders/twilight.gdshaderinc"
// THE PHYSICAL ATMOSPHERE (R27, src/sky/atmosphere/): with SkyAtmosphere.enabled the sky is the
// sky-view table plus the discs and the stars, and Sky3D's scatter below is not evaluated at all.
// Off (the editor, or the switch), every line below draws exactly what it drew before.
#include "res://src/sky/atmosphere/atmosphere.gdshaderinc"
// Touched by SkyAtmosphere whenever it re-bakes the view tables: the tables are globals, which never
// mark the sky dirty, and only a material write makes Godot redraw the reflection map.
uniform float atm_epoch = 0.0;

group_uniforms planet;
// Camera altitude in metres above sea level, pushed by PlanetHorizon each
// frame. At 0.0 every term below collapses and output matches stock Sky3D.
uniform float cam_altitude = 0.0;
uniform float planet_radius = 6371000.0;
uniform bool planet_enabled = true;
uniform vec4 sea_color_deep : source_color = vec4(0.015, 0.055, 0.09, 1.0);
uniform float sea_glitter_sharpness : hint_range(1.0, 512.0) = 96.0;
uniform float sea_glitter_intensity : hint_range(0.0, 8.0) = 1.6;

// PLANET/EARTH: pushed by PlanetHorizon. cam_ecef is the camera on the globe,
// enu_basis rotates a local (east, north, up) vector into ECEF. Together they
// place any view ray on the Earth in one line, with no flat-earth
// approximation and no far plane -- the far field is not geometry.
uniform bool earth_enabled = false;
uniform vec3 earth_cam_ecef = vec3(0.0);
uniform mat3 earth_enu_basis = mat3(1.0);
uniform sampler2D earth_global_tex : source_color, filter_linear_mipmap;

// PLANET/FRAME: ECEF -> the observer's local Y-up frame, i.e. mat3(north, up,
// east) at the camera's CURRENT ECEF position -- see
// PlanetGeometry.sky_basis_from_up(). Pushed once a frame by whatever drives
// this material on a true sphere (the flat map never pushes this and stays
// at the identity default).
//
// Sky3D's stock maths -- the flat-earth optical depth, the horizon cut, the
// ground/sea hit test -- all read world_pos.y directly as "elevation above
// MY horizon". A flat world has exactly one zenith direction, globally, so
// that was always true there. On a sphere "up" is a different ECEF direction
// at every point, so the ONE place that assumption needs correcting is
// wherever this shader reads world_pos.y for exactly that purpose -- see
// `local_up` in render_sky().
//
// Identity is an EXACT no-op: transpose(mat3(1.0)) * world_pos == world_pos,
// so local_up reduces to world_pos.y and every line below matches today's
// flat-world output bit for bit.
//
// world_pos, clouds_pos, sun_pos and moon_pos are DELIBERATELY NOT rotated by
// this. The star map, star field and sun/moon discs are already correct
// without it: they are effectively at infinite distance (the whole reason
// the sun stays painted rather than becoming geometry -- see the design
// doc), so EYEDIR alone already carries the right answer for them regardless
// of where the camera sits on the globe, exactly the way a fixed-attitude
// spacecraft window shows the same stars all the way around an orbit.
// Reprojecting them through the observer's LOCAL frame would glue the star
// field to the observer's personal horizon instead -- it would appear to
// drag around with camera POSITION alone, holding orientation fixed, which is
// precisely the failure the quarter-orbit acceptance test exists to catch.
uniform mat3 sky_frame_basis = mat3(1.0);

// PLANET/CELESTIAL: 0.0 at and below 100 km (painted discs only,
// bit-identical to today), 1.0 at and above 1000 km (real sun/moon geometry
// draws instead -- see src/sky/planet/celestial_bodies.gd). Pushed each
// frame from PlanetGeometry.celestial_geometry_fade(alt), the SAME function
// that gates the real geometry's own visibility, so the two handovers are
// complementary by construction and the body cannot render twice. At the
// default 0.0 this multiplies the sun disk / moon disk by 1.0 -- a no-op.
uniform float celestial_geometry_fade : hint_range(0.0, 1.0) = 0.0;

// PLANET: altitude band over which BOTH cloud layers retire, in metres.
//
// Two reasons, one honest and one pragmatic. Honest: the procedural decks are a
// LOCAL weather model -- a 1.5 km cumulus shell and a 10 km cirrus shell around
// the camera -- and from 100 km they are being asked to stand in for a
// planetary cloud field they were never built to represent. Pragmatic: the
// spherical cumulus currently renders as fine speckle (its march step is tiny
// against the noise-space position scale) and that speckle completely drowns
// the painted Earth.
//
// This MASKS that bug rather than fixing it. When the march is fixed, raising
// cloud_fade_end is how you get the decks back.
uniform float cloud_fade_start = 10000.0;
uniform float cloud_fade_end = 25000.0;

group_uniforms general;
uniform bool sky_visible = true;
uniform vec2 color_correction = vec2(0.0, 1.0);
uniform vec4 ground_color: source_color = vec4(0.3, 0.3, 0.3, 1.0);
uniform float horizon_offset = 0.0;
// The weather colour filter (WeatherLook): on the sky, its stars and every cloud
// it composites, after the photo tonemap. Identity when clear.
#include "res://src/weather/shaders/weather_grade_material.gdshaderinc"

group_uniforms sun_disk;
uniform vec4 sun_light_color: source_color = vec4(1.0);
uniform vec4 sun_disk_color: source_color = vec4(0.996, 0.541, 0.14, 1.0);
uniform float sun_disk_intensity = 2.0;
uniform float sun_disk_size = 0.015;

group_uniforms moon;
uniform vec4 moon_color: source_color = vec4(1.0);
uniform sampler2D moon_texture: source_color, repeat_disable;
uniform vec3 moon_texture_alignment = vec3(7.0, 1.4, 4.8);
uniform bool moon_texture_flip_u;
uniform bool moon_texture_flip_v;
uniform float moon_size = 0.07;

group_uniforms star_map;
uniform vec4 starmap_color: source_color = vec4(0.71, 0.71, 0.71, 0.855);
uniform sampler2D starmap_texture: source_color;
uniform bool starmap_flip_u = false;
uniform bool starmap_flip_v = false;
uniform vec3 starmap_alignment = vec3(2.68288, -0.25891, 0.40101);
uniform float star_rotation_offset = 9.38899;
uniform float star_rotation = 0.0; // For simulating Earth rotation.
uniform float star_tilt = 0.0; // For tilting the sky according to observer latitude in radians. (90° - latitude)

group_uniforms star_field;
uniform vec4 star_field_color: source_color = vec4(1.0);
uniform sampler2D star_field_texture: source_color;
uniform float star_scintillation = 0.75;
uniform float star_scintillation_speed = 0.01;
uniform sampler2D noise_tex: source_color;
// THE QUIET SKY (2026-11-15): the star twinkle's clock. It was
// TIME, and ANY use of TIME makes Godot re-render and re-filter the reflection map every frame
// (sky.cpp: uses_time). A buffer global never marks a material dirty, so the on-screen stars twinkle
// while the reflection map keeps whatever phase it was last drawn with (a reflected star field is
// never seen twinkle). Written every frame by PlanetHorizon; 0 in the editor (no twinkle there).
global uniform float sky_time;

/* Sky alignment values for a star map that is in galactic coordinates. Works for most star maps.
X: 2.6555
Y: -0.23935
Z: 0.4505

These alignment values are consistent with a sky view from the North Pole (latitude zero)
at midnight. The positions of Polaris, Vega, Rigel, and Alpha Centauri confirmed
through various sources and calculations.
*/

group_uniforms clouds;
uniform vec4 clouds_night_color: source_color = vec4(0.09, 0.094, 0.129, 1.0);

group_uniforms cirrus_clouds;
uniform bool cirrus_visible = true;
uniform float cirrus_intensity = 2.0;
uniform float cirrus_coverage = 0.5;
uniform float cirrus_thickness = 10.0;
uniform float cirrus_absorption = 2.0;
uniform float cirrus_sky_tint_fade = 0.5;
uniform float cirrus_size = 1.0;
uniform vec2 cirrus_uv = vec2(0.16, 0.11);
uniform vec2 cirrus_position1 = vec2(0.0);
uniform vec2 cirrus_position2 = vec2(0.0);
uniform sampler2D cirrus_texture;

group_uniforms cumulus_clouds;
uniform bool cumulus_visible = true;
uniform float cumulus_intensity = 0.6;
uniform float cumulus_coverage = 0.55;
uniform float cumulus_thickness = 0.0243;
uniform float cumulus_absorption = 2.0;
uniform float cumulus_noise_freq = 2.7;
uniform float cumulus_sky_tint_fade = 0.0;
uniform float cumulus_size = 0.5;
uniform vec2 cumulus_position = vec2(0.0);
uniform sampler2D cumulus_texture;
uniform vec3 cumulus_partial_mie_phase = vec3(0.95756, 1.04244, 0.412);
uniform float cumulus_mie_intensity = 1.0;

group_uniforms overlays;
uniform bool show_azimuthal_grid = false;
uniform vec4 azimuthal_grid_color : source_color = vec4(.871, .722, .529, 1.);
uniform float azimuthal_grid_rotation_offset = 0.03;
uniform bool show_equatorial_grid = false;
uniform vec4 equatorial_grid_color : source_color = vec4(0., .75, 1., 1.);
uniform float equatorial_grid_rotation_offset = 0.03;

group_uniforms transform_matrices;
uniform mat3 moon_matrix; // Calculated externally via GDScript.

// PLANET: absolute path. The addon includes this RELATIVELY, which resolves
// against the shader's own directory -- and this copy does not live beside
// Common.gdshaderinc. A failing include makes the preprocessor bail on the
// whole file, reported as a bogus "Unknown character '#'" at the FIRST
// directive. Keep this absolute when re-forking.
#include "res://addons/sky_3d/shaders/Common.gdshaderinc"
#include "res://src/sky/shaders/sky_scatter.gdshaderinc"
#ifdef CLOUDS_VOLUMETRIC
#include "res://src/sky/clouds/shaders/cloud_params.gdshaderinc"
#include "res://src/sky/clouds/shaders/cloud_field.gdshaderinc"
#include "res://src/sky/clouds/shaders/cloud_light.gdshaderinc"
#include "res://src/sky/clouds/shaders/cloud_march.gdshaderinc"
#endif

// Provides a transformation matrix when passed a vec3.
mat3 create_rotation_matrix(vec3 r) {
	float c1 = cos(r.x), s1 = sin(r.x);
	float c2 = cos(r.y), s2 = sin(r.y);
	float c3 = cos(r.z), s3 = sin(r.z);

	mat3 rotX = mat3(
		vec3(1.0, 0.0, 0.0),
		vec3(0.0, c1, -s1),
		vec3(0.0, s1, c1)
	);

	mat3 rotY = mat3(
		vec3(c2, 0.0, s2),
		vec3(0.0, 1.0, 0.0),
		vec3(-s2, 0.0, c2)
	);

	mat3 rotZ = mat3(
		vec3(c3, -s3, 0.0),
		vec3(s3, c3, 0.0),
		vec3(0.0, 0.0, 1.0)
	);

	return rotZ * rotY * rotX; // Combine rotations in ZYX order
}

vec2 calc_equirect_uv(vec3 norm) {
	float flipu = starmap_flip_u ? -1.0 : 1.0;
	float flipv = starmap_flip_v ? -1.0 : 1.0;
	float u = flipu * ((atan(norm.y, norm.x) + PI) * INV_TAU); // 0 to 1 horizontally
	float v = -flipv * (acos(norm.z) * INV_PI); // 0 (north pole) to 1 (south pole)
	return vec2(u, v);
}

vec3 sample_moon_texture(vec3 dir) {
	dir = moon_matrix * dir * create_rotation_matrix(moon_texture_alignment);
	dir.x = -dir.x;
	dir.z = -dir.z;
	float flipu = moon_texture_flip_u ? 1.0 : -1.0;
	float flipv = moon_texture_flip_v ? 1.0 : -1.0;
	float u = 0.5 + flipu * atan(dir.z, dir.x) * INV_TAU; // Longitude
	float v = 0.5 + flipv * asin(dir.y) * INV_PI; // Latitude
	return texture(moon_texture, vec2(u, v)).rgb;
}

float calc_disk_mask(vec3 norm, vec3 coords, float size) {
	float dist = length(norm - coords);
	// One pixel of coverage at both screen and radiance-cubemap resolutions.
	// The old binary edge shimmered as the camera/sun moved, especially in water.
	float edge_width = max(fwidth(dist), 0.00001);
	return 1.0 - smoothstep(size - edge_width * 0.5, size + edge_width * 0.5, dist);
}

float map_range(float value, float from_min, float from_max, float to_min, float to_max) {
	return to_min + (value - from_min) * (to_max - to_min) / (from_max - from_min);
}

bool ray_sphere_intersect(float r, vec3 origin, vec3 dir, out float t, out vec3 nrm) {
	origin += vec3(0.0, 450.0, 0.0);
	float a = dot(dir, dir);
	float b = 2.0 * dot(origin, dir);
	float c = dot(origin, origin) - r * r;
	float d = b * b - 4.0 * a * c;
	float valid = step(0.0, d); // 1.0 if d >= 0.0, else 0.0
	d = sqrt(max(d, 0.0)); // Prevent sqrt of negative numbers
	a *= 2.0;
	float t1 = 0.5 * (-b + d);
	float t2 = 0.5 * (-b - d);
	float t_min = min(t1, t2); // Select the smallest intersection
	t = mix(t2, t1, step(t2, t1) * step(0.0, t1)); // Use t1 if t2 < t1 and t1 >= 0, else t2
	t = mix(0.0, t, step(0.0, t) * valid); // Invalidate if t < 0 or d < 0
	nrm = mix(vec3(0.0), origin + t * dir, step(0.0, t) * valid); // Set nrm only if valid
	return bool(step(0.0, t) * valid);
}

// For rendering the moon. This function courtesy of Kelvin van Hoorn.
// https://kelvinvanhoorn.com/2024/12/07/skybox-tutorial-godot/
float simple_sphere_intersect(vec3 ray_dir, vec3 sphere_pos, float radius) {
	vec3 oc = -sphere_pos;
	float b = dot(oc, ray_dir);
	float c = dot(oc, oc) - radius * radius;
	float h = b * b - c;
	float valid = step(0.0, h); // 1.0 if h >= 0.0, else 0.0
	h = sqrt(max(h, 0.0)); // Ensure sqrt is non-negative
	return mix(-1.0, -b - h, valid);
}

// Atmosphere
//------------------------------------------------------------------------------

// Clouds
//------------------------------------------------------------------------------
// THE DOME TIER (LOW): its cumulus layer and its high layer (dome_sky.gdshaderinc; the cumulus
// field is shared with the LOW cloud-shadow bakes, #761). The volume tier draws neither.
#ifndef CLOUDS_VOLUMETRIC
#include "res://src/sky/shaders/dome_sky.gdshaderinc"
#endif

float sample_cirrus_noise(vec2 coords) {
#ifdef CLOUDS_VOLUMETRIC
	// THE QUIET SKY (CLOUDS2, 2026-11-15): on the volumetric tiers the 2D cirrus drifts by the cloud_cirrus BUFFER
	// global (CloudBridge, every frame; buffer globals never dirty a material), not by the material's
	// cirrus_position1/2, whose write every frame kept the reflection map re-rendering. The map keeps the drift
	// it was drawn with. The dome (bound in the editor, where the runtime cloud_* globals do not exist) keeps them.
	vec2 p1 = cloud_cirrus.xy;
	vec2 p2 = cloud_cirrus.xy;
#else
	vec2 p1 = cirrus_position1;
	vec2 p2 = cirrus_position2;
#endif
	float a = textureLod(cirrus_texture, coords.xy * cirrus_uv + p1, 0.0).r;
	float b = textureLod(cirrus_texture, coords.xy * cirrus_uv + p2, 0.0).r;
	return ((a + b) * 0.5);
}

float calc_cirrus_density(vec2 p) {
	float d = sample_cirrus_noise(p);
	float c = 1.0 - cirrus_coverage;
	d = d - c;
	return clamp_to_unit(d);
}

// THE CIRRUS SHELL (2026-11-13). Sky3D draws the cirrus on an infinite flat plane (pos.xz / pos.y)
// and cuts it by elevation: none under 1.7 deg, whole only from 21 deg up. Against a true shell
// the projection differs by under 3 % above 10 deg; what read as "a flat sheet" was the cut (the
// layer ended in mid-sky, a clear band under it) and its light (one tint, nothing toward the sun).
// Now the 2D pattern sits on a shell CIRRUS_ALT_M over the sea: `dist` metres along the ray
// (planet_shell_hit: the curve brings it down to the horizon 340 km out, where the plane ran to
// infinity), faded by the air on the way (the call site), not by elevation.
// ONLY WITH THE VOLUME (CIRRUS_ON_SHELL): on the dome tier (LOW), and with the planet off, it is
// Sky3D's flat plane, elevation cut and tint, exactly as before (the owner had the shell taken off
// LOW the day it went on: "they're bugged now").
#ifdef CLOUDS_VOLUMETRIC
const bool CIRRUS_ON_SHELL = true;
#else
const bool CIRRUS_ON_SHELL = false;
#endif
const float CIRRUS_ALT_M = 9000.0;
// A camera climbing through the shell: the pattern would blow up, so it fades out near it.
const float CIRRUS_NEAR_M = 1500.0;
// Ice cloud scatters forward: brighter toward its light.
const float CIRRUS_FORWARD = 1.2;
const float CIRRUS_FORWARD_POW = 6.0;

vec4 render_cirrus_clouds(vec3 pos, float up, float cam_alt, float radius, bool on_shell, out float dist) {
	float near = 1.0;
	dist = -1.0;
	if (on_shell) {
		dist = planet_shell_hit(cam_alt, up, CIRRUS_ALT_M, radius);
		if (dist < 0.0) {
			return vec4(0.0);
		}
		// xz / y on the flat plane is the horizontal distance in units of the plane's height.
		pos.xy = pos.xz * (dist / CIRRUS_ALT_M);
		near = smoothstep(0.0, CIRRUS_NEAR_M, dist);
	} else {
		pos.xy = pos.xz / pos.y;
	}
	pos *= cirrus_size;
	float density = calc_cirrus_density(pos.xy);
	float sh = clamp_to_unit(exp(-cirrus_absorption * density));
	float a = clamp_to_unit(density * cirrus_thickness) * near;
	return vec4(vec3(density*sh) * cirrus_intensity, a);
}

// THE SUN'S AND THE MOON'S DISCS BEHIND CLOUD (2026-11-13, the VOLUME only). The discs are painted
// into the sky and the cumulus composited over them, so a disc showed through whatever
// transmittance the cloud had left: 2-3 % in the volume (the march stops at T < 3 %, and a real
// cumulus passes e^-30 of the direct beam). Measured looking at the noon sun under cover 0.55: a
// clean circle on the cloud, 5-8 % brighter than the cloud round it, the same with the lens flare
// and the halo off (so it is this disc, not the post FX). Through thin cloud a real sun stays
// visible, dimmed: the disc keeps the cloud's transmittance less the march's floor.
// The DOME tier (LOW) had the same cut for a day (the fourth power of what the dome lets through)
// and the cirrus's shell; the owner found the LOW clouds bugged with them and had both taken out
// again the same day: LOW draws its discs and its cirrus as Sky3D does.
#ifdef CLOUDS_VOLUMETRIC
const float SKY_DISC_T_FLOOR = 0.06;

float sky_disc_through_cloud(float t_cloud) {
	return clamp((t_cloud - SKY_DISC_T_FLOOR) / (1.0 - SKY_DISC_T_FLOOR), 0.0, 1.0);
}
#endif

// Main
//------------------------------------------------------------------------------

vec3 render_sky(vec3 world_pos, vec3 clouds_pos, vec3 sun_pos, vec3 moon_pos, float p_time
#ifdef CLOUDS_VOLUMETRIC
		, vec4 cloud_buf, float cloud_key_scale, bool cloud_radiance, vec3 cloud_ro
#else
		, vec3 dome_cam, bool dome_coarse
#endif
		) {
	vec3 col = vec3(0.0);

	vec4 angle_mult = sky_twilight_factors(sun_pos.y);

	// Atmosphere
	vec2 mu = vec2(dot(sun_pos, world_pos), dot(moon_pos, world_pos));

	// PLANET/FRAME: the observer's local "up" component of the view ray, in
	// the Y-up frame Sky3D's flat-earth maths was written for. Reduces to
	// world_pos.y exactly when sky_frame_basis is the identity default --
	// see that uniform's own comment for why world_pos ITSELF stays raw
	// (read by the star map / sun / moon code below).
	float local_up = (transpose(sky_frame_basis) * world_pos).y;

	float local_up_raw = local_up;
	// PHYSICAL ATMOSPHERE: the view ray in the local Y-up frame (the tables' frame), and its sky.
	bool atm_on = atm_enabled();
	vec3 atm_dir = normalize(transpose(sky_frame_basis) * world_pos);
	vec4 atm_sv = atm_on ? atm_skyview(atm_dir) : vec4(0.0, 0.0, 0.0, 1.0);
	local_up -= horizon_offset;
	world_pos.y -= horizon_offset;
	float planet_blend = planet_enabled
			? planet_spherical_blend(cam_altitude) : 0.0;
	SkyHaze haze;
	if (atm_on) {
		// The air's light along the ray plus the night sky's own glow: everything that composites
		// over the sky (the clouds' distance fade) converges on the sky as drawn.
		vec3 atm_sky = atm_sv.rgb + atm_night_sky(atm_dir);
		haze.scatter = atm_sky;
		haze.scatter_flat = atm_sky;
		haze.sr = 0.0;
		haze.sm = 0.0;
		haze.planet_od = vec2(0.0);
	} else {
		haze = sky_haze(local_up_raw, mu, angle_mult.xyz, cam_altitude,
				planet_blend, planet_radius, horizon_offset);
	}
	float sr = haze.sr;
	float sm = haze.sm;

	// PLANET: both stock cuts are pinned to the y=0 plane, which is the true
	// horizon only at sea level. From 20 km the horizon dips 4.53 degrees
	// (y ~ -0.079), so deep space was cut well ABOVE where the planet edge
	// actually is -- a night flight showed a black gap band between the limb and
	// the starfield. sin(dip) is the y of the horizon direction; at h=0 the dip
	// is 0 and both lines reduce exactly to the stock cuts.
	float horizon_y = -sin(planet_horizon_dip(cam_altitude, planet_radius))
			* planet_blend;
	float horizonBlend = clamp_to_unit((local_up - horizon_y - 0.03) * 3.0);
	float horizonBlendCumulus = clamp_to_unit((local_up - horizon_y + 0.01) * 50.0);

	// PLANET: THE ONE MARCH.
	//
	// Sky3D's calc_simple_optical_depth gives sr = 8400/y -- a function of view
	// DIRECTION only, with camera altitude appearing nowhere. So the bright
	// horizon band is frozen at y=0 at every altitude, while from 20 km the
	// true horizon is 4.53 degrees BELOW level (y ~ -0.079). No amount of beta
	// scaling moves it there, which is why the old code needed an additive limb
	// and still looked wrong.
	//
	// planet_optical_depth_pair returns the SAME quantity in the SAME units --
	// metres of equivalent sea-level column -- and the two agree to ~4% at sea
	// level (zenith 8400 vs 8500, horizon 280000 vs 291500; pinned by
	// test_planet_geometry.gd). That agreement is what makes this a swap rather
	// than a re-tune.
	//
	// Marched ONCE here and reused by the sky colour, the sun disk's extinction
	// and the sea's aerial perspective. Previously the sea marched it while the
	// sky colour ran an incompatible flat-earth model -- that mismatch is
	// exactly why the limb could only ever be bolted on additively.
	vec2 planet_od = haze.planet_od;

	// Blend the two scatter COLOURS, not the two optical depths.
	//
	// calc_atmospheric_scatter is exponential in sr, so mixing the depths and
	// evaluating once is NOT the same as evaluating twice and mixing the
	// results. Measured on a ray 8 degrees below the true horizon, mixing
	// depths made the far sea brighten to a peak at 5 km and dip again at 8 km
	// -- a visible non-monotonic wobble while climbing. Mixing colours removes
	// it entirely at low sun and more than halves it in daylight.
	//
	// sr/sm deliberately stay ANALYTIC from here on, so scatter_flat IS today's
	// sea-level sky. The sea below reuses it directly, and the identity at
	// blend=0 becomes structural rather than something a mix() has to land on.
	vec3 scatter_flat = haze.scatter_flat;
	vec3 scatter = haze.scatter;
	// PLANET: the atmosphere's post-process now owns aerial perspective, so Sky3D's
	// own atmospheric wash retires from the shell top (60 km) to the Karman
	// line (100 km) -- above that this shader would otherwise fog the same
	// view a second time. Starmap, Milky Way, the sun disk and the moon disk
	// are untouched: only THIS contribution to col.rgb is gated. Exactly 1.0
	// at and below PLANET_ATMOSPHERE_TOP, so sea level and every flat-world
	// altitude a plane actually reaches are unaffected.
	if (atm_on) {
		// The table holds the air's light along the whole ray (none above 100 km: no fade needed);
		// `scatter` has the night sky's glow in it (atm_night_sky).
		col.rgb += scatter;
	} else {
		col.rgb += scatter.rgb * planet_atmosphere_scatter_fade(cam_altitude);
	}

	// Sun
	// PLANET: the stock disk is tinted by `scatter`, so as the sky correctly
	// darkens with altitude the SUN fades out along with it -- the one thing in
	// the frame that must not. Physically the disk's radiance is the solar
	// colour times the transmittance along the view ray, which tends to 1 as
	// the air thins. That gives a hard white sun high up and a red one at
	// sunset from any altitude, both for free. beta_ray is scaled by
	// atm_thickness to match what calc_atmospheric_scatter uses, so the two
	// cannot drift. mix() keeps sea level byte-identical.
	// Transmittances are blended as OUTPUTS too, for the same reason the
	// scatter colours are: exp() is nonlinear in the depth.
	vec3 sun_beta_ray = atm_beta_ray * atm_thickness;
	vec3 sun_transmittance = clamp_rgb_to_unit(mix(
			exp(-(sun_beta_ray * sr + atm_beta_mie * sm)),
			exp(-(sun_beta_ray * planet_od.x + atm_beta_mie * planet_od.y)),
			planet_blend));
	vec3 sun_radiance = mix(sun_disk_color.rgb * scatter.rgb,
			sun_light_color.rgb * sun_transmittance, planet_blend);
	vec3 sun_disk = calc_disk_mask(world_pos, sun_pos, sun_disk_size) * sun_radiance;
	sun_disk *= sun_disk_intensity;
	if (atm_on) {
		// The disc's radiance: the sun's illuminance above the air, spread over the drawn disc
		// (atm_night.w, 600, keeps the flux of a disc this size), times the air along
		// the view ray. sun_disk_intensity / its authored 30 is the weather's overcast fade, cubed:
		// a disc 600x the sky still glared through at 5 % (cover 0.95).
		float disc = calc_disk_mask(world_pos, sun_pos, sun_disk_size);
		sun_disk = vec3(0.0);
		if (disc > 0.0) {
			float overcast_fade = clamp(sun_disk_intensity / 30.0, 0.0, 1.0);
			sun_disk = disc * atm_transmittance(cam_altitude, atm_dir.y) * atm_sun.w * atm_night.w
					* overcast_fade * overcast_fade * overcast_fade;
		}
	}
	// PLANET/CELESTIAL: suppress the painted disc wherever the real geometry
	// draws (see the uniform's own comment). At fade=0 this is *1.0, a no-op.
	sun_disk *= (1.0 - celestial_geometry_fade);

	// Moon
	float moon_intersect = simple_sphere_intersect(world_pos, moon_pos, moon_size);
	float moon_mask = moon_intersect > (-1. + sqrt(moon_size)) ? 1.0 : 0.0;
	vec3 moon_normal = normalize(world_pos * moon_intersect - moon_pos);

	float moon_ndotl = clamp(dot(moon_normal, sun_pos), 0.0, 1.0);
	vec3 moon_tex = sample_moon_texture(moon_normal);
	vec3 moon_output = moon_mask * moon_ndotl * exp2(1.0) * moon_tex * moon_color.rgb;
	// PLANET/CELESTIAL: same suppression as the sun disk, see above.
	moon_output *= (1.0 - celestial_geometry_fade);
	// PLANET/CELESTIAL: moon_mask also gates the STAR background (so stars
	// don't show through the painted disc) -- once the disc itself is
	// suppressed that gate must relax too, or the handover leaves a black
	// hole where the real moon geometry now sits instead of stars. Scaling
	// moon_mask's contribution by (1 - fade) is exactly self-cancelling at
	// fade=0 (today's `1.0 - moon_mask`, unchanged) and at fade=1 collapses
	// to 1.0 (no gating at all, matching "the painted disc is gone").
	float moonMask = (1.0 - moon_mask * (1.0 - celestial_geometry_fade));

	// Deep space

	// Tilt the sky along the X-axis.
	mat3 tilt = create_rotation_matrix(vec3(star_tilt, 0.0, 0.0));

	// Rotation around Y-axis. For simulating Earth's rotation.
	mat3 rotation = create_rotation_matrix(vec3(0.0, star_rotation + star_rotation_offset, 0.0));

	// Initial XYZ rotation for alignment.
	mat3 alignment_xyz = create_rotation_matrix(starmap_alignment);

	// Combine everything together to get the desired alignment.
	vec3 final_alignment = normalize(alignment_xyz * rotation * tilt * world_pos);

	// Now generate UV coordinates for the texture.
	vec2 deep_space_uv = calc_equirect_uv(normalize(final_alignment));

	// Star map
	vec3 deep_space_background = textureLod(starmap_texture, deep_space_uv, 0.0).rgb;
	deep_space_background *= starmap_color.rgb;
	deep_space_background = adjust_contrast(deep_space_background, starmap_color.a);
	vec3 deep_space = deep_space_background.rgb * moonMask + moon_output;

	// Star Field
	float star_scint = textureLod(noise_tex, deep_space_uv + (p_time * star_scintillation_speed), 0.0).r;
	star_scint = mix(1.0, star_scint * 1.5, star_scintillation);

	vec3 star_field = textureLod(star_field_texture, deep_space_uv, 0.0).rgb * star_field_color.rgb;
	star_field = clamp_rgb_to_unit(mix(star_field.rgb, star_field.rgb * star_scint, star_scintillation));
	star_field = clamp_rgb_to_unit(star_field.rgb);
	//deep_space.rgb -= clamp_to_unit(star_field.r * 10.0);
	deep_space.rgb += star_field.rgb * moonMask;
	// PLANET: angle_mult.z gates stars on SUN ELEVATION, which is right at sea
	// level and wrong in space -- at 100 km it is vacuum and the stars are out
	// with the sun up. Gate on how much atmosphere is left above the camera
	// instead, and take whichever is more permissive so night is unchanged.
	// The knee is placed at 90% of the Rayleigh column being gone (~19.5 km),
	// so nothing appears anywhere the previous 20 km ceiling could reach.
	float star_vacuum = 1.0 - exp(-max(cam_altitude, 0.0) / PLANET_RAYLEIGH_H);
	star_vacuum = clamp_to_unit((star_vacuum - 0.9) * 10.0) * planet_blend;
	deep_space.rgb *= max(angle_mult.z, star_vacuum);
	if (atm_on) {
		// The moon and the stars through the air in front of them (dim and red at the horizon).
		deep_space.rgb *= atm_sv.a;
	}
	col.rgb += sun_disk.rgb + deep_space.rgb * horizonBlend;
#ifdef CLOUDS_VOLUMETRIC
	// THE DISCS BEHIND CLOUD (2026-11-13, the volume only): what the sun's and the moon's discs
	// put into `col`, kept apart so the cumulus can hide them (sky_disc_through_cloud).
	vec3 sky_discs = sun_disk.rgb + moon_output * max(angle_mult.z, star_vacuum) * horizonBlend;
#endif

	// PLANET: the sea is drawn BEFORE the clouds. It used to run after them and
	// mix() over the top, so from above the deck the ocean painted on top of the
	// clouds. From 20 km the clouds sit between the camera and the sea, so the
	// sea has to be the background they composite onto.
	// PLANET: below-horizon branch + limb.
	// Stock Sky3D cuts to a flat ground_color at y=0, which is why the horizon
	// reads flat from any altitude -- already visibly wrong from the 854 m
	// summit of Hachijo-Fuji, whose true horizon is 104 km out, well past the
	// 16 km camera far plane.
	if (planet_enabled) {
		// PLANET/FRAME: local_up, not world_pos.y -- this is a genuine
		// direction-relative-to-MY-horizon test, so it needs the same
		// correction render_sky's other elevation reads got. At identity
		// this is world_pos.y, unchanged. The reflect/glitter/Earth-texture
		// maths below this point still reads world_pos.x/z raw -- true
		// reprojection of the full horizontal plane is out of this task's
		// scope (see the shader header and the design doc); this line only
		// fixes whether a hit is found in the right direction AT ALL, which
		// is what stopped the sandbox painting a fake "sea" patch in an
		// arbitrary screen direction unrelated to where the real planet
		// mesh actually is.
		float t_ground = planet_ground_hit(cam_altitude, local_up, planet_radius);
		// >= not >, deliberately. At exactly h=0 the camera sits ON the surface,
		// so c = 2Rh + h^2 is 0 and every downward ray hits at t=0 -- which is
		// geometrically right, but a `> 0.0` test rejected it and drew NO sea,
		// leaving the raw below-horizon sky (which the analytic model saturates
		// to white). PlanetHorizon clamps altitude with maxf(h, 0.0), so any
		// underwater or floating camera -- a swimming player, a boat -- lands
		// exactly on that case. One centimetre up it already behaved.
		if (t_ground >= 0.0) {
			// Open sea. No wave geometry: beyond ~35 km a wave is far under a
			// pixel, so the glitter lobe and the haze are what actually read.
			// Mirror the view direction about the horizontal plane -- the sea
			// is flat at this scale, so that IS the reflected direction.
			// PLANET: `scatter` is the sky radiance at the CAMERA's altitude,
			// so using it to light the sea turns the ocean black as the camera
			// climbs and the sky around it darkens. The sea sits at sea level
			// and is lit by the SEA-LEVEL sky no matter where the camera is.
			//
			// scatter_flat is exactly that: calc_simple_optical_depth is
			// altitude-blind, so it IS the sea-level sky. Already computed
			// above, so this costs nothing and needs no tuning constant. At
			// blend=0 scatter == scatter_flat, so sea level is unchanged BY
			// CONSTRUCTION rather than by a mix() that has to be got right.
			//
			// Measured before this: a constant ambient was 5.8x too bright in
			// red by the top of the band, and neutral grey where the real
			// sea-level sky is strongly orange at sunset -- the far sea
			// visibly brightened and went muddy as you climbed.
			vec3 sea_light = scatter_flat;

			vec3 sea_reflect = vec3(world_pos.x, -world_pos.y, world_pos.z);
			float glitter = pow(max(dot(sea_reflect, sun_pos), 0.0),
					sea_glitter_sharpness);
			// PLANET/EARTH: the hit point, placed on the real globe. The
			// projection is entirely precomputed on the CPU, so this is a
			// rotation and an add -- exact at any distance, with no
			// flat-earth approximation and no far plane involved.
			vec3 earth_albedo = sea_color_deep.rgb;
			if (earth_enabled) {
				vec3 hit_ecef = earth_cam_ecef + earth_enu_basis
						* (t_ground * planet_world_dir_to_enu(world_pos));
				earth_albedo = texture(earth_global_tex,
						planet_ecef_to_equirect(hit_ecef)).rgb;
			}
			vec3 sea;
			if (!atm_on) {
				sea = earth_albedo * sea_light;
				sea += glitter * sea_glitter_intensity * sun_light_color.rgb * sea_light;

				// Aerial perspective, using the SAME function ocean_t3d.gdshader
				// calls with the same betas, so near and far sea cannot drift.
				sea = planet_aerial_perspective(sea, scatter, planet_od,
						atm_beta_ray, atm_beta_mie);
			} else {
				// PHYSICAL ATMOSPHERE: the sea lit by the atmosphere's own sun and sky at sea level,
				// mirroring the sky at a grazing look (Schlick, capped: waves break the mirror), then
				// seen through the air in front of it (the table's in-scatter to the hit, and its
				// transmittance).
				vec3 e_sun = atm_sun_illuminance(0.0);
				vec3 lit = earth_albedo * (e_sun * max(atm_sun.y, 0.0) / PI + atm_sky_ambient(0.0));
				float cos_v = clamp(-atm_dir.y, 0.0, 1.0);
				float fres = min(0.02 + 0.98 * pow(1.0 - cos_v, 5.0), 0.6);
				vec3 refl_dir = normalize(vec3(atm_dir.x, max(-atm_dir.y, 0.01), atm_dir.z));
				lit += fres * atm_sky_radiance(refl_dir);
				lit += glitter * sea_glitter_intensity * e_sun * 0.1;
				sea = lit * atm_sv.a + atm_sv.rgb;
			}

			// Feather the last fraction of a degree so the sea meets the sky
			// without an aliased edge.
			col.rgb = mix(col.rgb, sea, clamp_to_unit(-world_pos.y * 400.0));
		}

	} else {
		col.rgb = mix(col.rgb, ground_color.rgb * scatter, clamp_to_unit((-world_pos.y - atm_level_params.z) * 100.0));
	}

	// PLANET: both cloud layers multiply their alpha by horizonBlend, which is
	// ZERO for any ray below the horizon. At sea level that is right -- clouds
	// have no business below the horizon line. Once the camera is ABOVE the
	// deck it is exactly backwards: the deck is below the horizon, so the gate
	// erased it and clouds vanished entirely above ~5 km. Measured from the
	// sky_shot ladder: present at 0 m and 854 m, faint at 5 km, gone at 12 km
	// and 20 km, in both the horizon and the down-aimed shots.
	//
	// Above the band the shells bound themselves -- planet_shell_hit returns
	// -1.0 on a miss -- so the horizon cut has no work left to do. At blend=0
	// this is exactly horizonBlend and sea level is unchanged.
	float cloud_horizon_gate = mix(horizonBlend, 1.0, planet_blend);

	// PLANET: retire both decks with altitude. Multiplied into the SAME alpha
	// gate the horizon cut uses, so there is one place clouds can be silenced
	// rather than two. At and below cloud_fade_start this is exactly 1.0, so
	// everything the fleet actually flies through is untouched.
	cloud_horizon_gate *= 1.0 - smoothstep(cloud_fade_start, cloud_fade_end,
			cam_altitude);

	// Clouds
#ifndef CLOUDS_VOLUMETRIC
	// THE DOME TIER'S HIGH LAYER (dome_high_cloud): thin ice cloud on a shell 9 km up. One
	// scattering of its own key light (it holds the sun ~3 deg longer than the ground does),
	// strongly forward, plus the sky's light; the sky and the discs show through it.
	if (cirrus_visible) {
		vec3 high_dir = transpose(sky_frame_basis) * clouds_pos;
		float high_alt = max(cam_altitude, 0.0);
		float high_dist;
		float high_d = dome_high_cloud(dome_cam.xz, high_dir, high_alt, planet_radius, high_dist);
		high_d *= 1.0 - smoothstep(cloud_fade_start, cloud_fade_end, cam_altitude);
		if (high_d > 0.002) {
			float high_c = dot(high_dir, transpose(sky_frame_basis) * dome_key_dir);
			float high_ph = 4.0 * PI * mix(dome_hg(high_c, 0.7), dome_hg(high_c, -0.2), 0.35);
			vec3 high_amb = sky_ambient_for_clouds(sun_pos, moon_pos, angle_mult.xyz,
					cam_altitude, planet_blend, planet_radius, horizon_offset);
			float high_a = 1.0 - exp(-high_d * DOME_HIGH_TAU);
			vec3 high_lit = (dome_high_key * (0.35 * high_ph + 0.4) + high_amb * 0.8) * high_a;
			vec2 high_od = planet_optical_depth_pair_to(high_alt, high_dir.y, high_dist, 6, planet_radius);
			vec3 high_t = exp(-(atm_beta_ray * high_od.x + (atm_beta_mie + DOME_AEROSOL) * high_od.y));
			high_lit = high_lit * high_t + scatter * (1.0 - high_t) * high_a;
			col.rgb = col.rgb * (1.0 - high_a) + high_lit;
		}
	}
#else
	if (cirrus_visible) {
		float cirrus_dist;
		bool cirrus_shell = planet_enabled && CIRRUS_ON_SHELL;
		vec4 cirrus_clouds = render_cirrus_clouds(clouds_pos, local_up_raw, cam_altitude, planet_radius,
				cirrus_shell, cirrus_dist);
		cirrus_clouds.a = clamp_to_unit(cirrus_clouds.a);
		vec3 cloud_tint = sun_light_color.rgb;
		// Sky3D's own tint, on both tiers. The volume's key (its noon sun, the twilight's daylight,
		// the air between the shell and the sun) was tried on HIGH (2026-11-13): at 17:18 the cirrus
		// went from peach-pink, in step with the cumulus under it, to a dim olive (the daylight
		// curve is a sea-level one, and 9 km up the sun is still high and pale). Not kept.
		cloud_tint = mix(cloud_tint, clouds_night_color.rgb, angle_mult.w);
		float cirrus_fwd = cirrus_shell
				? pow(clamp(mix(mu.x, mu.y, angle_mult.w), 0.0, 1.0), CIRRUS_FORWARD_POW) : 0.0;
		cirrus_clouds.rgb *= cloud_tint * cirrus_intensity * (1.0 + CIRRUS_FORWARD * cirrus_fwd);
		vec3 cirrus_lit = cirrus_clouds.rgb
				+ mix(vec3(0.0), scatter, cirrus_sky_tint_fade);
		if (cirrus_shell) {
			// On the shell: hidden by the planet, not by an elevation cut (under the shell a
			// ray that meets the ground never reaches it), and faded by the air on the way
			// there: the sky's own betas, as the cumulus's aerial perspective, toward the
			// sky's colour on that ray. At the horizon the shell is 340 km off and all haze.
			float cirrus_gate = (cam_altitude > CIRRUS_ALT_M
					|| planet_ground_hit(cam_altitude, local_up_raw, planet_radius) < 0.0) ? 1.0 : 0.0;
			cirrus_gate *= 1.0 - smoothstep(cloud_fade_start, cloud_fade_end, cam_altitude);
			cirrus_clouds.a *= cirrus_gate;
			if (cirrus_clouds.a > 0.002) {
				vec2 cirrus_od = planet_optical_depth_pair_to(cam_altitude, local_up_raw, cirrus_dist, 6,
						planet_radius);
				cirrus_lit = mix(scatter, cirrus_lit,
						exp(-(atm_beta_ray * cirrus_od.x + atm_beta_mie * cirrus_od.y)));
			}
		} else {
			cirrus_clouds.a = mix(0.0, cirrus_clouds.a, cloud_horizon_gate);
			cirrus_lit = mix(cirrus_lit,
					planet_aerial_perspective(cirrus_lit, scatter, planet_od,
							atm_beta_ray, atm_beta_mie),
					planet_blend);
		}
#ifdef CLOUDS_VOLUMETRIC
		// Thin ice cloud: the discs show through it, dimmed as the sky behind it is.
		sky_discs *= 1.0 - cirrus_clouds.a;
#endif
		col.rgb = mix(col.rgb, cirrus_lit, cirrus_clouds.a);
	}
#endif

#ifndef CLOUDS_VOLUMETRIC
	// THE DOME TIER'S CUMULUS (dome_sky.gdshaderinc): the layer marched along this ray, lit by its
	// key light (dome_key_*), the sky (the same hemisphere mean the volume takes) and the light
	// off the sea under it, then faded by the air between (the sky's betas and a maritime haze)
	// toward the sky's own colour on this ray. The sun's and the moon's discs are behind it.
	if (cumulus_visible) {
		vec3 dome_dir = transpose(sky_frame_basis) * clouds_pos;
		vec3 dome_key = transpose(sky_frame_basis) * dome_key_dir;
		float dome_alt = max(cam_altitude, 0.0);
		DomeHit hit = dome_march(dome_cam.xz, dome_dir, dome_alt, planet_radius, dome_key, dome_coarse);
		if (hit.T < 0.999) {
			float fade = 1.0 - smoothstep(cloud_fade_start, cloud_fade_end, cam_altitude);
			vec3 amb_col = (dome_debug & 32) != 0 ? vec3(0.3) : sky_ambient_for_clouds(sun_pos, moon_pos, angle_mult.xyz,
					cam_altitude, planet_blend, planet_radius, horizon_offset);
			// The sea and the ground under the layer send a little of the key light and of the
			// sky back up at the bases.
			vec3 low_col = (dome_key_color * max(dome_key.y, 0.0) + amb_col) * 0.07;
			vec3 lit = dome_key_color * hit.key + amb_col * (DOME_AMBIENT * hit.amb) + low_col * hit.low;
			vec2 dome_od = planet_optical_depth_pair_to(dome_alt, dome_dir.y, hit.dist, 6, planet_radius);
			vec3 t_air = exp(-(atm_beta_ray * dome_od.x + (atm_beta_mie + DOME_AEROSOL) * dome_od.y));
			lit = lit * t_air + scatter * (1.0 - t_air) * (1.0 - hit.T);
			col.rgb = mix(col.rgb, col.rgb * hit.T + lit, fade);
		}
	}
#else
	// Volumetric cumulus: the half-res march, composited over sea + cirrus. The
	// horizon cut is gone (the march bounds itself); the altitude fade stays.
	// With the flight pass live (cloud_flags bit 0) it owns every mu < 0 pixel
	// (CloudPartition): the sky pass draws behind the ocean and hid the deck. The
	// radiance cubemap keeps every direction — no flight quad renders into it.
	// The sky's ambient (two sky_haze() marches, the same for every pixel) only where there is
	// cloud: cloud_composite returns col untouched for T >= 0.999 (card #770).
	if (cloud_mode == 1 && (cloud_radiance || ((cloud_flags & 1) == 0 || clouds_pos.y >= 0.0))
			&& cloud_decode(cloud_buf).T < 0.999) {
		float fade = 1.0 - smoothstep(cloud_fade_start, cloud_fade_end, cam_altitude);
		vec3 amb_col = sky_ambient_for_clouds(sun_pos, moon_pos, angle_mult.xyz,
				cam_altitude, planet_blend, planet_radius, horizon_offset);
		col.rgb = cloud_composite(col.rgb, cloud_buf, cloud_ro, clouds_pos, cam_altitude, scatter,
				amb_col, cloud_key_scale, fade, cloud_radiance ? 0.0 : 1.0);
		// The composite left the discs at what the cloud lets past (cloud_t_behind), and the march stops at
		// T < 3 %: 2-3 % of an HDR disc is a clean circle on the base of a thick cloud.
		float t_cloud = cloud_decode(cloud_buf).T;
		col.rgb -= sky_discs * fade * max(cloud_t_behind(t_cloud) - sky_disc_through_cloud(t_cloud), 0.0);
	}
#endif

	col.rgb = apply_photo_tonemap(col.rgb, color_correction.y, color_correction.x);
	col.rgb = weather_grade(col.rgb);
	return col;
}

vec4 create_axis_angle_quat(vec3 axis, float angle) {
	float s = sin(angle * 0.5);
	return vec4(axis * s, cos(angle * 0.5));
}

vec3 rotate_vector_by_quat(vec3 v, vec4 q) {
	vec3 t = 2.0 * cross(q.xyz, v);
	return v + q.w * t + cross(q.xyz, t);
}

vec3 align_and_rotate_vector(vec3 dir, vec3 target, float rotation_angle) {
	vec3 z_axis = vec3(0.0, 0.0, 1.0); // Original grid alignment

	// First, align Z-axis with target (Polaris)
	target = normalize(target);
	vec3 axis = cross(z_axis, target);
	float angle = acos(dot(z_axis, target));
	float valid = step(0.0001, length(axis)); // 1.0 if length(axis) >= 0.0001
	axis = normalize(axis);
	vec4 align_quat = create_axis_angle_quat(axis, angle);
	dir = mix(dir, rotate_vector_by_quat(dir, align_quat), valid);
	vec4 rot_quat = create_axis_angle_quat(vec3(0.0, 0.0, 1.0), rotation_angle);
	dir = mix(dir, rotate_vector_by_quat(dir, rot_quat), valid);
	return dir;
}

void render_grid(vec3 dir, vec3 pole_dir, float rotation_angle, vec4 line_color, float grid_spacing, float line_thickness, inout vec3 color) {
	float spacing = max(grid_spacing, 0.001);
	float thickness = max(line_thickness, 0.0001);

	// Rotate dir with sidereal motion and align with pole_dir
	dir = align_and_rotate_vector(dir, pole_dir, rotation_angle);

	// Latitude / Circles / Theta Spherical coordinates
	float theta = acos(dir.z);
	float theta_deriv = fwidth(theta);
	float circle_thickness = max(thickness, theta_deriv);
	float circle = mod(theta, spacing);
	float circle_line = 1.0 - smoothstep(0.0, circle_thickness * 1.5, abs(circle - circle_thickness * 0.5));
	circle_line *= clamp_to_unit(thickness / circle_thickness);

	// Add poles
	float pole_thickness = circle_thickness;
	float north_pole = 1.0 - smoothstep(0.0, pole_thickness, theta);
	float south_pole = 1.0 - smoothstep(0.0, pole_thickness, abs(theta - PI));
	circle_line = max(circle_line, max(north_pole, south_pole));

	// Darken Lat at poles
	float circle_adjust = sin(theta);
	circle_line *= clamp(circle_adjust, 0.2, 1.0);

	// Longitude / Radial lines / Phi Spherical coordinates
	float phi = atan(dir.y, dir.x);
	float phi_deriv = fwidth(phi);
	float radial_thickness = max(thickness, phi_deriv);
	float radial = mod(phi + PI, spacing); // PI w/ less precision to remove moire
	float radial_line = 1.0 - smoothstep(0.0, radial_thickness * 1.5, abs(radial - radial_thickness));
	radial_line *= clamp_to_unit(thickness / radial_thickness);

	float grid = max(radial_line, circle_line);
	color += line_color.rgb * line_color.a * grid;
}

void sky() {
#ifdef CLOUDS_HALF_RES
#ifdef CLOUDS_CUBE_COLOR
	if (AT_HALF_RES_PASS && !AT_CUBEMAP_PASS) {
#else
	if (AT_HALF_RES_PASS) {
#endif
		// The screen's half-res pass (and, in the old layout, the half-res radiance variant): march, encode.
		vec4 e = vec4(0.0, 0.0, 0.0, 1.0);
		// CloudPartition.sky_marches: skip what the flight pass owns, keeping a
		// margin below the split for the bilinear upsample. The main view's
		// screen pixels come from the temporal pass (cloud_view) when it is live.
		if (cloud_mode == 1 && (AT_CUBEMAP_PASS || (cloud_flags & 1) == 0 || EYEDIR.y >= -cloud_fade.w)
				&& (AT_CUBEMAP_PASS || !cloud_view_owns(FRAGCOORD.xy / SCREEN_UV, true))) {
			vec2 bn = AT_CUBEMAP_PASS ? vec2(0.5) : cloud_blue(FRAGCOORD.xy);
			e = cloud_encode(cloud_march(POSITION, EYEDIR, bn.x, bn.y, AT_CUBEMAP_PASS));
		}
		COLOR = e.rgb;
		ALPHA = e.a;
	} else {
#endif
	float current_time = sky_time;
	vec3 col = vec3(0.0); // Set up the initial sky color which will be added to later to produce the final result.
	vec3 world_pos = EYEDIR; // Original shader set this up in the vertex() function. For sky shaders the overall equivalent is EYEDIR.
	vec3 clouds_pos = EYEDIR; // The same is used for cloud rendering.
	vec3 sun_pos = LIGHT0_DIRECTION; // Redefined from now-deprecated _sun_direction.
	vec3 moon_pos = LIGHT1_DIRECTION; // Redefined from now-deprecated _moon_direction.

	if (sky_visible) {
#ifdef CLOUDS_VOLUMETRIC
#ifdef CLOUDS_CUBE_COLOR
		// THE REFLECTION MAP'S HALF-RES PASS DRAWS THE FINISHED SKY (CLOUDS2, 2026-11-15; the owner's flickering
		// windows). Godot renders it into the octmap's own mip 1 (sky.cpp update_radiance_buffers:
		// layers[0].mipmaps[1].framebuffer), the roughness layer glass, wet roads and mirrors reflect, until the
		// incremental filter rewrites that mip on the next frame. The clouds' encoded weights there (x64) flashed in
		// every such reflection one frame per re-render. So that pass marches (cheaply) and draws the whole sky, a
		// valid colour; the full-res octmap pass takes it (HALF_RES_COLOR is that mip) and draws nothing again. The
		// screen keeps its half-res pass (the march of the views the temporal pass does not own).
		vec4 cloud_buf = vec4(0.0, 0.0, 0.0, 1.0);
		bool cube_done = false;
		// Look-dev (CLOUDS5; n.CloudBridge.tune=debug_fallback:1, cloud_pf_c.w bit 128): the screen's per-pixel
		// fallback march tinted red, so a capture shows which frames the temporal pass did not own.
		bool fb_dbg = false;
		if (AT_CUBEMAP_PASS && !AT_HALF_RES_PASS) {
			col = HALF_RES_COLOR.rgb;
			cube_done = true;
		} else if (AT_CUBEMAP_PASS) {
			if (cloud_mode == 1) {
				cloud_buf = cloud_encode(cloud_march(POSITION, EYEDIR, 0.5, 0.5, true));
			}
		} else {
			cloud_buf = HALF_RES_COLOR;
			if (cloud_mode == 1 && cloud_view_owns(FRAGCOORD.xy / SCREEN_UV, false)) {
				cloud_buf = cloud_encode(cloud_view_sample(SCREEN_UV));
			} else {
				fb_dbg = (int(cloud_pf_c.w) & 128) != 0;
			}
		}
		if (!cube_done) {
			col = render_sky(world_pos, clouds_pos, sun_pos, moon_pos, current_time,
					cloud_buf, AT_CUBEMAP_PASS ? cloud_light_c.w : 1.0, AT_CUBEMAP_PASS, POSITION);
		}
		if (fb_dbg) {
			col *= vec3(1.8, 0.5, 0.5);
		}
#else
#ifdef CLOUDS_HALF_RES
		vec4 cloud_buf = HALF_RES_COLOR;
		if (!AT_CUBEMAP_PASS && cloud_mode == 1 && cloud_view_owns(FRAGCOORD.xy / SCREEN_UV, false)) {
			cloud_buf = cloud_encode(cloud_view_sample(SCREEN_UV));
		}
#else
		// NO HALF-RES PASS (CLOUDS2, 2026-11-15; the owner's "building windows flicker blue with HIGH clouds"). Godot
		// renders a sky's half-res pass for the reflection octmap INTO THAT OCTMAP'S MIP 1 (sky.cpp,
		// update_radiance_buffers: layers[0].mipmaps[1].framebuffer), the roughness layer glass, wet roads and
		// mirrors reflect, and the incremental filter rewrites it only on the next frame. Ours wrote the clouds'
		// ENCODED weights there (x64, cloud_encode), so for one frame in every eight (the roughness layers' cycle,
		// re-run while the sky is dirty) every low-roughness reflection flashed. The main view takes its clouds
		// from the temporal pass's history; the reflection cubemap and the views that pass does not own (mirrors,
		// the PIP, a stalled pass) march here, at full resolution (planet_sky_volumetric_fr.gdshader,
		// CloudBridge.sky_layout 1; the shipped layout is CLOUDS_CUBE_COLOR's above).
		vec4 cloud_buf = vec4(0.0, 0.0, 0.0, 1.0);
		if (!AT_CUBEMAP_PASS && cloud_mode == 1 && cloud_view_owns(FRAGCOORD.xy / SCREEN_UV, false)) {
			cloud_buf = cloud_encode(cloud_view_sample(SCREEN_UV));
		} else if (cloud_mode == 1 && (AT_CUBEMAP_PASS || (cloud_flags & 1) == 0 || EYEDIR.y >= -cloud_fade.w)) {
			vec2 bn = AT_CUBEMAP_PASS ? vec2(0.5) : cloud_blue(FRAGCOORD.xy);
			cloud_buf = cloud_encode(cloud_march(POSITION, EYEDIR, bn.x, bn.y, AT_CUBEMAP_PASS));
		}
#endif
		col = render_sky(world_pos, clouds_pos, sun_pos, moon_pos, current_time,
				cloud_buf, AT_CUBEMAP_PASS ? cloud_light_c.w : 1.0, AT_CUBEMAP_PASS, POSITION);
#endif
#else
		col = render_sky(world_pos, clouds_pos, sun_pos, moon_pos, current_time, POSITION, AT_CUBEMAP_PASS);
#endif
	}

	// Draw overlay grids
	{
		float grid_thickness = 0.0002;
		float grid_spacing = 0.261799; // 15 degrees
		vec3 zenith_dir = vec3(0.0, 1.0, 0.0); // Y-axis aligned azimuthal
		vec3 north_celestial_pole = create_rotation_matrix(vec3(star_tilt, 0.0, 0.0)) * zenith_dir;
		float rotation_angle = star_rotation + star_rotation_offset;
		if (show_azimuthal_grid) {
			render_grid(EYEDIR, zenith_dir, azimuthal_grid_rotation_offset, azimuthal_grid_color, grid_spacing, grid_thickness, col);
		}
		if (show_equatorial_grid) {
			render_grid(EYEDIR, north_celestial_pole, rotation_angle + equatorial_grid_rotation_offset, equatorial_grid_color, grid_spacing, grid_thickness, col);
		}
	}

	COLOR = col.rgb;
#ifdef CLOUDS_HALF_RES
	}
#endif
}
