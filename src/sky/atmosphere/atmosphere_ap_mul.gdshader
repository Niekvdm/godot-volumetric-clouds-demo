// The aerial perspective's first pass: the scene times what the air lets through. See
// atmosphere_ap.gdshaderinc. blend_mul with ALPHA 1 leaves the colour buffer's alpha as it was.
shader_type spatial;
render_mode blend_mul, cull_front, unshaded, fog_disabled, shadows_disabled;

#include "res://src/sky/atmosphere/atmosphere_ap.gdshaderinc"

void fragment() {
	ApOut o = ap_eval(SCREEN_UV, VIEWPORT_SIZE, INV_PROJECTION_MATRIX);
	ALBEDO = vec3(o.mul);
	ALPHA = 1.0;
}
