## Feeds engine output (print, push_warning, push_error, script errors) into the console.
## Called from any thread, so blocks are staged and the console lands them on the main
## thread (ConsoleModel.pump).
class_name ConsoleLogger
extends Logger

var _model: WeakRef


func _init(m: ConsoleModel) -> void:
	_model = weakref(m)


func _log_message(message: String, error: bool) -> void:
	var m := _model.get_ref() as ConsoleModel
	if m:
		m.stage(ConsoleTheme.Kind.ERROR if error else ConsoleTheme.Kind.DEBUG, message.trim_suffix("\n"))


func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool,
		error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
	var m := _model.get_ref() as ConsoleModel
	if m == null:
		return
	var text := rationale if rationale != "" else code
	var where := "%s:%d" % [file.get_file(), line] if file != "" else function
	var kind := ConsoleTheme.Kind.WARNING if error_type == ERROR_TYPE_WARNING else ConsoleTheme.Kind.ERROR
	m.stage(kind, "%s  (%s)" % [text, where])
