class_name CameraCompositorFollow
extends RefCounted
## A Camera3D's own Compositor REPLACES the WorldEnvironment's for that camera (Godot's
## camera_set_compositor; perf_capture.gd's note), it does not add to it. ZgUnderwater (Zeegang)
## gives every current camera one, for its underwater pass and lens drops, so an effect that lives
## only on the environment's compositor silently stops running on the live map: the temporal cloud
## pass (card #770: published frame 0, every HIGH frame on the full-res per-pixel march) and
## SenseOfSpeed's motion blur did.
##
## The fix is the owner's side of the pair: keep the effect on the environment's compositor (a
## camera without its own uses that one) AND ride the current camera's own, moving with it when the
## camera changes. Call follow() every frame with the camera's compositor of the moment; it only
## writes a list when the effect is missing or the compositor changed.


## The compositor `cam` renders with when it has its own, else null (the environment's runs).
## `home` is the compositor the effect lives on anyway (the environment's): a camera handed that same
## object counts as having none, so moving off it never strips the effect from its home.
static func own_compositor(cam: Camera3D, home: Compositor = null) -> Compositor:
	if cam == null or not is_instance_valid(cam) or cam.compositor == home:
		return null
	return cam.compositor


## `effect` leaves `old` and joins `now` (either may be null); returns `now`, the caller's new
## `old`. Other effects in both lists are left as they are. `front`: insert first instead of last
## (post-transparent order matters: a motion blur goes before ZgUnderwater's medium and lens drops,
## which sit on the glass).
static func follow(effect: CompositorEffect, old: Compositor, now: Compositor, front := false) -> Compositor:
	if effect == null:
		return now
	if old != null and old != now:
		var fx: Array[CompositorEffect] = old.compositor_effects.duplicate()
		if fx.has(effect):
			fx.erase(effect)
			old.compositor_effects = fx
	if now != null and not now.compositor_effects.has(effect):
		var fx: Array[CompositorEffect] = now.compositor_effects.duplicate()
		if front:
			fx.insert(0, effect)
		else:
			fx.append(effect)
		now.compositor_effects = fx
	return now
