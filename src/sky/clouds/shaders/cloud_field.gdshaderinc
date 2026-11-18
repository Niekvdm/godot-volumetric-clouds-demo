// Volumetric cloud density: the procedural field's entry points. Needs cloud_params.gdshaderinc first.
//   p = (world x, altitude above sea level, world z); h = altitude - cloud base.
// Every consumer (the march, the light ray, the rain shafts, the slope veil, the cloud shadows) reads
// the field through these; the field itself is cloud_pf_field.gdshaderinc, its march cloud_pf_march.
#ifndef CLOUD_FIELD_INC
#define CLOUD_FIELD_INC
#include "res://src/sky/clouds/shaders/cloud_pf_field.gdshaderinc"

// The dimensional-profile depth the lighting and the march share (metres).
const float CLOUD_PROFILE_M = 240.0;

// The cloud type's channel weights (deck, cumulus, cumulonimbus) for a type 0..1 (CloudWeather.type_from:
// 0 stratus, 0.25 stratocumulus, 0.5 cumulus, 1 cumulonimbus).
vec3 cloud_type_weights(float t) {
	float wd = clamp(1.0 - 2.0 * t, 0.0, 1.0);
	float wb = clamp(2.0 * t - 1.0, 0.0, 1.0);
	return vec3(wd, 1.0 - wd - wb, wb);
}

// The stratus weight: 1 at the deck, 0 from stratocumulus up (LOCKSTEP with CloudWeather.stratus_weight).
float cloud_stratus_weight(float t) {
	return clamp(1.0 - 4.0 * t, 0.0, 1.0);
}

// DEPTH SCALE (cloud_shape.z, CloudWeather.depth_scale_for): fair-weather cumulus is shallow.
// 0 (an unpushed global) reads as full depth.
float cloud_depth_scale() {
	return cloud_shape.z > 0.0 ? cloud_shape.z : 1.0;
}

// The field's stand-in depth inside a cloud at full density (vis.x below; the rain march reads it back).
const float CLOUD_PF_DEPTH_M = 600.0;

// Density (x cloud_layer.z) at p, with no distance bound (sdf_m 0: never skip) and the density standing in
// for the depth inside (`vis`: the rain's cores, the slope veil): CLOUD_PF_DEPTH_M at full density.
// `base_lod` picks the erosion's mip from the step length. smooth_h (the ground shadows' march, the far
// field): the proxy when cloud_pf_c.w bit 2048 (pf_proxy_shadow) is set; the rain's column probes
// (smooth_h false) keep the envelope.
float cloud_macro_q(vec3 p, float h, float base_lod, bool smooth_h, out float sdf_m, out vec2 vis) {
	sdf_m = 0.0;
	vis = vec2(1e6, 0.0);
	if (h <= 0.0 || p.y >= cloud_layer.y) {
		return 0.0;
	}
	float d = cloud_pf_density(p, h, false, 16.0 * exp2(base_lod + 1.0), smooth_h && (int(cloud_pf_c.w) & 2048) != 0);
	vis.x = d > 0.0 ? -CLOUD_PF_DEPTH_M * d / max(cloud_layer.z, 1e-3) : 1e6;
	return d;
}

float cloud_macro(vec3 p, float h, float base_lod, out float sdf_m, out vec2 vis) {
	return cloud_macro_q(p, h, base_lod, true, sdf_m, vis);
}

// The density with the close-up erosion. `dist` = distance from the camera; `lod` = noise mip chosen from
// the step length (removes step-vs-texel speckle). `vis_d`: no distance bound (1e6).
float cloud_density_v(vec3 p, float h, float dist, float lod, out float sdf_m, out float vis_d) {
	sdf_m = 0.0;
	vis_d = 1e6;
	return h > 0.0 ? cloud_pf_density(p, h, true, 16.0 * exp2(lod), false) : 0.0;
}

float cloud_density(vec3 p, float h, float dist, float lod, out float sdf_m) {
	float vis_d;
	return cloud_density_v(p, h, dist, lod, sdf_m, vis_d);
}

#endif
