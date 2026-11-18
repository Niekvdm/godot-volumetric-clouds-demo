class_name CloudWeather
extends RefCounted
## Maps the synced weather scalars onto the cloud layer. Pure: no nodes, no
## rendering, no global state.
##
## MULTIPLAYER: inputs must be identical on every peer.
##   * `fields.dew_point` is host-synced.
##   * the temperature is the SEA-LEVEL value (TemperatureSystem.get_temperature_at
##     (sea_level)) — the clock-derived base plus the synced weather modifier/override,
##     with NO lapse.
##   * NEVER `fields.humidity`: WeatherSim recomputes it every tick from
##     TemperatureSystem.get_temperature(), which is lapsed to the LOCAL camera's
##     altitude, so each player would see their own cloud base.

## THE CLOUDS' AIR IS MARINE (owner prompts/47, 2026-11-16: "is it normal that during day clouds are high and at night
## very close to the ground?"). The layer took its base from the island's land curve (Hachijo August: 24.3 degC at 05:00,
## 29.6 at 15:00) against an air mass whose dew point holds all day, so the whole sky - the sea's included - went from a
## ~675 m cumulus base in the afternoon to the 300 m floor (a deck 120 m) every night. Over the sea the air follows the
## water, which barely cools: about a third of the land's swing. marine_temperature() keeps that share of the curve's
## diurnal part (the weather's shift and a manual override pass whole). Night fog and stratus on the island stay with
## FogFormation and the slope veil.
const MARINE_SWING := 0.3


## The temperature the cloud layer forms from: `t_sea` (the sea-level air) with its diurnal part (`curve_now` -
## `curve_mean`, the climate curve at this hour against its daily mean) cut to MARINE_SWING. Pure: synced inputs only.
static func marine_temperature(t_sea: float, curve_now: float, curve_mean: float) -> float:
	return t_sea - (1.0 - MARINE_SWING) * (curve_now - curve_mean)


## Parcel LCL (Espy): a rising thermal cools dry-adiabatically, ~125 m per degC
## of temperature/dew-point spread. The CONVECTIVE base.
const LCL_M_PER_C := 125.0
## The kept LCL helper's floor (lcl_base_altitude: the climate docs and test_climate_profile).
const BASE_MIN := 120.0
## Thermals need some depth to organise; a cumulus base does not sit on the sea.
const BASE_MIN_CONVECTIVE := 300.0
## A DECK'S BASE STAYS OVER THE TOWNS (owner prompts/82, 2026-11-17: "at night when clouds come down they touch even
## the city floor??"). Hachijo's calm dew range (20.7-27.7 degC) against the marine night (~26.3 degC) leaves a spread
## of 2 degC or less on most nights, and the deck's environmental LCL (213 m/degC) took a third of them to its old 120 m
## floor: the layer 60 m over Mitsune's streets (~60 m), the slope veil under it on every street. The deck now stops
## where the cumulus does: a night ceiling of 300-600 m on the slopes, ~240 m over the coastal towns. Air saturated
## below it is fog, which FogFormation owns (radiation, advection: its own regimes from the ground's spread).
const DECK_BASE_MIN := 300.0
const BASE_MAX := 4000.0
const TOP_MAX := 9000.0
const TOP_MARGIN_M := 200.0
const DENSITY_DECK := 0.34
const DENSITY_CUMULUS := 0.60
const DENSITY_CB := 1.00
## Regional coverage scatter at mid cover (0.5).
const SCATTER := 0.5
## Manual presets slew 12x faster than weather (storm 0->1 in ~2.5 s); the deck
## would visibly morph, so type and base are rate-limited on top of the field slew.
## #772: 1/120 (was 1/60), so a front BUILDS: cumulus -> overcast or cumulus -> Cb
## takes a minute, the full stratus -> Cb swing two.
const TYPE_RATE_PER_S := 1.0 / 120.0
## THE TYPE AXIS (#772): one continuous, rate-limited scalar with four anchors.
## 0 stratus / overcast (the deck channel), 0.25 stratocumulus (the deck and the
## cumulus channels blended half and half: a ~700 m sheet of the cumulus cells'
## footprints, lumpy because its billows stay on), 0.5 cumulus, 1 cumulonimbus.
const TYPE_ST := 0.0
const TYPE_SC := 0.25
const TYPE_CU := 0.5
const TYPE_CB := 1.0
## Cover where the cumulus sky spreads out into stratocumulus (under the
## trade-wind inversion, the commonest cloud over a subtropical ocean), and where
## the stratocumulus closes into an overcast deck.
const SC_FROM := 0.5
const SC_FULL := 0.8
const DECK_FROM := 0.8
const DECK_FULL := 0.95
## Rain breaks a sheet into showers: precip this heavy has convection behind it.
const SC_RAIN_FROM := 0.1
const SC_RAIN_FULL := 0.4
## OVERCAST CLOSES (#772). A stratiform layer is a sheet, not a field of cells: once
## the air is saturated across the layer it is continuous, and breaks only open as
## it dissolves. The sky fraction is pushed toward 1 by this much of the STRATUS
## weight before the coverage table inverts it: the overcast slog's cover 0.9 draws
## a sheet (twin sky fraction >= 0.95), cover 1 a whole one.
const ST_CLOSE := 0.8
## RAIN SHAFTS / VIRGA (#772): how far below the base falling rain is still seen
## (m): drops evaporate on their way down through unsaturated air. Heavy rain
## reaches the ground from any base the model makes; light rain under a high (dry)
## base thins out on the way down: virga. Pushed as cloud_weather.w (0 = dry).
const RAIN_REACH_M := 600.0
const RAIN_REACH_PER_PR_M := 5000.0
const RAIN_MIN_PRECIP := 0.02
const BASE_RATE_MPS := 15.0
## FAIR-WEATHER CUMULUS IS SHALLOW (owner, 2026-09-28: "shallower fair-weather
## Cu"). Humilis/mediocris run ~0.5-1.5 km deep; a cloud only towers with the
## moisture and instability that also bring more of them. The baked skeleton is
## the full, congestus-capable field (median ~1.1 km, tallest ~3.1 km); stage 1
## reads its vertical axis stretched by 1 / depth_scale, so every cloud keeps
## its footprint (and so the coverage tables) and loses height. Before this,
## the calm drift's cover (0-0.5) drew 3.3 km-deep towers: near-overcast from
## the ground. DEPTH_FAIR at clear-ish skies, full depth from DEPTH_FULL_COVER,
## and always full with storm energy or rain.
## 0.45 until #771: the squash is vertical only, so at 0.45 every round lobe of the
## skeleton became a 2:1 oblate lens and fair weather read as stacked pancakes
## (the median cell ~500 m deep and ~1.2 km wide). At 0.6 a typical cloud is
## ~650 m deep and the lobes stay lobes.
const DEPTH_FAIR := 0.6
const DEPTH_FULL_COVER := 0.7
## A full swing in two minutes: presets slew cover 12x faster than weather.
const DEPTH_RATE_PER_S := 1.0 / 120.0
## THE PROCEDURAL FIELD (B2, CLOUDS2; cloud_pf_field.gdshaderinc, the weather-typed field). Its
## inputs, from synced fields only, ride in CloudState below so the multiplayer autotest compares them.
## The ordinary layer's depth: fair weather 4500 m (cumulus with room to tower), overcast 2500 m
## (a deck is 10-22 % of it); times the depth scale (fair-weather cumulus are shallow).
const PF_LAYER_CU_M := 4500.0
const PF_LAYER_ST_M := 2500.0
## Where storm towers flatten into anvils (the tropopause; STORM_TOP).
const PF_STORM_TOP_M := 11000.0
## The mid-level layer's height (max(4800, base + 0.4 depth + 800)).
const PF_ALTO_MIN_M := 4800.0
## Subsidence round storms: the ordinary layer's cover falls by this much of the storm amount (the synced
## storm sky is cover 1; a storms preset is cover 0.6 with towers through it).
const PF_STORM_SUBSIDE := 0.4
## A fair, broken sky now and then grows a distant tower (fair weather with storms 0.2).
const PF_FAIR_STORMS := 0.12


class CloudState extends RefCounted:
	## The synced cloud cover, raw (the sky fraction is re-derived from it at the
	## rate-limited type: see sky_fraction_for).
	var cover := 0.0
	var sky_fraction := 0.0
	var coverage := 0.0
	## 0 = deck/stratus, 0.5 = cumulus, 1 = cumulonimbus. Continuous.
	var cloud_type := 0.5
	var base_m := 600.0
	var top_m := 2400.0
	var density := 0.6
	var rain := 0.0
	var storm := 0.0
	var scatter_amp := 0.0
	## Vertical scale of the baked field (1 = full depth). See DEPTH_FAIR.
	var depth_scale := 1.0
	## Rain shafts' reach below the base (m); 0 when dry. See RAIN_REACH_M.
	var rain_reach_m := 0.0
	## The procedural field (B2): the ordinary layer's depth (m), the storm-tower ceiling (m, asl), the
	## storm-cell amount, the mid-level layer's amount and height (m, asl), the cover its columns
	## scatter round (subsided by storms) and the cirrus amount.
	var pf_layer_m := 2500.0
	var pf_ceiling_m := 3100.0
	var storms := 0.0
	var alto := 0.0
	var alto_m := 4800.0
	var pf_cover := 0.0
	var cirrus := 0.0

	func copy() -> CloudState:
		var s := CloudState.new()
		s.cover = cover
		s.sky_fraction = sky_fraction
		s.coverage = coverage
		s.cloud_type = cloud_type
		s.base_m = base_m
		s.top_m = top_m
		s.density = density
		s.rain = rain
		s.storm = storm
		s.scatter_amp = scatter_amp
		s.depth_scale = depth_scale
		s.rain_reach_m = rain_reach_m
		s.pf_layer_m = pf_layer_m
		s.pf_ceiling_m = pf_ceiling_m
		s.storms = storms
		s.alto = alto
		s.alto_m = alto_m
		s.pf_cover = pf_cover
		s.cirrus = cirrus
		return s


## Lifted condensation level from temperature and relative humidity (kept for
## test_climate_profile and the climate docs). Dew point via Magnus, then Espy.
static func lcl_base_altitude(temp_c: float, humidity: float) -> float:
	var dew := FogPhysics.dew_point(temp_c, humidity)
	return clampf(FogPhysics.spread(temp_c, dew) * LCL_M_PER_C, BASE_MIN, BASE_MAX)


## Continuous type (#772: four anchors, see TYPE_ST). More cover spreads the
## cumulus into stratocumulus and then closes it into an overcast deck, unless
## there is storm energy; rain keeps the cumulus (showers) instead of the sheet,
## and storm energy (or a wet, unsettled sky) pushes toward cumulonimbus. Only
## synced fields: cover, precip, storm energy.
static func type_from(f: WeatherFields) -> float:
	var storm := clampf(f.storm_energy, 0.0, 1.0)
	var cc := clampf(f.cloud_cover, 0.0, 1.0)
	var pr := clampf(f.precip, 0.0, 1.0)
	var deckness := smoothstep(DECK_FROM, DECK_FULL, cc) * (1.0 - storm)
	var sc := smoothstep(SC_FROM, SC_FULL, cc) * (1.0 - storm) \
			* (1.0 - smoothstep(SC_RAIN_FROM, SC_RAIN_FULL, pr))
	var t := lerpf(lerpf(TYPE_CU, TYPE_SC, sc), TYPE_ST, deckness)
	var convective := maxf(storm, 0.35 * pr * (1.0 - deckness))
	return clampf(lerpf(t, TYPE_CB, convective), 0.0, 1.0)


## How much of the type is stratus (1 at the deck, 0 from stratocumulus up).
## LOCKSTEP with cloud_field.gdshaderinc's cloud_stratus_weight.
static func stratus_weight(cloud_type: float) -> float:
	return clampf(1.0 - 4.0 * cloud_type, 0.0, 1.0)


## The sky fraction a cover draws at a type (#772): the cover itself for cumulus,
## stratocumulus and Cb, closed toward 1 by the stratus weight (ST_CLOSE). A storm
## sky opens in the field instead: subsidence round the storm regions
## (cloud_field's CLOUD_STORM_SUBSIDE, CloudFieldTwin.STORM_SUBSIDE).
static func sky_fraction_for(cover: float, cloud_type: float) -> float:
	var cc := clampf(cover, 0.0, 1.0)
	return clampf(1.0 - (1.0 - cc) * (1.0 - ST_CLOSE * stratus_weight(cloud_type)), 0.0, 1.0)


## Regional coverage scatter: SCATTER at a half-covered sky, none clear or closed.
static func scatter_for(sky_fraction: float) -> float:
	var f := clampf(sky_fraction, 0.0, 1.0)
	return SCATTER * 2.0 * minf(f, 1.0 - f)


## Rain shafts' reach below the base (m): 0 when dry. See RAIN_REACH_M.
static func rain_reach_for(precip: float) -> float:
	var pr := clampf(precip, 0.0, 1.0)
	if pr < RAIN_MIN_PRECIP:
		return 0.0
	return RAIN_REACH_M + RAIN_REACH_PER_PR_M * pr


## Two formulas, two roles, blended by how deck-like the sky is:
##   cumulus/Cb — Espy's PARCEL LCL (125 m/degC), floor 300 m;
##   deck       — FogPhysics' ENVIRONMENTAL saturation level (~213 m/degC), the
##                same altitude FogFormation calls "in cloud", so the visible
##                deck and the drive-into fog agree; floor DECK_BASE_MIN (300 m).
static func base_altitude_m(t_sea_c: float, dew_c: float, cloud_type: float) -> float:
	var spread := maxf(t_sea_c - dew_c, 0.0)
	var cu := clampf(spread * LCL_M_PER_C, BASE_MIN_CONVECTIVE, BASE_MAX)
	var deck := clampf(spread * FogPhysics.LCL_M_PER_DEGC, DECK_BASE_MIN, BASE_MAX)
	return lerpf(cu, deck, clampf(1.0 - 2.0 * cloud_type, 0.0, 1.0))


## THE SLOPE VEIL'S REACH (owner prompts/82), LOCKSTEP with cloud_march.gdshaderinc's CLOUD_CONTACT_BELOW_M /
## CLOUD_CONTACT_BELOW_K / CLOUD_VEIL_RAG_M (cloud_contact_below, cloud_veil_rag): the band under the base where a surface
## takes the veil is CLOUD_CONTACT_BELOW_M deep under a high base and VEIL_BELOW_K of the base under a low one (a cloud
## sags onto a slope by a share of its height, it does not lie on the coast), and its lower edge wanders down by the
## rag. The lowest surface any veil reaches, world Y.
const VEIL_BELOW_M := 260.0
const VEIL_BELOW_K := 0.4
const VEIL_RAG_M := 90.0


static func veil_lowest_m(base_m: float) -> float:
	return base_m - minf(VEIL_BELOW_M, VEIL_BELOW_K * maxf(base_m, 0.0)) - VEIL_RAG_M


static func density_for(cloud_type: float) -> float:
	if cloud_type < 0.5:
		return lerpf(DENSITY_DECK, DENSITY_CUMULUS, cloud_type / 0.5)
	return lerpf(DENSITY_CUMULUS, DENSITY_CB, (cloud_type - 0.5) / 0.5)


## Fair weather -> shallow cumulus; more cover, rain or storm energy -> deeper.
static func depth_scale_for(f: WeatherFields) -> float:
	var cc := clampf(f.cloud_cover, 0.0, 1.0)
	var fair := lerpf(DEPTH_FAIR, 1.0, smoothstep(0.1, DEPTH_FULL_COVER, cc))
	var convective := maxf(clampf(f.storm_energy, 0.0, 1.0), clampf(f.precip, 0.0, 1.0))
	return lerpf(fair, 1.0, convective)


## The procedural field's storm-cell amount (B2): the storm energy; showers (rain from a sky that is not a
## deck) grow towers too, and a fair broken sky a rare distant one. Synced fields only.
static func storms_for(f: WeatherFields) -> float:
	var cc := clampf(f.cloud_cover, 0.0, 1.0)
	var pr := clampf(f.precip, 0.0, 1.0)
	var deckness := smoothstep(DECK_FROM, DECK_FULL, cc)
	var showers := 0.5 * smoothstep(0.2, 0.6, pr) * (1.0 - deckness)
	var fair := PF_FAIR_STORMS * smoothstep(0.3, 0.55, cc) * (1.0 - smoothstep(0.65, 0.8, cc))
	return clampf(maxf(maxf(clampf(f.storm_energy, 0.0, 1.0), showers), fair), 0.0, 1.0)


## The mid-level layer's amount (B2; altocumulus, thickening into altostratus with a front).
static func alto_for(f: WeatherFields) -> float:
	var cc := clampf(f.cloud_cover, 0.0, 1.0)
	return clampf(0.35 * smoothstep(0.05, 0.5, cc) + 0.45 * smoothstep(0.5, 0.95, cc)
			+ 0.15 * clampf(f.precip, 0.0, 1.0) + 0.15 * clampf(f.storm_energy, 0.0, 1.0), 0.0, 1.0)


## THE COVER THE PROCEDURAL FIELD'S COLUMNS SCATTER ROUND (B2). The field turns from clear to closed over a
## narrow band of its slider (its base shape's remap is 0.667 +- 0.063: tools/sky/cloud_pf_stats.gd), so the synced
## cover (the sky fraction the weather means) is mapped onto that band. Measured straight up at noon (run cal1, the
## history's T < 0.5 share of a 70 deg view): slider 0.3 -> 4 %, 0.45 -> 30 %, 0.6 -> 86 %, 0.75 -> 100 %.
## CLOUDS6 (R34): the cumulus rows (0.15-0.70) +0.02, toward the baked field's cover at the same weather (with the
## steeper cumulus remap, CloudUniforms.PF_CORE_K, a half-covered sky draws ~60-70 % from below, the baked ~75 %);
## the deck rows (0.85 up: R29's rain deck) as they were.
## [cover, slider]; linear between the rows.
const PF_SLIDER := [[0.0, 0.0], [0.05, 0.30], [0.15, 0.39], [0.30, 0.45], [0.50, 0.51], [0.70, 0.565],
		[0.85, 0.62], [0.95, 0.72], [1.0, 0.80]]


static func pf_slider_for(cover: float) -> float:
	var c := clampf(cover, 0.0, 1.0)
	for i in range(1, PF_SLIDER.size()):
		var a: Array = PF_SLIDER[i - 1]
		var b: Array = PF_SLIDER[i]
		if c <= b[0]:
			return lerpf(a[1], b[1], (c - a[0]) / maxf(b[0] - a[0], 1e-6))
	return PF_SLIDER[PF_SLIDER.size() - 1][1]


## The procedural field's layer and ceiling from the (rate-limited) type and depth scale, and the amounts.
static func set_pf(s: CloudState, f: WeatherFields) -> void:
	s.storms = storms_for(f)
	s.alto = alto_for(f)
	pf_layer(s)
	s.pf_cover = pf_slider_for(s.cover * (1.0 - PF_STORM_SUBSIDE * s.storms))
	# The cirrus lifts with the cover; an overcast hides it anyway.
	s.cirrus = 0.35 * s.cover


## The layer's depth, the ceiling and the mid-level layer's height, from the type, base, depth scale and
## storm amount already in `s`.
static func pf_layer(s: CloudState) -> void:
	s.pf_layer_m = lerpf(PF_LAYER_ST_M, PF_LAYER_CU_M, clampf(2.0 * s.cloud_type, 0.0, 1.0)) * s.depth_scale
	var top := s.base_m + s.pf_layer_m
	s.pf_ceiling_m = maxf(PF_STORM_TOP_M, top + 1500.0) if s.storms > 0.0 else top
	s.alto_m = maxf(PF_ALTO_MIN_M, s.base_m + 0.4 * s.pf_layer_m + 800.0)


static func top_for(base_m: float, cloud_type: float, m: CloudManifest, depth_scale := 1.0) -> float:
	return minf(base_m + m.channel_top(cloud_type) * depth_scale + TOP_MARGIN_M, TOP_MAX)


static func state_from(f: WeatherFields, t_sea_c: float, m: CloudManifest) -> CloudState:
	var s := CloudState.new()
	var cc := clampf(f.cloud_cover, 0.0, 1.0)
	s.cover = cc
	s.cloud_type = type_from(f)
	s.sky_fraction = sky_fraction_for(cc, s.cloud_type)
	s.coverage = m.coverage_for(s.sky_fraction, s.cloud_type)
	s.base_m = base_altitude_m(t_sea_c, f.dew_point, s.cloud_type)
	s.depth_scale = depth_scale_for(f)
	s.top_m = top_for(s.base_m, s.cloud_type, m, s.depth_scale)
	s.density = density_for(s.cloud_type)
	s.rain = clampf(f.precip, 0.0, 1.0)
	s.storm = clampf(f.storm_energy, 0.0, 1.0)
	# Regional scatter by the sky fraction drawn, not the raw cover (#772): a closed
	# overcast has no regional holes.
	s.scatter_amp = scatter_for(s.sky_fraction)
	s.rain_reach_m = rain_reach_for(f.precip)
	set_pf(s, f)
	return s


## Coverage/rain/storm pass straight through: the fields already slew (cloud
## cover over 120 s), and a second tween would only add lag and per-peer drift.
static func limit_rate(prev: CloudState, target: CloudState, dt: float,
		m: CloudManifest) -> CloudState:
	var s := target.copy()
	s.cloud_type = move_toward(prev.cloud_type, target.cloud_type, TYPE_RATE_PER_S * dt)
	s.base_m = move_toward(prev.base_m, target.base_m, BASE_RATE_MPS * dt)
	s.depth_scale = move_toward(prev.depth_scale, target.depth_scale, DEPTH_RATE_PER_S * dt)
	# The sky fraction follows the RATE-LIMITED type: an overcast closes as the deck
	# arrives, not the frame the cover crosses into it.
	s.sky_fraction = sky_fraction_for(target.cover, s.cloud_type)
	s.coverage = m.coverage_for(s.sky_fraction, s.cloud_type)
	s.scatter_amp = scatter_for(s.sky_fraction)
	s.top_m = top_for(s.base_m, s.cloud_type, m, s.depth_scale)
	s.density = density_for(s.cloud_type)
	# The procedural field's layer follows the rate-limited type, base and depth; its amounts pass through
	# like the coverage (the fields already slew).
	pf_layer(s)
	return s
