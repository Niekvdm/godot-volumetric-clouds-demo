// THE AERIAL PERSPECTIVE PASS (R27): what AtmFog did, from the physical atmosphere. Sky3D's
// full-screen fog quad (SkyDome's _FogMeshI) keeps its mesh, its material and every uniform other
// systems push into it (SeaFogPlane's sea plane, CloudBridge's cloud view, WeatherLookDriver's
// filter, WeatherEnvironment's weather fog through SkyDome); SkyAtmosphere swaps this pair in.
//
//   colour = scene * T * (1 - f) + L * (1 - f) + fog * f
// with (L, T) the aerial perspective from the camera to the pixel (atm_aerial: the haze of the
// physical atmosphere, geometry only, the sky has its own), and f the WEATHER fog (AtmFog's formula
// and parameters, unchanged, so fog banks and rain haze keep their tuning), coloured by the
// atmosphere's own horizon sky instead of Sky3D's scatter.
//
// TWO PASSES, NEITHER WRITES THE COLOUR BUFFER'S ALPHA (FSR2 reads it as its reactive mask,
// fd1ca97ac): atmosphere_ap_mul multiplies by T (1 - f) (blend_mul, ALPHA 1: alpha x 1), then
// atmosphere_ap_add adds L (1 - f) + fog f (blend_premul_alpha, ALPHA 0: alpha untouched).
// Pure blending: the ocean drawn earlier in the transparent pass is fogged too (a screen-texture
// read would not see it).

#include "res://src/sky/atmosphere/atmosphere.gdshaderinc"

uniform float fog_density = .0001;
uniform float fog_falloff = 3.;
uniform float fog_start = 0.;
uniform float fog_end = 1000.;
// filter_nearest: a filtered depth blends a near edge with the sky behind it (reverse-Z 0), so the edge pixel read as
// far and took a far pixel's haze: a bright outline round poles, wires and roof edges in rain or fog (owner prompts/20).
uniform sampler2D DEPTH_TEXTURE : hint_depth_texture, filter_nearest;
// Fog the sea SURFACE, not the seabed behind it (a sea plane at sea_plane_y).
uniform bool sea_plane_enabled = false;
uniform float sea_plane_y = 0.;
// Fog a volumetric cloud at the cloud's own distance, not by what lies behind it (CloudBridge pushes these).
uniform sampler2D cloud_view_tex : filter_linear, repeat_disable;
uniform bool cloud_view_live = false;
uniform vec2 cloud_view_size = vec2(0.0);
#include "res://src/weather/shaders/weather_grade_material.gdshaderinc"

varying mat4 camera_matrix;

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
	camera_matrix = INV_VIEW_MATRIX;
}

// x: what multiplies the scene, rgb of .yzw unused; returned with the light to add.
struct ApOut {
	float mul;
	vec3 add;
};

ApOut ap_eval(vec2 screen_uv, vec2 viewport_size, mat4 inv_proj) {
	float depth_raw = texture(DEPTH_TEXTURE, screen_uv).r;
	vec3 ndc = vec3(screen_uv * 2.0 - 1.0, depth_raw);
	vec4 view4 = inv_proj * vec4(ndc, 1.0);
	vec3 view = view4.xyz / view4.w;
	vec3 dir = normalize((camera_matrix * vec4(view, 0.0)).xyz);
	// Reverse Z: the cleared far plane is 0. The sky's air is in the sky itself.
	bool sky = depth_raw <= 1e-7;
	float linear_depth = -view.z;
	float cos_fwd = linear_depth / max(length(view), 1e-6);
	if (sea_plane_enabled) {
		vec3 cam_w = camera_matrix[3].xyz;
		if (cam_w.y > sea_plane_y && dir.y < -1e-5) {
			float sea_depth = ((sea_plane_y - cam_w.y) / dir.y) * cos_fwd;
			if (sea_depth > 0.0 && (sky || sea_depth < linear_depth)) {
				linear_depth = sea_depth;
				sky = false;
			}
		}
	}
	float t_cloud = 1.0;
	if (cloud_view_live && all(lessThan(abs(viewport_size - cloud_view_size), vec2(1.5)))) {
		vec4 cv = textureLod(cloud_view_tex, screen_uv, 0.0);
		t_cloud = clamp(cv.b, 0.0, 1.0);
		float cloud_z = cv.a * 1000.0 * cos_fwd;
		if (t_cloud < 0.999 && (sky || cloud_z < linear_depth)) {
			linear_depth = sky ? cloud_z : mix(cloud_z, linear_depth, t_cloud);
		}
	}
	// The weather's fog (AtmFog's three terms, the same uniforms).
	float f = 1.0 - clamp(exp2(-linear_depth * fog_density), 0.0, 1.0);
	f *= clamp(exp(-dir.y * fog_falloff), 0.0, 1.0);
	f *= clamp(1.0 - (fog_end - linear_depth) / max(fog_end - fog_start, 1e-3), 0.0, 1.0);
	ApOut o;
	o.mul = 1.0 - f;
	o.add = vec3(0.0);
	if (!sky) {
		// Geometry only: the sky, and a cloud the sky pass composites, carry their own air (the
		// cloud's distance above only moves the weather fog, as in AtmFog).
		vec4 ap = atm_aerial(dir, linear_depth / max(cos_fwd, 1e-4));
		o.mul *= ap.a;
		// + the towns' glow on the haze in front of it (atm_town, 0 by day): it converges on the horizon's.
		o.add = weather_grade(ap.rgb + atm_town.rgb * (1.0 - ap.a)) * (1.0 - f);
	}
	if (f > 0.0005) {
		// Dense haze converges on the horizon sky's colour (grey under a closed deck, dark at night).
		vec3 hd = normalize(vec3(dir.x, max(dir.y, 0.035), dir.z));
		o.add += weather_grade(atm_sky_radiance(hd) + atm_night_sky(hd)) * f;
	}
	return o;
}
