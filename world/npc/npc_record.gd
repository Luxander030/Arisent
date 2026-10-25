## One simulated creature, as data. Authoritative for position, health and AI state; the
## NpcBody node (if the creature is near enough to have one) only shows it. Other records
## are referred to by id (no RefCounted cycles).
class_name NpcRecord
extends RefCounted

const LOG_SIZE := 16

var id := ""
var archetype := ""
var def: Dictionary = {}
var slot_id := ""           ## spawn slot that owns it ("" = console / scripted)
var unique_id := ""         ## entity id for unique NPCs
var display_name := ""
var level := 1
var pos := Vector3.ZERO
var yaw := 0.0
var home := Vector3.ZERO
var wander_radius := 0.0
var movement := "wander"    ## idle | wander | patrol
var path: PackedVector3Array = PackedVector3Array()
var path_mode := "loop"     ## loop | pingpong | once
var path_wait := 2.0
var path_index := 0
var path_dir := 1

var health := 1.0
var max_health := 1.0
var damage := 0.0
var alive := true
var invulnerable := false

var state := 0              ## NpcBrain state
var state_since := 0.0      ## sim time the state began
var timer := 0.0            ## state countdown (idle pause, attack cooldown, waypoint wait)
var move_target := Vector3.INF
var move_speed := 0.0
var target_id := ""         ## "player" or a record id
var threat := {}            ## attacker id -> threat
var flee_from := Vector3.ZERO
var progress_t := 0.0       ## last time it got closer to its goal (stuck detection)
var progress_d := INF

var tier := 3               ## SimScheduler tier (DORMANT until scheduled)
var node_id := 0            ## instance id of its NpcBody, 0 = none
var physics_mode := false   ## moved by physics (inside terrain collision) vs snapped to ground
var last_tick := 0.0        ## sim time of the last update
var think_phase := 0        ## staggers thinking across frames
var important_until := 0.0  ## stays ACTIVE (in combat) until then
var rng_counter := 0
var reactions_done := {}
var log: Array = []         ## [time, from, to, reason] — why it did what it did
var fade_in := false


func add_log(t: float, from: String, to: String, reason: String) -> void:
	log.append([t, from, to, reason])
	if log.size() > LOG_SIZE:
		log.pop_front()


## Deterministic random value in [0, 1) for this creature (no shared RNG state).
func rand() -> float:
	rng_counter += 1
	return Rng.hash2f(hash(id), rng_counter, 9187)


func in_combat(now: float) -> bool:
	return now < important_until
