// The weather colour filter as MATERIAL uniforms, for shaders the editor binds
// too (the sky, the cloud flight quad), where a runtime global would not exist
// yet. WeatherLookDriver pushes them on the sky material; CloudBridge mirrors them
// to the flight quad (MIRRORED_SKY_UNIFORMS). Identity defaults: upstream look.
// weather_grade() is LOCKSTEP with weather_look.gdshaderinc, AtmFog.gdshader and
// WeatherLook.apply_filter().

// (saturation mult, value mult, 0, strength)
uniform vec4 weather_filter = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec4 weather_tint : source_color = vec4(1.0);

vec3 weather_grade(vec3 c) {
	float l = dot(c, vec3(0.2126, 0.7152, 0.0722));
	return mix(vec3(l), c, weather_filter.x) * weather_filter.y * weather_tint.rgb;
}
