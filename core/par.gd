## Deterministic parallel loops over grid rows.
## Each band returns its own arrays; bands are concatenated in order afterwards, so the
## result is identical to a single-threaded run no matter how threads are scheduled.
## Call from the main thread or a dedicated Thread (not from inside a WorkerThreadPool task).
class_name Par
extends RefCounted


## fn(j0: int, j1: int) -> Array of packed arrays covering rows [j0, j1).
## Returns an Array with one concatenated packed array per output.
static func rows(n: int, fn: Callable, bands: int = 16) -> Array:
	bands = clampi(bands, 1, n)
	var step := ceili(float(n) / bands)
	var results := []
	results.resize(bands)
	var task := func(b: int) -> void:
		var j0 := b * step
		var j1 := mini(n, j0 + step)
		results[b] = fn.call(j0, j1) if j0 < j1 else []
	var id := WorkerThreadPool.add_group_task(task, bands, -1, true, "Par.rows")
	WorkerThreadPool.wait_for_group_task_completion(id)
	var out := []
	for b in bands:
		var part: Array = results[b]
		for idx in part.size():
			if out.size() <= idx:
				out.append(part[idx])
			else:
				var acc: Variant = out[idx]
				acc.append_array(part[idx])
				out[idx] = acc
	return out
