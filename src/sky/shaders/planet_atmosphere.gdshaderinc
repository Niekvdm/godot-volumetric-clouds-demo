// Planet geometry + atmosphere, shared by planet_sky.gdshader and
// ocean_t3d.gdshader so near and far water agree on haze by construction.
//
// LOCKSTEP with src/sky/planet_geometry.gd — that file is where this maths is
// unit-tested, because a shader cannot be. Change one, change both.
//
// Every formulation here is chosen for float32 stability. See the GDScript
// file's comments for why the textbook forms are unusable: measured, the
// naive ray-sphere near root returns 1.5 m for a true 1.7 m.

const float PLANET_EARTH_RADIUS = 6371000.0;
const float PLANET_RAYLEIGH_H = 8500.0;
const float PLANET_MIE_H = 1200.0;
const float PLANET_ATMOSPHERE_TOP = 60000.0;
// Measured worst-case error vs a 1024-sample reference: 8 steps → 3.2%,
// 16 → 0.81%. The worst case is an upward ray from sea level. Do not drop
// this to 8; PlanetGeometry.OPTICAL_DEPTH_STEPS must match it.
const int PLANET_OD_STEPS = 16;

// Altitude band over which the true spherical optical depth takes over from
// Sky3D's flat-earth analytic form. LOW is above the 854 m summit of
// Hachijo-Fuji, the highest ground on the map, so the blend is EXACTLY 0.0
// everywhere a player can walk or drive and sea-level output is unchanged by
// construction. Mirrored by PlanetGeometry.BLEND_LOW / BLEND_HIGH.
const float PLANET_BLEND_LOW = 1000.0;
const float PLANET_BLEND_HIGH = 8000.0;

// Mirrors PlanetGeometry.spherical_blend(). Exactly 0.0 at or below LOW.
float planet_spherical_blend(float h) {
	return smoothstep(PLANET_BLEND_LOW, PLANET_BLEND_HIGH, h);
}

// Line-of-sight distance to the horizon: sqrt(2Rh + h^2).
float planet_horizon_distance(float h, float radius) {
	float a = max(h, 0.0);
	return sqrt(2.0 * radius * a + a * a);
}

// Angle the horizon sits BELOW the local horizontal: acos(R/(R+h)).
// Mirrors PlanetGeometry.horizon_dip().
float planet_horizon_dip(float h, float radius) {
	float a = max(h, 0.0);
	return acos(clamp(radius / (radius + a), -1.0, 1.0));
}

// Distance to the planet surface along a view ray, or -1.0 on a miss.
// Reciprocal root: t_near = c / t_far. The textbook -b - sqrt(b*b - c) is
// catastrophic cancellation in float32 (11.76% error at eye height).
float planet_ground_hit(float h, float dir_y, float radius) {
	if (dir_y >= 0.0) {
		return -1.0;
	}
	float a = max(h, 0.0);
	float c = 2.0 * radius * a + a * a;
	float b = (radius + a) * dir_y;
	float disc = b * b - c;
	if (disc < 0.0) {
		return -1.0;
	}
	return c / (-b + sqrt(disc));
}

// Distance along a view ray to a concentric shell at `shell_alt` metres above
// sea level, or -1.0 on a miss. Mirrors PlanetGeometry.shell_hit_distance().
// Below the shell we are inside it and one root is positive; above it we need a
// downward ray and the NEAR root, which is the cloud TOP.
//
// STABILITY: this runs in float32, where b*b ~ 4e13 has no digits to spare.
// Neither root may be formed by subtraction — measured, the naive inside root
// loses 10% with the camera just below the deck. See the GDScript mirror for
// the derivation. -c/(b + root) inside, c/(-b + root) outside; both
// denominators are sums of positives.
float planet_shell_hit(float h, float dir_y, float shell_alt, float radius) {
	float a = max(h, 0.0);
	float ro = radius + a;
	float b = ro * dir_y;
	float c = (a - shell_alt) * (2.0 * radius + a + shell_alt);
	float disc = b * b - c;
	if (disc < 0.0) {
		return -1.0;
	}
	float root = sqrt(disc);
	if (c < 0.0) {
		return -c / (b + root);
	}
	if (dir_y >= 0.0) {
		return -1.0;
	}
	return c / (-b + root);
}

// Altitude above sea level at distance t along a view ray. Difference of
// squares, because length(O + t*d) - R subtracts two numbers near 6.37e6.
float planet_altitude_along_ray(float h, float dir_y, float t, float radius) {
	float a = max(h, 0.0);
	float c = 2.0 * radius * a + a * a;
	float b = (radius + a) * dir_y;
	float num = c + 2.0 * t * b + t * t;
	return num / (sqrt(radius * radius + num) + radius);
}

// Distance to the top of the atmosphere shell. The camera is always inside,
// so c < 0 and the far root is a sum of positives.
float planet_atmosphere_exit(float h, float dir_y, float radius) {
	float a = max(h, 0.0);
	float top = radius + PLANET_ATMOSPHERE_TOP;
	float ro = radius + a;
	float b = ro * dir_y;
	float c = ro * ro - top * top;
	return -b + sqrt(max(b * b - c, 0.0));
}

// Distance to where a view ray ENTERS the atmosphere shell: 0.0 if the camera
// is already inside (h <= PLANET_ATMOSPHERE_TOP), negative if the ray misses
// the shell entirely. Otherwise the near root.
//
// Mirrors PlanetGeometry.atmosphere_entry(). Same shape as planet_shell_hit's
// outside branch, with PLANET_ATMOSPHERE_TOP as the shell offset: c is formed
// from the altitude DIFFERENCE so it stays well-conditioned close to the
// shell, and the near root uses the reciprocal form c / (-b + sqrt(disc)) —
// -b - sqrt(disc) cancels the same way planet_ground_hit's naive form does.
float planet_atmosphere_entry(float h, float dir_y, float radius) {
	float a = max(h, 0.0);
	if (a <= PLANET_ATMOSPHERE_TOP) {
		return 0.0;
	}
	if (dir_y >= 0.0) {
		return -1.0;
	}
	float ro = radius + a;
	float b = ro * dir_y;
	float c = (a - PLANET_ATMOSPHERE_TOP) * (2.0 * radius + a + PLANET_ATMOSPHERE_TOP);
	float disc = b * b - c;
	if (disc < 0.0) {
		return -1.0;
	}
	return c / (-b + sqrt(disc));
}

// Optical depth in metres of equivalent sea-level column. Midpoint rule.
// Rays that strike the planet stop at the surface.
float planet_optical_depth(float h, float dir_y, float scale_height, int steps,
		float radius) {
	float t_end = planet_atmosphere_exit(h, dir_y, radius);
	float t_ground = planet_ground_hit(h, dir_y, radius);
	if (t_ground >= 0.0) {
		t_end = min(t_end, t_ground);
	}
	if (t_end <= 0.0) {
		return 0.0;
	}
	float dt = t_end / float(steps);
	float total = 0.0;
	for (int i = 0; i < steps; i++) {
		float t = (float(i) + 0.5) * dt;
		float alt = planet_altitude_along_ray(h, dir_y, t, radius);
		total += exp(-max(alt, 0.0) / scale_height) * dt;
	}
	return total;
}

// Rayleigh AND Mie optical depth in ONE pass. Both share the ray march, the
// altitude evaluation and the sphere intersections — only the exp() differs.
// Callers need both, so this halves the work versus two separate calls.
vec2 planet_optical_depth_pair(float h, float dir_y, int steps, float radius) {
	float t_end = planet_atmosphere_exit(h, dir_y, radius);
	float t_ground = planet_ground_hit(h, dir_y, radius);
	if (t_ground >= 0.0) {
		t_end = min(t_end, t_ground);
	}
	if (t_end <= 0.0) {
		return vec2(0.0);
	}
	float dt = t_end / float(steps);
	vec2 total = vec2(0.0);
	for (int i = 0; i < steps; i++) {
		float t = (float(i) + 0.5) * dt;
		float alt = max(planet_altitude_along_ray(h, dir_y, t, radius), 0.0);
		total += vec2(exp(-alt / PLANET_RAYLEIGH_H), exp(-alt / PLANET_MIE_H)) * dt;
	}
	return total;
}

// Fog a colour toward the haze colour using Beer-Lambert extinction over the
// given optical depths. Both the sky's sea and the ocean shader's far
// distances call THIS, with the same betas, which is what makes the seam
// between near and far water vanish rather than merely be hidden.
vec3 planet_aerial_perspective(vec3 col, vec3 haze, vec2 od, vec3 beta_ray,
		vec3 beta_mie) {
	vec3 transmittance = exp(-(beta_ray * od.x + beta_mie * od.y));
	return mix(haze, col, clamp(transmittance, vec3(0.0), vec3(1.0)));
}

// Mirrors PlanetGeometry.shell_far_root(): the far root of a shell seen from
// OUTSIDE (camera above it). -1 from inside or on a miss.
float planet_shell_far_root(float h, float dir_y, float shell_alt, float radius) {
	float a = max(h, 0.0);
	float c = (a - shell_alt) * (2.0 * radius + a + shell_alt);
	if (c < 0.0 || dir_y >= 0.0) {
		return -1.0;
	}
	float b = (radius + a) * dir_y;
	float disc = b * b - c;
	if (disc < 0.0) {
		return -1.0;
	}
	return -b + sqrt(disc);
}

// Mirrors PlanetGeometry.cloud_shell_segment(): (t0, t1) of the ray inside the
// cloud layer, empty when t0 >= t1.
vec2 planet_cloud_shell_segment(float h, float dir_y, float base, float top,
		float max_dist, float radius) {
	float tb = planet_shell_hit(h, dir_y, base, radius);
	float tt = planet_shell_hit(h, dir_y, top, radius);
	vec2 s = vec2(1.0, 0.0);
	if (h < base) {
		if (tb >= 0.0) {
			s = vec2(tb, tt);
		}
	} else if (h > top) {
		if (tt >= 0.0) {
			s = vec2(tt, tb >= 0.0 ? tb : planet_shell_far_root(h, dir_y, top, radius));
		}
	} else {
		s = vec2(0.0, min(tt >= 0.0 ? tt : 1e12, tb >= 0.0 ? tb : 1e12));
	}
	float tg = planet_ground_hit(h, dir_y, radius);
	if (tg >= 0.0) {
		s.y = min(s.y, tg);
	}
	s.y = min(s.y, max_dist);
	return s;
}

// Mirrors PlanetGeometry.optical_depth_pair_to(): optical depth over [0, t_end].
vec2 planet_optical_depth_pair_to(float h, float dir_y, float t_end, int steps,
		float radius) {
	if (t_end <= 0.0) {
		return vec2(0.0);
	}
	float te = min(t_end, planet_atmosphere_exit(h, dir_y, radius));
	float tg = planet_ground_hit(h, dir_y, radius);
	if (tg >= 0.0) {
		te = min(te, tg);
	}
	float dt = te / float(steps);
	vec2 total = vec2(0.0);
	for (int i = 0; i < steps; i++) {
		float alt = max(planet_altitude_along_ray(h, dir_y, (float(i) + 0.5) * dt, radius), 0.0);
		total += vec2(exp(-alt / PLANET_RAYLEIGH_H), exp(-alt / PLANET_MIE_H)) * dt;
	}
	return total;
}

// Altitude above which Sky3D's own atmospheric scatter (day-sky colour /
// twilight glow) retires. The atmosphere's post-process owns aerial perspective now;
// running Sky3D's dome as well above the real shell would fog the view
// twice. Starmap, Milky Way, sun disk and moon disk are NOT gated by this.
const float PLANET_KARMAN_LINE = 100000.0;

// Mirrors PlanetGeometry.atmosphere_scatter_fade(). Exactly 1.0 at and below
// PLANET_ATMOSPHERE_TOP, exactly 0.0 at and above PLANET_KARMAN_LINE — keep
// in LOCKSTEP with the GDScript twin.
float planet_atmosphere_scatter_fade(float h) {
	return 1.0 - smoothstep(PLANET_ATMOSPHERE_TOP, PLANET_KARMAN_LINE, h);
}
