class_name CloudAssets
extends RefCounted
## Loads the cloud volumes and builds the GPU textures. One instance per process.
##
## What a boot pays:
##   * shared(): the manifest and the committed 16 KB blue noise (present, real, of the manifest's
##     size; verify(.., true) also hashes it), and the base noise volume GENERATED on the main
##     RenderingDevice (CloudBake.generate_textures: no readback, no re-upload, no CPU copy);
##   * ensure_pf(): the procedural field's 128^3 noise volume, generated on the GPU on the first ask.
## Headless (a dedicated server) there is no device and no texture, and the clouds are not drawn.
##
## A missing file or an un-pulled LFS pointer makes `ok` false with a named
## error; CloudBridge then keeps Sky3D's own sky. The sky is never left black.

const DIR := "res://src/sky/clouds/baked"
const LFS_MAGIC := "version https://git-lfs"

static var _shared: CloudAssets = null

## The committed files are present, real (not LFS pointers) and of the manifest's sizes.
var ok := false
## The noise textures the field samples exist (base, blue). The procedural noise is ensure_pf()'s.
var textures_ok := false
var errors := PackedStringArray()
var manifest: CloudManifest
## The base noise (Perlin-Worley + three Worley octaves): the slope veil's ragged edge, the rain shafts.
var base_tex: Texture3D
## Blue noise for the march's ray jitter.
var blue_tex: ImageTexture
## The procedural field's noise (B2: the volume, an integer hash), ensure_pf()'s.
var pf_tex: Texture3D
var _dir := DIR


static func shared() -> CloudAssets:
	if _shared == null:
		_shared = CloudAssets.new()
		_shared._load(DIR)
	return _shared


## Every manifest file present, not an LFS pointer, of the manifest's size; `deep` also compares
## the SHA-256 (~26 MB hashed: the tests and tools ask for it, a boot does not).
static func verify(m: CloudManifest, dir: String, deep := false) -> PackedStringArray:
	var errs := PackedStringArray()
	for key in m.assets:
		var e: Dictionary = m.assets[key]
		# An entry with no file carries constants only (the macro field's period and height, which the
		# procedural field's uniforms still read; its volume is not part of the HIGH tier).
		if not e.has("file"):
			continue
		var path := dir.path_join(String(e.get("file", "")))
		if not FileAccess.file_exists(path):
			errs.append("%s missing" % path)
			continue
		var f := FileAccess.open(path, FileAccess.READ)
		var size := f.get_length()
		var head := f.get_buffer(mini(size, 24)).get_string_from_ascii()
		f.close()
		if head.begins_with(LFS_MAGIC):
			errs.append("%s is an LFS pointer — run `git lfs pull`" % path)
			continue
		if size != int(e.get("bytes", -1)):
			errs.append("%s is %d bytes, manifest says %d" % [path, size, int(e.get("bytes", -1))])
			continue
		if deep and FileAccess.get_sha256(path) != String(e.get("sha256", "")):
			errs.append("%s sha256 does not match the manifest" % path)
	return errs



static func _tex2d(bytes: PackedByteArray, dims: Array, fmt: Image.Format) -> ImageTexture:
	if bytes.is_empty():
		return null
	return ImageTexture.create_from_image(Image.create_from_data(dims[0], dims[1], false, fmt, bytes))


func _file(key: String) -> String:
	return _dir.path_join(String(manifest.assets[key]["file"]))


func _load(dir: String) -> void:
	_dir = dir
	manifest = CloudManifest.load_default()
	errors = verify(manifest, dir)
	if not errors.is_empty():
		push_warning("[clouds] baked assets unusable, volumetric clouds disabled: %s" % "; ".join(errors))
		return
	ok = true
	var a := manifest.assets
	blue_tex = _tex2d(FileAccess.get_file_as_bytes(_file("blue")), a["blue"]["dims"], Image.FORMAT_RGBA8)
	# The base noise is generated on the GPU at startup (CloudBake); BLUE stays committed (16 KB).
	# Headless there is no device to generate on, and nothing draws the clouds.
	if DisplayServer.get_name() != "headless":
		base_tex = CloudBake.generate_textures().get("base")
	textures_ok = base_tex != null and blue_tex != null
	if not textures_ok and DisplayServer.get_name() != "headless":
		push_warning("[clouds] cloud texture construction failed; volumetric clouds disabled")



## The procedural field's noise volume (B2, CloudBake.generate_pf_texture: 128^3 RGBA8 + mips, ~9 MB of
## VRAM), generated on the first ask. False without a RenderingDevice (headless) or on a failed kernel.
func ensure_pf() -> bool:
	if pf_tex != null:
		return true
	if DisplayServer.get_name() == "headless":
		return false
	pf_tex = CloudBake.generate_pf_texture()
	return pf_tex != null


