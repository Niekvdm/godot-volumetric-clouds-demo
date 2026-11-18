// THE PROCEDURAL FIELD'S MARCH (B2, CLOUDS2): bounds by storm mask,
// distance-growing steps that stretch through clear air, the light ray reusing the column's weather, the
// up-probe, the mid-level layer composited where the ray passes it, the cirrus sheet behind, in our
// CloudSample form (lighting WEIGHTS: the resolve applies this frame's key and ambient colours, and the
// lightning). Our additions, from the baked field's march: entering a cloud from a coarse step bisects
// back to its surface and steps by optical depth inside (one jittered sample per coarse
// step and lets TAA integrate it; our sky has no TAA and the history refreshes a pixel every lattice^2
// frames), and the rain column / earth shadow terms. cloud_march_layer dispatches here when cloud_pf.x = 1.
// Needs cloud_pf_field (via cloud_field), cloud_light, and cloud_march's CloudSample / cloud_ray_pos.
#ifndef CLOUD_PF_MARCH_INC
#define CLOUD_PF_MARCH_INC

// Inside cloud: a step's optical depth, and the shortest step (m).
const float PF_TAU_STEP = 0.6;
const float PF_DT_FINE = 16.0;
// THE MATERIALS' MARCH IS LIGHTER. The full march runs in the temporal pass's compute trace (CLOUD_COMPUTE),
// which draws the main view. The sky and flight-quad materials march per pixel only for what that pass does not
// own (mirrors, the PIP, a stalled pass) and for the reflection cubemap; compiled into every sky variant, the full
// march (its light loop and bisection unrolled round every shape call) made the sky's pipelines slow to build, so
// there: no bisection, at most 3 light samples, no mid-level layer.
#ifdef CLOUD_COMPUTE
const int PF_ENTRY_BISECT = 3;
const int PF_LIGHT_MAX = 8;
const bool PF_ALTO_MARCH = true;
#else
const int PF_ENTRY_BISECT = 0;
const int PF_LIGHT_MAX = 3;
const bool PF_ALTO_MARCH = false;
#endif
// The march ends here (0.004; the sun's disc is cut to the cloud's T less 6 %).
const float PF_T_CUT = 0.02;
// Clear air over a column's tops (its weather's cap, x PF_SKIP_TOP_K + PF_SKIP_TOP_M) strides up to x4 like the air
// over the layer, growing PF_SKIP_GROW a step (clear air elsewhere: 0.2 a step, up to x2).
const float PF_SKIP_TOP_K = 1.15;
const float PF_SKIP_TOP_M = 120.0;
const float PF_SKIP_GROW = 0.5;
// The half-res trace's pixel, radians (a 60 deg lens over 540 rows): the far noise's footprint.
const float PF_PX = 0.002;

// The mid-level layer (altocumulus: rafts of small cloudlets in rows, thickening into a grey altostratus
// sheet with the amount): lenses reaching PF_ALTO_BOT under its height to PF_ALTO_TOP over it.
const float PF_ALTO_TOP = 700.0;
const float PF_ALTO_BOT = 300.0;
// Its tiles (2^21 / n, the k 1.5 drift; the rows' 1.6 squeeze keeps the wrap whole: 1.6 n is an integer).
const float PF_ALTO_AMT = 95325.091;   // 2^21 / 22  [95 km]
const float PF_ALTO_BIG = 24672.376;   // 2^21 / 85  [24 km]
const float PF_ALTO_EL = 6553.6;       // 2^21 / 320 [6.5 km]
// The cirrus sheet (CIRRUS_H) and its anisotropic tiles (x long, z across; 2^21 / n, k 2.2).
const float PF_CIRRUS_H = 8800.0;
const float PF_CI_X1 = 139810.13;      // 2^21 / 15   [140 km]
const float PF_CI_Z1 = 59918.629;      // 2^21 / 35   [60 km]
const float PF_CI_X2 = 41943.04;       // 2^21 / 50   [42 km]
const float PF_CI_Z2 = 5203.8511;      // 2^21 / 403  [5.2 km]
const float PF_CI_X3 = 9000.6524;      // 2^21 / 233  [9 km]
const float PF_CI_Z3 = 1500.1087;      // 2^21 / 1398 [1.5 km]

// How much mid-level cloud this region has (0..1): the amount, in patches ~100 km across.
float cloud_pf_alto_amount(vec3 p) {
	vec2 q = p.xz - cloud_pf_off_c.xy;
	vec4 m = textureLod(cloud_pf_noise, vec3(q.x, p.y, q.y) / PF_ALTO_AMT + vec3(0.27, 0.64, 0.11), 0.0);
	return clamp(cloud_pf.w * 1.5 - 0.3 + (m.r - 0.5) * 1.5 + (m.g - 0.6) * 0.7, 0.0, 1.0);
}

// The lens at p: x bottom, y top (m from the layer height), z density inside, w how far it has thickened
// into altostratus. far = 1 when the cloudlets are smaller than a pixel (their mean is used instead).
// Squeezed along world X (not along the wind: a wind that veers would slide a pattern
// squeezed through the absolute drift), so the cloudlets line up in rows.
vec4 cloud_pf_alto_lens(vec3 p, float a, float far, float foot_m) {
	vec2 q = p.xz - cloud_pf_off_c.xy;
	float st = smoothstep(0.6, 1.0, a);
	vec3 qs = vec3(q.x * 1.6, p.y, q.y);
	vec4 big = textureLod(cloud_pf_noise, qs / PF_ALTO_BIG + vec3(0.53, 0.18, 0.77), pf_lod(PF_ALTO_BIG, foot_m));
	vec4 el = textureLod(cloud_pf_noise, qs / PF_ALTO_EL + vec3(0.12, 0.91, 0.38), pf_lod(PF_ALTO_EL, foot_m));
	float cl = mix(el.b * 0.7 + el.a * 0.3, 0.6, far);
	float raft = big.g * 0.7 + big.r * 0.3;
	float v = mix(cl * 0.65 + raft * 0.45, 0.45 + raft * 0.4 + big.b * 0.15, st);
	float thr = 1.02 - a * 0.75;
	// Altostratus is not uniform either: thicker and thinner stretches, darker and paler from below.
	float d = smoothstep(thr, thr + mix(0.12, 0.35, st), v)
			* mix(1.0, 0.35 + 0.9 * smoothstep(0.45, 0.85, raft * 0.75 + cl * 0.35), st);
	return vec4(-PF_ALTO_BOT * d * mix(0.5, 1.0, st), PF_ALTO_TOP * d * mix(0.55, 1.0, st), mix(0.55, 0.3, st), st);
}

// The layer between ar.x and ar.y (6 steps), lit as the cumulus are, composited behind `s` (in front of
// whatever the march meets after it). The light toward the sun crosses the rest of the lens above.
void cloud_pf_alto(inout CloudSample s, inout float dacc, inout float wacc, vec3 ro, vec3 rd, float h0, vec2 ar,
		float a, float jit, CloudFFPhase ph) {
	float dt = (ar.y - ar.x) / 6.0;
	float mid = 0.5 * (ar.x + ar.y);
	float far = smoothstep(30000.0, 110000.0, mid);
	float sigma = cloud_light_a.x;
	float mu = max(cloud_key_dir.y, 0.08);
	float earth = smoothstep(-0.006, 0.006, cloud_key_dir.y + sqrt(max(cloud_pf_b.y, 0.0) * 2.0 / PLANET_EARTH_RADIUS));
	float gnd = cloud_ff_ground(cloud_pf_b.z);
	float T = 1.0;
	float kw = 0.0;
	float aw = 0.0;
	for (int i = 0; i < 6; i++) {
		float ts = ar.x + dt * (float(i) + jit);
		vec3 p = cloud_ray_pos(ro, rd, h0, ts);
		float z = p.y - cloud_pf_b.y;
		vec4 ln = cloud_pf_alto_lens(p, a, far, max(ts * PF_PX, 0.35 * dt));
		float rho = ln.z * smoothstep(ln.x, ln.x + 40.0, z) * (1.0 - smoothstep(ln.y - 60.0, ln.y, z));
		if (rho <= 0.001) {
			continue;
		}
		float od = sigma * rho * max(ln.y - z, 0.0) / mu;
		float hn = clamp((z - ln.x) / max(ln.y - ln.x, 1.0), 0.0, 1.0);
		float e = rho * sigma;
		float st = exp(-e * dt);
		float w = T * (1.0 - st);
		kw += w * (cloud_ff_ms_p(ph, od) + gnd * mix(1.0, 0.3, hn)) * earth;
		aw += w * mix(0.35, 1.0, hn);
		T *= st;
	}
	float wa = s.T * (1.0 - T);
	s.key_w += s.T * kw;
	s.amb_w += s.T * aw;
	dacc += wa * mid;
	wacc += wa;
	s.T *= T;
}

// The cirrus's optical thickness at p: a thin streaky sheet at PF_CIRRUS_H (anisotropic streaks; wide
// thresholds: soft veils and streaks, never isolated specks).
float cloud_pf_cirrus(vec3 p) {
	vec2 q = p.xz - cloud_pf_off_c.zw;
	vec4 m = textureLod(cloud_pf_noise, vec3(q.x / PF_CI_X1 + 0.7, p.y / 60000.0 + 0.1, q.y / PF_CI_Z1 + 0.4), 0.0);
	float amount = clamp((m.r - 0.42) * 2.6 + (m.g - 0.6) + cloud_pf_c.z, 0.0, 1.0);
	if (amount <= 0.0) {
		return 0.0;
	}
	vec4 a = textureLod(cloud_pf_noise, vec3(q.x / PF_CI_X2, p.y / 5200.0, q.y / PF_CI_Z2) + (m.gba - 0.6) * 0.25, 0.0);
	vec4 b = textureLod(cloud_pf_noise, vec3(q.x / PF_CI_X3, p.y / 1500.0, q.y / PF_CI_Z3) + (a.gba - 0.6) * 0.18, 0.0);
	float v = a.r * 0.7 + b.g * 0.18 + b.a * 0.12;
	return smoothstep(0.82 - amount * 0.35, 1.05 - amount * 0.15, v) * amount * 0.8;
}

// The cirrus behind `s` (from below; from above only along rays that miss the ground), lit with its own
// phase: weights as the march's (key, ambient), its depth into the mean.
void cloud_pf_cirrus_over(inout CloudSample s, inout float dacc, inout float wacc, vec3 ro, vec3 rd, float h0,
		float t_max, float cos_t) {
	if (s.T <= 0.01 || cloud_pf_c.z <= 0.0 || (int(cloud_pf_c.w) & 2) == 0) {
		return;
	}
	float tci = -1.0;
	if (h0 < PF_CIRRUS_H) {
		tci = planet_shell_hit(h0, rd.y, PF_CIRRUS_H, PLANET_EARTH_RADIUS);
	} else if (planet_ground_hit(h0, rd.y, PLANET_EARTH_RADIUS) < 0.0) {
		tci = planet_shell_hit(h0, rd.y, PF_CIRRUS_H, PLANET_EARTH_RADIUS);
	}
	if (tci <= 0.0 || tci >= t_max || tci >= 400000.0) {
		return;
	}
	vec3 p = cloud_ray_pos(ro, rd, h0, tci);
	float slant = 1.0 / max(abs(rd.y), 0.08);
	float tau = cloud_pf_cirrus(p) * slant * 0.35;
	if (tau <= 0.001) {
		return;
	}
	float ph = mix(cloud_hg(cos_t, 0.75), cloud_hg(cos_t, -0.1), 0.35) + 0.04;
	float earth = smoothstep(-0.006, 0.006, cloud_key_dir.y + sqrt(PF_CIRRUS_H * 2.0 / PLANET_EARTH_RADIUS));
	float ac = 1.0 - exp(-tau);
	float w = s.T * ac * 0.95;
	s.key_w += w * (ph + 0.3 * cloud_ff_ground(cloud_pf_b.z)) * earth;
	s.amb_w += w * 0.5;
	dacc += s.T * ac * tci;
	wacc += s.T * ac;
	s.T *= 1.0 - ac;
}

// The march (see the header). `cheap` = the reflection / radiance branch: 8 even steps, no erosion, one
// light sample, no mid-level layer.
CloudSample cloud_pf_march_layer(vec3 ro, vec3 rd, float t_max, float jit, float jit_l, bool cheap,
		int max_steps_in, int light_n_in) {
	CloudSample s;
	s.key_w = 0.0;
	s.amb_w = 0.0;
	s.T = 1.0;
	s.depth_m = 0.0;
	float h0 = max(ro.y, 0.0);
	float cut = cloud_q_light.y;
	float base = cloud_layer.x;
	// Only rays that pass near a storm cell march up to its ceiling and look the cells up.
	uint mask = cloud_pf_storm_mask(ro, rd, min(t_max, cut));
	float top = mask != 0u ? cloud_pf_b.x : base + cloud_pf.y;
	vec2 seg = planet_cloud_shell_segment(h0, rd.y, base, top, cut, PLANET_EARTH_RADIUS);
	seg.y = min(seg.y, t_max);
	s.depth_m = max(seg.x, 0.0);
	float cos_t = dot(rd, cloud_key_dir.xyz);
	// Extinction per unit of the shape's density: sigma x our per-type density (cloud_layer.z, CloudWeather.density_for:
	// a deck 0.34, cumulus 0.6, a Cb 1). The field is 0..1 against sigma alone; at that its cumulus came out
	// optically ~1.7x thicker than the baked field's and self-shadowed into flat grey (run look2) -- through the
	// uneroded envelope the light probes saw then (and the tiers' pf_density_k 0.5 halves it); with the proxy the
	// cumulus take most of it back (cu_dens below).
	float sigma = cloud_light_a.x * cloud_layer.z;
	CloudFFPhase ph = cloud_ff_phases(cos_t);
	float dacc = 0.0;
	float wacc = 0.0;
	float rim_sun = 0.0;
	float rim_lit = 0.0;
	float rim_w = 0.0;
	int flags = int(cloud_pf_c.w);
	bool skip_tops = (flags & 8) != 0;
	// The mid-level layer, composited where the march passes its middle (in front of or behind the cumulus
	// and towers it meets), or after it.
	vec2 ar = vec2(1.0, 0.0);
	float aamt = 0.0;
	if (PF_ALTO_MARCH && !cheap && cloud_pf.w > 0.0 && (flags & 1) != 0) {
		float ay = cloud_pf_b.y;
		ar = planet_cloud_shell_segment(h0, rd.y, ay - PF_ALTO_BOT, ay + PF_ALTO_TOP, 250000.0, PLANET_EARTH_RADIUS);
		ar.y = min(min(ar.y, ar.x + 60000.0), t_max);
		if (ar.x < ar.y) {
			aamt = cloud_pf_alto_amount(cloud_ray_pos(ro, rd, h0, 0.5 * (ar.x + ar.y)));
		}
	}
	bool alto_on = aamt > 0.0;
	float alto_mid = 0.5 * (ar.x + ar.y);
	if (seg.x < seg.y) {
		int max_steps = cheap ? 8 : max_steps_in;
		// No key light at all (NIGHT/NOTES.md): the moon is the key and 3 deg under the horizon, where SkyAtmosphere's
		// moon_up (smoothstep(-0.05, 0.05, y): it re-bakes the frame that reaches 0) and Sky3D's moon energy (0 below
		// y 0) are both exactly 0, and no rain column reads the ray's depth (cloud_column_od 0): the light ray changes no
		// pixel (key_w is resolved times a black key), so it takes no sample. A/B: debug_view 7
		// (n.CloudBridge.tune=debug_view:7; debug_view:0 for the other leg) marches it anyway.
		bool key_dark = cloud_key_dir.w < 0.5 && cloud_key_dir.y < -0.0501 && cloud_light_e.w <= 0.0 && cloud_debug != 7;
		int light_n = key_dark ? 0 : (cheap ? 1 : light_n_in);
		float dt_even = (seg.y - seg.x) / 8.0;
		float fine_k = (flags & 4) != 0 ? 1.0 : 0.0;
		// t is where the NEXT sample sits: one jitter along the ray (the history integrates it), steps
		// growing with distance and stretching while the ray is in clear air.
		float t = seg.x + (cheap ? dt_even : cloud_q_view.x) * jit;
		float clear = 0.0;
		float t_empty = seg.x;
		// While t < fine_until, empty samples advance finely (just entered, or a gap inside a cloud).
		float fine_until = -1.0;
		float cover_g = cloud_ff_ground(cloud_pf_b.z);
		// THE PROXY (CLOUDS6, bit 256; CloudUniforms.PF_PROXY): the probes that skip the erosion take its mean
		// (cloud_pf_shape with fine < 0), not the uneroded envelope round the drawn cloud. Bit 512: the cheap march's
		// view samples too (the reflection cubemap: the envelope drew it near overcast and lit the scene so).
		float prx = (flags & 256) != 0 ? -1.0 : 0.0;
		float prx_cheap = (flags & 512) != 0 ? -1.0 : 0.0;
		float cu_dens = cloud_q_flight.w > 0.0 ? cloud_q_flight.w : 1.0;
		for (int i = 0; i < 256; i++) {
			if (i >= max_steps || s.T < PF_T_CUT) {
				break;
			}
			if (alto_on && t > alto_mid) {
				alto_on = false;
				cloud_pf_alto(s, dacc, wacc, ro, rd, h0, ar, aamt, jit, ph);
				if (s.T < PF_T_CUT) {
					break;
				}
			}
			if (t >= seg.y) {
				break;
			}
			float dt_c = cheap ? dt_even : clamp(cloud_q_view.x + cloud_q_view.y * t, cloud_q_view.x, cloud_q_view.z);
			bool fine = !cheap && t < fine_until;
			vec3 p = cloud_ray_pos(ro, rd, h0, t);
			float hb = p.y - base;
			CloudPfWx wx = cloud_pf_weather(p, hb, mask);
			float foot = max(t * PF_PX, 0.35 * (fine ? PF_DT_FINE : dt_c));
			// The close-up erosion octave only pays off within a few km.
			float fine_oct = fine_k * (1.0 - smoothstep(1500.0, 4500.0, t));
			float d = cloud_pf_shape(p, hb, wx, !cheap, cheap ? prx_cheap : fine_oct, foot);
			if (d <= 0.002) {
				t_empty = t;
				// Stride faster through clear air, and through the storm-only air over the ordinary layer. Over this
				// column's own cloud tops (the weather caps them: nothing but a storm cell reaches higher here) it
				// strides as over the layer (CLOUDS3, cloud_pf_c.w bit 8; the trace 0-0.3 ms cheaper in runs ab3 / lk1).
				if (!fine) {
					bool above = wx.cb <= 0.0 && hb > cloud_pf.y;
					bool over = skip_tops && wx.cb <= 0.0
							&& (above || hb > cloud_pf_column_top(wx) * PF_SKIP_TOP_K + PF_SKIP_TOP_M);
					clear = over ? min(clear + PF_SKIP_GROW, 3.0) : min(clear + 0.2, above ? 3.0 : 1.0);
				}
				float step = fine ? PF_DT_FINE : dt_c * (1.0 + clear);
				// NOT PAST THE TOPS COMING DOWN (owner prompts/46, 2026-11-16: the view down from over a deck). A ray
				// descending over a column's cloud tops strode up to x4 dt_c (~480 m at 5 km, 180 m of height at 22 deg
				// down) and a thin stratus slab under it was landed in or jumped over by the distance's phase: dark
				// contour rings round the point under the eye (shot set row 105). Striding, it stops at the column's top;
				// from there the ordinary steps go in (cloud_pf_c.w bit 8192, tier key pf_top_stop).
				if ((flags & 8192) != 0 && !fine && clear > 0.0 && rd.y < -0.02) {
					float to_top = (hb - cloud_pf_column_top(wx)) / -rd.y;
					if (to_top > 0.0) {
						step = min(step, max(to_top, dt_c));
					}
				}
				t += step;
				continue;
			}
			clear = 0.0;
			if (PF_ENTRY_BISECT > 0 && !cheap && !fine && t - t_empty > 2.0 * PF_DT_FINE) {
				// A coarse step landed in cloud: bisect back toward its surface (this column's weather), then
				// come in by a jittered fine step, so a pixel is not one jittered sample of a coarse step.
				float a = t_empty;
				float b = t;
				for (int k = 0; k < PF_ENTRY_BISECT; k++) {
					float m = 0.5 * (a + b);
					vec3 pm = cloud_ray_pos(ro, rd, h0, m);
					if (cloud_pf_shape(pm, pm.y - base, wx, true, fine_oct, foot) > 0.002) {
						b = m;
					} else {
						a = m;
					}
				}
				t = a + PF_DT_FINE * jit;
				fine_until = b + dt_c;
				continue;
			}
			// pf_cu_dens (CLOUDS6, cloud_q_flight.w): the cumulus' extinction x this (not storm cores, not decks: the
			// rain deck's look is R29's), over the view and light rays alike. Only the march: the ground shadows and the
			// rain's column probes keep cloud_layer.z alone.
			float sg = sigma * mix(1.0, cu_dens, smoothstep(0.45, 0.9, wx.typ) * (1.0 - smoothstep(0.0, 0.25, wx.cb)));
			// Inside: a step of PF_TAU_STEP optical depth (never past the segment's end).
			float dt_in = cheap ? dt_even : clamp(PF_TAU_STEP / max(d * sg, 1e-6), PF_DT_FINE, dt_c);
			dt_in = min(dt_in, max(seg.y - t, 1.0));
			float ctop = cloud_pf_column_top(wx);
			float hn = clamp(hb / max(ctop, 1.0), 0.0, 1.0);
			// The light ray: n samples at the middles of segments 36 m x 1.85^j long (jittered along the view
			// ray, #775), reusing this column's weather; only the first erodes (the second's carve read as
			// grain at our lattice-2 history, B1). A tall column takes one more, long sample: towers shade
			// their neighbours.
			float jl = cheap ? jit_l : fract(jit_l + float(i) * 0.6180339887);
			int nl = key_dark ? 0 : (cheap ? 1 : light_n + (ctop > CLOUD_FF_TALL_M ? 1 : 0));
			float od = 0.0;
			float ls = CLOUD_FF_LIGHT_D0;
			float lt = 0.0;
			for (int j = 0; j < PF_LIGHT_MAX; j++) {
				if (j >= nl) {
					break;
				}
				vec3 lp = p + cloud_key_dir.xyz * (lt + ls * (0.5 + 0.4 * (jl - 0.5)));
				if (lp.y >= top && cloud_key_dir.y > 0.0) {
					break;
				}
				bool lde = j < 1 && !cheap;
				od += cloud_pf_shape(lp, lp.y - base, wx, lde, lde ? 0.0 : prx, max(ls * 0.5, foot)) * ls;
				lt += ls;
				ls *= CLOUD_FF_LIGHT_GROW;
			}
			od *= sg;
			// Cloud overhead blocks the sky light: a probe straight up, through the diffusion falloff.
			float od_up = cheap ? 0.0 : cloud_pf_shape(p + vec3(0.0, CLOUD_FF_UP_M, 0.0), hb + CLOUD_FF_UP_M, wx, false,
					prx, max(CLOUD_FF_UP_M, foot)) * (2.0 * CLOUD_FF_UP_M) * sg;
			float occ = mix(1.0 / (1.0 + 0.15 * od_up), 1.0, 0.12);
			// The raining column the light ray cannot see (#774; 0 when dry), gated by the ray's own depth.
			float od_c = cloud_column_od(hn) * (cheap ? 1.0 : cloud_column_gate(od));
			float col_cheap = cheap ? cloud_column_amb(od_c) : 1.0;
			float od_l = od + (cheap ? 0.0 : od_c);
			float earth = smoothstep(-0.006, 0.006, cloud_key_dir.y + sqrt(max(p.y, 0.0) * 2.0 / PLANET_EARTH_RADIUS));
			// In-scatter probability (the dark creases), off looking into the sun; the ground's bounce as
			// sunlight from below.
			float pw = cloud_ff_powder(d, hn, cos_t);
			float s_key = (cloud_ff_ms_p(ph, od_l) * pw * col_cheap + cover_g * mix(1.0, 0.25, hn) * mix(0.5, 1.0, pw)) * earth;
			float amb = mix(0.25, 0.95, hn) * occ * mix(0.5, 1.0, pw) * cloud_column_amb(od_c);
			float st = exp(-d * sg * dt_in);
			float w = s.T * (1.0 - st);
			s.key_w += w * s_key;
			s.amb_w += w * amb;
			rim_sun += w * earth;
			rim_lit += w * exp(-od_l);
			rim_w += w;
			dacc += w * t;
			wacc += w;
			s.T *= st;
			t += dt_in;
			if (!cheap) {
				fine_until = max(fine_until, t + dt_c);
			}
		}
	}
	if (alto_on && s.T >= PF_T_CUT) {
		cloud_pf_alto(s, dacc, wacc, ro, rd, h0, ar, aamt, jit, ph);
	}
	// Silver lining: the outline's own thin optical depth (cloud_ff_rim), only the share the march left unlit.
	if (!cheap && rim_w > 1e-5) {
		s.key_w += (rim_sun / rim_w) * cloud_ff_rim(cos_t, s.T, rim_lit / rim_w);
	}
	cloud_pf_cirrus_over(s, dacc, wacc, ro, rd, h0, t_max, cos_t);
	if (wacc > 1e-5) {
		s.depth_m = dacc / wacc;
	}
	return s;
}

#endif
