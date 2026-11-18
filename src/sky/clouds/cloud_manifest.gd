class_name CloudManifest
extends RefCounted
## The bake's manifest (src/sky/clouds/baked/cloud_assets.json). Plain git, so
## it is present on every peer, the dedicated server included, even when the
## LFS payloads are not. The single source of truth for the constants shared by
## the shader, CloudFieldTwin and CloudWeather: nothing here is duplicated as a
## literal elsewhere.

const DEFAULT_PATH := "res://src/sky/clouds/baked/cloud_assets.json"

var version := 1
var wrap_m := 131072.0
var assets: Dictionary = {}
var field: Dictionary = {}
var channel_top_m: Array = [650.0, 2600.0, 9000.0]
var coverage_lut: Dictionary = {}
var coverage_lut2: Dictionary = {}


static func load_default() -> CloudManifest:
	if not FileAccess.file_exists(DEFAULT_PATH):
		return defaults()
	var d = JSON.parse_string(FileAccess.get_file_as_string(DEFAULT_PATH))
	return from_dict(d) if d is Dictionary else defaults()


static func defaults() -> CloudManifest:
	var lin: Array = []
	for i in 33:
		lin.append(float(i) / 32.0)
	return from_dict({
		"wrap_m": 131072.0,
		"assets": {"macro": {"period_m": 32768.0, "height_m": 9600.0, "sdf_range_m": 1024.0,
				"dims": [256, 256, 64]},
			"base": {"period_m": 4096.0}, "detail": {"period_m": 512.0},
			"curl": {"period_m": 2048.0}, "scatter": {"period_m": 131072.0}},
		"field": {"birth_band": 0.08, "birth_m": 1400.0, "erode_m": 250.0, "inflate_m": 300.0,
			"edge_m": 150.0, "erosion": 0.35},
		"channel_top_m": [650.0, 2600.0, 9000.0],
		"coverage_lut": {"fraction": lin, "deck": lin, "cumulus": lin, "cb": lin},
	})


static func from_dict(d: Dictionary) -> CloudManifest:
	var m := CloudManifest.new()
	m.version = int(d.get("version", 1))
	m.wrap_m = float(d.get("wrap_m", 131072.0))
	m.assets = d.get("assets", {})
	m.field = d.get("field", {})
	m.channel_top_m = d.get("channel_top_m", m.channel_top_m)
	m.coverage_lut = d.get("coverage_lut", {})
	m.coverage_lut2 = d.get("coverage_lut2", {})
	return m


## The texture periods the runtime samples at. Detail and curl are generated at
## startup (CloudBake) and have no manifest entry since 88ac3d5f3: their period
## fell to 0, every detail and curl fetch divided by zero and read a NaN
## coordinate, and stage 2's carve and curl were dead until #771. A period the
## manifest does not carry comes from here.
const RUNTIME_PERIODS := {"macro": 32768.0, "base": 4096.0, "detail": 512.0, "curl": 2048.0,
		"scatter": 131072.0}


func period(asset: String) -> float:
	var p := float(assets.get(asset, {}).get("period_m", 0.0))
	return p if p > 0.0 else float(RUNTIME_PERIODS.get(asset, 0.0))


## (deck, cumulus, cb) weights of the continuous type 0 deck .. 0.5 cumulus .. 1 Cb.
## LOCKSTEP with cloud_type_weights() in cloud_field.gdshaderinc.
static func type_weights(t: float) -> Vector3:
	var wd := clampf(1.0 - 2.0 * t, 0.0, 1.0)
	var wb := clampf(2.0 * t - 1.0, 0.0, 1.0)
	return Vector3(wd, 1.0 - wd - wb, wb)


func channel_top(cloud_type: float) -> float:
	var w := type_weights(cloud_type)
	return w.x * float(channel_top_m[0]) + w.y * float(channel_top_m[1]) + w.z * float(channel_top_m[2])


## Shader coverage threshold that yields `sky_fraction` of the sky covered.
## Mixed types blend the channel SDFs linearly, and the sky fraction of a blend is
## not the blend of the fractions, so the bake inverts the exact blended rule per
## type (coverage_lut2, evenly spaced types); between two type rows, interpolate.
## Older manifests fall back to weighting the single-channel LUTs.
func coverage_for(sky_fraction: float, cloud_type: float) -> float:
	var f := clampf(sky_fraction, 0.0, 1.0)
	var rows: Array = coverage_lut2.get("rows", [])
	if rows.size() >= 2:
		var x := clampf(cloud_type, 0.0, 1.0) * float(rows.size() - 1)
		var i := mini(int(x), rows.size() - 2)
		return lerpf(_row(rows[i], f), _row(rows[i + 1], f), x - float(i))
	var w := type_weights(cloud_type)
	return w.x * _lut(&"deck", f) + w.y * _lut(&"cumulus", f) + w.z * _lut(&"cb", f)


func _lut(ch: StringName, f: float) -> float:
	return _row(coverage_lut.get(String(ch), []), f)


func _row(col: Array, f: float) -> float:
	if col.size() < 2:
		return f
	var x := f * float(col.size() - 1)
	var i := mini(int(x), col.size() - 2)
	return lerpf(float(col[i]), float(col[i + 1]), x - float(i))
