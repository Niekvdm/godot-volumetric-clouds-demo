// The flight pass's ADD quad (cloud_flight.gdshaderinc has the whole story): the
// clouds' premultiplied colour added over the multiply quad's `dst * T`, alpha
// untouched (ALPHA 0 under blend_premul_alpha: rgb = C + rgb, a = a), so FSR2's
// reactive mask stays the opaque pass's 0. Where the temporal pass does not own the
// view (mirrors, the PIP), or alpha_mode = 1, it is the single premultiplied pass
// (ALPHA = opacity) it always was.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, blend_premul_alpha,
		fog_disabled, shadows_disabled;

#include "res://src/sky/clouds/shaders/cloud_flight.gdshaderinc"

// The terms that do not depend on the pixel (the sun, the camera altitude, the sky's own
// ambient: two sky_haze() marches of PLANET_OD_STEPS each), once per VERTEX of the quad
// instead of once per pixel (card #770). Flat: every vertex computes the same value.
varying flat vec4 v_angle_mult;
varying flat vec3 v_amb;
varying flat float v_planet_blend;
// The eye veil's light column (cloud_veil_od at the eye: the same for every pixel, prompts/82).
varying flat vec2 v_eye_od;
varying flat float v_eye_sigma;

void vertex() {
	// Fullscreen in clip space (the HeatHazePass pattern): QuadMesh size 2.
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
	v_angle_mult = sky_twilight_factors(sun_dir.y);
	v_planet_blend = planet_enabled ? planet_spherical_blend(cam_altitude) : 0.0;
	v_eye_od = cloud_veil_od(CAMERA_POSITION_WORLD, CLOUD_EYE_VEIL_M);
	v_eye_sigma = (int(cloud_pf_c.w) & 16) != 0 ? cloud_eye_veil_sigma(CAMERA_POSITION_WORLD) : 0.0;
	v_amb = sky_ambient_for_clouds(sun_dir, moon_dir, v_angle_mult.xyz, cam_altitude,
			v_planet_blend, planet_radius, horizon_offset);
}

void fragment() {
	FlightPixel fp = flight_pixel(SCREEN_UV, FRAGCOORD.xy, VIEWPORT_SIZE, INV_PROJECTION_MATRIX,
			INV_VIEW_MATRIX, CAMERA_POSITION_WORLD, v_eye_sigma);
	if (cloud_debug == 9) {
		// Look-dev: magenta where the deck past the cut from under / inside it has a span (cloud_far_below_seg),
		// green where the far estimate gives it opacity.
		vec2 fs = cloud_far_below_seg(fp.ro, fp.dir, fp.t_scene);
		float tmd;
		float fa = cloud_far_alpha(fp.ro, fp.dir, fp.t_scene, tmd);
		if (fs.x < fs.y || fp.t_scene < 1e11) {
			fp.draw = true;
			fp.owned = false;
			fp.cs.T = 0.0;
		}
	}
	if (!fp.draw) {
		discard;
	}
	if (fp.eye > 0.0) {
		fp.cs = cloud_eye_veil_od(fp.dir, fp.t_scene, fp.eye, v_eye_od);
	}
	vec2 mu = vec2(dot(sun_dir, fp.dir), dot(moon_dir, fp.dir));
	SkyHaze hz = sky_haze(fp.dir.y, mu, v_angle_mult.xyz, cam_altitude, v_planet_blend, planet_radius,
			horizon_offset);
	vec3 amb = v_amb;
	vec4 r = cloud_resolve(fp.cs, fp.ro, fp.dir, cam_altitude, hz.scatter, amb, 1.0, 1.0);
	if (fp.cs.T > 0.03) {
		vec4 far = cloud_far_field(fp.ro, fp.dir, fp.t_scene, hz.scatter, amb, cam_altitude);
		r = vec4(r.rgb + fp.cs.T * far.rgb, 1.0 - fp.cs.T * (1.0 - far.a));
	}
	if (r.a <= 0.001) {
		discard;
	}
	if (cloud_debug == 9) {
		vec2 fs9 = cloud_far_below_seg(fp.ro, fp.dir, fp.t_scene);
		float tm9;
		float fa9 = cloud_far_alpha(fp.ro, fp.dir, fp.t_scene, tm9);
		if (fs9.x < fs9.y) {
			r = vec4(fa9 > 0.0 ? vec3(0.0, fa9, 0.0) : vec3(1.0, 0.0, 1.0), 1.0);
		} else if (fp.t_scene < 1e11) {
			// Geometry: red by its distance (1 at 200 km).
			r = vec4(clamp(fp.t_scene / 200000.0, 0.0, 1.0), 0.0, 0.0, 1.0);
		}
	}
	// The sky's photo tonemap on the cloud's own colour, re-premultiplied.
	vec3 c = weather_grade(apply_photo_tonemap(r.rgb / max(r.a, 1e-4), color_correction.y, color_correction.x));
	ALBEDO = c * r.a * fp.fade;
	// The multiply quad already took dst to dst * T: add the colour, leave alpha alone.
	ALPHA = fp.owned ? 0.0 : r.a * fp.fade;
}
