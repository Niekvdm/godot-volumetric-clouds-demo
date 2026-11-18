// The march. Needs planet_atmosphere, sky_scatter, cloud_params, cloud_field,
// cloud_light first. Depth code is LOCKSTEP with CloudOptics.encode_depth.
#ifndef CLOUD_MARCH_INC
#define CLOUD_MARCH_INC

const float CLOUD_DEPTH_K = 64.0;
const float CLOUD_DEPTH_SPAN = 11.0;
// Godot's sky template adds +-1/255 debanding to the half-res RGB. Scaling the
// stored weights by 64 puts that noise below 0.01 % (fp16 keeps ~11 bits at 64).
const float CLOUD_ENC_SCALE = 64.0;

struct CloudSample {
	float key_w;
	float amb_w;
	float T;
	float depth_m;
};

vec4 cloud_encode(CloudSample s) {
	float code = log2(1.0 + max(s.depth_m, 0.0) / CLOUD_DEPTH_K) / CLOUD_DEPTH_SPAN;
	return vec4(vec3(s.key_w, s.amb_w, code) * CLOUD_ENC_SCALE, clamp(s.T, 0.0, 1.0));
}

CloudSample cloud_decode(vec4 e) {
	CloudSample s;
	vec3 v = e.rgb / CLOUD_ENC_SCALE;
	s.key_w = max(v.r, 0.0);
	s.amb_w = max(v.g, 0.0);
	s.T = clamp(e.a, 0.0, 1.0);
	s.depth_m = (exp2(v.b * CLOUD_DEPTH_SPAN) - 1.0) * CLOUD_DEPTH_K;
	return s;
}

// 64x64 void-and-cluster blue noise (IGN striped, Bayer streaked). The
// golden-ratio walk animates the dither only when TAA is OFF (cloud_flags
// bit 1 inverted since 2026-09-28: the original assumption — that TAA would
// integrate an animated dither — does not hold for Godot's sky pixels, and
// the un-integrated per-frame jitter was the cloud FLICKER under TAA. A
// screen-fixed pattern is temporally stable by construction; without TAA
// nothing resolves a static pattern, so the walk runs there instead.)
vec2 cloud_blue(vec2 frag) {
	vec2 bn = texelFetch(cloud_blue_noise, ivec2(mod(frag, 64.0)), 0).rg;
	if ((cloud_flags & 2) == 0) {
		bn = fract(bn + float(cloud_frame % 4096) * vec2(0.7548777, 0.5698403));
	}
	return bn;
}

vec3 cloud_ray_pos(vec3 ro, vec3 rd, float h0, float t) {
	return vec3(ro.x + rd.x * t, planet_altitude_along_ray(h0, rd.y, t, PLANET_EARTH_RADIUS),
			ro.z + rd.z * t);
}

// The procedural field's own march (B2): cloud_march_layer hands it the ray when cloud_pf.x = 1.
#include "res://src/sky/clouds/shaders/cloud_pf_march.gdshaderinc"

// March the layer along one ray: the procedural field's march (cloud_pf_march.gdshaderinc).
// ro = camera (world, y = altitude asl), rd unit. cheap = the reflection/radiance branch.
// t_max: the scene distance (flight pass: the depth buffer); the shell segment already ends at the
// sea-level sphere, which is where the transparent ocean is.
CloudSample cloud_march_layer(vec3 ro, vec3 rd, float t_max, float jit, float jit_l, bool cheap,
		int max_steps_in, int light_n_in) {
	return cloud_pf_march_layer(ro, rd, t_max, jit, jit_l, cheap, max_steps_in, light_n_in);
}

// RAIN SHAFTS / VIRGA (#772). Rain under a raining cloud, in the sub-cloud layer the
// cloud march never enters: from the base down to cloud_weather.w metres below it
// (CloudWeather.rain_reach_for: light rain under a high base evaporates on the way
// down, virga; heavy rain reaches the sea). A short jittered march (the temporal
// pass integrates the jitter):
//   * the column: the field sampled at its own slab height above the base, upwind of the
//     sample by the drift of the falling rain (shafts lean downwind), and only deep
//     inside its footprint: thin or shallow cloud does not rain;
//   * streaks: the base noise stretched in height (curtains, not blobs);
//   * the fall profile: full under the base, gone at the reach;
//   * faded in from the camera: the near field is the rain particles' own.
// Lighting: grey, mostly the dim light under the base (ambient at the cloud's
// AMBIENT_FLOOR) plus the sun where the cloud above lets it through.
// The deck's density (CloudWeather.DENSITY_DECK): the slope veil scales by the layer's.
const float CLOUD_DENSITY_DECK = 0.34;
const float CLOUD_RAIN_SIGMA = 0.002;
// Horizontal drift of falling rain per metre of fall, per m/s of steering wind: drops
// fall at ~7 m/s (#772 review: the slant was a fixed 0.6 m/m along the normalised wind
// direction, a 31 deg lean in calm air).
const float CLOUD_RAIN_FALL_MPS = 7.0;
const float CLOUD_RAIN_NEAR_M = 700.0;
const float CLOUD_RAIN_CUT_M = 30000.0;
// The analytic tail past the cut reaches at most this far along the ray (cloud_rain_march).
const float CLOUD_RAIN_TAIL_M = 150000.0;
// 28, not 14 (owner prompts/40, 2026-11-16): the veil under a raining base is smooth, and 14 jittered samples left
// it as noise the temporal pass integrates only with a still camera; in motion it read as blotches of the trace's
// cells (the cloud motion lab: tools/sky/cloud_motion_lab.sh, rain + a 40 deg/s pan). +0.0 ms measured there.
const int CLOUD_RAIN_STEPS = 28;
const float CLOUD_RAIN_AMB = 0.2;
const float CLOUD_RAIN_KEY = 0.04;
// The slope veil's field probe: under the base it reads the cloud this far above it;
// the veil is whole CLOUD_CONTACT_IN_M inside the visible surface.
const float CLOUD_CONTACT_PROBE_M = 120.0;
const float CLOUD_CONTACT_IN_M = 120.0;

CloudSample cloud_rain_march(vec3 ro, vec3 rd, float t_max, float jit) {
	CloudSample r;
	r.key_w = 0.0;
	r.amb_w = 0.0;
	r.T = 1.0;
	r.depth_m = 0.0;
	float reach = cloud_weather.w;
	float rain = clamp(cloud_weather.x, 0.0, 1.0);
	if (reach <= 0.0 || rain <= 0.0) {
		return r;
	}
	float h0 = max(ro.y, 0.0);
	float lo = max(cloud_layer.x - reach, 0.0);
	vec2 seg = planet_cloud_shell_segment(h0, rd.y, lo, cloud_layer.x,
			min(CLOUD_RAIN_CUT_M, t_max), PLANET_EARTH_RADIUS);
	seg.x = max(seg.x, 0.0);
	if (seg.x >= seg.y) {
		return r;
	}
	float ds = cloud_depth_scale();
	float sigma = CLOUD_RAIN_SIGMA * pow(rain, 0.8);
	float dt = (seg.y - seg.x) / float(CLOUD_RAIN_STEPS);
	float cos_t = dot(rd, cloud_key_dir.xyz);
	// Under the whole raining column (#774): the light that reaches the shafts came through it.
	float col_t = cloud_column_amb(cloud_column_od(0.0));
	float dacc = 0.0;
	float wacc = 0.0;
	float csum = 0.0;
	float cn = 0.0;
	for (int i = 0; i < CLOUD_RAIN_STEPS; i++) {
		float t = seg.x + (float(i) + jit) * dt;
		vec3 p = cloud_ray_pos(ro, rd, h0, t);
		float fall = cloud_layer.x - p.y;
		if (fall <= 0.0) {
			continue;
		}
		float near = smoothstep(CLOUD_RAIN_NEAR_M, 2.5 * CLOUD_RAIN_NEAR_M, t);
		float prof = 1.0 - smoothstep(0.55 * reach, reach, fall);
		if (near * prof <= 0.0) {
			continue;
		}
		// Capped at 1.2: the steering wind is the 1200 m one, and the air the rain falls
		// through slows toward the ground.
		vec2 up = p.xz - cloud_wind.xy * min(cloud_wind.z / CLOUD_RAIN_FALL_MPS, 1.2) * fall;
		// The procedural field's stratus slab is a few hundred metres deep (its column top ~0.11 of the layer):
		// probed 250 m up it read clear air over a whole raining deck. Its own height: cloud_wind.w.
		vec3 pc = vec3(up.x, cloud_layer.x + cloud_wind.w * ds, up.y);
		float sd;
		vec2 vis;
		cloud_macro_q(pc, pc.y - cloud_layer.x, 2.0, false, sd, vis);
		// Only the cores rain: from 60 m inside the footprint, whole 450 m in (a looser
		// test rained under every cloud, and the shafts summed to one haze at the horizon).
		// The procedural field has no depth, only its density (CLOUD_PF_DEPTH_M x shape): its own ramp
		// over the shape, cloud_offset_c.zw (CLOUDS5, R29: the baked field's rain-sky brightness).
		float col = smoothstep(cloud_offset_c.z, cloud_offset_c.w, -vis.x / CLOUD_PF_DEPTH_M);
		csum += col;
		cn += 1.0;
		if (col <= 0.0) {
			continue;
		}
		float n = textureLod(cloud_base_noise, vec3((up - cloud_offset_a.zw) / cloud_periods.y,
				p.y / (6.0 * cloud_periods.y)), 2.0).g;
		float streak = mix(0.1, 1.0, smoothstep(0.35, 0.75, n));
		float dens = sigma * col * prof * near * streak;
		float ts = exp(-dens * dt);
		float w = r.T * (1.0 - ts);
		// Under the core the sun is mostly blocked by the cloud above; the drops' phase
		// leans forward (a shaft against the sun glows a little).
		float key = CLOUD_RAIN_KEY * (1.0 - 0.75 * col) * (1.0 + 1.5 * max(cos_t, 0.0))
				* smoothstep(-0.006, 0.006, cloud_key_dir.y + sqrt(max(p.y, 0.0) * 2.0 / PLANET_EARTH_RADIUS));
		r.key_w += w * key * col_t;
		r.amb_w += w * CLOUD_RAIN_AMB * col_t;
		dacc += w * t;
		wacc += w;
		r.T *= ts;
		if (r.T < 0.03) {
			break;
		}
	}
	// THE RAIN PAST THE CUT (owner prompts/41, 2026-11-16: "the horizon atmosphere line shines through the ... rain
	// veil when looking at it from clouds level"). The shafts were marched to CLOUD_RAIN_CUT_M and nothing past it,
	// so from the base of a raining deck (and from the ground at the horizon) the clear horizon and the sunlit clouds
	// 30-160 km off showed through what is tens of km of rain (moderate rain: 5-10 km visibility). The rest of the
	// ray's path in the rain band, as one slab: the march's own raining share (at least a quarter of the rain
	// amount: a dry gap round the eye is not a dry horizon), the shafts' mean profile and streaks (~0.5), lit as the
	// veil.
	if (r.T >= 0.03 && t_max > CLOUD_RAIN_CUT_M) {
		vec2 tail = planet_cloud_shell_segment(h0, rd.y, lo, cloud_layer.x, t_max, PLANET_EARTH_RADIUS);
		tail.x = max(tail.x, CLOUD_RAIN_CUT_M);
		if (tail.x < tail.y) {
			float span = min(tail.y - tail.x, CLOUD_RAIN_TAIL_M);
			float colf = max(cn > 0.0 ? csum / cn : 0.0, 0.25 * rain);
			float k = sigma * colf * 0.5;
			float tt = exp(-k * span);
			float w = r.T * (1.0 - tt);
			float key = CLOUD_RAIN_KEY * (1.0 - 0.75 * colf) * (1.0 + 1.5 * max(cos_t, 0.0))
					* smoothstep(-0.006, 0.006, cloud_key_dir.y + sqrt(max(cloud_layer.x, 0.0) * 2.0 / PLANET_EARTH_RADIUS));
			r.key_w += w * key * col_t;
			r.amb_w += w * CLOUD_RAIN_AMB * col_t;
			dacc += w * (tail.x + min(1.0 / max(k, 1e-7), span) * 0.5);
			wacc += w;
			r.T *= tt;
		}
	}
	if (wacc > 1e-5) {
		r.depth_m = dacc / wacc;
	}
	return r;
}

// f in front of b.
CloudSample cloud_over(CloudSample f, CloudSample b) {
	CloudSample o;
	o.key_w = f.key_w + f.T * b.key_w;
	o.amb_w = f.amb_w + f.T * b.amb_w;
	o.T = f.T * b.T;
	float wf = 1.0 - f.T;
	float wb = f.T * (1.0 - b.T);
	o.depth_m = wf + wb > 1e-5 ? (wf * f.depth_m + wb * b.depth_m) / (wf + wb) : b.depth_m;
	return o;
}

// THE CLOUD MEETS THE SLOPE (#772). Where terrain rises into a low base the ray to
// it ends inside the base's thin first metres, and the march alone took it from clear
// to opaque over ~20-50 m of slope: a hard horizontal line round the mountain. Real
// bases sag onto a slope (the air is forced up it and saturates lower; scud hangs
// under the base), so the ray to a surface between CLOUD_CONTACT_BELOW_M under the
// base and CLOUD_CONTACT_ABOVE_M over it gains a veil of cloud just in front of the
// surface, growing with the surface's height in that band, and only where the field
// has cloud over the point (stage 1 sampled just above the base). Geometry only (the
// sea is not in the depth buffer); faded in from the camera, whose own fog is
// FogFormation's.
const float CLOUD_CONTACT_BELOW_M = 260.0;
const float CLOUD_CONTACT_ABOVE_M = 60.0;
const float CLOUD_CONTACT_DEPTH_M = 150.0;
const float CLOUD_CONTACT_SIGMA = 0.02;
const float CLOUD_CONTACT_NEAR_M = 250.0;
// THE VEIL KEEPS OFF THE LOWLAND (owner prompts/82, 2026-11-17: "at night when clouds come down they touch even the
// city floor??"). A cloud sags onto a slope by a share of its own height; the band was CLOUD_CONTACT_BELOW_M deep
// under every base, so under Hachijo's ~300 m night base it ran from 40 m (the rag: the coast) and laid the veil on
// every street of Mitsune and Okago and on the whole lowland past 750 m (the eye veil too, in town). Its depth is
// CLOUD_CONTACT_BELOW_K of the base under a low one: at 300 m the veil stops ~90 m up, under a 650 m base it is the
// whole 260 m (Fuji's caps unchanged). LOCKSTEP with CloudWeather.veil_lowest_m (VEIL_BELOW_M / _K / VEIL_RAG_M).
const float CLOUD_CONTACT_BELOW_K = 0.4;
float cloud_contact_below() {
	return min(CLOUD_CONTACT_BELOW_M, CLOUD_CONTACT_BELOW_K * max(cloud_layer.x, 0.0));
}

// THE VEIL IS RAGGED (owner prompts/45, 2026-11-16: "improve the cloud collision visual with the terrain"). A cloud
// sagging onto a slope is scud and tufts, not a smooth coat: the veil read as a uniform dome on Fuji's cone with a
// level lower edge. The base noise (the rain streaks' texture, anchored to the drifting field so it moves with the
// wind), at two scales: x = metres the band's edge moves (its lower edge wanders +-CLOUD_VEIL_RAG_M), y = the density's
// tufts (CLOUD_VEIL_TUFT_LO .. HI), applied toward the band's lower edge only (cloud_veil_tufts: at full band the cap is
// solid; the first look had them over the whole cone, a mottled camouflage). cloud_pf_c.w bit 32 (tier key veil_rag);
// off: (0, 1).
const float CLOUD_VEIL_RAG_M = 90.0;
const float CLOUD_VEIL_TUFT_LO = 0.55;
const float CLOUD_VEIL_TUFT_HI = 1.2;

// The tufts' share at a band value: whole at its lower edge, none from 0.75 of it up.
float cloud_veil_tufts(vec2 rag, float band, float col) {
	return mix(rag.y, 1.0, smoothstep(0.35, 0.75, band) * smoothstep(0.5, 1.0, col));
}

vec2 cloud_veil_rag(vec3 p) {
	if ((int(cloud_pf_c.w) & 32) == 0) {
		return vec2(0.0, 1.0);
	}
	vec2 fq = (p.xz - cloud_offset_a.zw) / cloud_periods.y;
	float big = textureLod(cloud_base_noise, vec3(fq * 0.6, 0.31), 1.0).r;
	float tuft = textureLod(cloud_base_noise, vec3(fq * 2.3 + vec2(0.37, 0.71), 0.62), 0.0).b;
	return vec2((2.0 * big - 1.0) * CLOUD_VEIL_RAG_M,
			mix(CLOUD_VEIL_TUFT_LO, CLOUD_VEIL_TUFT_HI, smoothstep(0.3, 0.7, tuft)));
}

// LIT AS THE BASE ABOVE IT (#772 review 2): the march's own source terms at the
// base (h01 = 0, profile 0) with the light column from just above it, not a constant
// ambient (a summit inside a deck read as a uniform grey dome at 138-145 against the
// deck's ~162, its outline showing). p: the veil's point; t_max: its distance (the light ray's jitter range).
// The light column over p (od_l: the light ray's optical depth with the raining column, od_c: the column alone).
// The eye veil's is the same for every pixel of a frame (its point is the eye): the flight quad takes it per vertex.
vec2 cloud_veil_od(vec3 p, float t_max) {
	vec3 q = vec3(p.x, cloud_layer.x + 30.0, p.z);
	float od_ray = cloud_look.x > 0.5 ? cloud_ff_light_od(q, t_max, 0.5, int(cloud_look.w))
			: cloud_light_od(q, t_max, 0.5, int(cloud_q_light.x));
	float od_c = cloud_column_od(0.0) * cloud_column_gate(od_ray);   // the raining column over the base (#774)
	return vec2(od_ray + od_c, od_c);
}

void cloud_veil_shade(vec2 od, vec3 rd, out float s_key, out float amb) {
	vec3 q = vec3(0.0, cloud_layer.x + 30.0, 0.0);
	float od_l = od.x;
	float od_c = od.y;
	float cos_t = dot(rd, cloud_key_dir.xyz);
	if (cloud_look.x > 0.5) {
		// the four-lobe terms at the base (B1): the column's foot, the densest powder.
		float pw = cloud_ff_powder(1.0, 0.0, cos_t);
		s_key = cloud_ff_ms(cos_t, od_l) * pw + cloud_ff_ground(cloud_shape.x) * mix(0.5, 1.0, pw);
		amb = 0.25 * mix(0.5, 1.0, pw) * cloud_column_amb(od_c);
	} else {
		s_key = cloud_octaves(cos_t, od_l, 0.0, 0.0) * cloud_powder(od_l, cos_t)
				+ cloud_ms_v(0.0) * cloud_ms_diffuse(od_l) + cloud_ms_reflect(od_l);
		amb = cloud_light_d.w * cloud_amb_p(0.0) * cloud_column_amb(od_c);
	}
	s_key *= smoothstep(-0.006, 0.006, cloud_key_dir.y + sqrt(max(q.y, 0.0) * 2.0 / PLANET_EARTH_RADIUS));
}

void cloud_veil_lit(vec3 p, float t_max, vec3 rd, out float s_key, out float amb) {
	cloud_veil_shade(cloud_veil_od(p, t_max), rd, s_key, amb);
}

CloudSample cloud_contact_veil(vec3 ro, vec3 rd, float t_max) {
	CloudSample v;
	v.key_w = 0.0;
	v.amb_w = 0.0;
	v.T = 1.0;
	v.depth_m = t_max;
	if (t_max > 1e11) {
		return v;
	}
	float h0 = max(ro.y, 0.0);
	float a = planet_altitude_along_ray(h0, rd.y, t_max, PLANET_EARTH_RADIUS);
	vec2 rag = cloud_veil_rag(cloud_ray_pos(ro, rd, h0, t_max));
	float band = smoothstep(cloud_layer.x - cloud_contact_below(), cloud_layer.x + CLOUD_CONTACT_ABOVE_M, a + rag.x);
	float near = smoothstep(CLOUD_CONTACT_NEAR_M, 3.0 * CLOUD_CONTACT_NEAR_M, t_max);
	if (band * near <= 0.0 || a >= cloud_layer.y) {
		return v;
	}
	vec3 p = cloud_ray_pos(ro, rd, h0, t_max);
	// ONLY WHERE THE FIELD HAS CLOUD (#772 review 2): stage 1 at the surface's own
	// altitude (a point under the base: just above the base, the cloud it would sag
	// from), and only INSIDE its visible surface. It probed the base + 120 m footprint
	// and switched on 150 m OUTSIDE it, so a summit standing in a gap between cumulus
	// was painted grey against open sky, its top edge the terrain's silhouette.
	// At the surface's own height, but never less than CLOUD_CONTACT_PROBE_M over the base
	// (#772 review 5, measured on row 54): a slope point UNDER the base read the deck 40 m
	// up, in its ragged bottom, where the field has cloud over only ~half the ground (the
	// twin: 47 % of Fuji's box at + 40 m, 100 % at + 120 m), so the band just under the base
	// went unveiled and the cloud above it ended in a 4 px edge.
	float hc = max(a - cloud_layer.x, CLOUD_CONTACT_PROBE_M * cloud_depth_scale());
	vec3 pc = vec3(p.x, cloud_layer.x + hc, p.z);
	float sd;
	vec2 vis;
	cloud_macro_q(pc, hc, 2.0, false, sd, vis);
	// Its footprint's edge over 2.5x the inside depth, broken by the tufts (prompts/46: from above, a summit standing in
	// a gap of the field read as a hard hole cut in the cap).
	float col = 1.0 - smoothstep(-2.5 * CLOUD_CONTACT_IN_M, 0.0, vis.x);
	float od = CLOUD_CONTACT_SIGMA * CLOUD_CONTACT_DEPTH_M * band * near * col * cloud_veil_tufts(rag, band, col)
			* (cloud_layer.z / max(CLOUD_DENSITY_DECK, 1e-3));
	if (od <= 0.0) {
		return v;
	}
	v.T = exp(-od);
	float w = 1.0 - v.T;
	float s_key;
	float amb;
	cloud_veil_lit(p, t_max, rd, s_key, amb);
	// SEEN FROM ABOVE (prompts/46): an eye over the base looking down on the veil sees the cap's sunlit TOP, not its
	// base: lit as the far deck from above (cloud_far_field), blended in by how far down the eye looks.
	float from_above = smoothstep(0.0, 120.0, h0 - cloud_layer.x) * smoothstep(0.02, 0.35, -rd.y);
	if (from_above > 0.0) {
		float c_up = dot(rd, cloud_key_dir.xyz);
		float top_key = (cloud_look.x > 0.5 ? cloud_ff_ms(c_up, 1.0) * cloud_ff_powder(1.0, 1.0, c_up)
				: cloud_octaves(c_up, 1.0, 1.0, 1.0))
				* smoothstep(-0.006, 0.006, cloud_key_dir.y + sqrt(max(a, 0.0) * 2.0 / PLANET_EARTH_RADIUS));
		s_key = mix(s_key, top_key, from_above);
		amb = mix(amb, 1.0, from_above);
	}
	v.key_w = w * s_key;
	v.amb_w = w * amb;
	v.depth_m = max(t_max - 0.5 * CLOUD_CONTACT_DEPTH_M, 0.0);
	return v;
}

// THE EYE IN THE VEIL (owner prompts/44, 2026-11-16: "where they collide with terrain they leave a fog like look but
// when i go in it there's nothing"). The slope veil is drawn at a surface 250 m+ off (faded in from the camera, "whose
// own fog is FogFormation's"), but FogFormation's cloud is the environmental LCL (213 m/degC) from the ground under the
// eye, while the drawn cumulus base is the parcel LCL (125 m/degC) from the sea: at a 3 degC spread the visible base
// meets the slope ~375 m up and FogFormation's ~640 m, and the slope between drove clear through a cloud seen from
// below. Where the eye stands in the veil's band under a field with cloud over it, the ray takes the same veil as a
// slab from the eye: the veil's band and field probe at the eye, CLOUD_CONTACT_SIGMA per metre (visibility ~150 m
// at the base), fading out over the base where the march's own layer takes over, lit as the veil. One function, so
// the trace, the flight quad and the near-object test agree (cloud_nothing_before).
const float CLOUD_EYE_VEIL_M = 1500.0;

float cloud_eye_veil_sigma(vec3 ro) {
	float h0 = max(ro.y, 0.0);
	float base = cloud_layer.x;
	// On the ground only (prompts/45): the veil is the cloud SAGGING ONTO A SLOPE, CLOUD_CONTACT_DEPTH_M deep in front of
	// the surface; an eye floating under a base over the sea, or flying, is in clear air. cloud_key_color.w = the ground
	// under the eye (CloudUniforms.eye_ground_y).
	float agl = h0 - cloud_key_color.w;
	vec2 rag = cloud_veil_rag(cloud_ray_pos(ro, vec3(0.0, 1.0, 0.0), h0, 0.0));
	float band = smoothstep(base - cloud_contact_below(), base + CLOUD_CONTACT_ABOVE_M, h0 + rag.x)
			* (1.0 - smoothstep(base, base + CLOUD_CONTACT_ABOVE_M, h0))
			* (1.0 - smoothstep(0.5 * CLOUD_CONTACT_DEPTH_M, 1.5 * CLOUD_CONTACT_DEPTH_M, agl));
	if (band <= 0.0) {
		return 0.0;
	}
	vec3 p = cloud_ray_pos(ro, vec3(0.0, 1.0, 0.0), h0, 0.0);
	float hc = max(h0 - base, CLOUD_CONTACT_PROBE_M * cloud_depth_scale());
	vec3 pc = vec3(p.x, base + hc, p.z);
	float sd;
	vec2 vis;
	cloud_macro_q(pc, hc, 2.0, false, sd, vis);
	float col = 1.0 - smoothstep(-2.5 * CLOUD_CONTACT_IN_M, 0.0, vis.x);
	return CLOUD_CONTACT_SIGMA * band * col * cloud_veil_tufts(rag, band, col) * (cloud_layer.z / max(CLOUD_DENSITY_DECK, 1e-3));
}

CloudSample cloud_eye_veil_od(vec3 rd, float t_max, float sigma, vec2 od) {
	CloudSample v;
	float len = min(t_max, CLOUD_EYE_VEIL_M);
	v.T = exp(-sigma * len);
	float w = 1.0 - v.T;
	float s_key;
	float amb;
	cloud_veil_shade(od, rd, s_key, amb);
	v.key_w = w * s_key;
	v.amb_w = w * amb;
	v.depth_m = min(1.0 / max(sigma, 1e-5), 0.5 * len);
	return v;
}

CloudSample cloud_eye_veil(vec3 ro, vec3 rd, float t_max, float sigma) {
	return cloud_eye_veil_od(rd, t_max, sigma,
			cloud_veil_od(cloud_ray_pos(ro, rd, max(ro.y, 0.0), 0.0), min(t_max, CLOUD_EYE_VEIL_M)));
}


// The cloud layer plus, under raining clouds, the rain below it (in front of the
// layer for a camera under the base, behind it for one above), and the slope's veil
// behind both (it ends at the surface).
CloudSample cloud_march_to(vec3 ro, vec3 rd, float t_max, float jit, float jit_l, bool cheap,
		int max_steps_in, int light_n_in) {
	CloudSample c = cloud_march_layer(ro, rd, t_max, jit, jit_l, cheap, max_steps_in, light_n_in);
	if (cheap) {
		return c;
	}
	if (cloud_weather.w > 0.0) {
		CloudSample rn = cloud_rain_march(ro, rd, t_max, jit);
		if (rn.T < 0.9999) {
			c = ro.y < cloud_layer.x ? cloud_over(rn, c) : cloud_over(c, rn);
		}
	}
	if (t_max < 1e11 && c.T > 0.03) {
		CloudSample v = cloud_contact_veil(ro, rd, t_max);
		if (v.T < 0.9999) {
			c = cloud_over(c, v);
		}
	}
	float eye = (int(cloud_pf_c.w) & 16) != 0 ? cloud_eye_veil_sigma(ro) : 0.0;
	if (eye > 0.0) {
		c = cloud_over(cloud_eye_veil(ro, rd, t_max, eye), c);
	}
	return c;
}

// The sky pass: the whole ray, the tier's view budget.
CloudSample cloud_march(vec3 ro, vec3 rd, float jit, float jit_l, bool cheap) {
	return cloud_march_to(ro, rd, 1e12, jit, jit_l, cheap, int(cloud_q_view.w), int(cloud_q_light.x));
}

// THE SHELL cloud_march_to DRAWS IN, along a ray: the layer and, under its base, what the
// march draws there (the rain shafts' reach, the slope veil's band). A ray that meets the
// scene before it (seg.x >= min(seg.y, t_scene)) has no cloud in front of the scene:
//   * the flight quad draws nothing there (#772 review: tested from the base, every surface
//     under it was dropped before the march, veil and rain included);
//   * the temporal trace marches it PAST the scene (cloud_trace_t_max).
// One function, so the two cannot disagree about which pixels hold cloud in front of
// geometry and which hold the sky's cloud behind it.
vec2 cloud_draw_shell(vec3 ro, vec3 rd) {
	// Above the layer the far field reaches past the march cut, so test uncut there.
	bool above = ro.y > cloud_layer.y;
	float lo = max(cloud_layer.x - max(cloud_weather.w, cloud_contact_below()), 0.0);
	return planet_cloud_shell_segment(max(ro.y, 0.0), rd.y, lo, cloud_layer.y,
			above ? 1e12 : cloud_q_light.y, PLANET_EARTH_RADIUS);
}

// FOREGROUND IS NOT THE CLOUDS' BUSINESS (the rim round objects, 2026-11-13). The temporal
// trace ended every ray at the scene, so a history texel on a pole, a tree or the car
// held "no cloud". The sky pass reads the history with a plain bilinear fetch, and the
// resolve reprojects it with no disocclusion test: sky pixels beside the object took those
// empty texels, a rim of erased cloud round every foreground object, 2 px wide with a still
// camera and 7 px in a 100 km/h drive (shot set rows 90-92). A ray whose scene lies before
// the shell is marched as open sky instead: the history then holds the cloud BEHIND the
// object, the same on both sides of its silhouette, and nothing draws it over the object
// (the flight quad discards those pixels by cloud_draw_shell too; AtmFog and the velocity
// kernel compare the cloud's depth with the scene's).
// True when nothing of the march draws in front of the scene point t_scene along the ray: the trace
// marches such a pixel past it (cloud_trace_t_max), the flight quad draws nothing over it.
bool cloud_nothing_before(vec3 ro, vec3 rd, float t_scene) {
	vec2 seg = cloud_draw_shell(ro, rd);
	if (seg.x >= min(seg.y, t_scene)) {
		return true;
	}
	// IN RAIN THE SHELL STARTS AT THE CAMERA (CLOUDS4): the shafts' reach runs down to the ground, so every
	// pole, wire and roof edge lay "inside" it, the trace ended there and its history texel held only the few
	// metres of rain before it (nothing: the shafts fade in from CLOUD_RAIN_NEAR_M): the deck and the shafts
	// behind went missing round every silhouette, a bright rim against the dark rain sky (owner prompts/20).
	// Nothing of the march draws in front of a scene point nearer than the shafts' fade-in and under the slope
	// veil's band (both ends of the segment under the base: no layer between).
	int flags = int(cloud_pf_c.w);
	float end_y = ro.y + rd.y * t_scene;
	bool under = ro.y < cloud_layer.x && end_y < cloud_layer.x;
	// UP THE SLOPES, IN ANY WEATHER (owner prompts/41, 2026-11-16; cloud_pf_c.w bit 4096, tier key near_rim): the
	// shell starts CLOUD_CONTACT_BELOW_M (cloud_contact_below) under the base for the slope veil, so on every road above base - 260 m (on
	// Hachijo, whose August base sits at 300-700 m, most of the interior) the camera stood INSIDE the shell, every
	// tree, pole and roof ended its trace there, and the cut-out of sky round foreground came back: blue gaps between
	// the crowns. Under the base the march draws only the slope veil (nothing nearer than CLOUD_CONTACT_NEAR_M, nor at
	// a surface under the veil's band) and the rain shafts (nothing nearer than CLOUD_RAIN_NEAR_M): a scene point both
	// leave alone has no cloud in front of it.
	// THE EYE VEIL IS NOT PART OF THIS TEST (owner prompts/82, 2026-11-17: "fix the halo / blue line issue around trees
	// again. it happened with the new clouds canopy/mist"). The eye inside the veil (25c2969b3) returned false here for
	// every pixel, so every crown and trunk ended its trace: its history texel held a few metres of veil where the sky
	// beside it held the whole slab, and the sky pass's plain bilinear read took those texels onto the sky round each
	// silhouette - a blue line round every needle (the history's half resolution, wider under DLSS / FSR2). The trace
	// marches such a pixel past the scene like any other (its history: the eye veil over CLOUD_EYE_VEIL_M, as the sky
	// beside it), and the flight quad draws the eye veil in front of the surface per pixel at the surface's own
	// distance (cloud_flight.gdshaderinc, FlightPixel.eye): the same slab, without a history texel at the silhouette.
	if ((flags & 4096) != 0) {
		bool veil_free = t_scene < CLOUD_CONTACT_NEAR_M || end_y < cloud_layer.x - cloud_contact_below();
		bool rain_free = cloud_weather.w <= 0.0 || t_scene < CLOUD_RAIN_NEAR_M;
		return under && veil_free && rain_free;
	}
	return (flags & 64) != 0 && t_scene < CLOUD_RAIN_NEAR_M && under
			&& end_y < cloud_layer.x - cloud_contact_below();
}

float cloud_trace_t_max(vec3 ro, vec3 rd, float t_scene) {
	if (t_scene > 1e11) {
		return t_scene;
	}
	return cloud_nothing_before(ro, rd, t_scene) ? 1e12 : t_scene;
}

// Everything below needs the sky's atmosphere uniforms (sky_scatter) or the
// temporal pass's output: the compute trace (CloudTemporalGlsl, CLOUD_COMPUTE)
// compiles only the march above.
#ifndef CLOUD_COMPUTE

// THE TEMPORAL PASS (CloudTemporal): cloud_flags bit 2 (LOCKSTEP with
// CloudBridge.FLAG_TEMPORAL) = its reconstructed history `cloud_view` is live for
// the MAIN viewport, whose internal size is cloud_view_size.xy. A pass rendering
// anything else (a mirror, the PIP camera) sees another target size and keeps
// its own march. The sky's half-res target is floor(size / 2) (sky.cpp).
const int CLOUD_FLAG_TEMPORAL = 4;

bool cloud_view_owns(vec2 target_size, bool half_pass) {
	if ((cloud_flags & CLOUD_FLAG_TEMPORAL) == 0) {
		return false;
	}
	vec2 want = half_pass ? floor(cloud_view_size.xy * 0.5) : cloud_view_size.xy;
	return all(lessThan(abs(target_size - want), vec2(1.5)));
}

// The history stores (key_w, amb_w, T, depth in km).
CloudSample cloud_view_decode(vec4 v) {
	CloudSample s;
	s.key_w = max(v.r, 0.0);
	s.amb_w = max(v.g, 0.0);
	s.T = clamp(v.b, 0.0, 1.0);
	s.depth_m = max(v.a, 0.0) * 1000.0;
	return s;
}

// Sampled at SCREEN_UV, the pixel centre: NOT the TAA-jittered ray. The history
// is un-jittered, so the clouds hold still while Godot jitters the sky around
// them (and TAA never accumulates sky pixels).
CloudSample cloud_view_sample(vec2 uv) {
	return cloud_view_decode(textureLod(cloud_view, uv, 0.0));
}

// The (Rayleigh, Mie) optical depth from altitude h toward a light at dir_y, to the top of the
// atmosphere (#773). Samples spaced QUADRATICALLY in distance: the low air the column is mostly
// made of lies in the first ~30 km of a path of hundreds, and 8 even steps put the first sample
// 18 km out (the 1.2 km Mie column toward an 8 deg sun from 1 km came out 3.5x too small; 12
// quadratic steps are within 5 %). A light under this altitude's horizon is taken at the
// GRAZING ray: the path that ends on the ground is shorter than the grazing one, so the tint
// jumped back to near white as the sun dipped under a cloud's horizon (the 17:31 flash, sun -1.1
// deg: mean cloud luminance 0.028 -> 0.109 -> 0.023 in one minute). The earth-shadow gate puts
// that light out. LOCKSTEP with CloudOptics.sun_od.
const int CLOUD_SUN_OD_STEPS = 12;

vec2 cloud_sun_od(float h, float dir_y) {
	float ro = PLANET_EARTH_RADIUS + h;
	float graze = -sqrt(h * (2.0 * PLANET_EARTH_RADIUS + h)) / ro;   // the horizon's dip at h
	float dy = max(dir_y, graze + 1e-4);
	float t_end = planet_atmosphere_exit(h, dy, PLANET_EARTH_RADIUS);
	vec2 total = vec2(0.0);
	for (int i = 0; i < CLOUD_SUN_OD_STEPS; i++) {
		float u0 = float(i) / float(CLOUD_SUN_OD_STEPS);
		float u1 = float(i + 1) / float(CLOUD_SUN_OD_STEPS);
		float alt = max(planet_altitude_along_ray(h, dy, t_end * 0.5 * (u0 * u0 + u1 * u1), PLANET_EARTH_RADIUS), 0.0);
		total += vec2(exp(-alt / PLANET_RAYLEIGH_H), exp(-alt / PLANET_MIE_H)) * (t_end * (u1 * u1 - u0 * u0));
	}
	return total;
}

// THE SUN AT THE CLOUD (golden hour, 2026-09-28). With the sun as the key
// (cloud_key_dir.w = 1, CloudUniforms.key_light) cloud_key_color is the sun's
// NOON colour, and this reddens it by the air between the cloud and the sun —
// the SKY's own raw betas and optical depth — relative to the zenith at the same
// altitude, so noon is unchanged and a low sun turns clouds gold, orange, red,
// as the sky's horizon already does. Sky3D's SunLight colour is an art-directed
// SEA-LEVEL lerp: (1, 0.66, 0.43) at a 1.6 deg sun, where the physics gives
// ~(1, 0.36, 0.02) — the clouds read beige-brown.
// AEROSOL (#773): Sky3D's Mie beta is ~3e-8 / m, next to nothing, and aerosol is
// most of the real extinction of a low sun. Without it a 1.6 deg sun kept ~9 %
// of noon's light at 1 km (real: ~2-3 %), and its diffusion through the cloud
// flooded the shadowed sides orange-brown (79, 48, 19) where the sky's blue
// should rule them. cloud_light_e.xyz is a maritime aerosol's extinction at sea
// level (CloudUniforms.aerosol_beta), on the Mie column (1.2 km scale height):
// low clouds redden and dim first, high tops keep the light longest. LOCKSTEP
// with CloudOptics.sun_tint.
vec3 cloud_sun_tint(float cloud_alt) {
	if (cloud_key_dir.w < 0.5) {
		return vec3(1.0);
	}
	float h = max(cloud_alt, 0.0);
	vec2 od = cloud_sun_od(h, cloud_key_dir.y);
	vec2 od0 = vec2(PLANET_RAYLEIGH_H * exp(-h / PLANET_RAYLEIGH_H), PLANET_MIE_H * exp(-h / PLANET_MIE_H));
	return exp(-(atm_beta_ray * max(od.x - od0.x, 0.0)
			+ (atm_beta_mie + cloud_light_e.xyz) * max(od.y - od0.y, 0.0)));
}

// LIGHTNING LIGHTS THE CLOUD FROM INSIDE (#774). One strike's light (CloudFlash, from the synced
// strike: the same on every peer): a line source from cloud_flash_a.xyz to cloud_flash_b.xyz (the
// channel, or an intra-cloud discharge), its radiance next to the channel cloud_flash_a.w (0 =
// dark) and its spread cloud_flash_b.w. Added at the RESOLVE, at the sample's transmittance-weighted
// mean depth, weighted by its opacity: the history refreshes a pixel every 4 frames and blends many,
// so a flash traced into it would lag the bolt and smear; here it is exact every frame, a few ALU a
// pixel, and the rain under the base (in the sample too) glows round the channel as well. The
// light escapes a thick cloud like a point source's (the dipole shape, (1 + q^2)^-1.5 at q = d / r),
// and leaks out through the base as it spreads, over about the slab's own depth (e^(-q/2)): 0.21
// at the radius, 3 % at two, so a strike 3.5 km off lights the base over the camera ~2x, not a
// white-out (without the leak it did, at 1/q^3). Seen from behind more cloud the mean depth sits
// farther from the channel, so it dims.
// LOCKSTEP with CloudOptics.flash_kernel / CloudFlash.COLOR.
const vec3 CLOUD_FLASH_COLOR = vec3(0.86, 0.9, 1.0);

vec3 cloud_flash_light(CloudSample cs, vec3 ro, vec3 dir) {
	if (cloud_flash_a.w <= 0.0 || cs.T >= 0.999) {
		return vec3(0.0);
	}
	vec3 p = cloud_ray_pos(ro, dir, max(ro.y, 0.0), cs.depth_m);
	vec3 ab = cloud_flash_b.xyz - cloud_flash_a.xyz;
	float u = clamp(dot(p - cloud_flash_a.xyz, ab) / max(dot(ab, ab), 1.0), 0.0, 1.0);
	float q = length(p - (cloud_flash_a.xyz + ab * u)) / max(cloud_flash_b.w, 1.0);
	float k = exp(-0.5 * q) / ((1.0 + q * q) * sqrt(1.0 + q * q));
	return CLOUD_FLASH_COLOR * (cloud_flash_a.w * k * (1.0 - cs.T));
}

// THE SEAM TO THE PHYSICAL ATMOSPHERE (R27; src/sky/atmosphere/atmosphere.gdshaderinc, the
// ATMOSPHERE helper's). The key light at a cloud and the ambient it sees, in one place. A shader
// that includes the atmosphere BEFORE this file (its guard ATMOSPHERE_INC is then defined) and runs
// with it enabled takes both from its tables: the sun's (or the moon's) illuminance through the air
// down to the cloud's altitude, and the sky hemisphere's mean radiance there, in the scene's own
// units. Otherwise: Sky3D's sun colour x 16 x the sky's twilight curve, reddened per cloud
// (cloud_sun_tint), and the caller's two-sample sky ambient. cloud_look (B1): the key's gain (the
// over-bright tops' dial while the key is not physical) and the ambient pulled toward grey
// (inside a field much of the "sky" a cloud sees is other clouds).
vec3 cloud_key_at(float cloud_alt) {
#ifdef ATMOSPHERE_INC
	if (atm_enabled()) {
		// Physical: no gain (cloud_look.y calibrates the non-physical key below).
		return cloud_key_dir.w > 0.5 ? atm_sun_illuminance(cloud_alt) : atm_moon_illuminance(cloud_alt);
	}
#endif
	return cloud_key_color.rgb * cloud_sun_tint(cloud_alt) * cloud_look.y;
}

vec3 cloud_ambient_at(vec3 amb_col, float cloud_alt) {
#ifdef ATMOSPHERE_INC
	if (atm_enabled()) {
		amb_col = atm_sky_ambient(cloud_alt);
	}
#endif
	return mix(amb_col, vec3(dot(amb_col, vec3(0.2126, 0.7152, 0.0722))), cloud_look.z);
}

// Composite a decoded sample over `col`: col*T + S, with aerial perspective ONCE
// at the transmittance-weighted mean depth, using the sky's RAW betas (the sea's
// convention). key_scale = 0.2 in the reflection cubemap: full brightness there
// lit the volumetric fog and washed the frame grey.
// One sample to premultiplied colour: (in-scattered light incl. aerial
// perspective, 1 - T). Shared by the sky composite and the flight pass so a
// cloud over terrain and the same cloud over the sky cannot drift apart.
// ro = the camera (world); flash_w scales the lightning (0 in the radiance cubemap, which updates
// a few faces a frame: a flash there would light the scene's ambient in patches).
// THE AIR IN FRONT OF A CLOUD THAT HIDES THE SUN IS IN ITS SHADOW (owner prompts/41, 2026-11-16). The aerial
// perspective's in-scatter between the eye and the cloud was lit as clear air, aureole and all, so a tower in front of
// the sun (or the moon: cloud_key_dir is the night's key) wore the sky's glow round the disc (sky_shot --debug 3).
// Looking within ~25 deg of the key, the air's sunlit share falls with the cloud's direct transmittance (the discs'
// floor, sky_disc_through_cloud); the sky light and the air's own multiple scattering stay (CLOUD_AIR_SHADOW_FLOOR).
const float CLOUD_AIR_SHADOW_FLOOR = 0.35;

float cloud_air_lit(vec3 dir, float T) {
	float align = smoothstep(0.9, 0.995, dot(dir, cloud_key_dir.xyz));
	float t_direct = clamp((T - 0.06) / 0.94, 0.0, 1.0);
	return mix(1.0, mix(CLOUD_AIR_SHADOW_FLOOR, 1.0, t_direct), align);
}

vec4 cloud_resolve(CloudSample cs, vec3 ro, vec3 dir, float cam_alt, vec3 haze, vec3 amb_col,
		float key_scale, float flash_w) {
	float cloud_alt = planet_altitude_along_ray(max(cam_alt, 0.0), dir.y, cs.depth_m, PLANET_EARTH_RADIUS);
	vec3 key_col = cloud_key_at(cloud_alt);
	amb_col = cloud_ambient_at(amb_col, cloud_alt);
	vec3 S = key_col * cs.key_w * key_scale + amb_col * cs.amb_w * cloud_light_c.z
			+ cloud_flash_light(cs, ro, dir) * flash_w;
	// Look-dev (cloud_debug, sky_shot --debug): 1 = the key light's share only,
	// 2 = the sky ambient's share only, 3 = neither (the aerial perspective alone),
	// 4 = the ambient COLOUR itself (amb_col at full weight), 5 = the key colour / 16,
	// 6 = the lightning's share only (#774).
	if (cloud_debug == 6) {
		S = cloud_flash_light(cs, ro, dir) * flash_w;
	} else if (cloud_debug == 1) {
		S = key_col * cs.key_w * key_scale;
	} else if (cloud_debug == 2) {
		S = amb_col * cs.amb_w * cloud_light_c.z;
	} else if (cloud_debug == 3) {
		S = vec3(0.0);
	} else if (cloud_debug == 4) {
		S = amb_col * (1.0 - cs.T);
	} else if (cloud_debug == 5) {
		S = key_col / 16.0 * (1.0 - cs.T);
	}
	float air_lit = cloud_air_lit(dir, cs.T);
#ifdef ATMOSPHERE_INC
	if (atm_enabled()) {
		// The atmosphere's aerial perspective at the cloud's mean depth (the seam above).
		vec4 ap = atm_aerial(dir, cs.depth_m);
		return vec4(S * ap.a + ap.rgb * air_lit * (1.0 - cs.T), 1.0 - cs.T);
	}
#endif
	vec2 od = planet_optical_depth_pair_to(max(cam_alt, 0.0), dir.y, cs.depth_m, 8,
			PLANET_EARTH_RADIUS);
	vec3 t_air = exp(-(atm_beta_ray * od.x + atm_beta_mie * od.y) * cloud_fade.x);
	S = S * t_air + haze * air_lit * (1.0 - t_air) * (1.0 - cs.T);
	return vec4(S, 1.0 - cs.T);
}

// What of the sky behind a cloud shows through it: the march's T less its cut (see cloud_composite).
float cloud_t_behind(float T) {
	return max(T - 0.03, 0.0) / 0.97;
}

vec3 cloud_composite(vec3 col, vec4 cbuf, vec3 ro, vec3 dir, float cam_alt, vec3 haze,
		vec3 amb_col, float key_scale, float fade, float flash_w) {
	CloudSample cs = cloud_decode(cbuf);
	if (cs.T >= 0.999) {
		return col;
	}
	vec4 r = cloud_resolve(cs, ro, dir, cam_alt, haze, amb_col, key_scale, flash_w);
	// The sky BEHIND the cloud through what the cloud really lets past: the march stops at T < 2-3 % (a cumulus
	// holds e^-30), and 1.5 % of the sun's HDR aureole drew a glow on a thick tower (owner prompts/41). Below the
	// cut it is nothing; above it the same light as before, less the cut.
	return mix(col, col * cloud_t_behind(cs.T) + r.rgb, fade);
}

// Far field (flight pass, camera ABOVE the layer): beyond the march cut the deck
// is a thin band at the horizon — from 5 km the cut (80 km) ends it ~0.9 deg above
// a horizon ~250 km away, and the ocean showed through. One 2D estimate: the
// stage-1 density at three points where the ray crosses the layer, lit like a
// sunlit top, fading IN exactly as the march fades out. Premultiplied, to be
// composited BEHIND the march.
// Its opacity alone (the flight pass's multiply quad needs no lighting); tm = the
// depth it sits at.
// THE DECK PAST THE CUT, SEEN FROM UNDER IT OR FROM INSIDE IT (owner prompts/41, 2026-11-16: "the horizon atmosphere
// line shines through the clouds/rain veil when looking at it from clouds level"; cloud_pf_c.w bit 1024, tier key
// far_below). Under a curved deck its base comes down to the eye's level sqrt(2 R (base - eye)) out (24 km for 45 m
// under it) and on toward the sea horizon, all of it past the march's cut (80 km on HIGH) for an eye near the base:
// the lab at 900 m under a 945 m base drew a band of clear horizon sky 0.6 deg tall between the march's last cloud
// and the sea. The same 2D estimate as from above, at the base, taking over as the march fades out (each sample
// weighted by the march's own fade, so the two do not double), lit as a base seen from below.
const float CLOUD_FAR_BASE_OD = 6.0;
const float CLOUD_FAR_BASE_AMB = 0.35;

// The far deck's span along the ray from under / inside the layer: (t0, t1), empty when t0 >= t1.
vec2 cloud_far_below_seg(vec3 ro, vec3 rd, float t_scene) {
	if ((int(cloud_pf_c.w) & 1024) == 0) {
		return vec2(1.0, 0.0);
	}
	float h0 = max(ro.y, 0.0);
	float base = cloud_layer.x;
	float top = cloud_layer.y;
	if (h0 > top) {
		return vec2(1.0, 0.0);
	}
	vec2 full;
	if (h0 < base) {
		full = planet_cloud_shell_segment(h0, rd.y, base, top, 1e12, PLANET_EARTH_RADIUS);
	} else {
		// Inside the layer: a ray that leaves through the base comes back up into it far away.
		float tr = planet_shell_far_root(h0, rd.y, base, PLANET_EARTH_RADIUS);
		if (tr < 0.0) {
			return vec2(1.0, 0.0);
		}
		float tt = planet_shell_hit(h0, rd.y, top, PLANET_EARTH_RADIUS);
		full = vec2(tr, tt > tr ? tt : tr + 200000.0);
		float tg = planet_ground_hit(h0, rd.y, PLANET_EARTH_RADIUS);
		if (tg >= 0.0) {
			full.y = min(full.y, tg);
		}
	}
	return vec2(max(full.x, cloud_fade.y * cloud_q_light.y), min(full.y, t_scene));
}

float cloud_far_alpha_below(vec3 ro, vec3 rd, float t_scene, out float tm) {
	tm = 0.0;
	float h0 = max(ro.y, 0.0);
	float base = cloud_layer.x;
	float cut = cloud_q_light.y;
	vec2 sg = cloud_far_below_seg(ro, rd, t_scene);
	float t0 = sg.x;
	float t1 = sg.y;
	if (t0 >= t1) {
		return 0.0;
	}
	// Where the ray rises through 150 / 400 / 900 m over the base (x the depth scale): the base's underside, at any
	// grazing angle (a fraction of a 100-300 km span put the first sample still under it).
	float a = 0.0;
	float wt = 0.0;
	float wsum = 0.0;
	for (int k = 0; k < 3; k++) {
		float alt = base + (k == 0 ? 150.0 : (k == 1 ? 400.0 : 900.0)) * cloud_depth_scale();
		float t = h0 < alt ? planet_shell_hit(h0, rd.y, alt, PLANET_EARTH_RADIUS)
				: planet_shell_far_root(h0, rd.y, alt, PLANET_EARTH_RADIUS);
		if (t < t0 || t > t1) {
			continue;
		}
		vec3 p = cloud_ray_pos(ro, rd, h0, t);
		float sd;
		vec2 vis;
		float d = cloud_macro(p, p.y - base, 3.0, sd, vis) / max(cloud_layer.z, 1e-4);
		float w = clamp(d, 0.0, 1.0) * smoothstep(cloud_fade.y * cut, cut, t);
		if (w > a) {
			a = w;
		}
		wt += w * t;
		wsum += w;
	}
	tm = wsum > 1e-4 ? wt / wsum : t0;
	return clamp(a, 0.0, 1.0);
}

float cloud_far_alpha(vec3 ro, vec3 rd, float t_scene, out float tm) {
	tm = 0.0;
	float h0 = max(ro.y, 0.0);
	if (h0 <= cloud_layer.y) {
		return cloud_far_alpha_below(ro, rd, t_scene, tm);
	}
	float cut = cloud_q_light.y;
	vec2 full = planet_cloud_shell_segment(h0, rd.y, cloud_layer.x, cloud_layer.y, 1e12,
			PLANET_EARTH_RADIUS);
	float t0 = max(full.x, cloud_fade.y * cut);
	float t1 = min(full.y, t_scene);
	if (t0 >= t1) {
		return 0.0;
	}
	float a = 0.0;
	for (int k = 0; k < 3; k++) {
		float t = mix(t0, t1, (float(k) + 0.5) / 3.0);
		vec3 p = cloud_ray_pos(ro, rd, h0, t);
		float sd;
		vec2 vis;
		a = max(a, cloud_macro(p, p.y - cloud_layer.x, 3.0, sd, vis) / max(cloud_layer.z, 1e-4));
	}
	tm = 0.5 * (t0 + t1);
	return max(a * smoothstep(cloud_fade.y * cut, cut, tm), 0.0);
}

vec4 cloud_far_field(vec3 ro, vec3 rd, float t_scene, vec3 haze, vec3 amb_col, float cam_alt) {
	float tm;
	float a = cloud_far_alpha(ro, rd, t_scene, tm);
	if (a <= 0.0) {
		return vec4(0.0);
	}
	CloudSample f;
	f.T = 1.0 - a;
	// The earth shadow at the deck's top, as the march has it (#773: the far deck kept a set sun).
	float c_far = dot(rd, cloud_key_dir.xyz);
	bool from_above = ro.y > cloud_layer.y;
	float earth = smoothstep(-0.006, 0.006, cloud_key_dir.y + sqrt(max(cloud_layer.y, 0.0) * 2.0 / PLANET_EARTH_RADIUS));
	if (from_above) {
		f.key_w = a * (cloud_look.x > 0.5 ? cloud_ff_ms(c_far, 1.0) * cloud_ff_powder(1.0, 1.0, c_far)
				: cloud_octaves(c_far, 1.0, 1.0, 1.0)) * earth;
		f.amb_w = a;
	} else {
		// The base from below: the key light through the deck, the sky's light from under it.
		f.key_w = a * (cloud_look.x > 0.5 ? cloud_ff_ms(c_far, CLOUD_FAR_BASE_OD)
				: cloud_octaves(c_far, 0.2, 0.2, 1.0)) * earth;
		f.amb_w = a * CLOUD_FAR_BASE_AMB;
	}
	f.depth_m = tm;
	return cloud_resolve(f, ro, rd, cam_alt, haze, amb_col, 1.0, 1.0);
}

#endif // !CLOUD_COMPUTE

#endif
