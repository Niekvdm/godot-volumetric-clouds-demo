// Volumetric-cloud globals. LOCKSTEP with CloudGlobals.TABLE (cloud_globals.gd):
// same names, same types, both directions (test_cloud_optics). Packing is
// documented in CloudGlobals.
#ifndef CLOUD_PARAMS_INC
#define CLOUD_PARAMS_INC

global uniform int cloud_mode;
global uniform int cloud_flags;
global uniform int cloud_frame;
global uniform int cloud_debug;
global uniform vec4 cloud_layer;
global uniform vec4 cloud_shape;
global uniform vec4 cloud_shape2;
global uniform vec4 cloud_weather;
global uniform vec4 cloud_wind;
global uniform vec4 cloud_field_a;
global uniform vec4 cloud_field_b;
global uniform vec4 cloud_field_c;
global uniform vec4 cloud_periods;
global uniform vec4 cloud_periods2;
global uniform vec4 cloud_offset_a;
global uniform vec4 cloud_offset_b;
global uniform vec4 cloud_offset_c;
global uniform vec4 cloud_light_a;
global uniform vec4 cloud_light_b;
global uniform vec4 cloud_light_c;
global uniform vec4 cloud_light_d;
global uniform vec4 cloud_light_e;
global uniform vec4 cloud_key_dir;
global uniform vec4 cloud_key_color;
global uniform vec4 cloud_q_view;
global uniform vec4 cloud_q_light;
global uniform vec4 cloud_q_flight;
global uniform vec4 cloud_fade;
global uniform vec4 cloud_view_size;
global uniform vec4 cloud_flash_a;
global uniform vec4 cloud_flash_b;
global uniform vec4 cloud_look;
global uniform vec4 cloud_pf;
global uniform vec4 cloud_pf_b;
global uniform vec4 cloud_pf_c;
global uniform vec4 cloud_pf_off_a;
global uniform vec4 cloud_pf_off_b;
global uniform vec4 cloud_pf_off_c;
global uniform vec4 cloud_cirrus;
global uniform sampler3D cloud_base_noise : filter_linear_mipmap, repeat_enable;
global uniform sampler2D cloud_blue_noise : filter_nearest, repeat_enable;
global uniform sampler3D cloud_pf_noise : filter_linear_mipmap, repeat_enable;
global uniform sampler2D cloud_storms : filter_nearest, repeat_disable;
global uniform sampler2D cloud_view : filter_linear, repeat_disable;

#endif
