class_name CloudGlobals
extends RefCounted
## The volumetric clouds' global shader parameters. LOCKSTEP with
## src/sky/clouds/shaders/cloud_params.gdshaderinc (test_cloud_optics checks both
## directions). Registered at RUNTIME, not in project.godot: the open editor
## rewrites project.godot on exit, and the only shaders that read these
## (planet_sky_volumetric, later cloud_flight) are never bound in the editor.
## CloudUniforms is the sole per-frame writer.

const _I := RenderingServer.GLOBAL_VAR_TYPE_INT
const _V := RenderingServer.GLOBAL_VAR_TYPE_VEC4
const _S2 := RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D
const _S3 := RenderingServer.GLOBAL_VAR_TYPE_SAMPLER3D

const TABLE := {
	"cloud_mode": [_I, 0],
	"cloud_flags": [_I, 0],
	"cloud_frame": [_I, 0],
	"cloud_debug": [_I, 0],
	"cloud_layer": [_V, Vector4(600.0, 2400.0, 0.6, 0.5)],
	"cloud_shape": [_V, Vector4(0.0, 0.0, 1.0, 342.0)],   # z = depth scale
	"cloud_shape2": [_V, Vector4(0.32, 1.0, 0.88, 0.12)],
	"cloud_weather": [_V, Vector4.ZERO],
	"cloud_wind": [_V, Vector4(1.0, 0.0, 0.0, 0.0)],
	"cloud_field_a": [_V, Vector4(0.08, 1400.0, 250.0, 300.0)],
	"cloud_field_b": [_V, Vector4(150.0, 0.35, 1024.0, 9600.0)],
	"cloud_field_c": [_V, Vector4(110.0, 180.0, 350.0, 45.0)],
	"cloud_periods": [_V, Vector4(32768.0, 4096.0, 512.0, 2048.0)],
	"cloud_periods2": [_V, Vector4(131072.0, 64.0, 0.0, 0.0)],
	"cloud_offset_a": [_V, Vector4.ZERO],
	"cloud_offset_b": [_V, Vector4.ZERO],
	"cloud_offset_c": [_V, Vector4.ZERO],
	"cloud_light_a": [_V, Vector4(0.05, 0.5, 0.5, 0.5)],
	"cloud_light_b": [_V, Vector4(0.7, -0.3, 0.3, 1.0)],
	"cloud_light_c": [_V, Vector4(16.0, 0.48, 1.0, 0.2)],
	"cloud_light_d": [_V, Vector4(1.0, 0.1125, 1000.0, 0.3)],
	"cloud_light_e": [_V, Vector4.ZERO],   # xyz = aerosol extinction at sea level (per m), #773
	"cloud_key_dir": [_V, Vector4(0.0, 1.0, 0.0, 0.0)],
	"cloud_key_color": [_V, Vector4.ZERO],
	"cloud_q_view": [_V, Vector4(60.0, 0.012, 800.0, 128.0)],
	"cloud_q_light": [_V, Vector4(4.0, 80000.0, 4000.0, 12000.0)],
	"cloud_q_flight": [_V, Vector4(64.0, 2.0, 0.0, 0.0)],
	"cloud_fade": [_V, Vector4(1.0, 0.75, 0.05, 0.02)],   # z = sea bounce gain
	# The temporal pass (CloudTemporal): the main view's internal size (xy) and
	# its reciprocal (zw); cloud_view is its reconstructed half-res history.
	"cloud_view_size": [_V, Vector4.ZERO],
	# Lightning (#774, CloudFlash): the source segment's ends (xyz) and its radiance (a.w, 0 = dark)
	# and spread (b.w, m).
	"cloud_flash_a": [_V, Vector4.ZERO],
	"cloud_flash_b": [_V, Vector4(0.0, 0.0, 0.0, 1000.0)],
	# The lighting model (B1, 2026-11-15): x = 0 the Nubis dual-lobe terms, 1 the four-lobe terms (
	# phase with the diffraction lobe, glow and silver, the rim, the up-probe, ground bounce, the long
	# light ray); y = the key light's gain at the resolve; z = the ambient's pull toward grey; w = the
	# long light ray's sample count (one more in a tall column).
	"cloud_look": [_V, Vector4(0.0, 1.0, 0.0, 6.0)],
	# The procedural field (B2, CLOUDS2; cloud_pf_field.gdshaderinc): x = the field model (0 the baked macro
	# SDF, 1 procedural), y = the ordinary layer's depth (m), z = the storm-cell amount, w = the mid-level
	# layer's amount.
	"cloud_pf": [_V, Vector4(0.0, 2500.0, 0.0, 0.0)],
	# x = the storm ceiling (m asl; the layer's top without storms), y = the mid-level layer's height (m asl),
	# z = the cover the columns scatter round, w = the storm cells listed in cloud_storms.
	"cloud_pf_b": [_V, Vector4(3100.0, 4800.0, 0.0, 0.0)],
	# x = the type the columns lean to (0 stratus .. 1 cumulus), y = the regional variation (0 closed / clear
	# .. 1 half covered), z = the cirrus amount, w = the tier's switches (bit 0 alto, bit 1 cirrus, bit 2 the
	# fine octave).
	"cloud_pf_c": [_V, Vector4(1.0, 0.0, 0.0, 7.0)],
	# The drift, wrapped (CloudUniforms.pf_offsets): a = (k 1 mod 65536 m).xy, (k 1 mod 2^21 m).zw;
	# b = (k 1.15 mod 65536).xy, (k 1.3 mod 65536).zw; c = (k 1.5 mod 2^21).xy, (k 2.2 mod 2^21).zw.
	"cloud_pf_off_a": [_V, Vector4.ZERO],
	"cloud_pf_off_b": [_V, Vector4.ZERO],
	"cloud_pf_off_c": [_V, Vector4.ZERO],
	# The 2D cirrus drift on the volumetric sky (xy, UV): a buffer global, so the sky material is not written every
	# frame (the quiet sky; DomeCloudDriver writes cirrus_position1/2 only for the dome's shader).
	"cloud_cirrus": [_V, Vector4.ZERO],
	"cloud_base_noise": [_S3, null],
	"cloud_blue_noise": [_S2, null],
	# The procedural field's noise volume (CloudBake.generate_pf_texture) and its storm cells (CloudStorms:
	# 16 x 1 RGBAF, world x, world z, radius m, maturity).
	"cloud_pf_noise": [_S3, null],
	"cloud_storms": [_S2, null],
	"cloud_view": [_S2, null],
}


static var _registered := false
## The placeholder each sampler global was registered with: the temporal pass binds it for a texture
## nobody pushed (the procedural field's on the baked field, and back), so a trace is never skipped for it.
static var _placeholders: Dictionary = {}


static func placeholder(name: StringName) -> Texture:
	if not _placeholders.has(name) and TABLE.has(String(name)):
		var t: int = TABLE[String(name)][0]
		if t == _S2 or t == _S3:
			_placeholders[name] = _placeholder(t)
	return _placeholders.get(name)


## Idempotent. Must run before any shader that includes cloud_params is parsed.
## A once-per-process flag, NOT global_shader_parameter_get_list(): that call is
## editor-only ("can severely damage performance") and errors at runtime. Only
## this class adds these names, so the flag is the whole truth.
static func ensure() -> void:
	if _registered:
		return
	_registered = true
	for name in TABLE:
		if ProjectSettings.has_setting("shader_globals/" + name):
			continue
		var spec: Array = TABLE[name]
		var v = spec[1]
		if v == null:
			v = placeholder(StringName(name))
		RenderingServer.global_shader_parameter_add(StringName(name), spec[0], v)


static func _placeholder(t: int) -> Texture:
	var img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 1, 1, 1))
	if t == _S3:
		var tex := ImageTexture3D.new()
		tex.create(Image.FORMAT_RGBA8, 1, 1, 1, false, [img])
		return tex
	return ImageTexture.create_from_image(img)
