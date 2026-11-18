shader_type spatial;
render_mode unshaded, cull_disabled;

// Cloud-shadow transmittance bake for the OCEAN:
// a 256^2 window that follows the camera, each texel the sun's transmittance
// through the cloud layer at that world XZ — from the SAME stage-1 macro
// field the CPU twin mirrors, so water shadows agree with sun dimming.
// The ocean samples this cheaply per pixel; marching per ocean pixel was the
// cost this pass exists to avoid (theirs refreshes 1/4 rows; ours is small
// enough to redraw whole every frame).
//
// Drawn on a quad in an OWN SubViewport (CloudShadowWindow owns the rig). Output:
// ALBEDO.r = transmittance (cloud_shadow_march.gdshaderinc, shared with the
// ground's sun-space bake).
//
// Depends on the cloud GLOBAL uniforms (cloud_params.gdshaderinc): the
// material compiles only after CloudGlobals.ensure() — CloudShadowWindow calls it
// before building the rig.

#include "res://src/sky/shaders/planet_atmosphere.gdshaderinc"
#include "res://src/sky/clouds/shaders/cloud_params.gdshaderinc"
#include "res://src/sky/clouds/shaders/cloud_field.gdshaderinc"
#include "res://src/sky/clouds/shaders/cloud_shadow_march.gdshaderinc"

uniform vec2 window_origin = vec2(-6000.0);
uniform float window_size = 12000.0;

void fragment() {
	// World XZ this texel stands for (UV comes from the quad). No shadow when the
	// key light is at/below the horizon — the moon then, and global dimming
	// handles twilight (plus the earth-shadow term in the clouds themselves).
	// R: the transmittance with the multiple-scattering leak (the light in the water, the foam); G: the DIRECT beam
	// alone, e^-tau (owner prompts/43: a sea glint is the sun's mirror image, and 20 % of it leaked through a tower).
	float tau = cloud_shadow_tau(window_origin + UV * window_size, cloud_key_dir.xyz);
	ALBEDO = vec3(cloud_shadow_transmittance_tau(tau), exp(-tau), 0.0);
}
