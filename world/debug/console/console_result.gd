## What a console command returns. Handlers may also return a String (plain success
## text), null (silent success) or a ConsoleJob (asynchronous work).
class_name ConsoleResult
extends RefCounted

var ok := true
var message := ""
var rich := false   ## message is BBCode (else plain text, shown as typed)


static func success(msg := "") -> ConsoleResult:
	var r := ConsoleResult.new()
	r.message = msg
	return r


static func failure(msg: String) -> ConsoleResult:
	var r := ConsoleResult.new()
	r.ok = false
	r.message = msg
	return r


## Success with BBCode (coloured text, tables).
static func rich_text(bbcode: String) -> ConsoleResult:
	var r := ConsoleResult.new()
	r.message = bbcode
	r.rich = true
	return r


static func rich_failure(bbcode: String) -> ConsoleResult:
	var r := failure(bbcode)
	r.rich = true
	return r


## Normalises whatever a handler returned.
static func from(v: Variant) -> ConsoleResult:
	if v is ConsoleResult:
		return v
	if v == null:
		return success()
	return success(str(v))


func has_message() -> bool:
	return message != ""
