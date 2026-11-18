class_name CloudTemporalMath
extends RefCounted
## Pure maths for the temporal cloud pass (CloudTemporal). The kernels in
## shaders/cloud_temporal_kernels.txt mirror ray_dir / project / scene_distance
## operation for operation — LOCKSTEP; test_cloud_temporal_math pins the maths and
## the byte layout of both UBOs the kernels read.
##
## Screen convention: uv (0, 0) is the TOP-LEFT pixel. A camera render stores its
## buffers top-down (RenderSceneDataRD.flip_y is true for every camera), which is
## also SCREEN_UV's convention in the sky and spatial shaders.

## Bayer order: every slot once per L*L frames, far-apart slots back to back.
const LATTICE_2: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 1), Vector2i(1, 0), Vector2i(0, 1)]
const LATTICE_4: Array[Vector2i] = [
	Vector2i(0, 0), Vector2i(2, 2), Vector2i(2, 0), Vector2i(0, 2),
	Vector2i(1, 1), Vector2i(3, 3), Vector2i(3, 1), Vector2i(1, 3),
	Vector2i(1, 0), Vector2i(3, 2), Vector2i(3, 0), Vector2i(1, 2),
	Vector2i(0, 1), Vector2i(2, 3), Vector2i(2, 1), Vector2i(0, 3),
]


## The trace's blue-noise walk (LOCKSTEP with KERNEL_TRACE): R4 increments, four low-discrepancy
## walks over the four blue-noise channels (march step, light samples, sub-pixel x, y).
const R4 := Vector4(0.8566748839, 0.7338918566, 0.6287067210, 0.5385972572)
## The frame counter the walk wraps at (a multiple of every L * L, so a pixel's refresh index
## steps by exactly one across the wrap's neighbours).
const WALK_WRAP := 16384


## A pixel's noise on the frame it is traced: its blue-noise value `bn` advanced once per REFRESH
## (every L * L frames), not per frame. Per frame, a pixel saw only every L^2-th point of the walk:
## 4 x R4 mod 1 = (0.43, 0.94, 0.51, 0.15), a light jitter creeping by -0.06 a refresh and a sub-pixel
## x of two values (#775).
static func walk(bn: Vector4, frame: int, l: int) -> Vector4:
	var refresh := floorf(float(posmod(frame, WALK_WRAP)) / float(l * l))
	var v := bn + R4 * refresh
	return Vector4(v.x - floorf(v.x), v.y - floorf(v.y), v.z - floorf(v.z), v.w - floorf(v.w))


static func lattice_offset(frame: int, l: int) -> Vector2i:
	if l == 2:
		return LATTICE_2[posmod(frame, 4)]
	if l == 4:
		return LATTICE_4[posmod(frame, 16)]
	return Vector2i.ZERO


## The half-resolution history the pass reconstructs: half of the OUTPUT size when an upscaler renders below it
## (owner prompts/40: under FSR2 Quality a 1080p screen renders 1280 x 720, and a history at half of THAT,
## 640 x 360, is a third of the screen per axis; FSR2's upscale then drew every cloud edge in 3 x 3-pixel blocks).
## The trace and the velocity pass read the scene depth by uv, so the history's size is free; the composite
## samples it by uv too. Native (target == internal): unchanged.
static func history_size(internal: Vector2i, target := Vector2i.ZERO) -> Vector2i:
	var base := Vector2i(maxi(internal.x, target.x), maxi(internal.y, target.y))
	return Vector2i((base.x + 1) / 2, (base.y + 1) / 2)


## One traced ray per L x L block of history pixels.
static func trace_size(hist: Vector2i, l: int) -> Vector2i:
	return Vector2i((hist.x + l - 1) / l, (hist.y + l - 1) / l)


## tan(half fov) per axis. RenderSceneDataRD.get_cam_projection() carries the TAA
## jitter in columns[2][0/1] (Projection.add_jitter_offset on the correction
## matrix) and the y-flip in the SIGN of columns[1][1]; neither touches these two
## terms, so rays built from them are un-jittered by construction.
static func tangents(p: Projection) -> Vector2:
	return Vector2(1.0 / p.x.x, 1.0 / absf(p.y.y))


## Unit world ray through screen uv. Godot cameras look down -Z of their basis.
static func ray_dir(basis: Basis, tan: Vector2, uv: Vector2) -> Vector3:
	return (basis.x * ((2.0 * uv.x - 1.0) * tan.x) + basis.y * ((1.0 - 2.0 * uv.y) * tan.y)
			- basis.z).normalized()


## World point -> Vector3(u, v, 1) for a camera, or z = -1 when it is behind it.
## The inverse of ray_dir.
static func project(origin: Vector3, basis: Basis, tan: Vector2, w: Vector3) -> Vector3:
	var d := w - origin
	var zf := -d.dot(basis.z)
	if zf <= 1e-4:
		return Vector3(0.0, 0.0, -1.0)
	var x := d.dot(basis.x) / zf / tan.x
	var y := d.dot(basis.y) / zf / tan.y
	return Vector3(0.5 + 0.5 * x, 0.5 - 0.5 * y, 1.0)


## Distance ALONG THE RAY at uv to the surface behind a reverse-Z depth sample,
## from the corrected projection's p22 = columns[2][2] and p32 = columns[3][2]:
## the view-axis distance is p32 / (d + p22). -1 for a cleared (sky) sample.
static func scene_distance(d: float, p22: float, p32: float, tan: Vector2, uv: Vector2) -> float:
	if d <= 0.0:
		return -1.0
	var v := Vector3((2.0 * uv.x - 1.0) * tan.x, (1.0 - 2.0 * uv.y) * tan.y, 1.0)
	return p32 / (d + p22) * v.length()


## The globals UBO members, std140: every int global first (padded to a multiple
## of four), then every vec4 global, each in CloudGlobals.TABLE order.
## CloudTemporalGlsl.header() declares exactly this list.
static func ubo_ints() -> PackedStringArray:
	return _names_of(RenderingServer.GLOBAL_VAR_TYPE_INT)


static func ubo_vecs() -> PackedStringArray:
	return _names_of(RenderingServer.GLOBAL_VAR_TYPE_VEC4)


static func _names_of(t: int) -> PackedStringArray:
	var out := PackedStringArray()
	for name in CloudGlobals.TABLE:
		if CloudGlobals.TABLE[name][0] == t:
			out.append(name)
	return out


## `values` = CloudUniforms.values (name -> the last pushed value); a missing name
## takes its TABLE default.
static func pack_globals(values: Dictionary) -> PackedByteArray:
	var ints := ubo_ints()
	var vecs := ubo_vecs()
	var nints := int(ceil(ints.size() / 4.0)) * 4
	var b := PackedByteArray()
	b.resize(4 * nints + 16 * vecs.size())
	for i in ints.size():
		b.encode_s32(4 * i, int(_value(values, ints[i])))
	for i in vecs.size():
		var v: Vector4 = _value(values, vecs[i])
		var o := 4 * nints + 16 * i
		b.encode_float(o, v.x)
		b.encode_float(o + 4, v.y)
		b.encode_float(o + 8, v.z)
		b.encode_float(o + 12, v.w)
	return b


## CloudUniforms records StringName keys, the TABLE is keyed by String.
static func _value(values: Dictionary, name: String) -> Variant:
	var sn := StringName(name)
	if values.has(sn):
		return values[sn]
	return values.get(name, CloudGlobals.TABLE[name][1])


## The per-frame UBO (FrameParams in the kernels), 13 vec4:
##   cam_pos (origin, tan.x)  cam_x (basis.x, tan.y)  cam_y (basis.y, p22)  cam_z (basis.z, p32)
##   prev_pos (origin, tan.x) prev_x (basis.x, tan.y) prev_y (basis.y, 0)   prev_z (basis.z, 0)
##   wind (drift.x, 0, drift.y, history valid)
##   sizes (history w, h, trace w, h)
##   frame_a (internal w, h, lattice L, frame index)
##   frame_b (lattice offset x, y, retain, sub-pixel jitter)
##   march (max steps, light samples, refreshes since the last reset, 0)
static func pack_frame(f: Dictionary) -> PackedFloat32Array:
	var b: Basis = f["basis"]
	var pb: Basis = f["prev_basis"]
	var o: Vector3 = f["origin"]
	var po: Vector3 = f["prev_origin"]
	var t: Vector2 = f["tan"]
	var pt: Vector2 = f["prev_tan"]
	var dr: Vector2 = f["drift"]
	var hs: Vector2i = f["hist_size"]
	var ts: Vector2i = f["trace_size"]
	var ins: Vector2i = f["internal"]
	var off: Vector2i = f["offset"]
	return PackedFloat32Array([
		o.x, o.y, o.z, t.x,
		b.x.x, b.x.y, b.x.z, t.y,
		b.y.x, b.y.y, b.y.z, float(f["p22"]),
		b.z.x, b.z.y, b.z.z, float(f["p32"]),
		po.x, po.y, po.z, pt.x,
		pb.x.x, pb.x.y, pb.x.z, pt.y,
		pb.y.x, pb.y.y, pb.y.z, 0.0,
		pb.z.x, pb.z.y, pb.z.z, 0.0,
		dr.x, 0.0, dr.y, 1.0 if bool(f["hist_valid"]) else 0.0,
		float(hs.x), float(hs.y), float(ts.x), float(ts.y),
		float(ins.x), float(ins.y), float(f["lattice"]), float(f["frame"]),
		float(off.x), float(off.y), float(f["retain"]), float(f["jitter"]),
		float(f["max_steps"]), float(f["light_n"]), float(f.get("refreshes", 1e6)),
		1.0 if bool(f.get("keep_geometry_motion", false)) else 0.0,
	])
