class_name CloudClock
extends RefCounted
## Cloud drift: the integral of the steering wind, in world metres.
##
## HOST-AUTHORITATIVE. Every peer integrates the same deterministic wind, so
## between the 5 s WeatherSync packets they already agree to within frame-time
## noise; apply_remote() slews out the residue (the OceanSurface._clock_err
## pattern) and snaps when the error is large (late join, host swap).
##
## PRECISION: x/z/t are GDScript `float` = 64-bit. NEVER store them in a
## Vector2 — that is float32, whose step at 1e6 m is 0.06 m, and a 60 Hz advance
## of ~0.1 m would be quantised by tens of percent. Wrap per texture period only
## when handing values to the GPU (wrapped()).

## Every horizontal texture period divides this (test-enforced).
const WRAP_M := 131072.0
const TIME_WRAP_S := 4096.0
const SNAP_M := 250.0
const SNAP_S := 2.0
## Exponential correction rate toward the host (1/s).
const GAIN := 1.0
## Correction speed cap, so a correction never reads as a lurch.
const MAX_CORRECT_MPS := 8.0

var x := 0.0
var z := 0.0
var t := 0.0
var _ex := 0.0
var _ez := 0.0
var _et := 0.0


func advance(w: Vector3, dt: float) -> void:
	x += w.x * dt
	z += w.z * dt
	t += dt
	if _ex != 0.0 or _ez != 0.0:
		var k := minf(GAIN * dt, 1.0)
		var cx := _ex * k
		var cz := _ez * k
		var n := sqrt(cx * cx + cz * cz)
		var cap := MAX_CORRECT_MPS * dt
		if n > cap:
			cx *= cap / n
			cz *= cap / n
		x += cx
		z += cz
		_ex -= cx
		_ez -= cz
	if _et != 0.0:
		var ct := _et * minf(GAIN * dt, 1.0)
		t += ct
		_et -= ct


## Scalars, not a Vector2: GD-Sync's var_to_bytes keeps a float scalar 64-bit.
func to_dict() -> Dictionary:
	return {"x": x, "z": z, "t": t}


func apply_remote(d: Dictionary) -> void:
	var ex := float(d.get("x", x)) - x
	var ez := float(d.get("z", z)) - z
	if sqrt(ex * ex + ez * ez) > SNAP_M:
		x += ex
		z += ez
		_ex = 0.0
		_ez = 0.0
	else:
		_ex = ex
		_ez = ez
	var et := float(d.get("t", t)) - t
	if absf(et) > SNAP_S:
		t += et
		_et = 0.0
	else:
		_et = et


## Save/load: a hard set, no slew.
func load_dict(d: Dictionary) -> void:
	x = float(d.get("x", 0.0))
	z = float(d.get("z", 0.0))
	t = float(d.get("t", 0.0))
	_ex = 0.0
	_ez = 0.0
	_et = 0.0


func wrapped(period: float) -> Vector2:
	return Vector2(fposmod(x, period), fposmod(z, period))


func wrapped_time() -> float:
	return fposmod(t, TIME_WRAP_S)
