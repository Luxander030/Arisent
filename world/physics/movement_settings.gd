## Player movement constants, modelled on Counter-Strike (Source engine). Values are kept
## in Source units ("u", 1 u = 1 inch = 0.0254 m) so they can be compared with Valve's
## numbers directly; the controller converts with U. Presets: CS:GO (default), CS:S, CS 1.6.
## Sources: Source SDK 2013 gamemovement.cpp / movevars_shared.cpp, HL1 pm_shared.c,
## community references (see docs/world-editor/ARCHITECTURE.md §13).
class_name MovementSettings
extends RefCounted

const U := 0.0254  ## metres per Source unit

var gravity := 800.0            ## sv_gravity (u/s²)
var friction := 5.2             ## sv_friction
var stop_speed := 80.0          ## sv_stopspeed (u/s): below this, friction is a constant deceleration
var accelerate := 5.5           ## sv_accelerate
var air_accelerate := 12.0      ## sv_airaccelerate
var air_speed_cap := 30.0       ## wishspeed cap used in AirAccelerate (makes air strafing work)
var max_speed := 250.0          ## run speed (knife / unarmed)
var walk_scale := 0.52          ## shift-walk
var duck_scale := 0.34          ## crouch-walk
var jump_impulse := 301.993377  ## sqrt(2 * 800 * 57): 57 u high jump
var step_size := 18.0
var max_velocity := 3500.0      ## sv_maxvelocity (per axis)
var non_jump_velocity := 140.0  ## upward speed above which you count as airborne
var walkable_normal := 0.7      ## floor if normal.y >= this (≈45.57°)
var hull_radius := 16.0         ## 32 u wide
var hull_height := 72.0
var duck_height := 54.0
var eye_height := 64.0
var duck_eye_height := 46.0
var duck_time := 0.16           ## seconds to fully crouch
var unduck_time := 0.125

## Bunny hopping: CS:GO competitive caps horizontal speed to 1.1 × max on each jump and
## requires re-pressing jump; set these to allow classic uncapped bhop.
var bunnyhop_uncapped := false
var auto_bunnyhop := false

## CS:GO stamina: jumping and landing cost stamina, which slows you and lowers the next jump.
var stamina_max := 80.0
var stamina_jump_cost := 0.08   ## × jump impulse
var stamina_land_cost := 0.05   ## × fall speed
var stamina_recovery := 60.0    ## per second

## Fall damage: (fall speed - safe) * 100 / (fatal - safe), CS:GO.
var fall_safe_speed := 580.0
var fall_fatal_speed := 1000.0

## Water (Source WaterMove).
var water_sink_speed := 60.0
var water_speed_scale := 0.8
var water_jump_speed := 100.0

## Pushing physics props (Source physics shadow: 85 kg; pushaway only above 75 u/s).
var player_mass := 85.0
var push_min_speed := 75.0
var pushaway_radius := 40.0     ## u: clutter within this distance gets nudged
var pushaway_force := 900.0     ## u/s² of push at 1 u distance… falls off with distance

## Ladders (Source LadderMove).
var ladder_climb_speed := 200.0
var ladder_jump_off_speed := 200.0
var ladder_slow_scale := 0.34   ## crouching or walking on a ladder


static func preset(name: String) -> MovementSettings:
	var s := MovementSettings.new()
	match name:
		"CS:S":
			s.friction = 4.0
			s.stop_speed = 100.0
			s.accelerate = 10.0
			s.air_accelerate = 10.0
			s.max_speed = 250.0
			s.hull_height = 62.0
			s.duck_height = 45.0
			s.eye_height = 64.0
			s.duck_eye_height = 47.0
			s.duck_time = 0.4
			s.unduck_time = 0.2
			s.stamina_max = 0.0
			s.fall_fatal_speed = 1100.0
		"CS 1.6":
			s.friction = 4.0
			s.stop_speed = 75.0
			s.accelerate = 5.0
			s.air_accelerate = 10.0
			s.jump_impulse = sqrt(2.0 * 800.0 * 45.0)
			s.duck_height = 36.0
			s.eye_height = 53.0
			s.duck_eye_height = 30.0
			s.duck_scale = 0.333
			s.duck_time = 0.4
			s.unduck_time = 0.4
			s.max_velocity = 2000.0
			s.stamina_max = 0.0
			s.fall_fatal_speed = 1024.0
	return s


func m(units: float) -> float:
	return units * U
