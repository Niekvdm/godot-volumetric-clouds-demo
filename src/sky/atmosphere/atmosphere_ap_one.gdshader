// The aerial perspective in ONE pass (SkyAtmosphere.ap_single_pass): the scene times what the air lets through
// plus the light it scatters in, as one premultiplied blend (dst x mul + add: ALPHA = 1 - mul). It writes the
// colour buffer's alpha, which FSR2 reads as its reactive mask (fd1ca97ac): used only while FSR2 is off; the
// mul + add pair (atmosphere_ap_mul / _add) is the FSR2-safe form. See atmosphere_ap.gdshaderinc.
shader_type spatial;
render_mode blend_premul_alpha, cull_front, unshaded, fog_disabled, shadows_disabled;

#include "res://src/sky/atmosphere/atmosphere_ap.gdshaderinc"

void fragment() {
	ApOut o = ap_eval(SCREEN_UV, VIEWPORT_SIZE, INV_PROJECTION_MATRIX);
	ALBEDO = o.add;
	ALPHA = 1.0 - o.mul;
}
