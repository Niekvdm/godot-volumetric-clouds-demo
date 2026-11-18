// Volumetric clouds IN FRONT OF GEOMETRY: fullscreen quads in
// the transparent queue that composite the SAME cloud field as the sky pass, from
// the camera to the scene — the depth buffer, or the sea-level sphere, since the
// ocean is transparent and absent from the depth texture (the shell segment ends
// at the ground hit on its own).
//
// Own every geometry pixel and every downward sky pixel; the sky pass keeps
// upward sky pixels (CloudPartition — LOCKSTEP, test_cloud_partition). The sky
// pass draws behind all geometry, so without this the ocean mesh hid the whole
// deck below anyone above the cloud base.
//
// TWO QUADS, NO ALPHA (A2, 2026-11-15). Godot hands FSR2 the colour buffer's alpha
// as its reactive mask (the opaque pass and the sky write 0). One premultiplied quad
// writing ALPHA = opacity marked every cloud-over-geometry pixel reactive. So the
// main view composites `dst * T + C` in two quads that leave alpha alone (the
// heat-haze pattern, fd1ca97ac):
//   * cloud_flight_mul.gdshader: blend_mul, ALBEDO = T, ALPHA = 1 -> rgb * T, a * 1;
//   * cloud_flight.gdshader:     blend_premul_alpha, ALBEDO = C, ALPHA = 0 -> rgb + C, a.
// The multiply quad draws first (CloudBridge: a lower sorting offset). Views the
// temporal pass does not own (mirrors, the PIP) march per pixel: there the add quad
// keeps the single premultiplied pass (ALPHA = opacity) and the multiply quad
// discards, so a march is never run twice. `alpha_mode` 1 forces that single pass
// everywhere (the A/B switch, CloudBridge.flight_alpha_legacy).
//
// Draw order (CloudBridge): render_priority = ocean + 1 with sorting offsets
// -2e7 (multiply) and -1e7 (add), i.e. after the transparent ocean and before
// AtmFog (also ocean + 1) and rain. Colour parity with the sky pass: the SAME
// includes and cloud_resolve(), the sky material's atmosphere uniforms mirrored
// every frame, the sky's photo tonemap on the cloud colour.
#include "res://src/sky/shaders/planet_atmosphere.gdshaderinc"
// The physical atmosphere BEFORE the march, as the sky body includes it: with it enabled the clouds'
// key, ambient and haze come from its tables in the sky pass and here alike (cloud_march's seam).
#include "res://src/sky/atmosphere/atmosphere.gdshaderinc"
#include "res://src/sky/shaders/twilight.gdshaderinc"
#include "res://addons/sky_3d/shaders/Common.gdshaderinc"
#include "res://src/sky/shaders/sky_scatter.gdshaderinc"
#include "res://src/sky/clouds/shaders/cloud_params.gdshaderinc"
#include "res://src/sky/clouds/shaders/cloud_field.gdshaderinc"
#include "res://src/sky/clouds/shaders/cloud_light.gdshaderinc"
#include "res://src/sky/clouds/shaders/cloud_march.gdshaderinc"
#include "res://src/weather/shaders/weather_grade_material.gdshaderinc"

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;

// Mirrored from the sky material by CloudBridge (same names as there).
uniform float cam_altitude = 0.0;
uniform float planet_radius = 6371000.0;
uniform bool planet_enabled = true;
uniform float horizon_offset = 0.0;
uniform vec2 color_correction = vec2(0.0, 1.0);
uniform float cloud_fade_start = 10000.0;
uniform float cloud_fade_end = 25000.0;
// Pushed by CloudBridge: directions TO the sun and moon (world).
uniform vec3 sun_dir = vec3(0.0, 1.0, 0.0);
uniform vec3 moon_dir = vec3(0.0, -1.0, 0.0);
// 0 = the two-quad composite that writes no alpha (the main view); 1 = the single
// premultiplied pass writing ALPHA = opacity everywhere (the pre-A2 path, for A/B).
uniform int alpha_mode = 0;

// Distance along the ray to the opaque surface at a screen uv (1e12 = none).
float scene_t(vec2 uv, mat4 inv_proj) {
	float raw = textureLod(depth_tex, uv, 0.0).r;
	if (raw <= 0.0) {
		return 1e12;
	}
	vec4 vp = inv_proj * vec4(uv * 2.0 - 1.0, raw, 1.0);
	return length(vp.xyz / vp.w);
}

// The temporal pass's half-res history, upsampled for THIS pixel: bilinear
// weights times the agreement of each tap's scene distance with ours (in log
// space), so a peak's silhouette neither takes the sky's cloud behind it nor
// leaks its own onto the sky.
CloudSample cloud_view_bilateral(vec2 uv, float t_px, mat4 inv_proj) {
	vec2 hs = vec2(textureSize(cloud_view, 0));
	vec2 tc = uv * hs - 0.5;
	vec2 b = floor(tc);
	vec2 f = tc - b;
	float lp = log(max(t_px, 1.0));
	vec4 acc = vec4(0.0);
	float ws = 0.0;
	for (int y = 0; y < 2; y++) {
		for (int x = 0; x < 2; x++) {
			vec2 q = clamp(b + vec2(float(x), float(y)), vec2(0.0), hs - 1.0);
			float tq = scene_t((q + 0.5) / hs, inv_proj);
			float wb = (x == 1 ? f.x : 1.0 - f.x) * (y == 1 ? f.y : 1.0 - f.y);
			float w = wb * (exp(-4.0 * abs(log(max(tq, 1.0)) - lp)) + 1e-4);
			acc += texelFetch(cloud_view, ivec2(q), 0) * w;
			ws += w;
		}
	}
	return cloud_view_decode(acc / max(ws, 1e-6));
}

// What the flight pass knows about one pixel before it lights anything.
struct FlightPixel {
	bool draw;      // false: nothing of the clouds in front of the scene here
	bool owned;     // the temporal pass owns this view (the two-quad composite applies)
	bool above;     // the camera is over the layer (the far field continues the march)
	vec3 ro;
	vec3 dir;
	float t_scene;
	float fade;     // the altitude fade (cloud_fade_start .. _end)
	float eye;      // > 0: the eye veil's sigma; cs.T is its slab to the scene, the add quad lights it (prompts/82)
	CloudSample cs;
};

// eye_sigma: cloud_eye_veil_sigma at the camera (it depends on the eye alone: each quad takes it once per vertex).
FlightPixel flight_pixel(vec2 screen_uv, vec2 frag, vec2 vp_size, mat4 inv_proj, mat4 inv_view, vec3 cam_pos,
		float eye_sigma) {
	FlightPixel fp;
	fp.draw = false;
	fp.owned = false;
	fp.above = false;
	fp.t_scene = 1e12;
	fp.fade = 1.0;
	fp.eye = 0.0;
	fp.ro = cam_pos;
	fp.dir = vec3(0.0, 1.0, 0.0);
	fp.cs.key_w = 0.0;
	fp.cs.amb_w = 0.0;
	fp.cs.T = 1.0;
	fp.cs.depth_m = 0.0;
	if (cloud_mode != 1 || (cloud_flags & 1) == 0) {
		return fp;
	}
	vec2 ndc_xy = screen_uv * 2.0 - 1.0;
	// Direction from the near plane (reverse-Z: 1), which is finite for sky pixels too.
	vec4 vn = inv_proj * vec4(ndc_xy, 1.0, 1.0);
	fp.dir = normalize((inv_view * vec4(normalize(vn.xyz / vn.w), 0.0)).xyz);
	float raw = texture(depth_tex, screen_uv).r;
	// Reverse-Z clears to 0: nothing opaque there.
	bool is_sky = raw <= 0.0;
	if (is_sky && fp.dir.y >= 0.0) {
		return fp;
	}
	if (!is_sky) {
		vec4 vp = inv_proj * vec4(ndc_xy, raw, 1.0);
		fp.t_scene = length(vp.xyz / vp.w);
	}
	// The common case on the ground: the ray meets the scene before the shell the march
	// draws in (cloud_draw_shell: the layer, the rain's reach and the slope veil's band under
	// its base). The temporal trace marched such a pixel past the scene (cloud_trace_t_max):
	// its history holds the cloud BEHIND the surface, which must not draw over it.
	fp.above = fp.ro.y > cloud_layer.y;
	// The deck past the cut from under / inside it (cloud_far_alpha_below) draws where the march has nothing.
	vec2 far_seg = cloud_far_below_seg(fp.ro, fp.dir, fp.t_scene);
	bool far_below = far_seg.x < far_seg.y;
	if (cloud_nothing_before(fp.ro, fp.dir, fp.t_scene)) {
		// The eye in the veil (prompts/82): nothing of the march in front of this surface, but the slab round the eye
		// is, to the surface's own distance - per pixel, so no history texel straddles a silhouette.
		fp.eye = eye_sigma;
		if (fp.eye > 0.0) {
			fp.cs.T = exp(-fp.eye * min(fp.t_scene, CLOUD_EYE_VEIL_M));
			fp.cs.depth_m = min(1.0 / fp.eye, 0.5 * min(fp.t_scene, CLOUD_EYE_VEIL_M));
			fp.owned = alpha_mode == 0 && cloud_view_owns(vp_size, false);
		}
		if (far_below || fp.eye > 0.0) {
			fp.fade = 1.0 - smoothstep(cloud_fade_start, cloud_fade_end, cam_altitude);
			fp.draw = true;
		}
		return fp;
	}
	fp.owned = alpha_mode == 0 && cloud_view_owns(vp_size, false);
	if (cloud_view_owns(vp_size, false)) {
		// The main view: the temporal pass already marched it (at the scene
		// distance, from the same depth buffer) and integrated the noise.
		fp.cs = cloud_view_bilateral(screen_uv, fp.t_scene, inv_proj);
	} else {
		vec2 bn = cloud_blue(frag);
		fp.cs = cloud_march_to(fp.ro, fp.dir, fp.t_scene, bn.x, bn.y, false,
				int(cloud_q_flight.x), int(cloud_q_flight.y));
	}
	if (fp.cs.T >= 0.999 && !fp.above && !far_below) {
		return fp;
	}
	fp.fade = 1.0 - smoothstep(cloud_fade_start, cloud_fade_end, cam_altitude);
	fp.draw = true;
	return fp;
}

// The pixel's opacity as the add pass composites it (the far deck behind the march
// included when the camera is over the layer), with the altitude fade.
float flight_opacity(FlightPixel fp) {
	float a = 1.0 - fp.cs.T;
	if (fp.cs.T > 0.03) {
		float tm;
		float fa = cloud_far_alpha(fp.ro, fp.dir, fp.t_scene, tm);
		a = 1.0 - fp.cs.T * (1.0 - fa);
	}
	return a * fp.fade;
}
