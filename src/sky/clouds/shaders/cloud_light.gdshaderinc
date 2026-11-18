// Cloud lighting (Hillaire 2016 / Wrenninge). LOCKSTEP with CloudOptics.
// Needs cloud_params + cloud_field first.
#ifndef CLOUD_LIGHT_INC
#define CLOUD_LIGHT_INC

float cloud_hg(float cos_t, float g) {
	float g2 = g * g;
	return (1.0 - g2) / (4.0 * PI * pow(max(1.0 + g2 - 2.0 * g * cos_t, 1e-6), 1.5));
}

// Dual-lobe HG (0.7 forward, -0.3 back, mix 0.3): keeps detail with the sun behind you.
float cloud_dual_lobe(float cos_t, float g_scale) {
	return mix(cloud_hg(cos_t, cloud_light_b.x * g_scale),
			cloud_hg(cos_t, cloud_light_b.y * g_scale), cloud_light_b.z);
}

// Wrenninge multiple-scattering octaves. Two octaves left the cores black ~40 m in.
// VERTICAL PROBABILITY (Nubis): multiply-scattered
// light BUILDS with height — a base sees mostly its own shadow, a sunlit top
// the whole white column above it. The DIRECT octave (i = 0) rides full
// height; the MS octaves (i >= 1) ride cloud_ms_v. LOCKSTEP with
// CloudOptics.ms_v (MS_V_FLOOR / MS_V_KNEE).
const float CLOUD_MS_V_FLOOR = 0.35;
const float CLOUD_MS_V_KNEE = 0.45;

float cloud_ms_v(float h01) {
	return mix(CLOUD_MS_V_FLOOR, 1.0, smoothstep(0.0, CLOUD_MS_V_KNEE, h01));
}

// NUBIS³ IN-SCATTER PROBABILITY (Schneider 2023): multiply-scattered light
// builds with DEPTH into the cloud — near the envelope most photons leave again,
// deep inside they have scattered toward us. The MS octaves ride the dimensional
// profile (0 at the envelope, 1 CLOUD_PROFILE_M in): a bulge's skin keeps
// CLOUD_MS_SKIN of them, the crevices carved deep into the profile glow — the
// inner light that makes cumulus read as fluffy. LOCKSTEP with CloudOptics.ms_p.
const float CLOUD_MS_SKIN = 0.35;

float cloud_ms_p(float prof) {
	return mix(CLOUD_MS_SKIN, 1.0, sqrt(clamp(prof, 0.0, 1.0)));
}

float cloud_octaves(float cos_t, float od, float h01, float prof) {
	float s = 0.0;
	float a = 1.0;
	float b = 1.0;
	float c = 1.0;
	float msv = cloud_ms_v(h01) * cloud_ms_p(prof);
	for (int i = 0; i < 4; i++) {
		float w = (i == 0) ? 1.0 : msv;
		s += w * b * cloud_dual_lobe(cos_t, c) * exp(-od * a);
		a *= cloud_light_a.y;
		b *= cloud_light_a.z;
		c *= cloud_light_a.w;
	}
	return s;
}

const float CLOUD_LIGHT_D[6] = float[6](30.0, 90.0, 250.0, 700.0, 1400.0, 2400.0);

// Optical depth toward the key light. Reads the ERODED density, so a lobe casts
// the shadow of its own billows; the 300 m mip floor on the light ray is the
// penumbra (hard straight terminators were a smooth-blob shadow, not sampling).
float cloud_light_od(vec3 p, float dist, float jit, int n) {
	float od = 0.0;
	float prev = 0.0;
	for (int i = 0; i < 6; i++) {
		if (i >= n) {
			break;
		}
		float d = CLOUD_LIGHT_D[i] * (1.0 + 0.4 * (jit - 0.5));
		float seg = d - prev;
		vec3 q = p + cloud_key_dir.xyz * d;
		float h = q.y - cloud_layer.x;
		if (h > 0.0 && q.y < cloud_layer.y) {
			float sdf;
			float lod = log2(max(max(seg, 300.0) / 16.0, 1.0));
			// Only the nearest sample sees the detail carve: past ~90 m it barely
			// moves the shadow, and the in-cloud march runs 4 of these per step.
			// It reads the detail at ITS OWN step's mip (#771): at the 300 m penumbra
			// mip (lod ~4, 256 m texels) the 128 m puffs were averaged away, so the
			// carved cauliflower cast no shadow on itself and could not read in light.
			if (i == 0) {
				od += cloud_density(q, h, dist, log2(max(seg / 16.0, 1.0)), sdf) * seg;
			} else {
				vec2 vis;
				od += cloud_macro_q(q, h, max(lod - 1.0, 0.0), false, sdf, vis) * seg;
			}
		}
		prev = d;
	}
	return od * cloud_light_a.x;
}

// Diffusion past the octaves (LOCKSTEP with CloudOptics.ms_diffuse): a thick
// cloud still passes ~1/(1 + 0.11 od) of the sunlight diffusely. Without it a
// base in the cloud's own shadow got only blue sky ambient. Zero on the lit surface.
float cloud_ms_diffuse(float od) {
	return cloud_light_d.x / (4.0 * PI) * max(1.0 / (1.0 + cloud_light_d.y * od) - exp(-od), 0.0);
}

// DIFFUSE REFLECTION (golden hour, 2026-09-28): a thick cloud sends ~85 % of
// its sunlight back out of its LIT side, nearly isotropically (~0.27 / sr); the
// octaves carry only ~0.12 / sr back toward a viewer with the sun behind them.
// Measured at a 1.6 deg sun from 3.5 km: front-lit tops (160, 131, 102) — brown,
// where real ones glow gold. An isotropic source strongest at the sunward skin,
// fading over CLOUD_REFLECT_OD optical depths toward the sun: the REFLECTED half
// of the two-stream field whose transmitted half is cloud_ms_diffuse. Shadowed
// cloud (large od) gets none. LOCKSTEP with CloudOptics.ms_reflect.
const float CLOUD_REFLECT_STRENGTH = 1.6;
const float CLOUD_REFLECT_OD = 2.0;

float cloud_ms_reflect(float od_l) {
	return CLOUD_REFLECT_STRENGTH / (4.0 * PI) * exp(-od_l / CLOUD_REFLECT_OD);
}

// POWDER (HZD, Schneider 2015: "Beer's-Powder"): the light a point sends us
// also depends on how much cloud lies toward the SUN — near the sunward skin
// little in-scattered light has built up, so bulges darken along their sunward
// edges while the crevices between them stay bright ("the powdered sugar
// look"). It used to read the LOCAL density (1 - e^(-10 rho)), which is ~1 a
// few metres inside any edge: no visible effect. View dependent: none looking
// into the sun (silver lining), full looking away. CLOUD_POWDER_FLOOR keeps a
// front-lit skin from going black. LOCKSTEP with CloudOptics.powder.
const float CLOUD_POWDER_FLOOR = 0.3;

float cloud_powder(float od_l, float cos_t) {
	float pw = mix(CLOUD_POWDER_FLOOR, 1.0, 1.0 - exp(-2.0 * od_l));
	return mix(1.0, mix(pw, 1.0, 0.5 + 0.5 * cos_t), cloud_light_b.w);
}

// STORM DARKNESS (#774): the raining column the light ray cannot see. The four light samples
// reach ~700 m toward the sun; a raining deck (nimbostratus) is 2-5 km of cloud with an optical
// thickness of 50-150, a cumulonimbus 10 km and several hundred, and from under either the sky is
// dark grey (diffuse transmittance 1 / (1 + 0.1125 tau): a few per cent). The drawn deck is only
// the layer's few hundred metres and the light ray sees 700 m of a 9 km tower, so a rain sky read
// LIGHTER than fair-weather cumulus (mean 0.385 against 0.323, shot set rows 19 / 15). This is the
// column's optical depth beyond the ray, from the weather (cloud_light_e.w = CloudOptics.column_tau:
// rain and storm energy, both synced), whole at the base and gone at the layer's top, so sunlit
// tops stay sunlit. Zero without rain or storm: fair weather and dry overcast are untouched.
// LOCKSTEP with CloudOptics.column_od / column_amb.
float cloud_column_od(float h01) {
	return cloud_light_e.w * (1.0 - clamp(h01, 0.0, 1.0));
}

// In a broken (cumuliform) sky the column continues only where the light ray is still deep in
// cloud at its end (its optical depth past CLOUD_COLUMN_OD_LO .. _HI, the last 450 m segment's
// share): a sunlit skin, a tower's flank or a top, has clear air toward the sun past it, and the
// storm towers seen from 26 km lost their sunlit faces without this (shot set row 47: 0.425 ->
// 0.119). A stratiform sheet is closed: from anywhere in it the sun's path runs through more sheet,
// so the stratus weight opens the gate whole (a rain deck, whose ~900 m the ray often leaves, read
// 0.276 gated against 0.116 whole). LOCKSTEP with CloudOptics.column_gate.
const float CLOUD_COLUMN_OD_LO = 3.0;
const float CLOUD_COLUMN_OD_HI = 12.0;

float cloud_column_gate(float od_ray) {
	return mix(smoothstep(CLOUD_COLUMN_OD_LO, CLOUD_COLUMN_OD_HI, od_ray), 1.0,
			cloud_stratus_weight(cloud_layer.w));
}

// The sky light that still reaches a point under that column: it comes through the same cloud
// (the two-stream diffuse transmittance, cloud_light_d.y = MS_K): under a storm the base is lit
// grey by the cloud above, not blue by a sky it cannot see.
float cloud_column_amb(float od_c) {
	return 1.0 / (1.0 + cloud_light_d.y * od_c);
}

// NUBIS³ AMBIENT PROBABILITY: sky light enters from all around but only
// penetrates the skin — pow(1 - profile, 0.5). Crevices carved deep into the
// profile see less sky: a cloud's own ambient occlusion. LOCKSTEP with
// CloudOptics.amb_p.
float cloud_amb_p(float prof) {
	return sqrt(1.0 - clamp(prof, 0.0, 1.0));
}

// ---------------------------------------------------------------------------------------------
// THE FOUR-LOBE LIGHTING (B1, 2026-11-15). cloud_look.x = 1 selects it in the march (cloud_march_layer); 0 keeps the Nubis
// dual-lobe terms above. LOCKSTEP with CloudOptics.ff_* (test_cloud_optics).
//   * the droplet phase as four lobes, the fourth a narrow diffraction peak: thin cloud over the
//     sun blazes;
//   * the octaves (energy 0.55, optical depth 0.38, phase flattening 0.5 a step), a two-stream
//     diffusion tail, and GLOW / SILVER: light diffused right through a cloud still travels away
//     from the sun, so a cloud in front of a low sun glows instead of going grey;
//   * MS_GAIN for what the octave sum misses in thick cloud;
//   * in-scatter probabilities from density and column height (the dark creases), a powder that
//     is off looking into the sun;
//   * the long light ray (6 samples from 36 m, x1.85 a step: 1.66 km; 7 in a tall column: 3.1 km),
//     the up-probe (cloud overhead blocks the sky light) and the ground's bounce;
//   * after the march, the rim: single scattering through the outline's own optical depth.
const float CLOUD_FF_MS_GAIN = 2.6;
const float CLOUD_FF_GLOW = 0.06;
const float CLOUD_FF_SILVER = 0.5;
const float CLOUD_FF_RIM = 1.5;
const float CLOUD_FF_LIGHT_D0 = 36.0;
const float CLOUD_FF_LIGHT_GROW = 1.85;
// A column deeper than this takes one more, long light sample (towers shade their neighbours).
const float CLOUD_FF_TALL_M = 2500.0;
const float CLOUD_FF_UP_M = 450.0;
const float CLOUD_FF_GROUND_ALBEDO = 0.11;

float cloud_ff_phase(float c, float k) {
	return cloud_hg(c, 0.86 * k) * 0.42 + cloud_hg(c, 0.5 * k) * 0.3 + cloud_hg(c, -0.25 * k) * 0.2
			+ cloud_hg(c, 0.97 * k) * 0.08;
}

float cloud_ff_glow(float c, float od) {
	return CLOUD_FF_GLOW * cloud_hg(c, 0.85) * (1.0 / (1.0 + 0.3 * od) + exp(-0.3 * od))
			+ CLOUD_FF_SILVER * cloud_hg(c, 0.9) * exp(-0.35 * od);
}

// Everything in cloud_ff_ms that depends on the view-sun angle alone, once per RAY (it is the
// same at every step): the four octaves' phases (energy 0.55 a step folded in: a = 0.55^i, the
// phase flattened by k = 0.5^i) and the glow's two lobes. 18 HG evaluations a step otherwise.
struct CloudFFPhase {
	vec4 oct;     // a_i x phase(c, k_i), i = 0..3
	vec2 glow;    // GLOW x hg(c, 0.85), SILVER x hg(c, 0.9)
};

CloudFFPhase cloud_ff_phases(float c) {
	CloudFFPhase ph;
	float a = 1.0;
	float k = 1.0;
	for (int i = 0; i < 4; i++) {
		ph.oct[i] = a * cloud_ff_phase(c, k);
		a *= 0.55;
		k *= 0.5;
	}
	ph.glow = vec2(CLOUD_FF_GLOW * cloud_hg(c, 0.85), CLOUD_FF_SILVER * cloud_hg(c, 0.9));
	return ph;
}

// The sunlight a sample sends toward the eye per unit of key light, before the powder: the
// octaves (optical depth x 0.38 a step), the diffusion tail and the glow, times MS_GAIN.
float cloud_ff_ms_p(CloudFFPhase ph, float od) {
	vec4 att = exp(-od * vec4(1.0, 0.38, 0.1444, 0.054872));
	float ms = dot(ph.oct, att);
	ms += 0.4 / (4.0 * PI) / (1.0 + 0.25 * od);
	ms += ph.glow.x * (1.0 / (1.0 + 0.3 * od) + exp(-0.3 * od)) + ph.glow.y * exp(-0.35 * od);
	return ms * CLOUD_FF_MS_GAIN;
}

float cloud_ff_ms(float c, float od) {
	return cloud_ff_ms_p(cloud_ff_phases(c), od);
}

float cloud_ff_remap(float v, float a, float b, float c, float d) {
	return c + (v - a) / (b - a) * (d - c);
}

// In-scatter probability (dprob from the density d01 in 0..1 and the column height hn, vprob from
// hn) folded into the powder, which is off looking toward the sun (thin edges glow there).
float cloud_ff_powder(float d01, float hn, float c) {
	float dprob = 0.08 + pow(max(d01, 0.0), cloud_ff_remap(clamp(hn, 0.3, 0.85), 0.3, 0.85, 0.5, 2.0));
	float vprob = pow(clamp(cloud_ff_remap(hn, 0.05, 0.2, 0.25, 1.0), 0.25, 1.0), 0.8);
	return mix(1.0, clamp(dprob * vprob * 1.25, 0.0, 1.0), 0.55 * (1.0 - smoothstep(0.0, 0.6, c)));
}

// The long light ray: n samples at the middles of segments 36 m x 1.85^j long (jittered), the
// first with the detail carve (a full-resolution march carves the first two; at our half-res, lattice-2 history
// the second's 64-128 m carve read as grain that twinkled, 1.6 % of a still frame's pixels
// against 0.4 % with one). Stops at the layer's top (the sun is above the horizon whenever
// it lights a cloud: past the top a sample can only be above it again).
float cloud_ff_light_od(vec3 p, float dist, float jit, int n) {
	float od = 0.0;
	float ls = CLOUD_FF_LIGHT_D0;
	float lt = 0.0;
	for (int j = 0; j < 8; j++) {
		if (j >= n) {
			break;
		}
		vec3 q = p + cloud_key_dir.xyz * (lt + ls * (0.5 + 0.4 * (jit - 0.5)));
		if (q.y >= cloud_layer.y && cloud_key_dir.y > 0.0) {
			break;
		}
		float h = q.y - cloud_layer.x;
		if (h > 0.0) {
			float sdf;
			if (j < 1) {
				od += cloud_density(q, h, dist, log2(max(ls / 16.0, 1.0)), sdf) * ls;
			} else {
				vec2 vis;
				float lod = log2(max(max(ls, 300.0) / 16.0, 1.0));
				od += cloud_macro_q(q, h, max(lod - 1.0, 0.0), false, sdf, vis) * ls;
			}
		}
		lt += ls;
		ls *= CLOUD_FF_LIGHT_GROW;
	}
	return od * cloud_light_a.x;
}

// Cloud overhead blocks the sky light: one sample CLOUD_FF_UP_M straight up, standing for
// 2 x that of cloud, through the two-stream diffusion falloff; 12 % always gets through.
float cloud_ff_up_occlusion(vec3 p, float h, float lod) {
	vec3 q = p + vec3(0.0, CLOUD_FF_UP_M, 0.0);
	float od_up = 0.0;
	if (q.y < cloud_layer.y) {
		float sdf;
		vec2 vis;
		od_up = cloud_macro_q(q, h + CLOUD_FF_UP_M, lod, false, sdf, vis) * (2.0 * CLOUD_FF_UP_M)
				* cloud_light_a.x;
	}
	return mix(1.0 / (1.0 + 0.15 * od_up), 1.0, 0.12);
}

// Sunlight off the ground and sea under the cloud, as uplight (Lambertian, albedo 0.11), dimmed by
// the cover's own shadow on the ground. Per unit of key light.
float cloud_ff_ground(float cover) {
	return CLOUD_FF_GROUND_ALBEDO * max(cloud_key_dir.y, 0.0) / PI * mix(1.0, 0.45, clamp(cover, 0.0, 1.0));
}

// The silver lining, added once after the march: looking toward the sun, only where the whole line
// of sight through the cloud is thin does sunlight get through, a band metres wide at the outline
// that the march cannot resolve. Its partly transparent pixels stand in for it: single scattering
// through a slab of optical depth tau = -ln T is tau e^-tau. Only the share the march left unlit.
float cloud_ff_rim(float c, float T, float lit) {
	if (c <= 0.5) {
		return 0.0;
	}
	float tau = -log(max(T, 1e-4));
	// NOT THROUGH A MARCH THAT STOPPED (owner prompts/41, 2026-11-16): the march ends at T < 2-3 %, so a cumulus in
	// front of the sun reported tau ~4 when it holds ~30, and tau e^-tau times this lobe (43 x isotropic at the sun)
	// drew a 10-degree glow of key light through the opaque body (lab, 17:12: T 0.015, key_w 2.8 at the disc, 0.85
	// 60 px out). The lining is the thin outline's: gone below T 3 %, whole from T 12 % (tau ~2).
	float open_t = smoothstep(0.03, 0.12, T);
	return CLOUD_FF_RIM * cloud_hg(c, 0.94) * tau * exp(-tau) * (1.0 - clamp(lit, 0.0, 1.0)) * open_t;
}

#endif
