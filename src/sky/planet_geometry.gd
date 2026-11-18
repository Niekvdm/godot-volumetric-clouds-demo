class_name PlanetGeometry
extends RefCounted

## Pure planet/atmosphere maths shared — as formulas, not as calls — with
## src/sky/shaders/planet_atmosphere.gdshaderinc. Keep the two in LOCKSTEP:
## the shader cannot be unit-tested, so this file is where the maths is
## proven. Same arrangement as WaveShoaling ↔ ocean_t3d.gdshader.
##
## Conventions: altitudes are metres above sea level, and sea level is exactly
## world y=0 on every map by import convention. `dir_y` is the Y component of
## a NORMALISED view direction; negative is downward.

const EARTH_RADIUS_M := 6371000.0
## Rayleigh (molecular) scale height — also the atmospheric-thinning constant.
const RAYLEIGH_H := 8500.0
## Mie (aerosol) scale height.
const MIE_H := 1200.0
## Top of the modelled atmosphere shell. Above this, density is treated as 0.
const ATMOSPHERE_TOP_M := 60000.0
## Production sample count for optical_depth(). Measured worst-case error
## against a 1024-sample reference across the altitude × direction grid:
##   8 steps → 3.2%   16 → 0.81%   24 → 0.36%   32 → 0.20%
## The worst case is an UPWARD ray from sea level, where uniform steps across
## the 60 km shell under-sample the dense bottom. 16 clears a 2% bar with
## margin; do not drop it to 8 (test_planet_geometry.gd asserts 8 fails).
const OPTICAL_DEPTH_STEPS := 16
## Far-plane ceiling. Set from the depth probe (tools/sky/depth_probe.gd):
## Vulkan/Forward+ resolves 0.5 m at 100 km with a 0.05 m near plane, so the
## reverse-Z depth buffer holds and 150 km is safe.
const FAR_CEILING := 150000.0
## Fraction of the camera far plane the ocean sheet is driven out to, so its
## outermost ring stays inside the frustum that clips it. far_plane() divides by
## it, PlanetHorizon multiplies by it, so the two cannot drift.
const HORIZON_MARGIN := 0.94
## Altitude band over which the true spherical optical depth takes over from
## Sky3D's flat-earth analytic form. Below LOW the analytic form is
## authoritative; above HIGH the spherical march is.
##
## LOW is deliberately ABOVE the 854 m summit of Hachijo-Fuji, the highest
## ground on the map. The sea-level identity guarantee is then a property of
## the terrain rather than a special case in the shader: blend is exactly 0.0
## everywhere a player can walk or drive. HIGH sits below normal aircraft
## cruise, so the whole 8-20 km range is fully spherical.
const BLEND_LOW := 1000.0
const BLEND_HIGH := 8000.0


## Line-of-sight distance to the horizon: sqrt(2Rh + h²).
static func horizon_distance(h: float, radius: float = EARTH_RADIUS_M) -> float:
	var a := maxf(h, 0.0)
	return sqrt(2.0 * radius * a + a * a)


## Drop of a spherical surface below the tangent plane at the viewer, for a
## point r metres away: r^2 / 2R. MIRRORED IN ocean_t3d.gdshader's
## planet_curve_radius branch — change both together, as this file's header
## requires.
##
## radius <= 0 means "flat", returning exactly 0.0. That is the shipping game's
## value: the clipmap sea is flat unless a planet is present.
static func curvature_drop(r: float, radius: float = EARTH_RADIUS_M) -> float:
	if radius <= 0.0:
		return 0.0
	return (r * r) / (2.0 * radius)


## Angle the horizon sits BELOW the local horizontal: acos(R/(R+h)).
static func horizon_dip(h: float, radius: float = EARTH_RADIUS_M) -> float:
	var a := maxf(h, 0.0)
	return acos(clampf(radius / (radius + a), -1.0, 1.0))


## Weight between Sky3D's analytic optical depth (0.0) and the spherical march
## (1.0). Exactly 0.0 at and below BLEND_LOW, exactly 1.0 at and above
## BLEND_HIGH — both endpoints are exact because smoothstep's Hermite
## polynomial evaluates to exactly 0 and 1 at its edges.
##
## Mirrors planet_spherical_blend() in planet_atmosphere.gdshaderinc. GLSL and
## GDScript smoothstep are the same polynomial, so the two agree to float32
## rounding. Keep them in LOCKSTEP.
static func spherical_blend(h: float) -> float:
	return smoothstep(BLEND_LOW, BLEND_HIGH, h)


## Altitude, in metres, by which SkyDome's AtmFog quad is fully faded out.
## See PlanetHorizon.atm_fog_scale_for for the bisect that set it.
const ATM_FOG_FADE_END := 3000.0


## Altitude thinning for SkyDome's AtmFog quad: 1.0 at and below BLEND_LOW,
## 0.0 at and above ATM_FOG_FADE_END.
##
## Static and tree-free so OceanSurface's editor preview can apply the same
## curve PlanetHorizon applies at runtime. That mattered: the quad is a
## GROUND-LEVEL screen-space haze that intersects the sea plane, so unfaded from
## altitude it paints a hard-edged wash from EYE LEVEL down — across the bottom
## of the sun disc, which the sky drew before it.
static func atm_fog_scale(h: float) -> float:
	return 1.0 - smoothstep(BLEND_LOW, ATM_FOG_FADE_END, h)


## Distance along a view ray to the planet surface, or -1.0 on a miss.
##
## STABILITY: the textbook near root -b - sqrt(b² - c) is catastrophic
## cancellation here — b² ≈ R² ≈ 4e13 while c = 2Rh is tiny near the ground,
## so in float32 it loses ~11% at eye height. Use the reciprocal root instead:
## the product of the two roots is c, so t_near = c / t_far, and t_far is a
## sum of positives. c itself is well-conditioned at every altitude.
## test_planet_geometry.gd proves the naive form breaks and this one does not.
static func ground_hit_distance(h: float, dir_y: float,
		radius: float = EARTH_RADIUS_M) -> float:
	if dir_y >= 0.0:
		return -1.0   # from outside the sphere, an upward ray never hits
	var a := maxf(h, 0.0)
	var c := 2.0 * radius * a + a * a       # |O|² - R², well-conditioned
	var b := (radius + a) * dir_y           # dot(O, dir) with O = (0, R+h, 0)
	var disc := b * b - c
	if disc < 0.0:
		return -1.0
	return c / (-b + sqrt(disc))


## Distance along a view ray to a concentric shell at `shell_alt` metres above
## sea level, or -1.0 on a miss. Used for the cloud decks.
##
## Two regimes, and getting them the wrong way round is the classic bug:
##   - camera BELOW the shell: we are inside it, so c < 0, the roots straddle
##     zero, and the single positive root is the one we want.
##   - camera ABOVE the shell: we are outside, so a hit needs a downward ray
##     steep enough to clear the shell's horizon, and the NEAR root is the
##     visible cloud TOP. Taking the far root would render the deck's underside
##     on the far side of the planet.
##
## STABILITY, and BOTH roots need it — the GLSL mirror runs in float32 where
## b^2 ~ 4e13 has no spare digits:
##   - c = |O|^2 - Rs^2 subtracts two numbers near 4e13, so form it from the
##     altitudes instead: c = (h - shell)(2R + h + shell).
##   - the inside root -b + sqrt(disc) cancels. Measured over a shell x
##     altitude x direction grid it is mostly fine (~2e-5), because c ~ 1e10 is
##     far better conditioned than the ground hit's c ~ 2e7 — but it loses 10%
##     where the camera sits just BELOW the deck, i.e. flying under the cloud
##     base, where the true distance is ~1 m and c goes tiny against b^2 ~ 4e13.
##     Multiply through by (b + root): (root^2 - b^2)/(b + root) = -c/(b + root),
##     and since root > |b| whenever c < 0 the denominator is a sum of
##     positives. Measured worst case then drops to 1.5e-7.
##   - the outside near root -b - sqrt(disc) cancels the same way; use the
##     reciprocal form c/(-b + root), as ground_hit_distance does.
static func shell_hit_distance(h: float, dir_y: float, shell_alt: float,
		radius: float = EARTH_RADIUS_M) -> float:
	var a := maxf(h, 0.0)
	var ro := radius + a
	var b := ro * dir_y
	# Well-conditioned form of ro*ro - rs*rs.
	var c := (a - shell_alt) * (2.0 * radius + a + shell_alt)
	var disc := b * b - c
	if disc < 0.0:
		return -1.0
	var root := sqrt(disc)
	if c < 0.0:
		# Inside the shell: one positive root, formed without cancellation.
		return -c / (b + root)
	# Outside the shell: need to be heading toward it.
	if dir_y >= 0.0:
		return -1.0
	# Near root — the visible cloud TOP — via the reciprocal form.
	return c / (-b + root)


## Altitude above sea level at distance `t` along a view ray.
##
## STABILITY: naive length(O + t·d) - R subtracts two numbers near 6.37e6 and
## loses the answer. Factor the difference of squares instead — the numerator
## reuses the well-conditioned c, and the denominator is a sum near 2R.
static func altitude_along_ray(h: float, dir_y: float, t: float,
		radius: float = EARTH_RADIUS_M) -> float:
	var a := maxf(h, 0.0)
	var c := 2.0 * radius * a + a * a
	var b := (radius + a) * dir_y
	var num := c + 2.0 * t * b + t * t
	return num / (sqrt(radius * radius + num) + radius)


## FAR root of a concentric shell seen from OUTSIDE it (camera above the shell):
## where a downward ray that dipped into the shell comes back out. -1 from inside
## or on a miss. Both factors of -b + root are positive here (b < 0), no cancellation.
## Mirrors planet_shell_far_root() in planet_atmosphere.gdshaderinc.
static func shell_far_root(h: float, dir_y: float, shell_alt: float,
		radius: float = EARTH_RADIUS_M) -> float:
	var a := maxf(h, 0.0)
	var c := (a - shell_alt) * (2.0 * radius + a + shell_alt)
	if c < 0.0 or dir_y >= 0.0:
		return -1.0
	var b := (radius + a) * dir_y
	var disc := b * b - c
	if disc < 0.0:
		return -1.0
	return -b + sqrt(disc)


## The segment of a view ray inside the cloud layer [base, top]: (t0, t1), empty
## when t0 >= t1. Camera below / inside / above the layer; never through the
## planet; capped at max_dist. Mirrors planet_cloud_shell_segment().
static func cloud_shell_segment(h: float, dir_y: float, base: float, top: float,
		max_dist: float, radius: float = EARTH_RADIUS_M) -> Vector2:
	var tb := shell_hit_distance(h, dir_y, base, radius)
	var tt := shell_hit_distance(h, dir_y, top, radius)
	var s := Vector2(1.0, 0.0)
	if h < base:
		if tb >= 0.0:
			s = Vector2(tb, tt)
	elif h > top:
		if tt >= 0.0:
			s = Vector2(tt, tb if tb >= 0.0 else shell_far_root(h, dir_y, top, radius))
	else:
		s = Vector2(0.0, minf(tt if tt >= 0.0 else 1e12, tb if tb >= 0.0 else 1e12))
	var tg := ground_hit_distance(h, dir_y, radius)
	if tg >= 0.0:
		s.y = minf(s.y, tg)
	s.y = minf(s.y, max_dist)
	return s


## Rayleigh / Mie optical depth over [0, t_end] (midpoint rule), for aerial
## perspective at a finite distance (the cloud's mean depth).
## Mirrors planet_optical_depth_pair_to().
static func optical_depth_pair_to(h: float, dir_y: float, t_end: float, steps: int,
		radius: float = EARTH_RADIUS_M) -> Vector2:
	if t_end <= 0.0:
		return Vector2.ZERO
	var tg := ground_hit_distance(h, dir_y, radius)
	var te := minf(t_end, _atmosphere_exit(h, dir_y, radius))
	if tg >= 0.0:
		te = minf(te, tg)
	var dt := te / float(steps)
	var total := Vector2.ZERO
	for i in steps:
		var alt := maxf(altitude_along_ray(h, dir_y, (float(i) + 0.5) * dt, radius), 0.0)
		total += Vector2(exp(-alt / RAYLEIGH_H), exp(-alt / MIE_H)) * dt
	return total


## Distance along a view ray to the top of the atmosphere shell.
## The camera is always INSIDE the shell, so c < 0 and the far root is a sum
## of positives — no cancellation, no miss case.
static func _atmosphere_exit(h: float, dir_y: float,
		radius: float = EARTH_RADIUS_M) -> float:
	var a := maxf(h, 0.0)
	var top := radius + ATMOSPHERE_TOP_M
	var ro := radius + a
	var b := ro * dir_y
	var c := ro * ro - top * top          # negative: we are inside
	return -b + sqrt(maxf(b * b - c, 0.0))


## Distance along a view ray to where it ENTERS the atmosphere shell:
##   - 0.0 if the camera is already inside the shell (h <= ATMOSPHERE_TOP_M).
##   - negative if the ray misses the shell entirely (no real roots, or an
##     upward ray from outside that only ever moves further away).
##   - otherwise the near root.
##
## STABILITY: same shape as shell_hit_distance()'s "outside" branch, with
## ATMOSPHERE_TOP_M as the shell radius offset — c is formed from the
## altitude DIFFERENCE (a - ATMOSPHERE_TOP_M) rather than a subtraction of the
## ~4e13 values ro² and top², so it stays well-conditioned even a few metres
## above the shell. The near root itself still cancels if formed as
## -b - sqrt(disc): use the reciprocal c / (-b + sqrt(disc)), as
## ground_hit_distance does. test_planet_geometry.gd pins the naive form
## breaking just above the shell and this one holding.
static func atmosphere_entry(h: float, dir_y: float,
		radius: float = EARTH_RADIUS_M) -> float:
	var a := maxf(h, 0.0)
	if a <= ATMOSPHERE_TOP_M:
		return 0.0
	if dir_y >= 0.0:
		return -1.0
	var ro := radius + a
	var b := ro * dir_y
	var c := (a - ATMOSPHERE_TOP_M) * (2.0 * radius + a + ATMOSPHERE_TOP_M)
	var disc := b * b - c
	if disc < 0.0:
		return -1.0
	return c / (-b + sqrt(disc))


## Optical depth along a view ray through an exponential atmosphere, in metres
## of equivalent sea-level column (∫ ρ/ρ₀ ds).
##
## Numerical integration rather than a closed-form Chapman function: the limb
## lives at rays just BELOW the local horizontal, exactly where the closed form
## needs a separate branch. Midpoint rule, so `steps` samples cost `steps`
## exp() calls. 8 tracks a 256-sample reference within 2%.
##
## A ray that strikes the planet is integrated only as far as the surface.
static func optical_depth(h: float, dir_y: float, scale_height: float,
		steps: int, radius: float = EARTH_RADIUS_M) -> float:
	var n := maxi(steps, 1)
	var t_end := _atmosphere_exit(h, dir_y, radius)
	var t_ground := ground_hit_distance(h, dir_y, radius)
	if t_ground >= 0.0:
		t_end = minf(t_end, t_ground)
	if t_end <= 0.0:
		return 0.0
	var dt := t_end / float(n)
	var total := 0.0
	for i in n:
		var t := (float(i) + 0.5) * dt
		var alt := altitude_along_ray(h, dir_y, t, radius)
		total += exp(-maxf(alt, 0.0) / scale_height) * dt
	return total


## Camera far plane for a given altitude. Floors at the caller's WORLD_FAR so
## nothing that reads that constant is surprised, and caps at FAR_CEILING —
## past which there is no real geometry, only sea the sky shader draws.
##
## Derived from the HORIZON, not from a tuning gain. The far plane exists so you
## can see as far as there is anything to see, and that distance is
## `horizon_distance(h)` — altitude enters here because the horizon's distance
## genuinely depends on it, not because anything is being faded or retired.
##
## The old `world_far + FAR_GAIN * h` form (gain 3.0) was the reason the sea
## could not reach the horizon from altitude: at 2 km it gave a 22 km far plane
## against a horizon 160 km out, so the ocean sheet was clipped at 22 km and
## ended 5.5 degrees below eye level — a visible edge with sky under it.
##
## HORIZON_MARGIN keeps the sheet just inside the plane that clips it: the ocean
## is driven to `far * HORIZON_MARGIN`, so asking for exactly the horizon here
## would put the sheet's last ring on the wrong side of the frustum.
static func far_plane(h: float, world_far: float) -> float:
	# maxf(minf(...)), NOT clampf(v, world_far, FAR_CEILING). A caller whose
	# world_far is ALREADY past the ceiling — an editor viewport set to 1000 km,
	# measured — inverts that clamp's bounds, and clampf resolves min > max in
	# favour of max, so the function returned 150 km for a camera asking for
	# 1000 km. It is documented to FLOOR at the caller's value and it must, or
	# it silently shortens a far plane it was only ever meant to lengthen.
	var need := horizon_distance(h) / HORIZON_MARGIN
	return maxf(world_far, minf(need, FAR_CEILING))


## Floor on how far the ocean sheet is driven, in metres.
##
## The true horizon at a car's eye height is only ~4.4 km, and driving the sheet
## to exactly that would visibly SHRINK the sea everywhere the game is actually
## played. At 15 km with the curvature on, the sheet's edge sits 0.073 degrees
## below eye level against a true 0.039 — a 0.03 degree error, far under a
## pixel. So the floor costs nothing and leaves sea level exactly as authored.
const OCEAN_MIN_HORIZON_M := 15000.0


## How far to drive the ocean sheet at a given altitude: the real horizon,
## floored so sea level is unchanged, capped so the sheet stays inside the
## camera far plane that clips it.
##
## The ONLY altitude term left on the ocean, and it is not a look knob — the
## horizon's distance IS sqrt(2Rh + h^2). Static and tree-free so PlanetHorizon
## (at runtime) and OceanSurface (in the editor viewport) share one law rather
## than each carrying a copy that can drift.
static func ocean_horizon(h: float, world_far: float) -> float:
	return clampf(horizon_distance(h), OCEAN_MIN_HORIZON_M,
			far_plane(h, world_far) * HORIZON_MARGIN)


## Altitude, in metres, above which Sky3D's OWN atmospheric scatter term
## (day-sky colour / twilight glow) is faded to zero — from ATMOSPHERE_TOP_M
## (where this file's shell model already treats density as zero) to the
## Karman line. The atmosphere's post-process now owns aerial perspective; leaving
## Sky3D's own scatter live above the shell would fog the same view twice,
## the same defect removed from planet_ocean's haze term.
##
## Starmap, Milky Way, sun disk and moon disk are NOT gated by this — only
## the atmospheric wash `render_sky` adds to `col.rgb` is. Mirrors
## planet_atmosphere_scatter_fade() in planet_atmosphere.gdshaderinc; keep the
## two in LOCKSTEP.
const KARMAN_LINE_M := 100000.0


## Weight for Sky3D's atmospheric scatter contribution: 1.0 at and below
## ATMOSPHERE_TOP_M, 0.0 at and above KARMAN_LINE_M. Both endpoints exact,
## same smoothstep-endpoint reasoning as spherical_blend() above.
static func atmosphere_scatter_fade(h: float) -> float:
	return 1.0 - smoothstep(ATMOSPHERE_TOP_M, KARMAN_LINE_M, h)


const CubeSphereRef := preload("res://src/sky/planet/cube_sphere.gd")

## SUPERSEDED 2026-07-28: an earlier version of this function anchored the
## wave chart at (lat 0, lon 0) using a global equirectangular projection
## (north_m = radius*lat, east_m = radius*lon*cos(lat)). That is NOT a
## tangent chart, despite reading like one -- its east axis is scaled by the
## point's ABSOLUTE longitude from the prime meridian, so changing LATITUDE
## (any north-south camera motion) drags a large longitude multiplier into
## the EAST coordinate: d(east_m)/d(lat) = -radius*lon*sin(lat). At
## Hachijojima's own 139 deg E / 35 deg N that coefficient is ~1.39, so a
## 20 m northward camera move swung the chart origin by 28 m -- WORSE than
## the camera-relative bug this fix exists to remove. Confirmed both
## analytically and by tools/sim_runner/_wave_chart_probe.gd's north-south
## leg (added after this was found) before being replaced with the
## cube-sphere-anchored version below, which has no lat/lon in it at all.

## Cube-sphere level the wave-chart anchor snaps to. MEASURED (not asserted)
## via CubeSphere.patch_edge_length / a direct corner-to-centre sweep over a
## level-8 face at Earth radius: mid-line patch edge 49 772 m, worst sampled
## centre-to-corner distance 35 195 m (at a face-centre patch -- face-centre
## patches are closer to square than face-corner ones on a cube-sphere, and
## happened to be the widest of the points sampled). float32's ULP at ~35 km
## is 0.0039 m -- exactly the same order as the 7.8 mm budget the earlier
## wrap-based version was built around, but here it is bounded BY
## CONSTRUCTION (the anchor lattice spacing), not by a wrap or a modulo.
const WAVE_CHART_ANCHOR_LEVEL := 8

## Cube-sphere-snapped anchor DIRECTION for the level-8 patch containing
## `dir_unit`. Delegates entirely to CubeSphere (dir_to_face_uv + the same
## patch_uv_size/patch_centre_dir quantisation CubeSphere's own quadtree
## patches use), so the anchor lattice has NO pole singularity (CubeSphere
## has none by construction -- the face assignment is the axis of largest
## magnitude, well-defined everywhere) and NO antimeridian seam (nothing here
## ever reads longitude). This is the fix's only consumer of
## CubeSphere.dir_to_face_uv, which the parked cube-sphere quadtree's own
## review flagged as dead API with only self-referential tests.
static func wave_chart_anchor_dir(dir_unit: DVec3,
		level: int = WAVE_CHART_ANCHOR_LEVEL) -> DVec3:
	var fuv: Array = CubeSphereRef.dir_to_face_uv(dir_unit)
	var face: int = fuv[0]
	var u: float = fuv[1]
	var v: float = fuv[2]
	var size: float = CubeSphereRef.patch_uv_size(level)
	var i: int = int(floor((u + 1.0) / size))
	var j: int = int(floor((v + 1.0) / size))
	return CubeSphereRef.patch_centre_dir(face, level, i, j)


## The camera's ACTUAL position (not its ground projection -- see below),
## expressed in a LOCAL ENU chart anchored at the nearest level-8 cube-sphere
## patch centre -- what anchors planet_ocean.gdshader's wave-sampling plane
## to the planet instead of to the camera, see the shader's vertex() and
## its "wave domain". Replaces the
## lat/lon version above.
##
## |camera_rel - anchor_pos| never exceeds ~35.2 km + the camera's altitude,
## the level-8 patch's measured worst-case centre-to-corner distance (see
## WAVE_CHART_ANCHOR_LEVEL's comment) plus however far the camera sits above
## sea level -- where float32's ULP is 0.0039 m at 35 km, still inside the
## 7.8 mm budget for any altitude the wave field is actually visible at (it
## fades out entirely past wave_fade_end, a few km, so a vertex near enough
## to carry waves is never far from a LOW-altitude camera either). Bounded BY
## CONSTRUCTION, not by a wrap or a modulo (deleted along with
## WAVE_CHART_WRAP; that was only ever a workaround for the old chart's
## unbounded magnitude).
##
## USE THE CAMERA'S ACTUAL POSITION, NOT ITS GROUND-PROJECTED POINT: an
## earlier version of this function took a unit DIRECTION and scaled it by
## `radius`, silently projecting the camera down to sea level before forming
## the offset. That is what the ORIGINAL brief for this fix specified
## ("compute wave_chart_origin ... from the camera's ground point"), and it
## measured a small but real drift (~0.157 m over a 2 km traverse at 500 m
## altitude, proportional to altitude * lateral distance / radius) even
## though the pathological lat/lon coupling was already gone -- because
## dropping altitude here while the shader's LOCAL term
## (dot(v_world, tangent_east/north), v_world computed from the camera's
## TRUE position) does not, is itself a frame mismatch, the same class of
## bug as pushing origin/tangent from two different ENU bases. Substituting
## both terms into the shader's own formula shows algebraically that
## `plane(vertex)` is then an EXACT function of the vertex's own universe
## position (independent of the camera, aside from the anchor snap itself)
## ONLY when this function uses the camera's actual position -- so
## `camera_rel` here is the FULL camera-relative position (already
## altitude-inclusive), not a unit direction.
##
## Returns the origin AND the tangent basis TOGETHER, and this is load-
## bearing, not a convenience: the local chart basis here is the ANCHOR's
## ENU, not the CAMERA's. Callers MUST push the returned tangent_east/
## tangent_north as the shader's tangent_east/tangent_north uniforms (not a
## separately-computed camera-up ENU, which is what the shader used before
## this fix) -- otherwise the origin and the shader's per-vertex local term
## would be expressed in two different bases and would not sum to a stable
## value, silently reintroducing a version of the same defect this whole fix
## chases.
##
## camera_rel MUST stay a DVec3 all the way to the final dot product below --
## narrowing camera_rel or the anchor position to Vector3 before subtracting
## reintroduces exactly the kind of error the class comment documents for
## dir_to_lat_lon (there: ~0.7 m from narrowing before a radius multiply;
## here the same trap would come from narrowing before the subtraction that
## cancels the two ~6.37e6 m position magnitudes). `d` itself is bounded to a
## few tens of km, which is the sanctioned point to narrow --
## UniverseFrame.relative()'s rule: subtract in doubles, then narrow.
static func wave_chart_origin(camera_rel: DVec3, radius: float) -> Dictionary:
	var up: DVec3 = camera_rel.unit()
	var anchor_dir: DVec3 = wave_chart_anchor_dir(up)
	var anchor_dir_v: Vector3 = anchor_dir.to_vector3()
	var enu: Basis = enu_basis_from_up(anchor_dir_v)
	var east: Vector3 = enu.x
	var north: Vector3 = enu.y
	# d = camera_rel - anchor_pos, where anchor_pos is the anchor's SEA-LEVEL
	# position (planet_centre + anchor_dir*radius, expressed camera-relative
	# by omitting the shared planet_centre term -- it cancels algebraically
	# either way, so skipping it avoids ever forming the large subtraction at
	# all). camera_rel carries the camera's REAL altitude; nothing here
	# projects it to sea level.
	var anchor_pos: DVec3 = anchor_dir.scaled(radius)
	var d: DVec3 = camera_rel.subtracted(anchor_pos)
	var chart := Vector2(
			d.x * east.x + d.y * east.y + d.z * east.z,
			d.x * north.x + d.y * north.y + d.z * north.z)
	return {
		"origin": chart,
		"tangent_east": east,
		"tangent_north": north,
	}


## ENU -> ECEF basis from a normalised radial "up" direction, using this
## project's north-pole axis (0,0,1) as the polar reference (see
## geo_reference.gd's ECEF convention). Columns are (east, north, up) — a
## proper right-handed rotation (determinant +1) everywhere, INCLUDING both
## poles, where the polar axis and up coincide and the fallback below picks
## an arbitrary (but still orthonormal) east.
##
## This is the SAME derivation PlanetSphere, PlanetSurface and PlanetNearWater
## each carried inline (east = polar x up, north = up x east) before this
## file existed to hold it once. Collapsed here on this task's invitation to
## reconsider the duplication — three copies of a basis that has already
## shipped mirrored/transposed twice on this feature is three chances to get
## it wrong a third time. Call sites now read `enu_basis_from_up(...).x` /
## `.y` / `.z` for east / north / up.
##
## See geo_reference.gd's enu_to_ecef_basis() for the LAT/LON-driven twin used
## by the flat world's Earth painting — same convention, different input
## (that one is fed geodetic coordinates from the map's own georeferencing;
## this one is fed a direction directly, which is what the sphere sandbox and
## a per-frame shader push already have on hand for free).
static func enu_basis_from_up(up: Vector3) -> Basis:
	var u := up.normalized()
	var polar := Vector3(0.0, 0.0, 1.0)
	var east := polar.cross(u)
	if east.length_squared() < 1.0e-12:
		east = Vector3(1.0, 0.0, 0.0)
	else:
		east = east.normalized()
	var north := u.cross(east)
	return Basis(east, north, u)


## The same ENU basis as enu_basis_from_up(), reordered so column 1 (Basis.y,
## GLSL mat3 column 1) is UP instead of column 2 — i.e. mat3(north, up, east).
##
## This is the basis planet_sky.gdshader wants: Sky3D's stock maths treats +Y
## as the observer's zenith everywhere (a flat world has exactly one, so that
## was never wrong there). Pushing ENU -> ECEF in THIS column order means
## `sky_basis_from_up(up) * (some local Y-up vector) == that vector in ECEF`,
## and the shader applies the TRANSPOSE (this is orthonormal, so inverse =
## transpose) to fold a raw ECEF ray into the Y-up frame Sky3D was written
## for. Still determinant +1: north x up = east follows directly from
## north == up x east (enu_basis_from_up's own construction), the same way
## east x north = up does there.
static func sky_basis_from_up(up: Vector3) -> Basis:
	var enu := enu_basis_from_up(up)
	return Basis(enu.y, enu.z, enu.x)


## ---------------------------------------------------------------------------
## Sun/Moon VISUAL PROXIES. This section used to hold the true-angular-
## diameter, per-body-proxy-distance maths and fed a dual-scene scaled space --
## both retired: the requirement they existed for (bodies must be REACHABLE
## at true scale) was withdrawn. The solar system is visibility only, scenery
## a camera flies around rather than a destination, which makes both
## true-scale distances and a second scaled-space camera unnecessary. See the
## scaled-space design doc's SUPERSEDED note for the full history.
##
## What survived the retirement, kept below: the handover band
## (CELESTIAL_HANDOVER_LOW/HIGH, celestial_geometry_fade) and the display-
## distance/display-radius pair that replaces the old true-distance proxy
## maths. The ENU->ECEF direction conversion (enu_basis_from_up /
## sky_basis_from_up above) also survived unchanged -- it was correct before
## and remains the sun/moon direction source. See CelestialBodies
## (src/sky/planet/celestial_bodies.gd) for the simple MeshInstance3D
## consumer of all of this.

## Altitude band over which Sky3D's painted sun/moon discs hand over to real
## geometry. Below LOW: painted only (celestial_geometry_fade == 0.0, exactly
## -- smoothstep's Hermite polynomial is exact at its own edges, the same
## reasoning spherical_blend() above relies on). Above HIGH: geometry only.
const CELESTIAL_HANDOVER_LOW := 100000.0
const CELESTIAL_HANDOVER_HIGH := 1000000.0

## Weight for the sun/moon GEOMETRY's visibility -- 0.0 at and below
## CELESTIAL_HANDOVER_LOW (painted disc only), 1.0 at and above
## CELESTIAL_HANDOVER_HIGH (geometry only). (1.0 - this) is the multiplier
## the sky shader applies to its OWN painted sun/moon discs (planet_sky.
## gdshader's celestial_geometry_fade uniform, already wired), so the two
## handovers are complementary by construction rather than two separately
## tuned curves that could drift apart and show the body twice (or neither).
static func celestial_geometry_fade(h: float) -> float:
	return smoothstep(CELESTIAL_HANDOVER_LOW, CELESTIAL_HANDOVER_HIGH, h)


## Apparent angular diameter, DEGREES, chosen for LOOKS, not physics. The true
## values are close to each other (Sun 0.533 deg, Moon 0.518 deg -- that
## near-equality is real, and is why eclipses work) and both are unreadable
## on screen at any altitude this sandbox flies at: a true-scale render is a
## few-pixel dot. These are deliberately larger. DELIBERATE NON-PHYSICAL
## VALUES -- do not "correct" them to reality.
const SUN_APPARENT_DEG := 2.0
const MOON_APPARENT_DEG := 1.5

## Display distance for both bodies, as a FRACTION of the CURRENT camera far
## plane -- not a hard-coded metres value, so the proxy can never fall
## outside the frustum when far changes with altitude (see planet_sandbox.
## gd's near/far-vs-altitude formula). 0.5 sits comfortably inside (0, 1)
## with margin on both sides for float precision at the far plane's own edge.
const CELESTIAL_DISPLAY_FAR_FRACTION := 0.5


## A body's display distance: a fraction of the CURRENT far plane.
static func celestial_display_distance(far_plane_m: float) -> float:
	return far_plane_m * CELESTIAL_DISPLAY_FAR_FRACTION


## Display radius for a body placed at `distance` so it subtends exactly
## `apparent_diameter_deg` on screen -- the exact inverse of
## celestial_angular_diameter below (radius = distance * sin(diameter/2)),
## not the small-angle approximation, so the chosen apparent size is exact
## rather than approximately what was asked for.
static func celestial_display_radius(distance: float, apparent_diameter_deg: float) -> float:
	return distance * sin(deg_to_rad(apparent_diameter_deg) * 0.5)


## Angular diameter (radians) of a body of `radius` at `distance`, exact via
## asin -- the inverse of celestial_display_radius. Used by tests to confirm
## a placed body's on-screen angular size matches the chosen apparent
## diameter, not the small-angle radius/distance approximation.
static func celestial_angular_diameter(radius: float, distance: float) -> float:
	return 2.0 * asin(clampf(radius / distance, -1.0, 1.0))
