class_name CloudTemporalGlsl
extends RefCounted
## Builds the temporal pass's compute shaders from the SHIPPED cloud includes, so
## the compute march is the sky's march by construction — never a hand copy. The
## four includes are plain GLSL but for Godot's `PI`, defined here; the parts that
## need the sky's atmosphere uniforms sit behind `#ifndef CLOUD_COMPUTE`.
##
## The globals header (a std140 UBO + one combined sampler per texture) is
## generated from CloudGlobals.TABLE in CloudTemporalMath.ubo_ints/ubo_vecs order,
## so a new global reaches the compute path without anyone copying it there.

const INCLUDES: Array[String] = [
	"res://src/sky/shaders/planet_atmosphere.gdshaderinc",
	"res://src/sky/clouds/shaders/cloud_field.gdshaderinc",
	"res://src/sky/clouds/shaders/cloud_light.gdshaderinc",
	"res://src/sky/clouds/shaders/cloud_march.gdshaderinc",
]
const KERNELS := "res://src/sky/clouds/shaders/cloud_temporal_kernels.txt"
## Globals the compute march never samples (the pass's own output).
const NOT_TRACED: Array[StringName] = [&"cloud_view"]
## [linear, mipmap, repeat] per traced sampler — LOCKSTEP with the hints in
## cloud_params.gdshaderinc (test_cloud_temporal_glsl parses them).
const SAMPLER_STATE := {
	&"cloud_base_noise": [true, true, true],
	&"cloud_blue_noise": [false, false, true],
	&"cloud_pf_noise": [true, true, true],
	&"cloud_storms": [false, false, false],
}


## Traced samplers in binding order (1, 2, ...): TABLE order. Built once: TABLE and NOT_TRACED are constants, and it is
## asked twice a frame (the snapshot on the main thread, the trace on the render thread; ~0.06 ms a frame in the script
## profiler, PERF2). PackedStringArray is copied on write, so a caller cannot change the cached one.
static var _sampler_names_cache := PackedStringArray()


static func sampler_names() -> PackedStringArray:
	if not _sampler_names_cache.is_empty():
		return _sampler_names_cache
	_sampler_names_cache = _build_sampler_names()
	return _sampler_names_cache


static func _build_sampler_names() -> PackedStringArray:
	var out := PackedStringArray()
	for name in CloudGlobals.TABLE:
		var t: int = CloudGlobals.TABLE[name][0]
		if (t == RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D or t == RenderingServer.GLOBAL_VAR_TYPE_SAMPLER3D) \
				and not NOT_TRACED.has(StringName(name)):
			out.append(name)
	return out


static func header() -> String:
	var ints := CloudTemporalMath.ubo_ints()
	var s := "layout(set = 0, binding = 0, std140) uniform CloudGlobalsUBO {\n"
	for n in ints:
		s += "\tint %s;\n" % n
	for i in range(ints.size(), int(ceil(ints.size() / 4.0)) * 4):
		s += "\tint cloud_ubo_pad%d;\n" % i
	for n in CloudTemporalMath.ubo_vecs():
		s += "\tvec4 %s;\n" % n
	s += "};\n"
	var names := sampler_names()
	for i in names.size():
		var t: int = CloudGlobals.TABLE[names[i]][0]
		s += "layout(set = 0, binding = %d) uniform %s %s;\n" % [i + 1,
				"sampler3D" if t == RenderingServer.GLOBAL_VAR_TYPE_SAMPLER3D else "sampler2D", names[i]]
	return s


## "TRACE" (the march, assembled from the shipped includes), "RESOLVE" or "VELOCITY".
static func source(kernel: String) -> String:
	var s := "#version 450\n#define KERNEL_%s\n" % kernel
	if kernel == "TRACE":
		s += "#define CLOUD_COMPUTE\n#define PI 3.14159265358979\n" + header()
		for inc in INCLUDES:
			s += expand_includes(FileAccess.get_file_as_string(inc)) + "\n"
	return s + FileAccess.get_file_as_string(KERNELS)


## The includes' own `#include "res://..."` lines (Godot's preprocessor resolves them for the gdshaders;
## glslang has no include support here) replaced by the files' text, recursively. The files carry include
## guards, so a file pulled in twice compiles once.
static func expand_includes(text: String, depth := 0) -> String:
	if depth > 8 or not text.contains("#include"):
		return text
	var out := PackedStringArray()
	for line in text.split("\n"):
		var l := line.strip_edges()
		if l.begins_with("#include \"res://") and l.ends_with("\""):
			var path := l.substr(10, l.length() - 11)
			out.append(expand_includes(FileAccess.get_file_as_string(path), depth + 1))
		else:
			out.append(line)
	return "\n".join(out)


## {shader: RID, error: String}. Runs on whatever device it is given: the render
## thread's for the live pass, a local one for the compile check.
static func compile(rd: RenderingDevice, kernel: String) -> Dictionary:
	var src := RDShaderSource.new()
	src.set_language(RenderingDevice.SHADER_LANGUAGE_GLSL)
	src.set_stage_source(RenderingDevice.SHADER_STAGE_COMPUTE, source(kernel))
	var spirv: RDShaderSPIRV = rd.shader_compile_spirv_from_source(src)
	var err: String = spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if not err.is_empty():
		return {"shader": RID(), "error": err}
	return {"shader": rd.shader_create_from_spirv(spirv, "cloud_temporal_" + kernel.to_lower()), "error": ""}


static func sampler_state(name: StringName) -> RDSamplerState:
	var st: Array = SAMPLER_STATE.get(name, [true, false, false])
	var s := RDSamplerState.new()
	var f := RenderingDevice.SAMPLER_FILTER_LINEAR if st[0] else RenderingDevice.SAMPLER_FILTER_NEAREST
	s.min_filter = f
	s.mag_filter = f
	s.mip_filter = RenderingDevice.SAMPLER_FILTER_LINEAR if st[1] else RenderingDevice.SAMPLER_FILTER_NEAREST
	var rep := RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT if st[2] else RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	s.repeat_u = rep
	s.repeat_v = rep
	s.repeat_w = rep
	if not st[1]:
		s.max_lod = 0.0
	return s
