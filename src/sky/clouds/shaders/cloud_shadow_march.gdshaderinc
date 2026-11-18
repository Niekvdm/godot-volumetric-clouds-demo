// The sun's transmittance through the volumetric cloud layer from a point at SEA LEVEL (altitude 0),
// along `to_sun` — the one march both cloud-shadow bakes share:
//   cloud_shadow_bake.gdshader     — the sea's window, a texel per world XZ (CloudShadowWindow);
//   cloud_shadow_sun_bake.gdshader — the ground's sun-space map, a texel per sun ray (CloudShadowReceiver).
// Every point of one sun ray below the cloud base has the same transmittance, so a sun ray is
// fully described by where it meets sea level.
//
// 16 steps through the stage-1 macro field at LOD 2 (the weather-scale silhouette: the CPU twin
// averages the same way, so the shadows agree with the CPU twin), with the
// multiple-scattering leak (0.8·e^-tau + 0.2·e^-tau/4: thick cloud passes a fifth of the light).
// 1.0 when the sun is at or below the horizon.
//
// Needs planet_atmosphere.gdshaderinc, cloud_params.gdshaderinc and cloud_field.gdshaderinc first.

// The optical depth along the key ray from wxz (0 when the key is at or below the horizon, or no layer).
float cloud_shadow_tau(vec2 wxz, vec3 to_sun) {
	if (to_sun.y <= 0.02) {
		return 0.0;
	}
	vec2 seg = planet_cloud_shell_segment(0.0, to_sun.y,
			cloud_layer.x, cloud_layer.y, 40000.0, PLANET_EARTH_RADIUS);
	if (seg.x >= seg.y) {
		return 0.0;
	}
	float dt = (seg.y - seg.x) / 16.0;
	float od = 0.0;
	for (int i = 0; i < 16; i++) {
		float t = seg.x + (float(i) + 0.5) * dt;
		vec3 q = vec3(wxz.x + to_sun.x * t,
				planet_altitude_along_ray(0.0, to_sun.y, t, PLANET_EARTH_RADIUS),
				wxz.y + to_sun.z * t);
		float sdf;
		vec2 vis;
		od += cloud_macro(q, q.y - cloud_layer.x, 2.0, sdf, vis) * dt;
	}
	return od * cloud_light_a.x;
}

float cloud_shadow_transmittance_tau(float tau) {
	return 0.8 * exp(-tau) + 0.2 * exp(-tau * 0.25);
}

float cloud_shadow_transmittance(vec2 wxz, vec3 to_sun) {
	return cloud_shadow_transmittance_tau(cloud_shadow_tau(wxz, to_sun));
}
