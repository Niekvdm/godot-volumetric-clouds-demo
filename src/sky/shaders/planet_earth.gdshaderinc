// Earth far field: ECEF -> equirectangular UV, and the tier sampling.
//
// LOCKSTEP with src/sky/geo_reference.gd. The ECEF convention is fixed there
// and must not be re-derived here: sphere; +X through (lat 0, lon 0), +Y
// through (lat 0, lon 90E), +Z through the north pole.
//
// The camera's ECEF position and ENU basis are computed on the CPU in doubles
// by PlanetHorizon; this file only rotates a view ray and reads a texture. That
// split is deliberate -- the projection maths wants double precision and the
// GPU has none, but a rotate-and-add at Earth radius still resolves ~0.4 m in
// float32, far below what any of these textures show.

// Equirectangular UV from an ECEF direction. u wraps at the antimeridian,
// v is 0 at the north pole and 1 at the south -- the standard layout every
// Blue Marble tile ships in.
vec2 planet_ecef_to_equirect(vec3 ecef) {
	vec3 n = normalize(ecef);
	float lat = asin(clamp(n.z, -1.0, 1.0));
	float lon = atan(n.y, n.x);
	return vec2(0.5 + lon / TAU, 0.5 - lat / PI);
}

// Godot world axes -> ENU. Confirmed from bake_farfield.gd, not assumed:
// world +X is EAST, world -Z is NORTH, world +Y is UP.
vec3 planet_world_dir_to_enu(vec3 world_dir) {
	return vec3(world_dir.x, -world_dir.z, world_dir.y);
}
