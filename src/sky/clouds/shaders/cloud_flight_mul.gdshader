// The flight pass's MULTIPLY quad (cloud_flight.gdshaderinc has the whole story):
// takes what lies behind the clouds to dst * T before the add quad adds their colour.
// blend_mul is rgb = ALBEDO * rgb, a = ALPHA * a: ALPHA 1 leaves alpha (FSR2's reactive
// mask) as it was. Only where the temporal pass owns the view and alpha_mode = 0:
// elsewhere the add quad keeps its single premultiplied pass and this one discards.
// Lighting-free: the history's transmittance (and the far deck's opacity) only.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, blend_mul,
		fog_disabled, shadows_disabled;

#include "res://src/sky/clouds/shaders/cloud_flight.gdshaderinc"

// cloud_eye_veil_sigma at the camera, once per vertex (prompts/82).
varying flat float v_eye_sigma;

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
	v_eye_sigma = (int(cloud_pf_c.w) & 16) != 0 ? cloud_eye_veil_sigma(CAMERA_POSITION_WORLD) : 0.0;
}

void fragment() {
	FlightPixel fp = flight_pixel(SCREEN_UV, FRAGCOORD.xy, VIEWPORT_SIZE, INV_PROJECTION_MATRIX,
			INV_VIEW_MATRIX, CAMERA_POSITION_WORLD, v_eye_sigma);
	if (!fp.draw || !fp.owned) {
		discard;
	}
	float a = flight_opacity(fp);
	if (a <= 0.001) {
		discard;
	}
	ALBEDO = vec3(1.0 - a);
	ALPHA = 1.0;
}
