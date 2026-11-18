class_name CloudPartition
extends RefCounted
## Which pass composites the volumetric clouds for a pixel.
##
## The sky pass runs only on SKY pixels (no geometry) and can only draw BEHIND
## geometry — the transparent ocean included, which hid the whole deck below
## anyone above the cloud base. So once the flight pass (a depth-aware
## fullscreen quad, cloud_flight.gdshader) exists, it owns every geometry pixel
## and every downward (mu < 0) sky pixel; the sky keeps mu >= 0. Without it
## (LOW tier, planet sandbox, editor) the sky composites every direction.
##
## LOCKSTEP: planet_sky_body.gdshaderinc (sky_composites) and cloud_flight.gdshader
## (flight_claims) carry this rule; test_cloud_partition checks both sources.

enum Owner { NONE, SKY, FLIGHT }
## cloud_flags bit: the flight pass is live.
const FLAG_FLIGHT := 1


static func owner(is_sky_pixel: bool, mu: float, flight_on: bool) -> int:
	if is_sky_pixel and sky_composites(mu, flags(flight_on)):
		return Owner.SKY
	if flight_claims(is_sky_pixel, mu, flight_on):
		return Owner.FLIGHT
	return Owner.NONE


static func flags(flight_on: bool) -> int:
	return FLAG_FLIGHT if flight_on else 0


## How far below the split the half-res sky march still runs (sin of the angle,
## pushed as cloud_fade.w): the full-res composite upsamples it bilinearly, so the
## texels next to mu = 0 need valid data from both sides.
const SPLIT_MARGIN := 0.02


## The sky pass's view (it only runs on sky pixels). The radiance cubemap keeps
## every direction: no flight quad renders into it, so without this an aircraft
## above a deck got dark sea ambient and reflections from below.
static func sky_composites(mu: float, cloud_flags: int, radiance := false) -> bool:
	return radiance or (cloud_flags & FLAG_FLIGHT) == 0 or mu >= 0.0


## Which directions the half-res pass marches: what the sky composites, plus the
## upsample margin. Below it the flight pass owns the pixels; marching them was
## ~2 ms thrown away looking down from above a deck.
static func sky_marches(mu: float, cloud_flags: int, radiance := false) -> bool:
	return radiance or (cloud_flags & FLAG_FLIGHT) == 0 or mu >= -SPLIT_MARGIN


## The flight pass's view (it runs on every pixel).
static func flight_claims(is_sky_pixel: bool, mu: float, flight_on: bool) -> bool:
	return flight_on and not (is_sky_pixel and mu >= 0.0)
