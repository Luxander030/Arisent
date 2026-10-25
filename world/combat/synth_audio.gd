## Placeholder sound effects generated at runtime (no audio files needed): filtered noise
## bursts with simple envelopes for shots, clicks, reloads, impacts and footsteps.
class_name SynthAudio
extends RefCounted

const RATE := 22050
static var _cache := {}


static func get_sound(name: String) -> AudioStreamWAV:
	if _cache.has(name):
		return _cache[name]
	var s: AudioStreamWAV
	match name:
		"shot_pistol": s = _burst(0.18, 0.55, 9.0, 0.35, 140.0)
		"shot_rifle": s = _burst(0.22, 0.7, 7.0, 0.45, 90.0)
		"shot_sniper": s = _burst(0.5, 0.9, 3.5, 0.6, 55.0)
		"knife": s = _burst(0.12, 0.25, 18.0, 0.9, 0.0)
		"empty": s = _burst(0.04, 0.3, 60.0, 1.0, 0.0)
		"reload": s = _clicks([0.0, 0.35, 0.5], 0.7)
		"impact": s = _burst(0.08, 0.35, 30.0, 0.5, 0.0)
		"impact_flesh": s = _burst(0.1, 0.4, 25.0, 0.15, 60.0)
		_: s = _burst(0.05, 0.2, 40.0, 0.5, 0.0)
	_cache[name] = s
	return s


## Noise burst: `length` s, `gain`, exponential `decay`, `brightness` 0..1 (low-pass), plus
## an optional low "thump" sine at `thump_hz`.
static func _burst(length: float, gain: float, decay: float, brightness: float, thump_hz: float) -> AudioStreamWAV:
	var n := int(length * RATE)
	var data := PackedByteArray()
	data.resize(n * 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([length, decay, thump_hz])
	var lp := 0.0
	for i in n:
		var t := float(i) / RATE
		var env := exp(-t * decay)
		var noise := rng.randf_range(-1.0, 1.0)
		lp = lerpf(lp, noise, brightness)
		var v := lp * env
		if thump_hz > 0.0:
			v += sin(TAU * thump_hz * t) * exp(-t * decay * 1.5) * 0.8
		data.encode_s16(i * 2, clampi(int(v * gain * 32767.0), -32768, 32767))
	return _wav(data)


static func _clicks(times: Array, gain: float) -> AudioStreamWAV:
	var n := int((float(times[-1]) + 0.08) * RATE)
	var data := PackedByteArray()
	data.resize(n * 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for t0 in times:
		var start := int(float(t0) * RATE)
		for i in int(0.05 * RATE):
			if start + i >= n:
				break
			var v := rng.randf_range(-1.0, 1.0) * exp(-float(i) / RATE * 80.0)
			data.encode_s16((start + i) * 2, clampi(int(v * gain * 32767.0), -32768, 32767))
	return _wav(data)


static func _wav(data: PackedByteArray) -> AudioStreamWAV:
	var s := AudioStreamWAV.new()
	s.format = AudioStreamWAV.FORMAT_16_BITS
	s.mix_rate = RATE
	s.stereo = false
	s.data = data
	return s


## One-shot positional sound.
static func play_at(parent: Node, name: String, pos: Vector3, volume_db := 0.0) -> void:
	var p := AudioStreamPlayer3D.new()
	p.stream = get_sound(name)
	p.volume_db = volume_db
	p.unit_size = 12.0
	parent.add_child(p)
	p.global_position = pos
	p.play()
	p.finished.connect(p.queue_free)
