class_name DVec3
extends RefCounted

## Double-precision 3-vector.
##
## WHY THIS EXISTS: Godot's Vector3 stores float32 in a single-precision build,
## and float32's ULP at Earth radius (6 371 000 m) is 0.5 m. Any position
## expressed planet-centred in a Vector3 therefore jitters by half a metre.
## GDScript's own `float` is 64-bit regardless of the build, so three of them
## carry the whole solar system at sub-millimetre precision.
##
## Used for the SMALL number of API-level positions: camera position, planet
## centre, patch centre. It is deliberately NOT used inside inner loops —
## patch_mesh_builder.gd computes with raw local floats (which are doubles
## anyway) to avoid one RefCounted allocation per vertex.
##
## Methods return new instances; nothing mutates in place. Names avoid the
## Object built-ins (`free`, `duplicate`, `connect`) that the parser misroutes.

var x: float = 0.0
var y: float = 0.0
var z: float = 0.0


static func make(px: float, py: float, pz: float) -> DVec3:
	var d := DVec3.new()
	d.x = px
	d.y = py
	d.z = pz
	return d


static func from_vector3(v: Vector3) -> DVec3:
	return DVec3.make(v.x, v.y, v.z)


func added(o: DVec3) -> DVec3:
	return DVec3.make(x + o.x, y + o.y, z + o.z)


func subtracted(o: DVec3) -> DVec3:
	return DVec3.make(x - o.x, y - o.y, z - o.z)


func scaled(s: float) -> DVec3:
	return DVec3.make(x * s, y * s, z * s)


func dot(o: DVec3) -> float:
	return x * o.x + y * o.y + z * o.z


func length() -> float:
	return sqrt(x * x + y * y + z * z)


func unit() -> DVec3:
	var l := length()
	if l <= 0.0:
		return DVec3.make(0.0, 0.0, 0.0)
	return scaled(1.0 / l)


## Narrowing conversion to float32. ONLY call this on a vector whose magnitude
## is already camera-relative — calling it on a planet-centred position is the
## precision bug this class exists to prevent.
func to_vector3() -> Vector3:
	return Vector3(x, y, z)
