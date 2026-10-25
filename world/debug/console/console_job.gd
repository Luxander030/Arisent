## Asynchronous console work. A handler returns ConsoleJob.new(body) where body is a
## Callable(job) that may `await` (timers, frames, save threads) and returns what a
## synchronous handler would. The console starts jobs one at a time, in order, and polls
## is_done() every frame; it never awaits.
class_name ConsoleJob
extends RefCounted

var body: Callable
var result: ConsoleResult
var started := false
var _done := false
var _t0 := 0


func _init(b: Callable) -> void:
	body = b


func start() -> void:
	started = true
	_t0 = Time.get_ticks_usec()
	_run()


func _run() -> void:
	var v: Variant = await body.call(self)
	result = ConsoleResult.from(v)
	_done = true


func is_done() -> bool:
	return _done


func elapsed() -> float:
	return (Time.get_ticks_usec() - _t0) / 1e6 if started else 0.0


## For bodies: wait real seconds (unaffected by time scale or pause).
static func wait(seconds: float) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	await tree.create_timer(seconds, true, false, true).timeout


## For bodies: wait one rendered frame.
static func frame() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	await tree.process_frame
