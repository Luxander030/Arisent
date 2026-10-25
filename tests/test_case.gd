class_name TestCase
extends RefCounted

var failures: Array[String] = []

func check(cond: bool, msg: String = "check failed") -> void:
	if not cond:
		failures.append(msg)

func eq(a: Variant, b: Variant, msg: String = "") -> void:
	if a != b:
		failures.append("%s expected %s, got %s" % [msg, str(b), str(a)])
