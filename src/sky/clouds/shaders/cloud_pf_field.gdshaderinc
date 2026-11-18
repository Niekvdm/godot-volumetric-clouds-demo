// THE PROCEDURAL FIELD (B2, CLOUDS2, 2026-11-15). The weather-typed cloud field (cloud_weather_m, cloud_shape_f, storm_*, the alto and the cirrus),
// laid onto our flat world (x, altitude, z; the planet's curve is
// only in the ray's altitude). It replaces the baked macro SDF (cloud_field's cloud_macro_q) when
// cloud_pf.x = 1 (tier key `field_model`, A/B n.CloudBridge.field_model=0|1):
//   * per column, a WEATHER: the cover (the synced cover, scattered by drifting noise as much as the sky
//     is half covered), the type (stratus .. stratocumulus .. cumulus: our rate-limited type, leaning
//     cumulus where the column is clearer than the sky round it), how tall its cumulus grow (mostly
//     fair-weather puffs, some towers; a closing deck caps them), and a stratocumulus cell mosaic;
//   * a SHAPE: one Perlin-Worley read stretched upward for cumulus (puffs grow into towers), flat sharp
//     bases and domed tops, a slab for stratus, cell lumps for stratocumulus;
//   * cumulonimbus CELLS (CloudStorms, the CPU picker; the global cloud_storms): lobed towers that twist
//     with height and lean downwind, Worley turrets at ~2.5 km and ~1 km, an overshooting top, and an anvil
//     that spreads downwind with maturity under the ceiling;
//   * the EROSION: a 1.35 km Worley warped by a 2.9 km read (curl-like), plus a 310 m fine octave close up;
//     its inverse erodes the tops (cauliflower), the Worley itself the undersides and the anvils (wisps);
//   * (CLOUDS6) the cumulus' cover remap steepened before the erosion (cloud_q_flight.z), and THE PROXY: a probe that
//     skips the erosion takes its mean (fine < 0), so the light it sees is the drawn cloud's, not the envelope's.
// The mid-level layer and the cirrus are cloud_pf_march's (they belong to the march, not the field).
//
// MULTIPLAYER: every input is synced state (CloudState via cloud_pf / cloud_pf_b / cloud_pf_c, the storm
// cells from CloudStorms, the drift from the synced CloudClock in cloud_pf_off_*), and the noise volume
// is generated with an integer hash (CloudBake KERNEL_PFNOISE), never the sin hash.
//
// Needs cloud_params first. Plain GLSL + Godot's textureLod: the temporal pass's compute trace compiles it
// too (CloudTemporalGlsl expands the #include in cloud_field).
#ifndef CLOUD_PF_FIELD_INC
#define CLOUD_PF_FIELD_INC

// Tiles (m). Each is P / n for an integer n, P the period its drift offset is wrapped by (65536 m for the
// small ones, 2^21 m for the weather), so the wrap never shows (CloudUniforms.pf_offsets). The
// sizes in brackets.
const float PF_SHAPE = 7281.7778;      // 65536 / 9     [7600]
// THE SECOND SHAPE TILE (owner prompts/47, 2026-11-16: "the cloud tiling when few clouds: you can see them form a rows
// pattern"). At a thin cover only the base shape's highest peaks are cloud - a few clusters a 7.3 km tile, its lowest
// octave 4 cells across - and the tile repeats them every 7.3 km in x and in z: seen along an axis they line up in rows
// (the lab at cover 0.15: straight columns to the horizon looking north). Any one periodic tile does that (a shift by
// the 11-22 km weather noise moved neighbouring copies alike and left the rows). Regions of the 29 km weather noise
// (cel.r over a threshold, CloudPfWx.alt) read the volume at a second tile, 65536 / 7 m across (it divides the drift's
// wrap like the first, so a wrap never shows), at the same vertical scale. Only while the sky is thin, where the rows
// show: the threshold rises out of reach from cover 0.35 to 0.6, so a fuller sky reads the one tile as before and
// pays nothing (the regions at every cover cost +0.35 ms at 0.55). One fetch away from the region borders (a narrow
// band), both across them. cloud_pf_c.w bit 16384 (tier key pf_untile).
const float PF_SHAPE2 = 9362.2857;     // 65536 / 7
const float PF_DETAIL = 1365.3333;     // 65536 / 48    [1350]
const float PF_FINE = 310.59716;       // 65536 / 211   [310]
const float PF_WARP = 2849.3913;       // 65536 / 23    [2900]
const float PF_SC_CELL = 16384.0;      // 65536 / 4     [16000]
const float PF_TURRET = 21845.333;     // 65536 / 3     [7600 x 2.6]
const float PF_MID = 174762.67;        // 2^21 / 12     [173 km]
const float PF_CELL = 29127.111;       // 2^21 / 72     [29 km]
// The base shape's texel (the mip a footprint picks): 128 texels a tile.
const float PF_TEXELS = 128.0;
// How the erosion's sample offsets are spread (tuned constants).
const float PF_WARP_M = 420.0;

float pf_remap(float v, float a, float b, float c, float d) {
	return c + (v - a) / (b - a) * (d - c);
}

// The mip for a tile from a footprint in metres (0 = full detail).
float pf_lod(float tile, float foot_m) {
	return log2(max(foot_m * PF_TEXELS / tile, 1.0));
}

// The weather of one column. cb: the storm cell's strength there (0 outside, 1 at the core), sc: the nearest
// listed cell (world x, z, tower radius m, maturity; radius 0 = none), cell: the stratocumulus mosaic.
struct CloudPfWx {
	float cov;
	float typ;
	float top;
	float cb;
	vec4 sc;
	float cell;
	float alt;    // the second shape tile's share here (PF_SHAPE2)
};

// Every listed cell (the rays' bitmask is cloud_pf_storm_mask's).
uint cloud_pf_all_storms() {
	return 65535u;
}

// storm_find: the cell with the most reach over this column, among those in `mask`.
vec4 cloud_pf_storm_find(vec2 xz, uint mask) {
	vec4 sc = vec4(0.0);
	float best = -1.5;
	int n = int(cloud_pf_b.w);
	for (int i = 0; i < 16; i++) {
		if (i >= n) {
			break;
		}
		if ((mask & (1u << uint(i))) == 0u) {
			continue;
		}
		vec4 c = texelFetch(cloud_storms, ivec2(i, 0), 0);
		float val = 1.0 - distance(xz, c.xy) / max(c.z * 2.6, 1.0);
		if (val > best) {
			best = val;
			sc = c;
		}
	}
	return sc;
}

// How high a cell grows, as a share of base .. ceiling: young towers stop short.
float cloud_pf_storm_top(float sm) {
	return mix(0.3, 1.0, smoothstep(0.0, 0.55, sm));
}

// A cell's strength (0..1) at p, hb metres over the base: 1 at the centre, 0.6 at the tower wall, 0 at the
// edge of its anvil (2.6 radii out). The tower leans downwind (10 cm a metre); at anvil level the cell
// stretches downwind; a few bulges round the tower twist with height (a cluster of updrafts, not a cylinder).
float cloud_pf_storm_cb(vec3 p, float hb, vec4 sc) {
	if (sc.z <= 0.0) {
		return 0.0;
	}
	float hc = hb / max(cloud_pf_b.x - cloud_layer.x, 1.0);
	vec2 wd = cloud_wind.xy;
	vec2 dv = p.xz - wd * (hb * 0.1) - sc.xy;
	float dw = dot(dv, wd);
	dv -= wd * (max(dw, 0.0) * 0.5 * smoothstep(0.5, 0.8, sc.w) * smoothstep(0.6, 0.9, hc));
	float ang = atan(dv.y, dv.x);
	float lob = 1.0 + (0.24 * sin(2.0 * ang + sc.w * 40.0 + hc * 1.7) + 0.13 * sin(3.0 * ang + sc.w * 73.0 - hc * 2.3))
			* (1.0 - smoothstep(0.7, 0.9, hc) * 0.3);
	return clamp(1.0 - length(dv) / (sc.z * 2.6 * lob), 0.0, 1.0);
}

// Bit i set when the ray (ro, unit rd, up to tmax m) passes within reach of listed cell i: the tower, its
// lobes, its lean and the anvil streaming downwind. Only those rays march up to the ceiling.
uint cloud_pf_storm_mask(vec3 ro, vec3 rd, float tmax) {
	uint m = 0u;
	int n = int(cloud_pf_b.w);
	vec2 rh = rd.xz;
	float rr = max(dot(rh, rh), 1e-6);
	for (int i = 0; i < 16; i++) {
		if (i >= n) {
			break;
		}
		vec4 c = texelFetch(cloud_storms, ivec2(i, 0), 0);
		float r0 = c.z * 2.6 * 1.37;
		vec2 v = c.xy + cloud_wind.xy * (r0 * 0.5) - ro.xz;
		float t = clamp(dot(v, rh) / rr, 0.0, tmax);
		if (length(v - rh * t) < r0 * 1.5 + 1200.0) {
			m |= 1u << uint(i);
		}
	}
	return m;
}

CloudPfWx cloud_pf_weather(vec3 p, float hb, uint mask) {
	CloudPfWx w;
	w.cov = 0.0;
	w.typ = 0.0;
	w.top = 0.0;
	w.cb = 0.0;
	w.sc = vec4(0.0);
	w.cell = 0.0;
	w.alt = 0.0;
	if (mask != 0u) {
		w.sc = cloud_pf_storm_find(p.xz, mask);
		w.cb = cloud_pf_storm_cb(p, hb, w.sc);
	}
	// Above the ordinary layer only storm towers reach (light probes from here only go up).
	if (hb >= cloud_pf.y) {
		return w;
	}
	vec2 qb = p.xz - cloud_pf_off_a.zw;
	vec4 mid = textureLod(cloud_pf_noise, vec3(qb.x / PF_MID, 0.29, qb.y / PF_MID), 0.0);
	vec4 cel = textureLod(cloud_pf_noise, vec3(qb.x / PF_CELL + 0.53, 0.21, qb.y / PF_CELL + 0.87), 0.0);
	if ((int(cloud_pf_c.w) & 16384) != 0) {
		// cel.r's median is ~0.445 (half the sky each tile at a thin cover); out of reach over a fuller one.
		float t_alt = mix(0.44, 1.1, smoothstep(0.35, 0.6, cloud_pf_b.z));
		w.alt = smoothstep(t_alt, t_alt + 0.012, cel.r);
	}
	// The synced cover, scattered by weather systems and clearings only as much as the sky is broken
	// (a global field would also bias it by a fixed 1700 km climate read: on one island that would only offset
	// the sky the weather asked for).
	// (0.45 / 0.2, x 1.5: its sky turns over a narrow band of the cover, and a wider regional swing
	// gives clear and cloudy stretches instead of one even sky.)
	float var_k = cloud_pf_c.y * 1.5;
	w.cov = clamp(cloud_pf_b.z + var_k * ((mid.r - 0.5) * 0.45 + (cel.g - 0.48) * 0.2), 0.0, 1.0);
	// Broken skies grow cumulus; as it closes in the cloud flattens into stratocumulus, then stratus. Our
	// rate-limited type sets the lean; a column clearer than the sky round it leans cumulus.
	w.typ = clamp(cloud_pf_c.x + smoothstep(0.68, 0.98, cloud_pf_b.z) - smoothstep(0.68, 0.98, w.cov)
			+ (mid.g - 0.62) * 0.6 * var_k, 0.0, 1.0);
	// How tall the cumulus here grow: mostly fair-weather puffs, some towers. Towers need broken sky round
	// them; a closed deck caps the convection (storm cells are separate and still punch through).
	float tower = smoothstep(0.25, 0.95, w.cov * 0.75 + cel.r * 0.55 - 0.1) * (1.0 - 0.75 * smoothstep(0.7, 0.92, w.cov));
	float cu_top = 0.28 + 0.72 * tower * tower;
	w.top = mix(mix(0.1, 0.22, smoothstep(0.0, 0.5, w.typ)), cu_top, smoothstep(0.4, 1.0, w.typ));
	// Stratocumulus decks are a mosaic of cells 1-2 km across (Worley, columnar so each cell is one lump).
	if (w.typ < 0.9) {
		vec2 qs = p.xz - cloud_pf_off_a.xy;
		w.cell = textureLod(cloud_pf_noise, vec3(qs.x, cloud_layer.x + 0.15 * hb, qs.y) / PF_SC_CELL
				+ vec3(0.41, 0.77, 0.19), 0.0).g;
	}
	return w;
}

// The height of a column's cloud above the base (m): storm cores reach the ceiling.
float cloud_pf_column_top(CloudPfWx wx) {
	return mix(cloud_pf.y * wx.top, (cloud_pf_b.x - cloud_layer.x) * cloud_pf_storm_top(wx.sc.w),
			smoothstep(0.55, 0.8, wx.cb));
}

// Cloud density (0..1) at p (hb m over the base) given its column's weather. detail = erode with the
// warped Worley; fine = how much of the close-up octave (0 far away); foot_m = the sample's footprint
// (picks the mips: our sky is not TAA'd, so far noise must be filtered).
float cloud_pf_shape(vec3 p, float hb, CloudPfWx wx, bool detail, float fine, float foot_m) {
	if (hb <= 0.0 || p.y >= cloud_pf_b.x) {
		return 0.0;
	}
	float hn = hb / max(cloud_pf.y * wx.top, 1.0);
	// The storm profile is re-evaluated here, not taken from the column: towers are a few km across, so
	// light probes leave them quickly.
	float cb = cloud_pf_storm_cb(p, hb, wx.sc);
	bool storm = false;
	float reach = 0.0;
	float thr = 1.0;
	float hc = 0.0;
	float mature = smoothstep(0.5, 0.8, wx.sc.w);
	if (cb > 0.0) {
		hc = hb / max((cloud_pf_b.x - cloud_layer.x) * cloud_pf_storm_top(wx.sc.w), 1.0);
		reach = pow(smoothstep(0.52, 0.93, hc), 1.6) * mature;
		// Young towers round off into a cauliflower dome; mature ones overshoot the anvil at the core.
		thr = mix(mix(0.6, 0.72, hc) + smoothstep(0.6, 1.0, hc) * (1.0 - mature) * 0.35, 0.06, reach);
		storm = hc < 1.0 && cb + 0.28 * mix(1.0, 0.55, reach) > thr;
	}
	bool cumulus = hn < 1.0 && wx.cov > 0.02;
	if (!storm && !cumulus) {
		return 0.0;
	}
	// For cumulus the base shape is stretched upward (half the vertical frequency), so a puff keeps its
	// footprint as it climbs and grows into a tower instead of leaning off into a flat smear.
	vec2 qs = p.xz - cloud_pf_off_a.xy;
	float vy = p.y - hb * 0.5 * wx.typ;
	vec4 n = vec4(0.0);
	if (wx.alt < 0.999) {
		n = textureLod(cloud_pf_noise, vec3(qs.x, vy, qs.y) / PF_SHAPE, pf_lod(PF_SHAPE, foot_m));
	}
	if (wx.alt > 0.001) {
		vec4 n2 = textureLod(cloud_pf_noise, vec3(qs.x / PF_SHAPE2 + 0.37, vy / PF_SHAPE + 0.11, qs.y / PF_SHAPE2 + 0.61),
				pf_lod(PF_SHAPE2, foot_m));
		n = mix(n, n2, wx.alt);
	}
	float fbm = n.g * 0.625 + n.b * 0.25 + n.a * 0.125;
	float base = pf_remap(n.r, fbm - 1.0, 1.0, 0.0, 1.0);
	float d = 0.0;
	if (cumulus) {
		// Flat, sharp bases (sharper for cumulus); tops that round off into domes as only the strongest
		// cores reach them; stratus a slab with a soft top. The profile scales the coverage, so the
		// threshold rises with height and every puff keeps a crisp edge all the way up. Stratocumulus:
		// each cell of the deck is thickest in the middle and thins toward its edges.
		float stw = 1.0 - smoothstep(0.45, 0.9, wx.typ);
		float tl = mix(1.0, mix(0.55, 1.0, smoothstep(0.25, 0.8, wx.cell)), stw);
		float bv = mix(base, base * 0.5 + wx.cell * 0.55 + 0.05, stw);
		float bottom = smoothstep(0.0, mix(150.0, 70.0, wx.typ), hb);
		float dome = 1.0 - pow(min(hn, 1.0), mix(3.0, 1.6, wx.typ));
		float prof = bottom * mix(1.0 - smoothstep(tl * 0.7, tl, hn), dome, wx.typ);
		float cv = mix(min(wx.cov * 1.15, 1.0), wx.cov, wx.typ);
		d = pf_remap(bv, min(1.0 - cv * prof, 0.999), 1.0, 0.0, 1.0);
		// CLOUDS6 (cloud_q_flight.z, CloudUniforms.PF_CORE_K): the cover remap steepened for cumulus. The base shape
		// is narrow (0.667 +- 0.063), so its remap rises only to ~0.3-0.6 over a puff, about what the erosion takes off
		// (ed x 0.62, ed ~0.5): the erosion picked the cloud out of a near-solid envelope and left a porous puff.
		float ck = cloud_q_flight.z > 0.0 ? cloud_q_flight.z : 1.0;
		d = min(d * mix(1.0, ck, smoothstep(0.45, 0.9, wx.typ)), 1.0);
	}
	// Storm cell: a fat tower of stacked billows that narrows a little with height, overshoots above the
	// anvil at its core, and spreads into a flat-topped anvil whose underside slopes back into the tower.
	float anvil = 0.0;
	if (storm) {
		anvil = reach * (1.0 - smoothstep(0.55, 0.85, cb));
		// Billowy turrets: Worley bulges (~2.5 km and ~1 km) push the tower wall in and out.
		vec4 tn = textureLod(cloud_pf_noise, vec3(qs.x, p.y, qs.y) / PF_TURRET + vec3(0.71, 0.33, 0.12),
				pf_lod(PF_TURRET, foot_m));
		float turret = tn.g * 0.55 + n.g * 0.3 + n.b * 0.15;
		float cbp = cb + (turret - 0.5) * mix(0.55, 0.3, reach);
		float topf = mix(1.0, 0.93 + 0.07 * smoothstep(0.65, 1.0, cb), mature);
		float env = smoothstep(thr, thr + 0.16, cbp) * smoothstep(0.0, 70.0, hb) * (1.0 - smoothstep(topf - 0.03, topf, hc));
		// Anvils are smooth ice sheets; the tower is solid and keeps the noise.
		float body = mix(0.6 + base * 0.6, 0.85 + base * 0.15, anvil);
		d = max(d, pf_remap(body * env, 0.2, 1.0, 0.0, 1.0));
	}
	if (d <= 0.0) {
		return 0.0;
	}
	if (detail) {
		// A curl-like warp so the erosion swirls instead of looking like stamped noise.
		vec2 qw = p.xz - cloud_pf_off_b.xy;
		vec3 wv = textureLod(cloud_pf_noise, vec3(qw.x, p.y, qw.y) / PF_WARP + vec3(0.31, 0.62, 0.17),
				pf_lod(PF_WARP, foot_m)).gba - 0.62;
		vec2 qd = p.xz - cloud_pf_off_b.zw;
		vec3 pe = vec3(qd.x, p.y, qd.y) + wv * PF_WARP_M;
		vec4 e = textureLod(cloud_pf_noise, pe / PF_DETAIL, pf_lod(PF_DETAIL, foot_m));
		float ef = e.g * 0.625 + e.b * 0.25 + e.a * 0.125;
		if (fine > 0.0) {
			// Close up, a finer octave keeps the billows crisp instead of going soft.
			vec4 e2 = textureLod(cloud_pf_noise, pe / PF_FINE + vec3(0.17, 0.59, 0.43), pf_lod(PF_FINE, foot_m));
			ef = mix(ef, ef * 0.72 + (e2.g * 0.7 + e2.b * 0.3) * 0.28, fine);
		}
		// Worley is brightest at cell centres. Eroding by its inverse keeps round bulges (cauliflower
		// billows); eroding by it directly leaves ragged, wispy strands: the undersides and the anvil's ice.
		float low = storm ? 1.0 - smoothstep(80.0, 600.0, hb) : 1.0 - smoothstep(0.02, 0.13, hn);
		float wisp = max(low, anvil);
		float ed = mix(1.0 - ef, ef, wisp);
		d = pf_remap(d, ed * mix(0.5, 0.62, wx.typ) * mix(1.0, 0.35, anvil), 1.0, 0.0, 1.0);
		if (d <= 0.0) {
			return 0.0;
		}
	} else if (fine < 0.0) {
		// THE PROXY (fine < 0; CLOUDS6, CloudUniforms.PF_PROXY): the erosion's mean (the Worley fBm's mean is 0.48, so ed is ~0.5
		// either way) for the light and up probes, so they see the drawn cloud's extent and not the uneroded envelope
		// round it (at a half-covered sky that envelope fills 84-98 % of the lower layer: every puff sat in the
		// shadow of cloud nobody draws).
		d = pf_remap(d, 0.5 * mix(0.5, 0.62, wx.typ) * mix(1.0, 0.35, anvil), 1.0, 0.0, 1.0);
		if (d <= 0.0) {
			return 0.0;
		}
	}
	// Real cloud edges are abrupt: a few tens of metres from clear air to dense.
	return smoothstep(0.0, mix(0.22, 0.16, wx.typ), d) * mix(0.55, 1.0, max(wx.typ, min(cb * 4.0, 1.0)));
}

// One sample of the field with its own column's weather (every listed storm): what cloud_macro_q answers
// for the shadow bakes, the rain's column, the slope veil and the far field.
// proxy: without the detail, take the erosion's mean (cloud_pf_shape's fine < 0) instead of the envelope.
float cloud_pf_density(vec3 p, float hb, bool detail, float foot_m, bool proxy) {
	if (hb <= 0.0 || p.y >= cloud_pf_b.x) {
		return 0.0;
	}
	CloudPfWx wx = cloud_pf_weather(p, hb, cloud_pf_all_storms());
	// x the per-type density, as the baked field's stage 1 answers (and the march's extinction uses).
	return cloud_pf_shape(p, hb, wx, detail, proxy && !detail ? -1.0 : 0.0, foot_m) * cloud_layer.z;
}

#endif
