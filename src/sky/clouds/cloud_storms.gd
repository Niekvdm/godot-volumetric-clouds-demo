class_name CloudStorms
extends RefCounted
## The procedural field's cumulonimbus cells (B2): the storm picker, on a flat world. Pure: no nodes, no rendering.
##
## Candidate sites sit on a jittered 40 km grid in CLOUD space (world position minus the synced
## CloudClock drift, so a tower moves with the field and never pops); an integer hash of the grid cell
## decides whether a site is active, its size and its age, a coarse value noise makes them cluster, and
## the amount (CloudWeather.storms_for: synced fields only) fades them in. Every peer runs this from the
## same synced state, so every cell's existence, size and age are global: peers see the same towers where
## their views overlap. Only which 16 are NEAREST (the shaders' list) is per peer.
##
## The shaders read the cells from the global `cloud_storms` (a 16 x 1 RGBAF texture: world x, world z,
## tower radius in metres, maturity 0..1) and their count from cloud_pf_b.w. CloudBridge fills it.

const GRID_M := 40000.0
## Cells are listed out to this distance from the camera (cloud space).
const RANGE_M := 190000.0
const MAX_CELLS := 16
## The value noise that clusters storms (320 km).
const REGION_M := 320000.0
const MASK32 := 0xffffffff


## the integer hash (a PCG-style permutation), exact in 32 bits.
static func shash(x: int) -> int:
	var h := ((x & MASK32) * 747796405 + 2891336453) & MASK32
	h = (((h >> ((h >> 28) + 4)) ^ h) * 277803737) & MASK32
	return ((h >> 22) ^ h) & MASK32


static func unit(h: int) -> float:
	return float(h & 0xffff) / 65535.0


static func _cell_hash(x: int, y: int, z: int) -> int:
	return shash(((x & MASK32) * 73856093 & MASK32) ^ ((y & MASK32) * 19349663 & MASK32)
			^ ((z & MASK32) * 83492791 & MASK32))


## Smooth 0..1 value noise on an integer lattice (for where storms cluster).
static func value_noise(p: Vector3) -> float:
	var c := p.floor()
	var f := p - c
	f = f * f * (Vector3(3.0, 3.0, 3.0) - 2.0 * f)
	var ix := int(c.x)
	var iy := int(c.y)
	var iz := int(c.z)
	var v := []
	for k in 2:
		for j in 2:
			for i in 2:
				v.append(unit(_cell_hash(ix + i, iy + j, iz + k)))
	var x00 := lerpf(v[0], v[1], f.x)
	var x10 := lerpf(v[2], v[3], f.x)
	var x01 := lerpf(v[4], v[5], f.x)
	var x11 := lerpf(v[6], v[7], f.x)
	return lerpf(lerpf(x00, x10, f.y), lerpf(x01, x11, f.y), f.z)


## The cells within RANGE_M of `cam_cs` (the camera in CLOUD space: world xz minus the clock), nearest
## first, at most MAX_CELLS: Vector4(cloud-space x, cloud-space z, tower radius m, maturity 0..1).
## `storms` = CloudState.storms, `cover` = the raw synced cloud cover.
static func pick(storms: float, cover: float, cam_cs: Vector2) -> Array[Vector4]:
	var out: Array[Vector4] = []
	var amount := clampf(storms, 0.0, 1.0)
	var prob_amount := amount * 0.5 * smoothstep(0.12, 0.45, clampf(cover, 0.0, 1.0))
	if prob_amount <= 0.0:
		return out
	var reach := int(ceil(RANGE_M / GRID_M)) + 1
	var g := cam_cs / GRID_M
	var gx := int(floor(g.x))
	var gy := int(floor(g.y))
	var found: Array = []
	for j in range(-reach, reach + 1):
		for i in range(-reach, reach + 1):
			var cx := gx + i
			var cy := gy + j
			var h0 := _cell_hash(cx, cy, 0)
			var h1 := shash(h0)
			var h2 := shash(h1)
			var cg := (Vector2(cx, cy) + Vector2(0.2, 0.2) + 0.6 * Vector2(unit(h1), unit(h1 >> 16))) * GRID_M
			var dist := cg.distance_to(cam_cs)
			if dist > RANGE_M:
				continue
			var region := value_noise(Vector3(cg.x / REGION_M + 0.41, 0.07, cg.y / REGION_M + 0.66))
			var prob := prob_amount * smoothstep(0.2, 0.6, region + amount * 0.25)
			# Fades in rather than pops as the amount or the region changes.
			var r0 := unit(h0)
			var on := smoothstep(r0 - 0.04, r0 + 0.04, prob)
			if on <= 0.0:
				continue
			# A cell fading out shrinks into a smaller, younger (lower) tower.
			var rad := (2200.0 + 3000.0 * unit(h2)) * (0.6 + 0.4 * on)
			# Stormier days have more mature cells (with anvils).
			var u := unit(h2 >> 16)
			var age := (u + (1.0 - (1.0 - u) * (1.0 - u) - u) * amount) * on
			found.append([dist, Vector4(cg.x, cg.y, rad, age)])
	found.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	for k in mini(found.size(), MAX_CELLS):
		out.append(found[k][1])
	return out


## A signature of the cells near a fixed cloud-space point (the multiplayer autotest compares it across
## peers): the count x 1e6 plus the sum of radius x (0.5 + maturity), rounded, picked from the amount and the
## cover at CloudBridge's 1/256 steps.
static func signature(storms: float, cover: float, at_cs := Vector2.ZERO) -> float:
	var cells := pick(roundi(storms * 256.0) / 256.0, roundi(cover * 256.0) / 256.0, at_cs)
	var s := 0.0
	for c in cells:
		s += c.z * (0.5 + c.w)
	return cells.size() * 1.0e6 + roundf(s)
