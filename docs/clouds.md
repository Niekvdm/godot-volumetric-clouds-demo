# The volumetric clouds

A guide to what the clouds do, how the weather shapes them, and the settings worth knowing. The code
lives in `src/sky/clouds/`.

## In one paragraph

You hand the clouds a weather: how much of the sky is covered, rain, storm energy, wind, and how
humid the air is. From that they work out what kind of sky it is (fair cumulus, a sheet of
stratocumulus, an overcast deck, thunderstorms) and where the cloud base sits. They drift the field
with the wind, and draw it by ray-marching a 3D density through the sky. Clouds in front of
geometry (mountains, buildings, or you flying through them) get their own pass, a compute pass
keeps the cost down, and the clouds cast shadows on the ground.

## How a frame comes together

1. **Weather in.** A `WeatherFields` holds the weather (see the table below).
2. **Weather becomes a cloud state.** `CloudWeather` turns it into a `CloudState`: the cloud type,
   the base and top heights, the depth, how many storm cells, the mid-level layer and the cirrus. It
   is pure code with no nodes, so every multiplayer peer gets the same answer from the same weather.
3. **The model eases and drifts.** `CloudModel.tick()` eases the state toward the new weather (a real
   sky does not change type in a frame) and advances `CloudClock`, which drifts the whole field with
   the wind.
4. **Numbers go to the shaders.** `CloudBridge` (a node) and `CloudUniforms` write everything the
   shaders need as global shader parameters, once a frame.
5. **Three passes draw it:**
   - **The sky pass:** the sky shader (`src/sky/shaders/planet_sky_volumetric.gdshader`) marches
     the clouds behind everything, on pixels where only sky shows.
   - **The flight pass:** two fullscreen quads march the clouds in front of geometry, up to the
     depth buffer. This is what lets a cloud hide a mountain top, or lets you fly into one.
   - **The temporal pass:** a compute pass (`CloudTemporal`) marches only 1 of every 4 half-res
     pixels each frame and rebuilds the rest from the previous frames. The sky and the flight pass
     read its result, so the full march runs on a quarter of the pixels.
6. **Shadows.** `CloudShadowReceiver` bakes the sun's light through the clouds into a map that
   follows the camera and darkens the ground beneath the clouds with a decal. `CloudShadowWindow`
   makes the same kind of map for a water shader to read.

## The weather you give it

| `WeatherFields` field | Range | What it does to the clouds |
|---|---|---|
| `cloud_cover` | 0..1 | How much of the sky is cloud. It also picks the cloud type (see below). |
| `precip` | 0..1 | Rain. It breaks sheets into showers, grows shower towers, darkens bases, and draws rain shafts under the clouds. |
| `storm_energy` | 0..1 | Turns the sky convective: cumulonimbus towers with anvils. |
| `wind_dir`, `wind_speed` | vector, m/s | The surface wind. The clouds drift with the wind at about 1,200 m, which `WindProfile` derives from it (faster, and turned). |
| `dew_point` | °C | With the air temperature, it sets the cloud base. |

The air temperature is passed separately to `model.tick(delta, weather, hour, air_temp_c)`.

## How the weather becomes a sky

**The cloud type** is one number from 0 to 1:

| Type | Sky |
|---|---|
| 0 | stratus: a flat overcast deck |
| 0.25 | stratocumulus: a lumpy sheet |
| 0.5 | cumulus: separate fair-weather clouds |
| 1 | cumulonimbus: storm towers with anvils |

- Low and medium cover gives **cumulus**.
- From cover 0.5 the cumulus spreads into **stratocumulus**, full by 0.8.
- From 0.8 that closes into an **overcast deck**, full by 0.95.
- **Rain** keeps the sky as showers instead of a sheet.
- **Storm energy** pushes it toward **cumulonimbus**.

**The cloud base** comes from how dry the air is, the gap between air temperature and dew point:

| Sky | Base height | Floor | Ceiling |
|---|---|---|---|
| cumulus | about 125 m per °C of gap | 300 m | 4,000 m |
| deck | about 213 m per °C of gap | 300 m | 4,000 m |

So a 4 °C gap puts a cumulus base near 500 m.

**The rest of the sky** comes from the same weather:
- **Depth:** fair-weather cumulus are shallow; they grow to full depth by cover 0.7, or with rain or
  storms.
- **Storm cells:** they come from storm energy, from showers, and now and then as a distant tower in
  a broken fair sky. The cells sit on a 40 km grid, up to 16 at a time, and their anvils flatten at
  about 11 km.
- **The mid-level layer** (altocumulus) grows with cover, rain and storms.
- **Cirrus** grows with cover.

**Changes ease in.** The type takes about two minutes for a full swing, and the base moves at up to
15 m/s. Call `model.reprime()` to land a change at once; the demo's *Snap weather changes* does that.

## Drift and multiplayer

`CloudClock` adds up the wind over time, so the field's position depends only on the weather and
the time. The field itself comes from integer hashes, so every GPU grows the same clouds.

For multiplayer:
- Run `CloudModel` on every peer from the synced weather.
- Have the host send `model.clock.to_dict()`, and each client apply it with
  `model.clock.apply_remote(...)`.

Everyone then sees the same clouds in the same places.

## The settings

The tier table is `CloudQuality.PARAMS[&"high"]` (`src/sky/clouds/cloud_quality.gd`).

| Key | Default | What it does |
|---|---|---|
| `cut_m` | 80000 | How far the march reaches (m). |
| `detail_fade` | 4000, 12000 | Where the close-up detail fades out (m from the camera). |
| `flight` | true | The pass that draws clouds in front of geometry. |
| `flight_steps` | 128 | Its march steps. |
| `temporal` | true | The compute pass. Off, every pixel runs the full march (slower). |
| `temporal_lattice` | 2 | 2 traces 1 pixel in 4 per frame, 4 traces 1 in 16, 1 traces every pixel. |
| `temporal_retain` | 0.9 | How much of the history a traced pixel keeps (smoother but slower to react). |
| `ground_shadows` | true | The cloud shadows on the ground. |
| `lighting` | 1 | The lighting model of the slope veil, the rain shafts and the far field: 1 = the four-lobe phase terms, 0 = the Nubis dual-lobe ones. The main field always uses the four-lobe terms. |
| `key_gain` | 0.7 | Brightness of the sunlit sides. |
| `amb_grey` | 0.2 | How much the ambient light is pulled toward grey. |
| `pf_density_k` | 0.5 | Thickness: scales how much light the clouds absorb. |
| `pf_light` | 5 | Light samples per point toward the sun: more gives deeper shading, at a cost. |
| `pf_max_steps` | 160 | March steps per ray. |
| `pf_step_base_m`, `pf_step_growth`, `pf_step_max_m` | 40, 0.016, 2000 | The first step, how much it grows per metre, the largest step. |
| `pf_alto`, `pf_cirrus` | true | The mid-level layer and the cirrus. |
| `pf_fine` | true | The close-up erosion detail. |
| `pf_skip` | true | Longer steps (up to 4x) once the ray is above a column's own tops. |

`CloudBridge` also has live overrides for trying things out without editing the table:
- `flight_override`, `temporal_override`, `ground_shadow_override`: -1 follows the tier, 0 is off,
  1 is on.
- `key_gain_override`, `amb_grey_override` (and `lighting_override`, which only reaches the veil, the
  rain shafts and the far field).
- `storm_cells_off`.
- `temporal_tuning`: a dictionary of tier keys that wins over the table.

The demo's panel drives these.

## Cost

On an RTX 5070 Laptop GPU at 1600×900, the whole demo frame runs at about 100–120 fps with the HIGH
tier on. That is the whole frame, not the clouds alone. The levers, roughly from cheapest to
dearest:
- `temporal_lattice` 4: traces a quarter as many pixels.
- Fewer `pf_light` samples.
- Fewer `pf_max_steps`.
- Turning off `pf_fine`.

## Rules for the environment

The half-res cloud buffer is packed around a few environment values, and `CloudBridge` prints a
warning if they're broken:
- fog aerial perspective at 1;
- fog sun scatter at 0;
- volumetric fog's sky affect at 0;
- no sky rotation.

The look was tuned with the sky's radiance map at 1024 (`environment.sky.radiance_size`). At Godot's
default of 256 the ground's ambient reads darker.

## When something looks wrong

- **No volumetric clouds, Sky3D's own sky instead.** There is no GPU device (a headless run; the
  volumetric sky needs the Forward+ renderer), or the noise could not be made. Look for a `[clouds]`
  warning in the output.
- **The sky changes slowly after a slider move.** That is the easing; call `model.reprime()`.
- **The clouds look grey and flat in the distance.** Sky3D's fog is thick; lower its density
  (`sky3d.sky.fog_density`).

## The files

| File | Job |
|---|---|
| `cloud_weather.gd` | weather to cloud state (the rules above) |
| `cloud_model.gd`, `cloud_clock.gd` | easing and drift |
| `cloud_storms.gd` | picks the storm cells |
| `cloud_bridge.gd` | the node that runs it all and switches the sky shader |
| `cloud_uniforms.gd`, `cloud_globals.gd` | the shader globals |
| `cloud_temporal*.gd` | the compute pass |
| `cloud_partition.gd` | which pass draws which pixel |
| `cloud_shadow_receiver.gd`, `cloud_shadow_window.gd` | shadows on the ground and for water |
| `cloud_flash.gd` | lightning lighting a cloud from inside |
| `cloud_bake.gd`, `cloud_assets.gd`, `baked/` | the noise, generated on the GPU at start (only the blue noise is a file) |
| `cloud_quality.gd` | the tier table |
| `shaders/` | the field, its march, the lighting, the flight pass and the shadow bakes |

The techniques build on Schneider's Horizon Zero Dawn and Nubis talks, and on Hillaire's cloud
lighting. The cloud shadow technique is credited to Dropside, of the Terrain3D community.
