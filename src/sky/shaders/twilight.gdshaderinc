// Shared by the sky and atmospheric fog so distant surfaces converge to the
// same twilight color. Input is sin(solar elevation), in the local sky frame.
vec4 sky_twilight_factors(float sun_up) {
	// Fade the sunset tint through civil twilight (~6 degrees below horizon).
	// The former 1-sun_up clamp kept the entire sky orange all night.
	float warmth = clamp(1.0 - sun_up, 0.0, 1.0)
			* smoothstep(-0.104528, 0.0, sun_up);
	// Retain daylight response above the horizon; smoothly extinguish solar
	// scattering by the end of astronomical twilight (~18 degrees below).
	float daylight = clamp(sun_up + 0.45, 0.0, 1.0)
			* smoothstep(-0.309017, 0.0, sun_up);
	// Stars emerge after sunset instead of appearing in the daytime sky.
	float stars = 1.0 - smoothstep(-0.207912, 0.0, sun_up);
	// Cloud illumination must lose the warm solar tint too, rather than
	// retaining orange cloud tops against a night sky.
	float night = 1.0 - smoothstep(-0.104528, 0.104528, sun_up);
	return vec4(warmth, daylight, stars, night);
}
