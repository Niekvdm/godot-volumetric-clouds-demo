# Volumetric Clouds Demo (Godot 4 + Sky3D)

Volumetric clouds and a physical atmosphere for Godot 4, on top of an unmodified Sky3D. A procedural,
weather-typed cloud field (cumulus, storm cells with anvils, a mid-level layer, cirrus) is ray-marched
in the sky shader. Where clouds stand in front of geometry, a full-resolution flight pass draws them,
so you can fly into and above the deck. A compute temporal pass traces a quarter of the half-res
pixels each frame and reprojects the rest. The clouds cast shadows on the ground, and `CloudFlash`
lights a cloud from inside for a lightning strike (the demo starts none). The drift comes from a
deterministic clock, so every multiplayer peer that shares the clock sees the same sky.

The sky they are lit by is a physical atmosphere (Hillaire's transmittance, multiple-scattering and
sky-view tables, baked on the GPU), which takes over Sky3D's scatter, its fog and the sun's colour
while it is on.

The demo switches between these and Sky3D exactly as it ships, its own 2D clouds included, so the
two can be compared in the same scene.

Two short guides explain how it works and what to tune: [the clouds](docs/clouds.md) and
[the atmosphere](docs/atmosphere.md).

This is the HIGH cloud tier of a Godot 4 driving sandbox, lifted out to run on its own. It is an
AI-assisted project, built with Claude (Anthropic); see [AI assistance](#ai-assistance).

## Running it

Sky3D is not committed here: fetch it from upstream first (Python 3, no git needed):

    python3 tools/fetch_sky3d.py

It downloads Sky3D v2.1.0 from [TokisanGames/Sky3D](https://github.com/TokisanGames/Sky3D) and places its
`addons/sky_3d` folder in this project.

Open the folder in Godot 4.8 (Forward+, Vulkan) and run the main scene, `demo/demo.tscn`. It was
built and checked on a Godot 4.8 beta build; earlier 4.x versions have not been tried. On the first
open, let the editor finish importing. The noise volumes and the atmosphere's tables are generated
on the GPU at start.

| Input | Does |
|---|---|
| Right mouse button (hold) | look around |
| W A S D | move |
| Q / E | down / up |
| Shift | 5x faster |
| Mouse wheel | flying speed |
| F1 | hide the panel |

The panel's **Clouds** choice is the comparison: *Volumetric (HIGH)* draws the volumetric clouds
over the physical atmosphere; *Sky3D default* is stock Sky3D, with its 2D clouds, its scatter and
its fog. *Physical atmosphere* turns the atmosphere off under the volumetric clouds, leaving
Sky3D's scatter and fog, and *Clear-day haze* sets how hazy its air is.

The rest of the panel sets:
- **Weather:** cover, rain, storm energy, wind, temperature and dew point.
- **Time and light:** time of day, the clock, exposure, sun, and Sky3D's fog.
- **Volumetric passes:** each one on or off (flight pass, temporal pass, ground shadows, storm
  cells, mid-level layer, cirrus, close-up erosion).
- **Look and cost:** density, key light gain, ambient, light samples, march steps and pixels traced
  per frame.
- **Camera presets:** the ground, the cloud base, above the deck and the hill.

`-- --shot out.png [--hour H] [--cover C] [--rain R] [--storm S] [--pos x,y,z] [--look yaw,pitch]
[--tier high|off] [--atmosphere on|off] [--bridge <CloudBridge property>=<value>]
[--sky <Sky3D property>=<value>] [--panel]` renders one frame and quits, for checking a change
without clicking.

## Using it in your own project

Copy these folders, plus Sky3D (`addons/sky_3d`, or your own copy of Sky3D 2.1):
- `src/sky/`: the clouds, the volumetric sky shader and the physical atmosphere.
- `src/weather/`: the weather fields and three small helpers. One of them is `WindProfile`, which
  turns the surface wind into the wind at the clouds' steering level (about 1,200 m), and that wind
  drifts the field.
- `src/post_fx/`.

Then do what `demo/cloud_demo.gd` does:

```gdscript
CloudGlobals.ensure()          # the shaders' global uniforms, before the first sky shader compiles
AtmosphereGlobals.ensure()
# ... add the Sky3D node, then the atmosphere as a child of its dome:
var atmosphere := SkyAtmosphere.new()
atmosphere.name = "SkyAtmosphere"
atmosphere.dome = sky3d.sky
sky3d.sky.add_child(atmosphere)

var model := CloudModel.new()
var bridge := CloudBridge.new()
bridge.weather = weather       # a WeatherFields: cloud_cover, precip, storm_energy, wind, dew_point
add_child(bridge)
bridge.bind(sky3d, model)      # after the Sky3D node is ready

func _process(delta):
	model.tick(delta, weather, sky3d.current_time, air_temp_c)
```

`CloudQuality` (`src/sky/clouds/cloud_quality.gd`) holds the tier table: `high`, and `off` for
Sky3D's own sky. For multiplayer, sync `model.clock` (`CloudClock.to_dict()` / `apply_remote()`)
from the host. Every peer then grows the same field from the same weather.

The look was tuned with three Sky3D / environment settings the demo sets, which differ from the
defaults:
- **Sky radiance:** `environment.sky.radiance_size = Sky.RADIANCE_SIZE_1024`. The ground's ambient
  is filtered from it; at Godot's default of 256 the ground reads darker.
- **Fog falloff:** `sky3d.sky.fog_falloff = 2.0` (Sky3D ships 3.0).
- **Ambient fade:** `sky3d.contribution_tween_time = 0` before the node enters the tree, restored
  after a few seconds. Sky3D 2.1 otherwise fades the ambient in for 3 s after load.

Keep the environment's fog aerial perspective at 1, its sun scatter at 0, volumetric fog's sky
affect at 0 and the sky unrotated. The half-res cloud buffer is encoded around those values, and
`CloudBridge` warns when the environment breaks them.

## What is in here

- `src/sky/clouds/`, three groups of classes:
  - the cloud model and weather mapping: `CloudModel`, `CloudWeather`, `CloudClock`, `CloudStorms`;
  - the render glue and passes: `CloudBridge`, `CloudUniforms`, `CloudGlobals`, the temporal pass
    `CloudTemporal`, the ground shadows `CloudShadowReceiver`, `CloudShadowWindow` for a water
    shader, and the lightning light `CloudFlash`;
  - the noise generation (`CloudBake`, `CloudAssets`) and the shaders.

  Only the manifest and a 16 KB blue-noise file are committed; every noise volume is generated at
  start.
- `src/sky/shaders/`: the volumetric sky shader the clouds are marched in.
- `src/sky/atmosphere/`: the physical atmosphere (`SkyAtmosphere`). It attaches to Sky3D's dome from
  outside and needs no change to Sky3D.
- `addons/sky_3d/`: Sky3D v2.1.0 as released, unmodified, fetched by `tools/fetch_sky3d.py` (not committed).
- `tools/fetch_sky3d.py`: fetches Sky3D from upstream.
- `docs/`: the guides to [the clouds](docs/clouds.md) and [the atmosphere](docs/atmosphere.md).

The density and lighting build on published work: Schneider, "The Real-time Volumetric
Cloudscapes of Horizon Zero Dawn" (SIGGRAPH 2015) and the Nubis talks (2017, 2023); Hillaire,
"Physically Based Sky, Atmosphere and Cloud Rendering in Frostbite" (2016) and "A Scalable and
Production Ready Sky and Atmosphere Rendering Technique" (2020). The cloud shadow technique is
credited to Dropside, of the Terrain3D community.

## Known limits

- The volumetric sky needs the Forward+ renderer (checked on Vulkan). Without a GPU device (headless)
  the bridge keeps Sky3D's own sky.
- The physical atmosphere is on only under the volumetric clouds: Sky3D's stock sky shader cannot
  read its tables, so *Sky3D default* is Sky3D's own sky throughout.
- The tier is tuned for a ground-level view of a large world. The demo's flat 400 km plane stands in
  for terrain.

## AI assistance

This project was built with AI assistance: the clouds, the sky they are marched in and this demo
were developed with Claude (Anthropic), directed, reviewed and tested by the developer.

## License

MIT, see `LICENSE`. Sky3D keeps its own MIT licence in `addons/sky_3d/`.
