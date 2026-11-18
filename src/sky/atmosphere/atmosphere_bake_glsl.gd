class_name AtmosphereBakeGlsl
extends RefCounted
## The atmosphere's LUT bake kernels (GLSL 450, compiled at runtime by SkyAtmosphere). The model's
## math is NOT repeated here: source() pastes the text of atmosphere_math.gdshaderinc (the same file
## the materials include) between this header and the kernels, so the bake and the lookups cannot
## drift apart.
##
## Kernels (one compute shader each, by #define):
##   TRANS    256 x 64   transmittance to space; depends on the haze only
##   MS       32 x 32    Hillaire's multiple-scattering transfer (per unit sun); haze
##   AMBIENT  32 x 32    mean radiance of the sky hemisphere at (sun zenith cosine, altitude); haze,
##                       the deck, the gain (scene units per the sun's illuminance)
##   SKYVIEW  2 x 256 x 128  the camera's sky: in-scatter of sun + moon, mean transmittance in alpha; the right
##                       half the sun's single-scattered aerosol light, unphased (the aureole, per pixel)
##   AERIAL   64 x 32 x 32  the same along every direction, slice by slice (aerial perspective)

const MATH_PATH := "res://src/sky/atmosphere/atmosphere_math.gdshaderinc"
const KERNELS: PackedStringArray = ["TRANS", "MS", "AMBIENT", "SKYVIEW", "AERIAL"]

const HEADER := """#version 450
#define KERNEL_%s
#define PI 3.14159265358979
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// 64 bytes. sun / moon: xyz toward the body, w its illuminance x the sky's gain (scene units);
// medium: x planet radius km, y haze, z closed deck, w camera altitude km; extra: x aerial reach km, y the
// aureole (TODO 45: 1 = the two-term aerosol phase and the sky's split, 0 = one Cornette-Shanks lobe, as before).
layout(push_constant, std430) uniform Params {
	vec4 sun;
	vec4 moon;
	vec4 medium;
	vec4 extra;
} P;

#ifdef KERNEL_AERIAL
layout(rgba16f, set = 0, binding = 0) uniform restrict writeonly image3D out_img;
#else
layout(rgba16f, set = 0, binding = 0) uniform restrict writeonly image2D out_img;
#endif
#ifndef KERNEL_TRANS
layout(set = 0, binding = 1) uniform sampler2D trans_lut;
#endif
#if defined(KERNEL_AMBIENT) || defined(KERNEL_SKYVIEW) || defined(KERNEL_AERIAL)
layout(set = 0, binding = 2) uniform sampler2D ms_lut;
#endif

"""

const BODY := """

#ifndef KERNEL_TRANS
vec3 bake_sun_trans(float h, float mu) {
	float mu_h = atm_horizon_mu(h, P.medium.x);
	float vis = smoothstep(mu_h - 0.006, mu_h + 0.006, mu);
	return textureLod(trans_lut, atm_trans_uv(h, mu, P.medium.x), 0.0).rgb * vis;
}
#endif

#if defined(KERNEL_AMBIENT) || defined(KERNEL_SKYVIEW) || defined(KERNEL_AERIAL)
vec3 bake_ms(float h, float mu) {
	return textureLod(ms_lut, atm_ms_uv(h, mu), 0.0).rgb;
}

// The eye the deck is judged from (atm_deck_below): the camera for the view tables, the table row's
// own altitude for the ambient one. Set by each kernel before it integrates.
float g_eye_h = 0.0;

// The light one body scatters into the ray at a sample (per unit of the body's illuminance).
vec3 bake_source(vec3 up, float h, vec3 to_light, float pr, float pm, vec3 sr, float sm) {
	float mu = dot(up, to_light);
	return bake_sun_trans(h, mu) * atm_deck_sun(h, P.medium.z, g_eye_h) * (sr * pr + sm * pm)
			+ atm_deck_ms(bake_ms(h, mu), h, P.medium.z, g_eye_h) * (sr + vec3(sm));
}

// In-scatter and transmittance along oc + rd t, t0..t1 (km), `steps` samples, spaced evenly
// (quad = false) or packed toward t0 (quad = true: the near air, which matters most).
// sun_k / moon_k scale each body's light (0 switches it off).
// THE AUREOLE (TODO 45; SkyAtmosphere.aureole, P.extra.y): the aerosol phase is atm_phase_aureole_baked in
// place of one Cornette-Shanks lobe (ATM_MIE_G), and with `split` the sun's single-scattered aerosol light is
// kept apart, UNPHASED, in Lm: the sky applies atm_phase_aureole to it per pixel (atm_skyview).
void bake_integrate(vec3 oc, vec3 rd, float t0, float t1, int steps, bool quad, vec3 sun, float sun_k,
		vec3 moon, float moon_k, bool split, inout vec3 L, inout vec3 Lm, inout vec3 T) {
	float rg = P.medium.x;
	float haze = P.medium.y;
	bool aureole = P.extra.y > 0.5;
	bool sp = split && aureole;
	float cs = dot(rd, sun);
	float cm = dot(rd, moon);
	float pr_s = atm_phase_rayleigh(cs);
	float pm_s = aureole ? atm_phase_aureole_baked(cs) : atm_phase_mie(cs, ATM_MIE_G);
	float pr_m = atm_phase_rayleigh(cm);
	float pm_m = aureole ? atm_phase_aureole_baked(cm) : atm_phase_mie(cm, ATM_MIE_G);
	float len = max(t1 - t0, 0.0);
	float tp = t0;
	for (int i = 0; i < steps; i++) {
		float f = float(i + 1) / float(steps);
		float tn = t0 + len * (quad ? f * f : f);
		float dt = tn - tp;
		vec3 p = oc + rd * (0.5 * (tp + tn));
		float r = length(p);
		float h = r - rg;
		vec3 up = p / r;
		vec3 d = atm_density(h);
		vec3 ext = atm_extinction(d, haze);
		vec3 sr = ATM_RAYLEIGH_S * d.x;
		float sm = ATM_MIE_S * haze * d.y;
		vec3 S = vec3(0.0);
		vec3 Sm = vec3(0.0);
		if (sun_k > 0.0) {
			if (sp) {
				float mu = dot(up, sun);
				vec3 direct = bake_sun_trans(h, mu) * atm_deck_sun(h, P.medium.z, g_eye_h) * sun_k;
				S += direct * sr * pr_s
						+ atm_deck_ms(bake_ms(h, mu), h, P.medium.z, g_eye_h) * (sr + vec3(sm)) * sun_k;
				Sm = direct * sm;
			} else {
				S += bake_source(up, h, sun, pr_s, pm_s, sr, sm) * sun_k;
			}
		}
		if (moon_k > 0.0) {
			S += bake_source(up, h, moon, pr_m, pm_m, sr, sm) * moon_k;
		}
		vec3 st = exp(-ext * dt);
		vec3 w = T * (vec3(1.0) - st) / max(ext, vec3(1e-9));
		L += w * S;
		Lm += w * Sm;
		T *= st;
		tp = tn;
	}
}
#endif

void main() {
#ifdef KERNEL_TRANS
	ivec2 px = ivec2(gl_GlobalInvocationID.xy);
	if (px.x >= int(ATM_TRANS_SIZE.x) || px.y >= int(ATM_TRANS_SIZE.y)) {
		return;
	}
	float rg = P.medium.x;
	vec2 hm = atm_trans_from_uv((vec2(px) + 0.5) / ATM_TRANS_SIZE, rg);
	vec3 oc = vec3(0.0, rg + hm.x, 0.0);
	vec3 rd = vec3(sqrt(max(1.0 - hm.y * hm.y, 0.0)), hm.y, 0.0);
	float d = max(atm_ray_sphere(oc, rd, rg + ATM_TOP_KM).y, 0.0);
	vec3 od = vec3(0.0);
	const int N = 48;
	for (int i = 0; i < N; i++) {
		vec3 p = oc + rd * (d * (float(i) + 0.5) / float(N));
		od += atm_extinction(atm_density(length(p) - rg), P.medium.y) * (d / float(N));
	}
	imageStore(out_img, px, vec4(exp(-od), 1.0));
#endif

#ifdef KERNEL_MS
	// Hillaire 2020 section 5.5: second-order light over the sphere of directions, isotropic phase,
	// and the geometric series of every higher order: psi = L2 / (1 - f_ms). Per unit sun.
	ivec2 px = ivec2(gl_GlobalInvocationID.xy);
	if (px.x >= int(ATM_MS_SIZE) || px.y >= int(ATM_MS_SIZE)) {
		return;
	}
	float rg = P.medium.x;
	float haze = P.medium.y;
	vec2 hm = atm_ms_from_uv((vec2(px) + 0.5) / ATM_MS_SIZE);
	vec3 oc = vec3(0.0, rg + max(hm.x, 0.001), 0.0);
	vec3 sun = vec3(sqrt(max(1.0 - hm.y * hm.y, 0.0)), hm.y, 0.0);
	vec3 l2 = vec3(0.0);
	vec3 fms = vec3(0.0);
	const int ND = 64;
	const int NS = 20;
	for (int k = 0; k < ND; k++) {
		float z = 1.0 - (2.0 * float(k) + 1.0) / float(ND);
		float rr = sqrt(max(1.0 - z * z, 0.0));
		float ph = float(k) * 2.399963;
		vec3 rd = vec3(rr * cos(ph), z, rr * sin(ph));
		float tmax = atm_ray_sphere(oc, rd, rg + ATM_TOP_KM).y;
		vec2 g = atm_ray_sphere(oc, rd, rg);
		bool hit = g.x > 0.0;
		if (hit) {
			tmax = g.x;
		}
		vec3 T = vec3(1.0);
		vec3 L = vec3(0.0);
		vec3 F = vec3(0.0);
		float dt = max(tmax, 0.0) / float(NS);
		for (int i = 0; i < NS; i++) {
			vec3 p = oc + rd * (dt * (float(i) + 0.5));
			float r = length(p);
			float hp = r - rg;
			vec3 d = atm_density(hp);
			vec3 ext = atm_extinction(d, haze);
			vec3 sc = ATM_RAYLEIGH_S * d.x + vec3(ATM_MIE_S * haze * d.y);
			vec3 st = exp(-ext * dt);
			vec3 w = T * (vec3(1.0) - st) / max(ext, vec3(1e-9));
			L += w * sc * bake_sun_trans(hp, dot(p / r, sun)) / (4.0 * PI);
			F += w * sc;
			T *= st;
		}
		if (hit) {
			vec3 nrm = normalize(oc + rd * tmax);
			float mu = dot(nrm, sun);
			L += T * bake_sun_trans(0.0, mu) * max(mu, 0.0) * ATM_GROUND_ALBEDO / PI;
		}
		l2 += L / float(ND);
		fms += F / float(ND);
	}
	imageStore(out_img, px, vec4(l2 / max(vec3(1.0) - fms, vec3(1e-3)), 1.0));
#endif

#ifdef KERNEL_AMBIENT
	ivec2 px = ivec2(gl_GlobalInvocationID.xy);
	if (px.x >= int(ATM_MS_SIZE) || px.y >= int(ATM_MS_SIZE)) {
		return;
	}
	float rg = P.medium.x;
	vec2 hm = atm_ms_from_uv((vec2(px) + 0.5) / ATM_MS_SIZE);
	vec3 oc = vec3(0.0, rg + max(hm.x, 0.001), 0.0);
	vec3 sun = vec3(sqrt(max(1.0 - hm.y * hm.y, 0.0)), hm.y, 0.0);
	vec3 sum = vec3(0.0);
	g_eye_h = hm.x;
	const int ND = 48;
	for (int k = 0; k < ND; k++) {
		// Even in solid angle over the upper hemisphere.
		float z = 1.0 - (float(k) + 0.5) / float(ND);
		float rr = sqrt(max(1.0 - z * z, 0.0));
		float ph = float(k) * 2.399963;
		vec3 rd = vec3(rr * cos(ph), z, rr * sin(ph));
		float tmax = atm_ray_sphere(oc, rd, rg + ATM_TOP_KM).y;
		vec2 g = atm_ray_sphere(oc, rd, rg);
		if (g.x > 0.0) {
			tmax = g.x;
		}
		vec3 L = vec3(0.0);
		vec3 Lm = vec3(0.0);
		vec3 T = vec3(1.0);
		bake_integrate(oc, rd, 0.0, max(tmax, 0.0), 12, true, sun, P.sun.w, sun, 0.0, false, L, Lm, T);
		sum += L;
	}
	imageStore(out_img, px, vec4(sum / float(ND), 1.0));
#endif

#ifdef KERNEL_SKYVIEW
	ivec2 px = ivec2(gl_GlobalInvocationID.xy);
	if (px.x >= int(ATM_SKYVIEW_SIZE.x) || px.y >= int(ATM_SKYVIEW_SIZE.y)) {
		return;
	}
	float rg = P.medium.x;
	float h = P.medium.w;
	g_eye_h = h;
	vec2 unit = atm_uv_to_unit((vec2(px) + 0.5) / ATM_SKYVIEW_SIZE, ATM_SKYVIEW_SIZE);
	vec3 rd = atm_dir_from_unit(unit, h, rg);
	vec3 oc = vec3(0.0, rg + max(h, 0.0), 0.0);
	vec2 top = atm_ray_sphere(oc, rd, rg + ATM_TOP_KM);
	vec3 L = vec3(0.0);
	vec3 Lm = vec3(0.0);
	vec3 T = vec3(1.0);
	if (top.y > 0.0) {
		float t0 = max(top.x, 0.0);
		float t1 = top.y;
		vec2 g = atm_ray_sphere(oc, rd, rg);
		if (g.x > 0.0) {
			t1 = min(t1, g.x);
		}
		bake_integrate(oc, rd, t0, t1, 32, true, P.sun.xyz, P.sun.w, P.moon.xyz, P.moon.w, true, L, Lm, T);
	}
	// The table is two halves side by side: the sky as before (left), the sun's unphased aerosol light (right;
	// black with the aureole off, so the sky's per-pixel term adds nothing).
	imageStore(out_img, px, vec4(L, dot(T, vec3(1.0 / 3.0))));
	imageStore(out_img, px + ivec2(int(ATM_SKYVIEW_SIZE.x), 0), vec4(Lm, 1.0));
#endif

#ifdef KERNEL_AERIAL
	ivec2 px = ivec2(gl_GlobalInvocationID.xy);
	if (px.x >= int(ATM_AERIAL_SIZE.x) || px.y >= int(ATM_AERIAL_SIZE.y)) {
		return;
	}
	float rg = P.medium.x;
	float h = P.medium.w;
	g_eye_h = h;
	vec2 unit = atm_uv_to_unit((vec2(px) + 0.5) / ATM_AERIAL_SIZE.xy, ATM_AERIAL_SIZE.xy);
	vec3 rd = atm_dir_from_unit(unit, h, rg);
	vec3 oc = vec3(0.0, rg + max(h, 0.0), 0.0);
	vec3 L = vec3(0.0);
	vec3 T = vec3(1.0);
	float tp = 0.0;
	for (int k = 0; k < int(ATM_AERIAL_SIZE.z); k++) {
		float tn = atm_aerial_slice_dist(float(k), P.extra.x);
		vec3 Lm = vec3(0.0);
		bake_integrate(oc, rd, tp, tn, k < 4 ? 4 : 2, false, P.sun.xyz, P.sun.w, P.moon.xyz, P.moon.w, false, L, Lm, T);
		imageStore(out_img, ivec3(px, k), vec4(L, dot(T, vec3(1.0 / 3.0))));
		tp = tn;
	}
#endif
}
"""


## The full GLSL of one kernel.
static func source(kernel: String) -> String:
	var inc := load(MATH_PATH) as ShaderInclude
	return HEADER % kernel + inc.code + BODY
