class_name AtmosphereGlobals
extends RefCounted
## The atmosphere's global shader parameters (and the sky's twinkle clock, `sky_time`). LOCKSTEP with
## the `global uniform` lines in src/sky/atmosphere/atmosphere.gdshaderinc and
## src/sky/shaders/planet_sky_body.gdshaderinc.
##
## They live in project.godot [shader_globals] because the LOW sky (planet_sky.gdshader) is bound in
## the editor, and the editor refuses a shader whose global it does not know. This table registers
## any of them that are missing at RUNTIME as well, before the first map loads (PlanetHorizon, an
## autoload, calls ensure() in _init): an open editor rewrites project.godot on exit from what it had
## in memory, and a session that started before these entries existed would drop them.

const _F := RenderingServer.GLOBAL_VAR_TYPE_FLOAT
const _V := RenderingServer.GLOBAL_VAR_TYPE_VEC4
const _S2 := RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D
const _S3 := RenderingServer.GLOBAL_VAR_TYPE_SAMPLER3D

const TABLE := {
	"sky_time": [_F, 0.0],
	"atm_transmittance_lut": [_S2, null],
	"atm_multiscatter_lut": [_S2, null],
	"atm_skyview_lut": [_S2, null],
	"atm_aerial_lut": [_S3, null],
	"atm_ambient_lut": [_S2, null],
	"atm_sun": [_V, Vector4(0.0, 1.0, 0.0, 0.0)],
	"atm_moon": [_V, Vector4(0.0, -1.0, 0.0, 0.0)],
	"atm_cam": [_V, Vector4(0.0, 32000.0, 6371000.0, 0.0)],
	"atm_medium": [_V, Vector4(1.0, 0.0, 1.0, 0.0)],
	"atm_night": [_V, Vector4.ZERO],
	"atm_town": [_V, Vector4.ZERO],
}

static var _registered := false


## Idempotent; a once-per-process flag (global_shader_parameter_get_list is editor-only).
static func ensure() -> void:
	if _registered:
		return
	_registered = true
	for name: String in TABLE:
		if ProjectSettings.has_setting("shader_globals/" + name):
			continue
		var spec: Array = TABLE[name]
		var v: Variant = spec[1]
		if v == null:
			v = placeholder(spec[0])
		RenderingServer.global_shader_parameter_add(StringName(name), spec[0], v)


## A 1-texel black texture of the global's kind (a sampler3D needs a 3D one).
static func placeholder(t: int) -> Texture:
	var img := Image.create(1, 1, false, Image.FORMAT_RGBAH)
	img.fill(Color(0, 0, 0, 1))
	if t == _S3:
		var tex := ImageTexture3D.new()
		tex.create(Image.FORMAT_RGBAH, 1, 1, 1, false, [img])
		return tex
	return ImageTexture.create_from_image(img)
