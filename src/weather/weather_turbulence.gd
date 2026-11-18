class_name WeatherTurbulence
extends RefCounted
## DETERMINISTIC smooth turbulence in [0,1], a function of the shared game clock
## (so MP peers gust identically with no sync). `speed` bends the octave freqs so
## a slow clock (clouds aloft) gusts lazily and a fast clock (ground) churns.
## Shared by WeatherManager's surface gusts and CloudModel's steering wind.
static func turb(t: float, speed: float = 1.0) -> float:
	# Three incommensurate octaves — a single sine-product is visibly periodic, so
	# layer a mid + fine octave to break the repeat and add the sharp lulls/surges
	# real gusts have. Centered on 0.5.
	var n := 0.5 + 0.30 * sin(t * 1.7 * speed) * sin(t * 0.53 * speed + 1.3)
	n += 0.14 * sin(t * 4.1 * speed + 0.7)
	n += 0.06 * sin(t * 9.3 * speed + 2.1)
	return clampf(n, 0.0, 1.0)
