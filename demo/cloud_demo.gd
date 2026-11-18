extends Node3D
## The volumetric clouds' standalone demo: Sky3D, the HIGH cloud tier and nothing else.
##
## This node is what a game's weather system would be. It owns the weather (a WeatherFields), ticks
## the CloudModel with it every frame and binds a CloudBridge to the Sky3D node, which swaps the
## sky material to the volumetric sky and runs the flight pass, the temporal pass and the cloud
## shadows. The ground and the props are only there to show the shadows and the clouds in front
## of geometry.
##
## Fly: right mouse button to look, WASD to move, Q / E down / up, Shift faster, mouse wheel speed.
## F1 hides the panel.

## The sea surface's air temperature (deg C). The cloud base rises with the spread to the dew point.
var air_temp_c := 24.0
## Air temperature minus dew point (deg C): about 125 m of cloud base per degree.
var dew_spread_c := 4.0

var weather := WeatherFields.new()
## The model eases its state toward the weather over minutes, the way a real sky turns over. On, a slider
## change lands at once (CloudModel.reprime); off, it eases in.
var snap_weather := true
var model: CloudModel
var bridge: CloudBridge
var sky3d: Sky3D
## The physical atmosphere (Hillaire's LUTs) the volumetric clouds are lit by: a child of Sky3D's dome.
var atmosphere: SkyAtmosphere
var cam: Camera3D

var _yaw := 0.0
var _pitch := 0.08
var _speed := 60.0
var _looking := false
var _ui: Control
var _status: Label


func _ready() -> void:
	# The shaders' global uniforms must exist before the first sky shader compiles.
	CloudGlobals.ensure()
	AtmosphereGlobals.ensure()

	sky3d = Sky3D.new()
	sky3d.name = "Sky3D"
	# Sky3D v2.1 fades the ambient's sky share in over contribution_tween_time from the moment it enters
	# the tree; instant here, so the first seconds are not darker than the rest. Back to its value once
	# the scene has settled.
	var tween_s := sky3d.contribution_tween_time
	sky3d.contribution_tween_time = 0.0
	add_child(sky3d)
	# The time aliases forward to TimeOfDay, which Sky3D only builds once it is in the tree: a value
	# set before add_child() is dropped.
	sky3d.game_time_enabled = false
	sky3d.minutes_per_day = 30.0
	sky3d.current_time = 10.5
	get_tree().create_timer(5.0).timeout.connect(func() -> void: sky3d.contribution_tween_time = tween_s)
	# Sky3D's distance fog: its default density (0.0007 /m) hides a third of the ground 600 m off; lighter
	# here so the cloud shadows read across the landscape (the panel has the full range).
	if sky3d.sky != null:
		sky3d.sky.fog_density = 0.00015
		# The height falloff the clouds and the atmosphere were tuned with (Sky3D v2.1 ships 3.0).
		sky3d.sky.fog_falloff = 2.0
		# Next to the stock SkyDome: it bakes its tables on the GPU and takes over the sky's scatter, the fog
		# quad and the sun's colour while enabled; disabled, Sky3D's own come back.
		atmosphere = SkyAtmosphere.new()
		atmosphere.name = "SkyAtmosphere"
		atmosphere.dome = sky3d.sky
		sky3d.sky.add_child(atmosphere)
	_author_environment()

	_build_ground()
	cam = Camera3D.new()
	cam.name = "Camera"
	cam.far = 250000.0
	cam.near = 0.2
	cam.fov = 70.0
	add_child(cam)
	cam.position = Vector3(0.0, 4.0, 0.0)
	cam.make_current()

	weather.cloud_cover = 0.45
	weather.precip = 0.0
	weather.storm_energy = 0.0
	weather.wind_dir = Vector2(1.0, 0.3).normalized()
	weather.wind_speed = 6.0
	_update_dew_point()

	model = CloudModel.new()
	bridge = CloudBridge.new()
	bridge.name = "CloudBridge"
	bridge.weather = weather
	add_child(bridge)
	# Sky3D builds its environment, lights and SkyDome in its own _ready: bind after it.
	_bind.call_deferred()

	_build_ui()


func _bind() -> void:
	bridge.bind(sky3d, model)
	_shot_from_args()


## `-- --shot <file.png> [--frames N] [--hour H] [--cover C] [--rain R] [--storm S] [--pos x,y,z] [--look yaw,pitch]
## [--tier high|off] [--bridge <CloudBridge property>=<value>] [--panel]`: saves one
## frame after N drawn frames (default 240) and quits. For checking a change without opening the demo.
func _shot_from_args() -> void:
	var a := OS.get_cmdline_user_args()
	var path := ""
	var frames := 240
	for i in a.size() - 1:
		match a[i]:
			"--shot": path = a[i + 1]
			"--frames": frames = int(a[i + 1])
			"--hour": sky3d.current_time = float(a[i + 1])
			"--cover": weather.cloud_cover = float(a[i + 1])
			"--rain": weather.precip = float(a[i + 1])
			"--storm": weather.storm_energy = float(a[i + 1])
			"--sky":
				var kv := a[i + 1].split("=")
				sky3d.set(kv[0], kv[1] == "true" if kv[1] in ["true", "false"] else float(kv[1]))
			"--bridge":
				var kv := a[i + 1].split("=")
				bridge.set(kv[0], float(kv[1]) if kv[1].is_valid_float() else kv[1])
			"--tier":
				_set_cloud_mode(a[i + 1] != "off")
			"--atmosphere":
				_atmosphere_wanted = a[i + 1] != "off"
				_sync_atmosphere()
			"--pos":
				var p := a[i + 1].split(",")
				cam.position = Vector3(float(p[0]), float(p[1]), float(p[2]))
			"--look":
				var l := a[i + 1].split(",")
				_yaw = deg_to_rad(float(l[0]))
				_pitch = deg_to_rad(float(l[1]))
	model.reprime()
	if path == "":
		return
	_ui.visible = "--panel" in a
	for f in frames:
		await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	var _sn := sky3d.sun
	print("[shot] %s mode=%d base=%.0f hour=%.2f cover=%.2f flight=%s ground_shadow=%s" % [path, bridge.get_mode(),
			model.state.base_m, sky3d.current_time, model.state.cover, bridge.get("_flight") != null,
			bridge.get_ground_shadow() != null])
	get_tree().quit()


func _process(delta: float) -> void:
	model.tick(delta, weather, sky3d.current_time, air_temp_c)
	if atmosphere != null:
		# The weather's share of the air: heavy rain hazes the distance (up to 3x the clear-day aerosol,
		# low-end compressed so light rain barely shows), and a closing deck greys and dims the light the
		# sky scatters under it (open below cover 0.25, closed at 0.98).
		var rain_haze := pow(clampf(weather.precip, 0.0, 1.0), 2.2) * 0.35
		atmosphere.set_weather(1.0 + 2.0 * rain_haze, smoothstep(0.25, 0.98, weather.cloud_cover))
	bridge.ground_y = 0.0
	_fly(delta)
	if _status != null:
		var mode_name: String = ["Sky3D default clouds", "Volumetric clouds", "No clouds"][clampi(bridge.get_mode(), 0, 2)]
		_status.text = "%d fps   %s   cloud base %.0f m   eye %.0f m   %02d:%02d" % [
			Engine.get_frames_per_second(), mode_name, model.state.base_m, cam.position.y,
			int(sky3d.current_time), int(fmod(sky3d.current_time, 1.0) * 60.0)]


# --- The scene ---------------------------------------------------------------------------------

func _author_environment() -> void:
	var env := sky3d.environment
	if env == null:
		return
	# The sky's radiance map at 1024 (Godot's default is 256): the ambient the ground takes from the sky
	# is filtered from it, and the clouds' look was tuned at this size.
	if env.sky != null:
		env.sky.radiance_size = Sky.RADIANCE_SIZE_1024
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_white = 6.0
	env.glow_enabled = true
	env.glow_hdr_threshold = 2.0
	env.glow_hdr_scale = 0.5
	env.ssao_enabled = true
	# The half-res cloud encoding needs these (CloudBridge.invariant_problems warns otherwise).
	env.fog_enabled = false
	env.volumetric_fog_enabled = false
	env.background_energy_multiplier = 1.0
	env.sky_rotation = Vector3.ZERO


func _build_ground() -> void:
	var ground := MeshInstance3D.new()
	ground.name = "Ground"
	var plane := PlaneMesh.new()
	plane.size = Vector2(400000.0, 400000.0)
	plane.subdivide_width = 8
	plane.subdivide_depth = 8
	ground.mesh = plane
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.32, 0.38, 0.22)
	gm.roughness = 0.95
	ground.material_override = gm
	add_child(ground)

	# Tall props: the clouds in front of geometry (the flight pass) and their shadows on the ground.
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var pm := StandardMaterial3D.new()
	pm.albedo_color = Color(0.72, 0.70, 0.66)
	pm.roughness = 0.8
	for i in 40:
		var b := MeshInstance3D.new()
		var box := BoxMesh.new()
		var h := rng.randf_range(20.0, 180.0)
		box.size = Vector3(rng.randf_range(15.0, 40.0), h, rng.randf_range(15.0, 40.0))
		b.mesh = box
		b.material_override = pm
		var a := rng.randf() * TAU
		var r := rng.randf_range(120.0, 2500.0)
		b.position = Vector3(cos(a) * r, h * 0.5, sin(a) * r)
		add_child(b)

	# A hill that reaches the cloud base: the slope veil where cloud meets terrain.
	var hill := MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 60.0
	cone.bottom_radius = 2600.0
	cone.height = 900.0
	cone.radial_segments = 64
	hill.mesh = cone
	hill.material_override = gm
	hill.position = Vector3(-4200.0, 450.0, -5200.0)
	add_child(hill)


# --- Camera ------------------------------------------------------------------------------------

func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			_looking = mb.pressed
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if _looking else Input.MOUSE_MODE_VISIBLE
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_speed = minf(_speed * 1.25, 4000.0)
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_speed = maxf(_speed / 1.25, 2.0)
	elif e is InputEventMouseMotion and _looking:
		var mm := e as InputEventMouseMotion
		_yaw -= mm.relative.x * 0.003
		_pitch = clampf(_pitch - mm.relative.y * 0.003, -1.5, 1.5)
	elif e is InputEventKey and e.pressed and not e.echo and (e as InputEventKey).keycode == KEY_F1:
		_ui.visible = not _ui.visible


func _fly(delta: float) -> void:
	cam.basis = Basis.from_euler(Vector3(_pitch, _yaw, 0.0))
	var v := Vector3.ZERO
	if Input.is_key_pressed(KEY_W): v -= cam.basis.z
	if Input.is_key_pressed(KEY_S): v += cam.basis.z
	if Input.is_key_pressed(KEY_A): v -= cam.basis.x
	if Input.is_key_pressed(KEY_D): v += cam.basis.x
	if Input.is_key_pressed(KEY_E): v += Vector3.UP
	if Input.is_key_pressed(KEY_Q): v -= Vector3.UP
	var s := _speed * (5.0 if Input.is_key_pressed(KEY_SHIFT) else 1.0)
	cam.position += v.normalized() * s * delta if v != Vector3.ZERO else Vector3.ZERO
	cam.position.y = maxf(cam.position.y, 1.5)


# --- Panel -------------------------------------------------------------------------------------

const PANEL_BG := Color(0.06, 0.07, 0.09, 0.82)
const HEADER_COLOR := Color(0.62, 0.78, 1.0)
const DIM := Color(1, 1, 1, 0.6)

## The march's look and cost keys (CloudBridge.temporal_tuning: they reach every march).
var _tuning := {}


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var panel := PanelContainer.new()
	panel.position = Vector2(12, 12)
	var sb := StyleBoxFlat.new()
	sb.bg_color = PANEL_BG
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(10)
	panel.add_theme_stylebox_override("panel", sb)
	layer.add_child(panel)
	_ui = panel
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(340, minf(get_viewport().get_visible_rect().size.y - 44.0, 860.0))
	panel.add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 3)
	scroll.add_child(box)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD
	box.add_child(_status)

	_header(box, "Weather")
	_slider(box, "Cloud cover", 0.0, 1.0, weather.cloud_cover, func(v: float) -> void: weather.cloud_cover = v, true)
	_slider(box, "Rain", 0.0, 1.0, weather.precip, func(v: float) -> void: weather.precip = v, true)
	_slider(box, "Storm energy", 0.0, 1.0, weather.storm_energy, func(v: float) -> void: weather.storm_energy = v, true)
	_slider(box, "Wind (m/s)", 0.0, 25.0, weather.wind_speed, func(v: float) -> void: weather.wind_speed = v, true)
	_slider(box, "Wind from (deg)", 0.0, 360.0, rad_to_deg(weather.wind_dir.angle()) + 180.0,
			func(v: float) -> void: weather.wind_dir = Vector2.from_angle(deg_to_rad(v - 180.0)), true)
	_slider(box, "Air temp (C)", -5.0, 35.0, air_temp_c, func(v: float) -> void:
			air_temp_c = v
			_update_dew_point(), true)
	_slider(box, "Dew spread (C)", 0.0, 15.0, dew_spread_c, func(v: float) -> void:
			dew_spread_c = v
			_update_dew_point(), true)
	_toggle(box, "Snap weather changes", snap_weather, func(on: bool) -> void: snap_weather = on)

	_header(box, "Time and light")
	_slider(box, "Time of day", 0.0, 23.99, sky3d.current_time, func(v: float) -> void: sky3d.current_time = v)
	_toggle(box, "Run the clock", sky3d.game_time_enabled, func(on: bool) -> void: sky3d.game_time_enabled = on)
	_slider(box, "Day length (min)", 1.0, 120.0, sky3d.minutes_per_day,
			func(v: float) -> void: sky3d.minutes_per_day = v)
	_atmo_toggle = _toggle(box, "Physical atmosphere (volumetric only)", true, func(on: bool) -> void:
			_atmosphere_wanted = on
			_sync_atmosphere())
	if atmosphere != null:
		_slider(box, "Clear-day haze", 0.5, 8.0, atmosphere.base_haze, func(v: float) -> void: atmosphere.base_haze = v)
	_slider(box, "Exposure", 0.2, 3.0, sky3d.tonemap_exposure, func(v: float) -> void: sky3d.tonemap_exposure = v)
	_slider(box, "Sun energy", 0.0, 3.0, sky3d.sun_energy, func(v: float) -> void: sky3d.sun_energy = v)
	_toggle(box, "Sky3D fog", sky3d.fog_enabled, func(on: bool) -> void: sky3d.fog_enabled = on)
	_slider(box, "Fog density (1e-4/m)", 0.0, 20.0, sky3d.sky.fog_density * 1e4 if sky3d.sky != null else 1.5,
			func(v: float) -> void:
				if sky3d.sky != null:
					sky3d.sky.fog_density = v * 1e-4)

	_header(box, "Clouds")
	_option(box, "Clouds", ["Volumetric (HIGH)", "Sky3D default"], 0, func(i: int) -> void:
			_set_cloud_mode(i == 0))
	var note := Label.new()
	note.text = "The settings below apply to the volumetric clouds."
	note.add_theme_font_size_override("font_size", 11)
	note.modulate = DIM
	box.add_child(note)
	_toggle(box, "Clouds in front of geometry (flight pass)", true,
			func(on: bool) -> void: bridge.flight_override = 1 if on else 0)
	_toggle(box, "Temporal pass (off: full march per pixel)", true,
			func(on: bool) -> void: bridge.temporal_override = 1 if on else 0)
	_toggle(box, "Cloud shadows on the ground", true,
			func(on: bool) -> void: bridge.ground_shadow_override = 1 if on else 0)
	_toggle(box, "Storm cells", true, func(on: bool) -> void: bridge.storm_cells_off = 0.0 if on else 1.0)
	_toggle(box, "Mid-level layer", true, func(on: bool) -> void: _tune(&"pf_alto", 1.0 if on else 0.0))
	_toggle(box, "Cirrus", true, func(on: bool) -> void: _tune(&"pf_cirrus", 1.0 if on else 0.0))
	_toggle(box, "Close-up erosion octave", true, func(on: bool) -> void: _tune(&"pf_fine", 1.0 if on else 0.0))
	var t: Dictionary = CloudQuality.PARAMS[&"high"]
	_slider(box, "Density", 0.1, 1.5, float(t["pf_density_k"]), func(v: float) -> void: _tune(&"pf_density_k", v))
	_slider(box, "Key light gain", 0.2, 1.5, float(t["key_gain"]), func(v: float) -> void: bridge.key_gain_override = v)
	_slider(box, "Ambient to grey", 0.0, 0.6, float(t["amb_grey"]), func(v: float) -> void: bridge.amb_grey_override = v)
	_slider(box, "Light samples", 2.0, 10.0, float(t["pf_light"]), func(v: float) -> void: _tune(&"pf_light", roundf(v)),
			false, 1.0)
	_slider(box, "March steps", 40.0, 320.0, float(t["pf_max_steps"]),
			func(v: float) -> void: _tune(&"pf_max_steps", roundf(v)), false, 1.0)
	_option(box, "Traced per frame", ["1 in 4 pixels", "1 in 16 pixels", "every pixel"], 0, func(i: int) -> void:
			_tune(&"temporal_lattice", [2.0, 4.0, 1.0][i]))

	_header(box, "Camera")
	_slider(box, "Field of view", 30.0, 110.0, cam.fov, func(v: float) -> void: cam.fov = v)
	var presets := HFlowContainer.new()
	box.add_child(presets)
	for p: Array in [["Ground", Vector3(0, 4, 0), 0.0, 12.0], ["In the base", Vector3(0, 520, 0), 0.0, 2.0],
			["Above", Vector3(0, 2600, 0), 0.0, -18.0], ["Hill", Vector3(-1500, 40, -1500), 36.0, 4.0]]:
		var b := Button.new()
		b.text = p[0]
		b.pressed.connect(func() -> void:
				cam.position = p[1]
				_yaw = deg_to_rad(p[2])
				_pitch = deg_to_rad(p[3]))
		presets.add_child(b)

	var help := Label.new()
	help.text = "RMB look · WASD move · Q/E down/up · Shift fast · wheel speed · F1 panel"
	help.add_theme_font_size_override("font_size", 11)
	help.autowrap_mode = TextServer.AUTOWRAP_WORD
	help.modulate = DIM
	box.add_child(help)


func _tune(key: StringName, v: float) -> void:
	_tuning[key] = v
	bridge.temporal_tuning = _tuning.duplicate()


func _header(parent: Container, text: String) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", HEADER_COLOR)
	l.add_theme_font_size_override("font_size", 15)
	parent.add_child(HSeparator.new())
	parent.add_child(l)


func _toggle(parent: Container, text: String, on: bool, on_change: Callable) -> CheckBox:
	var c := CheckBox.new()
	c.text = text
	c.button_pressed = on
	c.toggled.connect(on_change)
	parent.add_child(c)
	return c


func _option(parent: Container, label: String, items: Array, selected: int, on_change: Callable) -> void:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = label
	l.custom_minimum_size = Vector2(120, 0)
	row.add_child(l)
	var o := OptionButton.new()
	for it: String in items:
		o.add_item(it)
	o.select(selected)
	o.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	o.item_selected.connect(on_change)
	row.add_child(o)
	parent.add_child(row)


## A labelled slider. `weather_change`: a weather field, landed at once when snap_weather is on.
func _slider(parent: Container, label: String, lo: float, hi: float, value: float, on_change: Callable,
		weather_change := false, step := -1.0) -> void:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = label
	l.custom_minimum_size = Vector2(120, 0)
	row.add_child(l)
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step if step > 0.0 else (hi - lo) / 500.0
	s.value = value
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.custom_minimum_size = Vector2(130, 0)
	var n := Label.new()
	n.custom_minimum_size = Vector2(48, 0)
	n.text = "%.2f" % value if step < 1.0 else "%d" % int(value)
	s.value_changed.connect(func(v: float) -> void:
			n.text = "%.2f" % v if step < 1.0 else "%d" % int(v)
			on_change.call(v)
			if weather_change and snap_weather:
				model.reprime())
	row.add_child(s)
	row.add_child(n)
	parent.add_child(row)


var _atmosphere_wanted := true
var _atmo_toggle: CheckBox


## The A/B: the volumetric clouds over the physical atmosphere, or Sky3D exactly as it ships (its 2D
## clouds, its scatter and its AtmFog). The atmosphere follows: Sky3D's stock sky shader cannot read it.
func _set_cloud_mode(volumetric: bool) -> void:
	CloudQuality.quality = &"high" if volumetric else &"off"
	bridge.reapply()
	_sync_atmosphere()
	if _atmo_toggle != null:
		_atmo_toggle.disabled = not volumetric


func _sync_atmosphere() -> void:
	if atmosphere != null:
		atmosphere.enabled = _atmosphere_wanted and CloudQuality.quality == &"high"


func _update_dew_point() -> void:
	weather.dew_point = air_temp_c - dew_spread_c
