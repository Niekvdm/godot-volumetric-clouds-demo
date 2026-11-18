class_name CloudQuality
extends RefCounted
## The cloud tiers CloudBridge reads. `high` is the volumetric field:
## the procedural cloud field marched in the sky, a full-resolution flight pass in front of geometry,
## the temporal pass for the main view and cloud shadows on the ground. `off` leaves Sky3D's own sky.

## The tier CloudBridge draws. Call CloudBridge.reapply() after changing it.
static var quality: StringName = &"high"

const PARAMS := {
	&"off": {"volumetric": false, "ground_shadows": false},
	&"high": {"volumetric": true,
		# How far the march reaches (m), and where the close-up detail fades out (m from the camera).
		"cut_m": 80000.0, "detail_fade": Vector2(4000.0, 12000.0),
		# The terrain/flight pass (full resolution, in front of geometry).
		"flight": true, "flight_steps": 128,
		# The temporal pass (CloudTemporal): the main view traces 1 of every lattice^2 half-res pixels
		# per frame and reconstructs the rest; retain = the history's weight on a traced pixel;
		# jitter = sub-pixel spread of the traced ray, in half-res texels.
		"temporal": true, "temporal_lattice": 2, "temporal_retain": 0.9, "temporal_jitter": 0.5,
		# Cloud shadows on the ground (CloudShadowReceiver): one sun-aligned decal.
		"ground_shadows": true,
		# The lighting model: 1 = the four-lobe phase terms (cloud_light.gdshaderinc), 0 = the Nubis
		# dual-lobe ones; the key's gain at the resolve, the ambient's pull toward grey and the long
		# light ray's samples (one more in a tall column) belong to model 1.
		"lighting": 1, "key_gain": 0.7, "amb_grey": 0.2, "light_samples_ff": 6,
		# The procedural weather-typed field's march (cloud_pf_field.gdshaderinc): steps from
		# pf_step_base_m growing pf_step_growth per metre to pf_step_max_m (x2 in clear air; x4 over a
		# column's own tops with pf_skip), pf_max_steps, pf_light light samples (one more in a tall
		# column), the mid-level layer, the cirrus and the close-up erosion octave. pf_density_k scales
		# its extinction.
		"pf_step_base_m": 40.0, "pf_step_growth": 0.016, "pf_step_max_m": 2000.0,
		"pf_max_steps": 160, "pf_light": 5, "pf_alto": true, "pf_cirrus": true, "pf_fine": true,
		"pf_density_k": 0.5, "pf_skip": true},
}
