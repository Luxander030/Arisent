extends TestCase

func test_splitmix64_reference_vectors() -> void:
	# Vigna's reference splitmix64 output for state 1234567.
	var golden := -7046029254386353131
	eq(Rng.splitmix64(1234567), 6457827717110365317, "splitmix #1")
	eq(Rng.splitmix64(1234567 + golden), 3203168211198807973, "splitmix #2")
	eq(Rng.splitmix64(1234567 + 2 * golden), -8629252141511181193, "splitmix #3")

func test_pcg32_reference_vectors() -> void:
	# pcg32-demo: pcg32_srandom_r(&rng, 42, 54)
	var r := Rng.new()
	r.set_stream(54)
	r.seed_raw(42)
	for expected in [0xa15c02b7, 0x7b47f409, 0xba1d3330, 0x83d2f293, 0xbfa4784b, 0xcbed606e]:
		eq(r.next_u32(), expected, "pcg32")

func test_same_seed_same_sequence() -> void:
	var a := Rng.new(99)
	var b := Rng.new(99)
	for i in 100:
		eq(a.next_u32(), b.next_u32())
	check(Rng.new(1).next_u32() != Rng.new(2).next_u32(), "different seeds differ")

func test_floats_in_range() -> void:
	var r := Rng.new(5)
	for i in 1000:
		var f := r.next_float()
		check(f >= 0.0 and f < 1.0, "float out of range %f" % f)
		var k := r.range_i(-3, 3)
		check(k >= -3 and k <= 3, "int out of range %d" % k)

func test_seed_from_text() -> void:
	eq(Rng.seed_from_text("12345"), 12345)
	eq(Rng.seed_from_text("Frostvale"), Rng.seed_from_text("Frostvale"))
	check(Rng.seed_from_text("a") != Rng.seed_from_text("b"))

func test_hash_is_stateless_and_spread() -> void:
	eq(Rng.hash2(-5, 7, 11), Rng.hash2(-5, 7, 11))
	var sum := 0.0
	for i in 4096:
		sum += Rng.hash2f(i % 64 - 32, i / 64, 3)
	check(absf(sum / 4096.0 - 0.5) < 0.03, "hash mean %f" % (sum / 4096.0))
