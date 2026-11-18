// Copyright (c) 2023-2025 Cory Petkovsek and Contributors
// Copyright (c) 2021 J. Cuellar
//
// VOLUMETRIC wrapper: the planet_sky body plus the volumetric cumulus (src/sky/clouds/shaders/).
// CloudBridge swaps it onto the sky material at runtime when cloud_quality != low; it is never bound in the
// editor, which is why its cloud_* globals can be registered at runtime (CloudGlobals.ensure).
// The screen's half-res pass marches what the temporal pass does not own; the reflection octmap's half-res pass,
// which Godot renders into the octmap's own mip 1, draws the finished sky (CLOUDS_CUBE_COLOR: planet_sky_body's
// sky() has the story of the flickering windows). Other layouts, CloudBridge.sky_layout: 1 no half-res pass
// (planet_sky_volumetric_fr), 2 the old one (planet_sky_volumetric_hr: encoded weights in the octmap's mip 1).
shader_type sky;
render_mode use_debanding, use_half_res_pass;

#define CLOUDS_VOLUMETRIC
#define CLOUDS_HALF_RES
#define CLOUDS_CUBE_COLOR
#include "res://src/sky/shaders/planet_sky_body.gdshaderinc"
