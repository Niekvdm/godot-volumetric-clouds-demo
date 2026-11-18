class_name CloudShadowWindow
extends Node
## Cloud shadows for a sea: a RES^2 window of the sun's transmittance
## through the cloud layer, SPAN metres across, following the camera — baked on the GPU by
## cloud_shadow_bake.gdshader from the clouds' stage-1 macro field (the same one the CPU twin
## mirrors, so the water's shadows agree with the sun's dimming) on a quad in its own SubViewport.
## A sea samples `texture` over `origin` .. `origin + SPAN` and multiplies its sun terms by it.
## Shared by both oceans (OceanSurface, the Zeegang glue), through SeaCloudShadow, which swaps in
## its LOW sibling DomeShadowWindow (the dome cumulus, #761) while the dome draws the clouds. One job: the bake rig. The march itself is
## cloud_shadow_march.gdshaderinc, shared with the ground's sun-space map (CloudShadowReceiver): the sea
## samples this world-XZ window, the ground decal needs one texel per sun ray, so they are two targets.

const RES := 256
const SPAN := 12000.0

## The transmittance window (R); null when the volumetric clouds are not running.
var texture: Texture2D
## World XZ of the window's corner (INF until the first follow()).
var origin := Vector2(INF, INF)

var _vp: SubViewport
var _mat: ShaderMaterial


## Builds the rig (call once in the tree). False, and no texture, when the volumetric clouds are
## not running — the sea keeps its unshadowed look.
func setup() -> bool:
	# The bake material needs the cloud GLOBAL uniforms registered before it compiles.
	CloudGlobals.ensure()
	if not CloudAssets.shared().textures_ok:
		return false
	_vp = SubViewport.new()
	_vp.size = Vector2i(RES, RES)
	# This build spells the update/clear enums with the render_target_* names (verified via
	# ClassDB); own_world_3d / transparent_bg are Viewport's.
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.own_world_3d = true
	_vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	_vp.transparent_bg = false
	add_child(_vp)
	var cam := Camera3D.new()
	_vp.add_child(cam)
	cam.current = true
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 2.0
	cam.near = 0.1
	cam.far = 10.0
	# The camera looks -Z: at z = +1 it sees the quad. It sat at z = -1 from 2026-09-29 to #760 and
	# saw only the clear colour (0.298), a flat 0.40 sun window on the sea in every tier (#759).
	cam.position = Vector3(0.0, 0.0, 1.0)
	var quad := MeshInstance3D.new()
	_vp.add_child(quad)
	quad.mesh = QuadMesh.new()
	(quad.mesh as QuadMesh).size = Vector2(2.0, 2.0)
	_mat = ShaderMaterial.new()
	_mat.shader = load("res://src/sky/clouds/shaders/cloud_shadow_bake.gdshader") as Shader
	quad.material_override = _mat
	texture = _vp.get_texture()
	return true


## Draws every frame while on; SeaCloudShadow turns it off while the dome casts instead (LOW, #761).
func set_active(on: bool) -> void:
	if _vp != null:
		_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_DISABLED


## Snaps the window to the camera on the texel grid (a crawling window
## shimmers at the borders). True when it moved — push the new `origin` to the sea.
func follow(camera_xz: Vector2) -> bool:
	if _vp == null:
		return false
	var texel := SPAN / float(RES)
	var o := (camera_xz - Vector2(SPAN, SPAN) * 0.5).snapped(Vector2(texel, texel))
	if o.distance_to(origin) < 0.01:
		return false
	origin = o
	_mat.set_shader_parameter("window_origin", o)
	_mat.set_shader_parameter("window_size", SPAN)
	return true
