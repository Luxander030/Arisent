## Deterministic random numbers that give identical results on every platform and
## Godot version. Never use randi()/randf()/hash()/Array.shuffle() for generation.
##
## - Rng.new(seed): sequential PCG32 stream (for code that needs "the next number").
## - Rng.hash2/hash3/...: stateless position hashes (for anything placed in space, so
##   changing one area never reshuffles another).
class_name Rng
extends RefCounted

const MASK32 := 0xFFFFFFFF
const PCG_MULT := 6364136223846793005
const PCG_INC := 1442695040888963407
const INV_2_24 := 1.0 / 16777216.0

var _state: int = 0
var _inc: int = PCG_INC


func _init(seed_value: int = 0) -> void:
	seed_raw(splitmix64(seed_value))


## Standard PCG32 seeding (pcg32_srandom_r) with the current stream increment.
func seed_raw(init_state: int) -> void:
	_state = 0
	next_u32()
	_state = _state + init_state
	next_u32()


func set_stream(stream: int) -> void:
	_inc = (stream << 1) | 1


## Uniform unsigned 32-bit integer.
func next_u32() -> int:
	var old := _state
	_state = old * PCG_MULT + _inc
	var xorshifted := (((_lsr(old, 18)) ^ old) >> 27) & MASK32
	var rot := _lsr(old, 59)
	return ((xorshifted >> rot) | (xorshifted << ((-rot) & 31))) & MASK32


## Uniform float in [0, 1). Exact 24-bit resolution, identical on all platforms.
func next_float() -> float:
	return float(next_u32() >> 8) * INV_2_24


func range_f(lo: float, hi: float) -> float:
	return lo + (hi - lo) * next_float()


## Uniform integer in [lo, hi] inclusive.
func range_i(lo: int, hi: int) -> int:
	return lo + int(next_u32() % (hi - lo + 1))


func chance(p: float) -> bool:
	return next_float() < p


func pick(arr: Array) -> Variant:
	return arr[range_i(0, arr.size() - 1)]


## Deterministic in-place Fisher-Yates shuffle.
func shuffle(arr: Array) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j := range_i(0, i)
		var tmp: Variant = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp


# --- Stateless helpers -------------------------------------------------------

## Logical (unsigned) right shift on a 64-bit int.
static func _lsr(x: int, n: int) -> int:
	if n == 0:
		return x
	return (x >> n) & ((1 << (64 - n)) - 1)


## SplitMix64: turns any int into a well-mixed 64-bit seed.
static func splitmix64(x: int) -> int:
	var z := x + -7046029254386353131  # 0x9E3779B97F4A7C15
	z = (z ^ _lsr(z, 30)) * -4658895280553007687  # 0xBF58476D1CE4E5B9
	z = (z ^ _lsr(z, 27)) * -7723592293110705685  # 0x94D049BB133111EB
	return z ^ _lsr(z, 31)


## Derive an independent sub-seed, e.g. Rng.derive(world_seed, Rng.STAGE_CITY).
static func derive(seed_value: int, salt: int) -> int:
	return splitmix64(seed_value ^ splitmix64(salt))


## Stable seed from text (FNV-1a over UTF-8, then mixed). Same text -> same seed everywhere.
static func seed_from_text(text: String) -> int:
	if text.is_valid_int():
		return text.to_int()
	var h := -3750763034362895579  # FNV offset basis 0xcbf29ce484222325
	for b in text.to_utf8_buffer():
		h = (h ^ b) * 1099511628211
	return splitmix64(h)


## lowbias32-style integer finalizer, 32-bit in/out.
static func mix32(x: int) -> int:
	x &= MASK32
	x ^= x >> 16
	x = (x * 0x7feb352d) & MASK32
	x ^= x >> 15
	x = (x * 0x846ca68b) & MASK32
	x ^= x >> 16
	return x


## Stateless hash of (x, y) with a seed -> unsigned 32-bit.
static func hash2(x: int, y: int, seed_value: int) -> int:
	return mix32(mix32(mix32((seed_value ^ (seed_value >> 32)) & MASK32) + (x & MASK32)) + (y & MASK32))


static func hash3(x: int, y: int, z: int, seed_value: int) -> int:
	return mix32(hash2(x, y, seed_value) + (z & MASK32))


## Stateless hash -> float in [0, 1).
static func hash2f(x: int, y: int, seed_value: int) -> float:
	return float(hash2(x, y, seed_value) >> 8) * INV_2_24


static func hash3f(x: int, y: int, z: int, seed_value: int) -> float:
	return float(hash3(x, y, z, seed_value) >> 8) * INV_2_24
