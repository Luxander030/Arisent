## Who may open the debug console. Always in debug builds and in the World Editor (whose
## export is a release build with the "level_editor" feature). In release game builds only
## when started with `-- --dev` or when user://settings.cfg has [dev] console=true.
class_name DevGate
extends RefCounted

const SETTINGS := "user://settings.cfg"

static var force := false  ## tests


static func console_allowed() -> bool:
	if force or OS.is_debug_build() or OS.has_feature("level_editor"):
		return true
	if OS.get_cmdline_user_args().has("--dev"):
		return true
	var cfg := ConfigFile.new()
	return cfg.load(SETTINGS) == OK and bool(cfg.get_value("dev", "console", false))
