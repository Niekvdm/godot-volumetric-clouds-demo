class_name CloudBake
extends RefCounted

## Procedural cloud-noise generation on the GPU at startup. Drives the KERNEL_* kernels in
## shaders/cloud_bake_kernels.txt through a RenderingDevice: the base volume (its statistics,
## KERNEL_STATS, and the remap to fixed target numbers the field is tuned against, KERNEL_REMAP), its
## box-filter mip chain, and the procedural field's noise volume.
##
## generate_textures() and generate_pf_texture() record on the MAIN device, on the render thread, and
## hand out Texture3DRDs: nothing comes back to the CPU and nothing is uploaded again. Both return
## nothing when there is no RenderingDevice (headless / dedicated server).
##
## Deterministic: fixed SEED, no time, no randomness outside it.

const GLSL := "res://src/sky/clouds/shaders/cloud_bake_kernels.txt"
const SEED := 1337.0

# The base volume's dims (its 4096 m period). BLUE stays committed (16 KB; an incremental
# void-and-cluster is its own project).
const BASE_N := 128
## The procedural field's noise volume (B2): the 128^3, its own seed.
const PF_N := 128
const PF_SEED := 7.0

const _RGBA8 := RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM


## The base noise, generated on the main RenderingDevice: {base: Texture3DRD}, or {} (no device, a
## failed kernel).
## Blocks the main thread until the render thread has recorded the work (RenderingServer.force_sync);
## the GPU runs it with the next frame, before anything samples it.
static func generate_textures() -> Dictionary:
	if RenderingServer.get_rendering_device() == null:
		return {}
	var job := {}
	RenderingServer.call_on_render_thread(CloudBake._record_main.bind(job))
	RenderingServer.force_sync()
	if not bool(job.get("ok", false)):
		return {}
	var base := Texture3DRD.new()
	base.texture_rd_rid = job["base"]
	# Setting texture_rd_rid only QUEUES the swap on the render thread (texture_rd.cpp): until it has
	# run, get_rid() hands out a 2D PLACEHOLDER, and a sampler3D bound to that (the dome's dome_noise,
	# the cloud_* globals) failed the sky's uniform set ("expected: 3D, actual: 2D"): the whole sky drew
	# black on LOW and HIGH, on boots where the main thread got there first. Wait for the swap, and
	# hand out nothing that is not live (get_format() is written last by the swap).
	RenderingServer.force_sync()
	var out := {"base": base}
	for k in out:
		if not is_live(out[k]):
			push_error("[cloud_bake] the generated %s texture is not live after the render-thread sync" % k)
			return {}
	return out


## The procedural field's noise volume (B2, KERNEL_PFNOISE: the noise with an integer hash),
## 128^3 RGBA8 with its box-filter mip chain, generated on the MAIN device on the render thread and
## handed out as a live Texture3DRD, or null (no device, a failed kernel). Generated on demand
## (CloudAssets.ensure_pf): only the procedural field reads it.
static func generate_pf_texture() -> Texture3DRD:
	if RenderingServer.get_rendering_device() == null:
		return null
	var job := {}
	RenderingServer.call_on_render_thread(CloudBake._record_pf_main.bind(job))
	RenderingServer.force_sync()
	if not bool(job.get("ok", false)):
		return null
	var t := Texture3DRD.new()
	t.texture_rd_rid = job["pf"]
	# The same wait as generate_textures(): until the swap has run get_rid() is a 2D placeholder.
	RenderingServer.force_sync()
	if not is_live(t):
		push_error("[cloud_bake] the generated procedural-field noise is not live after the render-thread sync")
		return null
	return t


## The procedural field's noise as bytes (level 0, x fastest) from a LOCAL device: tools/sky/cloud_pf_stats.gd.
static func generate_pf_bytes() -> PackedByteArray:
	var rd := RenderingServer.create_local_rendering_device()
	if rd == null:
		return PackedByteArray()
	var job := {}
	_record_pf(rd, job)
	var out := PackedByteArray()
	if bool(job.get("ok", false)):
		rd.submit()
		rd.sync()
		out = rd.texture_get_data(job["pf"], 0).slice(0, PF_N * PF_N * PF_N * 4)
		rd.free_rid(job["pf"])
	rd.free()
	return out


static func _record_pf_main(job: Dictionary) -> void:
	_record_pf(RenderingServer.get_rendering_device(), job)


static func _record_pf(rd: RenderingDevice, job: Dictionary) -> void:
	var rec := {"ok": false, "_free": []}
	var src := FileAccess.get_file_as_string(GLSL)
	var tex := _tex(rd, _RGBA8, PF_N, PF_N, PF_N, _mip_count(PF_N))
	var ok := tex.is_valid() \
			and _dispatch(rd, src, "#define KERNEL_PFNOISE\n", [_mip_view(rd, tex, 0, rec)], PackedFloat32Array([PF_SEED]),
					PF_N, PF_N, PF_N, 4, rec) \
			and _mip_chain(rd, src, tex, PF_N, rec)
	job["ok"] = ok
	job["pf"] = tex
	_free_all(rd, rec, false)
	if not ok and tex.is_valid():
		rd.free_rid(tex)


## A Texture3DRD / Texture2DRD whose render-thread swap has run (the 3D one writes its format last,
## the 2D one its size): only then is get_rid() the real texture and not a 2D placeholder.
static func is_live(t: Texture) -> bool:
	if t is Texture3D:
		return (t as Texture3D).get_format() != Image.FORMAT_MAX
	if t is Texture2D:
		return (t as Texture2D).get_width() > 0
	return false



# ---- the recording ---------------------------------------------------------------

## Render thread: the main device's recording into `job` (ok, and the base texture's RID). The
## kernels, pipelines, sets, views and the stats buffer are freed at once: the device keeps them
## until the frame that uses them is done.
static func _record_main(job: Dictionary) -> void:
	var rd := RenderingServer.get_rendering_device()
	var rec := _record(rd)
	job["ok"] = bool(rec.get("ok", false))
	job["base"] = rec.get("base", RID())
	_free_all(rd, rec, not job["ok"])


## Records every dispatch on `rd`. Returns {ok, base (the texture's RID), _free (everything else to free)}.
static func _record(rd: RenderingDevice) -> Dictionary:
	var rec := {"ok": false, "_free": []}
	var src := FileAccess.get_file_as_string(GLSL)
	var base := _tex(rd, _RGBA8, BASE_N, BASE_N, BASE_N, _mip_count(BASE_N))
	rec["base"] = base
	if not base.is_valid():
		return rec
	var stats := rd.storage_buffer_create(16)
	(rec["_free"] as Array).append(["buf", stats])
	var b0 := _mip_view(rd, base, 0, rec)
	var seed := PackedFloat32Array([SEED])
	var ok := _dispatch(rd, src, "#define KERNEL_BASE\n", [b0], seed, BASE_N, BASE_N, BASE_N, 4, rec) \
			and _dispatch(rd, src, "#define KERNEL_STATS\n", [b0, stats], PackedFloat32Array(), 1, 1, 0, 1, rec, 1) \
			and _dispatch(rd, src, "#define KERNEL_REMAP\n", [b0, stats], PackedFloat32Array(),
					BASE_N, BASE_N, BASE_N, 4, rec, 1) \
			and _mip_chain(rd, src, base, BASE_N, rec)
	rec["ok"] = ok
	return rec


static func _mip_count(n: int) -> int:
	var c := 1
	while n > 1:
		n = maxi(n >> 1, 1)
		c += 1
	return c


## Every level from the one above it (KERNEL_MIP3D), through single-level views.
static func _mip_chain(rd: RenderingDevice, src: String, tex: RID, n: int, rec: Dictionary) -> bool:
	var level := n
	var mip := 0
	while level > 1:
		level = maxi(level / 2, 1)
		var dst := _mip_view(rd, tex, mip + 1, rec)
		var srcv := _mip_view(rd, tex, mip, rec)
		if not _dispatch(rd, src, "#define KERNEL_MIP3D\n", [dst, srcv], PackedFloat32Array(),
				level, level, level, 4, rec):
			return false
		mip += 1
	return true


static func _mip_view(rd: RenderingDevice, tex: RID, mip: int, rec: Dictionary) -> RID:
	var v := rd.texture_create_shared_from_slice(RDTextureView.new(), tex, 0, mip, 1,
			RenderingDevice.TEXTURE_SLICE_3D)
	(rec["_free"] as Array).append(["view", v])
	return v




static func _free_all(rd: RenderingDevice, rec: Dictionary, textures_too := true) -> void:
	# A freed shader takes its pipelines with it, a freed texture or buffer its uniform sets: so sets
	# first, then pipelines, shaders, views and buffers (each kind in the order made).
	var items: Array = rec.get("_free", [])
	for kind in ["set", "pipe", "shader", "view", "buf"]:
		for it in items:
			if it[0] == kind and (it[1] as RID).is_valid():
				rd.free_rid(it[1])
	if textures_too:
		for k in ["base", "detail", "curl", "scatter"]:
			var t: RID = rec.get(k, RID())
			if t.is_valid():
				rd.free_rid(t)


# ---- RD plumbing -------------------------------------------------------------

## Insert the kernel define right after the #version line and compile.
## API verified against the engine (ClassDB): set_language + set_stage_source.
static func _kernel(rd: RenderingDevice, src: String, define: String) -> RID:
	var source := RDShaderSource.new()
	source.set_language(RenderingDevice.SHADER_LANGUAGE_GLSL)
	# GLSL demands #version FIRST — the file's documentation header precedes
	# it, so cut to the version line before splicing the kernel define in.
	var body := src.substr(src.find("#version"))
	source.set_stage_source(RenderingDevice.SHADER_STAGE_COMPUTE,
			body.insert(body.find("\n") + 1, define))
	var spirv: RDShaderSPIRV = rd.shader_compile_spirv_from_source(source)
	# Per-stage compile error (ClassDB-verified: get_stage_compile_error).
	var err: String = spirv.get_stage_compile_error(
			RenderingDevice.SHADER_STAGE_COMPUTE)
	if not err.is_empty():
		push_error("[cloud_bake] %s: %s" % [define.strip_edges(), err])
		return RID()
	return rd.shader_create_from_spirv(spirv)


static func _tex(rd: RenderingDevice, fmt: int, w: int, h: int, d: int, mips: int) -> RID:
	var f := RDTextureFormat.new()
	f.width = w
	f.height = h
	if d > 0:
		f.depth = d
		f.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	f.array_layers = 1
	f.mipmaps = mips
	f.format = fmt
	f.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
			| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	return rd.texture_create(f, RDTextureView.new(), [])


## Compile + record `define` with `res` bound in binding order (storage images; the one at
## `buf_binding` a storage buffer: the stats) and `pc` float push constants (exact block size matters to Vulkan).
## Nothing is submitted here: a local device submits once after the whole recording, the main
## device with its frame.
static func _dispatch(rd: RenderingDevice, src: String, define: String, res: Array,
		pc: PackedFloat32Array, w: int, h: int, d: int, group: int, rec: Dictionary,
		buf_binding := -1) -> bool:
	var shader := _kernel(rd, src, define)
	if not shader.is_valid():
		return false
	var pipeline := rd.compute_pipeline_create(shader)
	var uniforms: Array[RDUniform] = []
	for i in res.size():
		var u := RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER if i == buf_binding \
				else RenderingDevice.UNIFORM_TYPE_IMAGE
		u.binding = i
		u.add_id(res[i])
		uniforms.append(u)
	var set := rd.uniform_set_create(uniforms, shader, 0)
	var cb := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cb, pipeline)
	rd.compute_list_bind_uniform_set(cb, set, 0)
	if not pc.is_empty():
		var pc_bytes := pc.to_byte_array()
		rd.compute_list_set_push_constant(cb, pc_bytes, pc_bytes.size())
	rd.compute_list_dispatch(cb, ceili(w / float(group)), ceili(h / float(group)),
			maxi(ceili(d / float(group)), 1))
	rd.compute_list_end()
	(rec["_free"] as Array).append_array([["set", set], ["pipe", pipeline], ["shader", shader]])
	return true


