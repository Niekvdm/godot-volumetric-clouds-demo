class_name CubeSphere
extends RefCounted

## Cube-sphere: the mapping between a quadtree on six square faces and
## directions on the unit sphere, plus patch bounds and key packing.
##
## Chosen over an icosphere because the quadtree, the UV mapping and the
## neighbour logic are all trivial on a square grid.
##
## AXES ARE ECEF, matching src/sky/geo_reference.gd exactly: +X through
## (lat 0, lon 0), +Y through (lat 0, lon 90E), +Z through the north pole.
## dir_to_lat_lon is unit-tested against GeoReference.geodetic_to_ecef so the
## two cannot drift.
##
## Face index -> cube normal:
##   0 = +X   1 = -X   2 = +Y   3 = -Y   4 = +Z   5 = -Z
##
## u and v run over [-1, 1] within a face. A patch at (level, i, j) covers
##   u in [-1 + 2i/2^level, -1 + 2(i+1)/2^level], likewise v with j.

const FACE_COUNT := 6

## Bit layout for encode_key. Level 19 needs 20 bits of index, and 3 + 5 + 20 +
## 20 = 48 bits fits an int64 with room to spare.
const _LEVEL_BITS := 5
const _INDEX_BITS := 20


## Face (u, v) -> UNIT direction. u and v in [-1, 1].
static func face_uv_to_dir(face: int, u: float, v: float) -> DVec3:
	var x := 0.0
	var y := 0.0
	var z := 0.0
	match face:
		0: x = 1.0;  y = v;    z = -u
		1: x = -1.0; y = v;    z = u
		2: x = u;    y = 1.0;  z = -v
		3: x = u;    y = -1.0; z = v
		4: x = u;    y = v;    z = 1.0
		_: x = -u;   y = v;    z = -1.0
	return DVec3.make(x, y, z).unit()


## UNIT direction -> [face, u, v]. Exact inverse of face_uv_to_dir; the face is
## the axis of largest magnitude, which is what makes edges and corners resolve
## consistently rather than flipping between neighbours.
static func dir_to_face_uv(dir: DVec3) -> Array:
	var ax := absf(dir.x)
	var ay := absf(dir.y)
	var az := absf(dir.z)
	if ax >= ay and ax >= az:
		if dir.x > 0.0:
			return [0, -dir.z / dir.x, dir.y / dir.x]
		return [1, dir.z / -dir.x, dir.y / -dir.x]
	if ay >= az:
		if dir.y > 0.0:
			return [2, dir.x / dir.y, -dir.z / dir.y]
		return [3, dir.x / -dir.y, dir.z / -dir.y]
	if dir.z > 0.0:
		return [4, dir.x / dir.z, dir.y / dir.z]
	return [5, dir.x / dir.z, dir.y / -dir.z]


static func patch_uv_size(level: int) -> float:
	return 2.0 / float(1 << level)


static func patch_uv_origin(level: int, i: int, j: int) -> Vector2:
	var s := patch_uv_size(level)
	return Vector2(-1.0 + s * float(i), -1.0 + s * float(j))


static func patch_centre_dir(face: int, level: int, i: int, j: int) -> DVec3:
	var o := patch_uv_origin(level, i, j)
	var h := patch_uv_size(level) * 0.5
	return face_uv_to_dir(face, o.x + h, o.y + h)


## Chord length across the patch's MID-LINE, in metres. Used only by the
## split rule, so a chord rather than an arc is fine — within ~10% of the
## arc even for a level-0 patch, and the split constant K absorbs it.
##
## MID-LINE, NOT THE v-ORIGIN EDGE. Sampling at o.y measures the patch's
## bottom edge, which on a cube-sphere is a genuinely different length from
## its middle: a level-0 face's bottom edge subtends arccos(1/3) = 70.53
## degrees against the mid-line's 90, a 26% error. That is not a rounding
## difference — it would make the split rule treat whole faces as a quarter
## smaller than they are and leave the far sphere visibly coarse.
static func patch_edge_length(face: int, level: int, i: int, j: int,
		radius: float) -> float:
	var o := patch_uv_origin(level, i, j)
	var s := patch_uv_size(level)
	var vc: float = o.y + s * 0.5
	var a := face_uv_to_dir(face, o.x, vc).scaled(radius)
	var b := face_uv_to_dir(face, o.x + s, vc).scaled(radius)
	return a.subtracted(b).length()


static func encode_key(face: int, level: int, i: int, j: int) -> int:
	return (face << (_LEVEL_BITS + 2 * _INDEX_BITS)) \
			| (level << (2 * _INDEX_BITS)) \
			| (i << _INDEX_BITS) \
			| j


static func decode_key(key: int) -> Array:
	var mask := (1 << _INDEX_BITS) - 1
	return [
		key >> (_LEVEL_BITS + 2 * _INDEX_BITS),
		(key >> (2 * _INDEX_BITS)) & ((1 << _LEVEL_BITS) - 1),
		(key >> _INDEX_BITS) & mask,
		key & mask,
	]


## UNIT direction -> (lat, lon) in RADIANS, under the ECEF convention above.
static func dir_to_lat_lon(dir: DVec3) -> Vector2:
	return Vector2(asin(clampf(dir.z, -1.0, 1.0)), atan2(dir.y, dir.x))
