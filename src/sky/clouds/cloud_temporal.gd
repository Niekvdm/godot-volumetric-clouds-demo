class_name CloudTemporal
extends CompositorEffect
## The temporal cloud pass: marches the cloud field for the
## MAIN viewport in compute, a quarter of the half-res pixels per frame, and
## reconstructs a stable half-res history the sky shader and the flight quad
## sample (the global `cloud_view`, a Texture2DRD over `published().out`).
##
## Why it exists: Godot draws the sky with the TAA-jittered projection
## (sky.cpp:1228) but sky pixels never get a motion vector (the velocity buffer
## is cleared to (-1, -1), render_forward_clustered.cpp:2248), so TAA reprojects
## them off-screen and keeps ~100 % of the current frame. Nothing integrated the
## per-pixel march's grain, and the jitter moved it every frame.
##
## POST_OPAQUE: the opaque depth is complete and draw_sky has not run yet
## (render_forward_clustered.cpp :2282 < :2314). Only the root viewport's render
## target is traced; mirrors, the PIP camera and the radiance cubemap keep the
## per-pixel march. CloudBridge owns this object: it attaches it to the Sky3D
## WorldEnvironment's compositor, feeds submit() every frame and reads
## published().
##
## Threads: submit()/published() run on the main thread, _render_callback on the
## render thread; the two dictionaries are swapped under a mutex.

const HIST_FORMAT := RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
## Per-pixel refreshes the history holds (#775): a pixel the camera just revealed starts a running
## mean of its own instead of taking the global count, which kept ~90 % of its first sample.
const AGE_FORMAT := RenderingDevice.DATA_FORMAT_R16_SFLOAT
## Frames an old `out` texture stays alive after a resize: the main thread swaps
## the Texture2DRD a frame or two later, and the sky samples it until then.
const RETIRE_FRAMES := 8
## History reset triggers: a camera cut, a zoom, a clock snap (late join).
const RESET_JUMP_M := 500.0
const RESET_TAN := 0.02
const RESET_DRIFT_M := 200.0

## GPU timestamps around the trace and the resolve ("ct:trace", "ct:resolve", "ct:done") for the
## cost probe's stage split (tools/sky/cloud_cost_probe --only passes). Off in the game.
static var capture_stamps := false

var _mutex := Mutex.new()
var _pending: Dictionary = {}
var _pub: Dictionary = {"out": RID(), "size": Vector2i.ZERO, "frame": 0, "error": ""}

# ---- render thread ----
var _rd: RenderingDevice = null
## 0 = not built yet, 1 = ready, -1 = failed (published().error says why).
var _state := 0
var _trace_shader := RID()
var _trace_pipe := RID()
var _resolve_shader := RID()
var _resolve_pipe := RID()
var _velocity_shader := RID()
var _velocity_pipe := RID()
var _globals_ubo := RID()
var _globals_size := 0
var _frame_ubo := RID()
var _frame_size := 0
var _samplers: Dictionary = {}
var _s_nearest := RID()
var _s_linear := RID()
var _size := Vector2i.ZERO
## The output size the history was built for (an upscaler renders below it: CloudTemporalMath.history_size).
var _target := Vector2i.ZERO
var _hist_size := Vector2i.ZERO
var _trace_size := Vector2i.ZERO
var _lattice := 0
var _trace_tex := RID()
var _hist: Array[RID] = [RID(), RID()]
var _age: Array[RID] = [RID(), RID()]
var _out := RID()
var _pp := 0
var _retired: Array = []
var _frame := 0
var _have_prev := false
var _prev_origin := Vector3.ZERO
var _prev_basis := Basis.IDENTITY
var _prev_tan := Vector2.ONE
var _prev_clock := PackedFloat64Array()
var _prev_reset := -1
## Frames since the history was last reset (the resolve's running-mean count).
var _since_reset := 0


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_OPAQUE
	# MSAA: bind the resolved single-sample depth.
	access_resolved_depth = true


## Main thread, once per frame. Keys: main_rt (RID), globals (PackedByteArray,
## CloudTemporalMath.pack_globals), textures (Array of RS texture RIDs in
## CloudTemporalGlsl.sampler_names() order), clock (PackedFloat64Array [x, z]),
## lattice, retain, jitter, max_steps, light_n, reset (serial), velocity (bool: write the clouds'
## motion vectors for TAA, #775).
func submit(snapshot: Dictionary) -> void:
	_mutex.lock()
	_pending = snapshot
	_mutex.unlock()


## Main thread: {out: RID, size: Vector2i (internal), frame: int, error: String}; once a frame has
## been traced also xf (Transform3D) and tan (Vector2): the un-jittered camera it was traced with
## (the motion metrics' reprojection, tools/sky/cloud_motion_metrics.gd).
func published() -> Dictionary:
	_mutex.lock()
	var d := _pub.duplicate()
	_mutex.unlock()
	return d


func _publish(out: RID, size: Vector2i, frame: int, error: String, cam: Dictionary = {}) -> void:
	_mutex.lock()
	_pub = {"out": out, "size": size, "frame": frame, "error": error}
	_pub.merge(cam)
	_mutex.unlock()


func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE:
		return
	var rids: Array[RID] = [_trace_pipe, _resolve_pipe, _velocity_pipe, _trace_shader,
			_resolve_shader, _velocity_shader,
			_globals_ubo, _frame_ubo, _s_nearest, _s_linear, _trace_tex, _hist[0], _hist[1], _age[0], _age[1], _out]
	for s in _samplers.values():
		rids.append(s)
	for e in _retired:
		rids.append(e[0])
	if _rd != null:
		RenderingServer.call_on_render_thread(CloudTemporal._free_rids.bind(_rd, rids))


## Pipelines are listed before their shaders: freeing a shader frees its
## pipelines, and a second free of those would be an invalid-RID error.
static func _free_rids(rd: RenderingDevice, rids: Array[RID]) -> void:
	for r in rids:
		if r.is_valid():
			rd.free_rid(r)


# ---- render thread ----------------------------------------------------------

func _render_callback(callback_type: int, render_data: RenderData) -> void:
	if callback_type != EFFECT_CALLBACK_TYPE_POST_OPAQUE:
		return
	var rsb := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var sd := render_data.get_render_scene_data()
	if rsb == null or sd == null or rsb.get_view_count() != 1:
		return
	_mutex.lock()
	var snap := _pending
	_mutex.unlock()
	if snap.is_empty() or rsb.get_render_target() != snap.get("main_rt", RID()):
		return
	if not _ensure_pipelines():
		return
	_retire_tick()

	var internal := rsb.get_internal_size()
	var target := rsb.get_target_size()
	var l := int(snap.get("lattice", 2))
	l = 4 if l >= 4 else (2 if l >= 2 else 1)
	var reset := false
	if internal != _size or target != _target or l != _lattice:
		_build_textures(internal, l, target)
		reset = true

	# Textures first: a frame whose inputs are not resident is skipped, never
	# half-traced.
	var names := CloudTemporalGlsl.sampler_names()
	var texs: Array = snap.get("textures", [])
	var u0: Array[RDUniform] = []
	for i in names.size():
		var rs_rid: RID = texs[i] if i < texs.size() else RID()
		var tex := RenderingServer.texture_get_rd_texture(rs_rid) if rs_rid.is_valid() else RID()
		if not tex.is_valid():
			return
		u0.append(_sampler_uniform(i + 1, _samplers[StringName(names[i])], tex))

	var xf := sd.get_cam_transform()
	var tan := CloudTemporalMath.tangents(sd.get_cam_projection())
	var proj := sd.get_cam_projection()
	var clock: PackedFloat64Array = snap.get("clock", PackedFloat64Array([0.0, 0.0]))
	var drift := Vector2.ZERO
	if _prev_clock.size() == 2 and clock.size() == 2:
		drift = Vector2(clock[0] - _prev_clock[0], clock[1] - _prev_clock[1])
	var serial := int(snap.get("reset", 0))
	if not _have_prev or serial != _prev_reset or xf.origin.distance_to(_prev_origin) > RESET_JUMP_M \
			or (tan - _prev_tan).length() > RESET_TAN or drift.length() > RESET_DRIFT_M:
		reset = true

	_since_reset = 0 if reset else _since_reset + 1
	var g: PackedByteArray = snap.get("globals", PackedByteArray())
	if g.is_empty():
		return
	if not _globals_ubo.is_valid() or g.size() != _globals_size:
		if _globals_ubo.is_valid():
			_rd.free_rid(_globals_ubo)
		_globals_ubo = _rd.uniform_buffer_create(g.size(), g)
		_globals_size = g.size()
	else:
		_rd.buffer_update(_globals_ubo, 0, g.size(), g)

	var off := CloudTemporalMath.lattice_offset(_frame, _lattice)
	var fr := CloudTemporalMath.pack_frame({
		"origin": xf.origin, "basis": xf.basis, "tan": tan, "p22": proj.z.z, "p32": proj.w.z,
		"prev_origin": _prev_origin if _have_prev else xf.origin,
		"prev_basis": _prev_basis if _have_prev else xf.basis,
		"prev_tan": _prev_tan if _have_prev else tan,
		"drift": drift, "hist_valid": not reset,
		"hist_size": _hist_size, "trace_size": _trace_size, "internal": internal,
		"lattice": _lattice, "frame": _frame, "offset": off,
		"retain": float(snap.get("retain", 0.8)), "jitter": float(snap.get("jitter", 0.5)),
		"max_steps": int(snap.get("max_steps", 128)), "light_n": int(snap.get("light_n", 4)),
		# Each pixel is traced once per lattice^2 frames: that many refreshes so far.
		"refreshes": floorf(float(_since_reset) / float(_lattice * _lattice)),
		"keep_geometry_motion": bool(snap.get("keep_geometry_motion", false)),
	}).to_byte_array()
	if not _frame_ubo.is_valid() or fr.size() != _frame_size:
		if _frame_ubo.is_valid():
			_rd.free_rid(_frame_ubo)
		_frame_ubo = _rd.uniform_buffer_create(fr.size(), fr)
		_frame_size = fr.size()
	else:
		_rd.buffer_update(_frame_ubo, 0, fr.size(), fr)

	u0.push_front(_ubo_uniform(0, _globals_ubo))
	var tsh := _trace_shader
	var set0 := UniformSetCacheRD.get_cache(tsh, 0, u0)
	var u1: Array[RDUniform] = [_ubo_uniform(0, _frame_ubo),
			_sampler_uniform(1, _s_nearest, rsb.get_depth_layer(0)), _image_uniform(2, _trace_tex)]
	var set1 := UniformSetCacheRD.get_cache(tsh, 1, u1)
	if capture_stamps:
		_rd.capture_timestamp("ct:trace")
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _trace_pipe)
	_rd.compute_list_bind_uniform_set(cl, set0, 0)
	_rd.compute_list_bind_uniform_set(cl, set1, 1)
	_rd.compute_list_dispatch(cl, ceili(_trace_size.x / 8.0), ceili(_trace_size.y / 8.0), 1)
	_rd.compute_list_end()

	var prev_hist := _hist[_pp]
	var next_hist := _hist[1 - _pp]
	var ur: Array[RDUniform] = [_ubo_uniform(0, _frame_ubo), _sampler_uniform(1, _s_nearest, _trace_tex),
			_sampler_uniform(2, _s_linear, prev_hist), _image_uniform(3, next_hist), _image_uniform(4, _out),
			_sampler_uniform(5, _s_nearest, _age[_pp]), _image_uniform(6, _age[1 - _pp])]
	var setr := UniformSetCacheRD.get_cache(_resolve_shader, 0, ur)
	if capture_stamps:
		_rd.capture_timestamp("ct:resolve")
	cl = _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _resolve_pipe)
	_rd.compute_list_bind_uniform_set(cl, setr, 0)
	_rd.compute_list_dispatch(cl, ceili(_hist_size.x / 8.0), ceili(_hist_size.y / 8.0), 1)
	_rd.compute_list_end()
	if capture_stamps:
		_rd.capture_timestamp("ct:done")
	if bool(snap.get("velocity", true)):
		_write_velocity(rsb, internal)

	_pp = 1 - _pp
	_have_prev = true
	_prev_origin = xf.origin
	_prev_basis = xf.basis
	_prev_tan = tan
	_prev_clock = clock
	_prev_reset = serial
	_frame += 1
	_publish(_out, internal, _frame, "", {"xf": xf, "tan": tan})


## The clouds' motion vectors into the velocity buffer TAA reads (KERNEL_VELOCITY: the sky and
## the sea keep (0, 0) there without an upscaler, and TAA ghosted them). Only where the buffer is
## the single-sample one TAA reads: with MSAA the post-transparent resolve overwrites it.
func _write_velocity(rsb: RenderSceneBuffersRD, internal: Vector2i) -> void:
	if rsb.get_msaa_3d() != RenderingServer.VIEWPORT_MSAA_DISABLED:
		return
	var vel := rsb.get_velocity_texture(false)
	if not vel.is_valid():
		return
	var uv: Array[RDUniform] = [_ubo_uniform(0, _frame_ubo), _sampler_uniform(1, _s_nearest, rsb.get_depth_layer(0)),
			_sampler_uniform(2, _s_linear, _out), _image_uniform(3, vel)]
	var setv := UniformSetCacheRD.get_cache(_velocity_shader, 0, uv)
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _velocity_pipe)
	_rd.compute_list_bind_uniform_set(cl, setv, 0)
	_rd.compute_list_dispatch(cl, ceili(internal.x / 8.0), ceili(internal.y / 8.0), 1)
	_rd.compute_list_end()


func _ensure_pipelines() -> bool:
	if _state != 0:
		return _state == 1
	_state = -1
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		_publish(RID(), Vector2i.ZERO, 0, "no RenderingDevice")
		return false
	var t := CloudTemporalGlsl.compile(_rd, "TRACE")
	var r := CloudTemporalGlsl.compile(_rd, "RESOLVE")
	var v := CloudTemporalGlsl.compile(_rd, "VELOCITY")
	var err := ""
	if t["error"] != "":
		err += "TRACE: " + t["error"]
	if r["error"] != "":
		err += "RESOLVE: " + r["error"]
	if v["error"] != "":
		err += "VELOCITY: " + v["error"]
	if err != "":
		push_error("[clouds] temporal pass disabled, the compute shaders did not compile:\n" + err)
		for s in [t["shader"], r["shader"], v["shader"]]:
			if (s as RID).is_valid():
				_rd.free_rid(s)
		_publish(RID(), Vector2i.ZERO, 0, err)
		return false
	_trace_shader = t["shader"]
	_resolve_shader = r["shader"]
	_velocity_shader = v["shader"]
	_trace_pipe = _rd.compute_pipeline_create(_trace_shader)
	_resolve_pipe = _rd.compute_pipeline_create(_resolve_shader)
	_velocity_pipe = _rd.compute_pipeline_create(_velocity_shader)
	for n in CloudTemporalGlsl.sampler_names():
		_samplers[StringName(n)] = _rd.sampler_create(CloudTemporalGlsl.sampler_state(StringName(n)))
	var sn := RDSamplerState.new()
	sn.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sn.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	_s_nearest = _rd.sampler_create(sn)
	var sl := RDSamplerState.new()
	sl.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sl.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	_s_linear = _rd.sampler_create(sl)
	_state = 1
	return true


func _build_textures(internal: Vector2i, l: int, target := Vector2i.ZERO) -> void:
	for r in [_trace_tex, _hist[0], _hist[1], _age[0], _age[1]]:
		if (r as RID).is_valid():
			_rd.free_rid(r)
	if _out.is_valid():
		_retired.append([_out, RETIRE_FRAMES])
	_size = internal
	_target = target
	_lattice = l
	_hist_size = CloudTemporalMath.history_size(internal, target)
	_trace_size = CloudTemporalMath.trace_size(_hist_size, l)
	_trace_tex = _tex(_trace_size)
	_hist[0] = _tex(_hist_size)
	_hist[1] = _tex(_hist_size)
	_age[0] = _tex(_hist_size, AGE_FORMAT)
	_age[1] = _tex(_hist_size, AGE_FORMAT)
	_out = _tex(_hist_size)
	_pp = 0


## Cleared to "no cloud" (T = 1) so nothing samples garbage before the first resolve (an age
## texture: 0 refreshes).
func _tex(size: Vector2i, format: int = HIST_FORMAT) -> RID:
	var f := RDTextureFormat.new()
	f.format = format
	f.width = maxi(size.x, 1)
	f.height = maxi(size.y, 1)
	f.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	var rid := _rd.texture_create(f, RDTextureView.new(), [])
	_rd.texture_clear(rid, Color(0.0, 0.0, 1.0, 0.0), 0, 1, 0, 1)
	return rid


func _retire_tick() -> void:
	for i in range(_retired.size() - 1, -1, -1):
		_retired[i][1] -= 1
		if _retired[i][1] <= 0:
			_rd.free_rid(_retired[i][0])
			_retired.remove_at(i)


static func _ubo_uniform(binding: int, buf: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	u.binding = binding
	u.add_id(buf)
	return u


static func _sampler_uniform(binding: int, sampler: RID, tex: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u.binding = binding
	u.add_id(sampler)
	u.add_id(tex)
	return u


static func _image_uniform(binding: int, tex: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u.binding = binding
	u.add_id(tex)
	return u
