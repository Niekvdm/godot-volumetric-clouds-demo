# The physical atmosphere

A guide to the sky the volumetric clouds are lit by. The code lives in `src/sky/atmosphere/`.

## What it does

Sky3D colours its sky with an artistic model, and its fog is a separate effect on top.
`SkyAtmosphere` swaps both for one physical model of the air, after Hillaire's 2020 paper "A
Scalable and Production Ready Sky and Atmosphere Rendering Technique". The same air then decides:
- the colour of the sky;
- the haze over distant hills;
- the colour and strength of the sunlight;
- the light the clouds are lit by.

A low sun turns red and dim because the air in front of it is long, not because a curve says so.

Sky3D still runs the clock, the sun and moon discs, the stars and the lights. Turn the atmosphere
off (`enabled = false`) and Sky3D's own sky and fog come back unchanged.

## How it works

The atmosphere bakes a few small lookup tables on the GPU:

| Table | Size | Holds |
|---|---|---|
| transmittance | 256 × 64 | how much light gets through the air, along any ray |
| multiple scattering | 32 × 32 | the light that bounces more than once in the air |
| sky-view | 256 × 128 | the whole sky's colour as seen from the camera |
| aerial perspective | 64 × 32 × 32 | the haze between the camera and anything in view |
| sky ambient | | the light the sky sends to the ground |

The sky shader, the clouds and two fog passes read these tables as global shader parameters.

It rebakes only when something has visibly moved: the sun by 0.03°, the camera's altitude by a few
percent, or the haze by 1%. A still scene costs nothing extra.

## Setting it up

It needs no change to Sky3D. Add it as a child of Sky3D's dome once the Sky3D node is in the tree:

```gdscript
AtmosphereGlobals.ensure()     # its shader globals, before the first sky shader compiles
var atmosphere := SkyAtmosphere.new()
atmosphere.name = "SkyAtmosphere"
atmosphere.dome = sky3d.sky
sky3d.sky.add_child(atmosphere)
```

The clouds' bridge finds it by that node name, so keep the name.

Let it know about the weather each frame (or when the weather changes):

```gdscript
# haze_mult: 1 = a clear day, up to 3 in heavy rain or fog
# closed:    0 = open sky, 1 = a closed overcast deck
atmosphere.set_weather(haze_mult, closed)
```

The demo feeds it as follows:
- **haze_mult** rises with heavy rain: `1 + 2 × 0.35 × rain^2.2`.
- **closed** eases from 0 to 1 as the cover goes from 0.25 to 0.98.

Under a closed deck, the sky's scattered light turns grey and dim.

## The settings

| Setting | Default | What it does |
|---|---|---|
| `enabled` | true | The switch. Off brings back Sky3D's sky and fog. |
| `base_haze` | 3.5 | The haze of a clear day, as a multiple of Hillaire's clear-air aerosol (1). 5 is about 70 km visibility at sea level. The default suits humid, maritime air. |
| `sky_gain` | 2.3 | The sky's brightness against the sun's. It keeps the ambient light where Sky3D's sky put it. |
| `sun_disc_gain` | 600 | How bright the sun's disc is. |
| `aureole` | true | The bright glow just round the sun (a narrow peak on a broad lobe). Off, one broad lobe. |
| `moon_sky_ratio` | 0.02 | The moonlit sky's brightness against daylight. The real ratio is far smaller; this keeps a night readable. |
| `night_sky` | dark blue | The night sky's own faint light (airglow, starlight). |
| `town_glow_level`, `town_glow` | 0, warm orange | City lights glowing in the haze low over the horizon at night. 0 is off. |
| `adapt_pow`, `adapt_pow_dusk`, `adapt_knee`, `adapt_max` | 0.35, 0.6, 0.05, 40 | The eye's adaptation (below). `adapt_pow` 0 turns it off. |
| `ap_single_pass` | 2 | How the haze is drawn: 0 = two passes (FSR2-safe), 1 = one pass, 2 = one pass unless FSR2 is on. |
| `sun_step_deg`, `alt_step_m` | 0.03, 5 | How far the sun or the camera must move before it rebakes. |

## The eye's adaptation

Real daylight falls by many times from noon to dusk, but a game camera's exposure barely moves.
Lit purely physically, golden hour would go dark and the twilight sky black.

So the atmosphere scales the sun and the sky together by `(noon light / light now)^adapt_pow`,
capped at `adapt_max`. The sky-to-sun balance stays physical, and the scene still gets darker as the
sun goes down, just less than raw physics says. Below `adapt_knee` (the sun a degree or two up) it
adapts harder, so the blue hour stays readable. Moonlight isn't adapted.

## With the clouds

- **The clouds' sunlight** comes from the atmosphere's tables: sunlight at about 2,000 m, the
  height they sit at, so cloud tops redden at sunset by the real air path.
- **Haze in front of a cloud** is applied at the cloud's distance, not at whatever lies behind it.
  Without this, a cloud in front of the far horizon got that horizon's thick haze, and a hard line
  showed across the clouds. Sky3D's stock fog doesn't do this.
- **In the demo's *Sky3D default* mode** the atmosphere is off. Sky3D's stock sky shader can't read
  its tables, so that mode is Sky3D throughout.

## Multiplayer

Every input is shared or local only:
- the sun and moon come from the synced clock;
- the haze and the deck come from the synced weather;
- the camera's altitude is each player's own, and only changes the view.

## Limits

- It runs at runtime only. The editor's viewport keeps Sky3D's own sky.
- It needs a GPU device. Without one (a headless run) it never turns on. If a bake fails it prints
  a `[SkyAtmosphere]` warning and Sky3D's sky stays.

## The files

| File | Job |
|---|---|
| `sky_atmosphere.gd` | the node: bakes the tables, publishes them, takes over the fog quad and the sun's colour |
| `atmosphere_model.gd` | the physics constants and CPU-side maths (the sun's light, the phase functions) |
| `atmosphere_bake_glsl.gd` | the compute shaders that bake the tables |
| `atmosphere_globals.gd` | the global shader parameters |
| `atmosphere.gdshaderinc`, `atmosphere_math.gdshaderinc` | what the sky, the clouds and the fog read |
| `atmosphere_ap*.gdshader`, `atmosphere_ap.gdshaderinc` | the haze passes over the scene |
