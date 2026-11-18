shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never, shadows_disabled;

// The GROUND's cloud-shadow map, in SUN SPACE (CloudShadowReceiver):
// texel (u, v) is the sun ray through map_center + (u - .5)·span·map_x + (v - .5)·span·map_z, the
// receiver Decal's local frame (+Y = to_sun; Godot's decal reads u along local +X, v along local +Z,
// and UV.y here is the image row). One texel is one sun ray, so a hillside, a tree top and a car
// roof each get the shadow of their own ray, exact at every height.
//
// The ray's transmittance is the sea-level march both bakes share (cloud_shadow_march.gdshaderinc)
// from where the ray meets altitude 0. Output: ALPHA = 1 - T (the decal's modulate is black and its
// albedo_mix carries the strength), feathered to 0 over the map's border so the box edge never shows.
// The viewport is transparent (clear alpha 0) and the shader blends mix with ALBEDO 0, so alpha
// lands as written.

#include "res://src/sky/shaders/planet_atmosphere.gdshaderinc"
#include "res://src/sky/clouds/shaders/cloud_params.gdshaderinc"
#include "res://src/sky/clouds/shaders/cloud_field.gdshaderinc"
#include "res://src/sky/clouds/shaders/cloud_shadow_march.gdshaderinc"

uniform vec3 map_center = vec3(0.0);
uniform vec3 map_x = vec3(1.0, 0.0, 0.0);
uniform vec3 map_z = vec3(0.0, 0.0, 1.0);
uniform vec3 to_sun = vec3(0.0, 1.0, 0.0);
uniform float map_span = 12000.0;
// The border band, as a fraction of the map, over which the shadow fades out.
uniform float feather = 0.06;

void fragment() {
	float a = 0.0;
	if (to_sun.y > 0.02) {
		vec3 p0 = map_center + (UV.x - 0.5) * map_span * map_x + (UV.y - 0.5) * map_span * map_z;
		// Down the ray to sea level.
		vec3 foot = p0 - (p0.y / to_sun.y) * to_sun;
		float t = cloud_shadow_transmittance(foot.xz, to_sun);
		vec2 e = min(UV, 1.0 - UV);
		a = (1.0 - t) * smoothstep(0.0, feather, min(e.x, e.y));
	}
	ALBEDO = vec3(0.0);
	ALPHA = a;
}
