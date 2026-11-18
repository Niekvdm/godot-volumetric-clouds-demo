// The aerial perspective's second pass: the light the air scatters in, and the weather's fog. See
// atmosphere_ap.gdshaderinc. blend_premul_alpha with ALPHA 0 adds the colour, the alpha untouched.
shader_type spatial;
render_mode blend_premul_alpha, cull_front, unshaded, fog_disabled, shadows_disabled;

#include "res://src/sky/atmosphere/atmosphere_ap.gdshaderinc"

void fragment() {
	ApOut o = ap_eval(SCREEN_UV, VIEWPORT_SIZE, INV_PROJECTION_MATRIX);
	ALBEDO = o.add;
	ALPHA = 0.0;
}
