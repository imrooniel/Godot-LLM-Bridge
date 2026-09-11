@tool
extends RefCounted

## Shared eval safety policy for both bridges (BD-007/BD-008).
##
## Validates one GDScript expression before it is wrapped as
## `func _eval(): return (expr)` and compiled. Returns "" when allowed,
## otherwise a short, agent-actionable error message. Used by the game
## DebugBridge (`editor_context = false`) and the editor-side eval
## channel (`editor_context = true`, adds editor-only prohibitions).

const MAX_LENGTH := 4096

const SINGLE_EXPR_MSG := (
	"single expression only — gd-eval wraps one expression as 'return (expr)'; "
	+ "move statements into a project script and call its method instead"
)

const DANGEROUS_PATTERNS: Array[String] = [
	"os.execute", "os.create_process", "os.kill", "get_tree().quit",
	"save_quit", "quit_app", "call_deferred(\"quit", "call_deferred('quit",
	"diraccess.make_dir_recursive", "diraccess.remove",
	"diraccess.copy", "diraccess.rename", "diraccess.write",
	"fileaccess.write", "fileaccess.open_write", "fileaccess.rename",
	"fileaccess.remove", "duplicate(0", "set_script(",
]

# Editor-context extras: never let eval close or mutate the editor session.
const EDITOR_PATTERNS: Array[String] = [
	"quit_editor", "save_quit", "quit_play", "restart_editor",
	"editorfeatureplugin",
]

# Strips double/single-quoted string literals so semicolons inside
# strings don't read as statement separators.
const _STRING_RE := "\"(?:[^\"\\\\]|\\\\.)*\"|'(?:[^'\\\\]|\\\\.)*'"


static func validate(expression: String, editor_context: bool = false) -> String:
	var trimmed := expression.strip_edges()
	if trimmed.is_empty():
		return "empty expression"
	if trimmed.length() > MAX_LENGTH:
		return "expression too long (%d > %d chars)" % [trimmed.length(), MAX_LENGTH]

	var lower := trimmed.to_lower()
	for pattern: String in DANGEROUS_PATTERNS:
		if lower.contains(pattern):
			return "refused: '%s' is not allowed via bridge eval" % pattern
	if editor_context:
		for pattern: String in EDITOR_PATTERNS:
			if lower.contains(pattern):
				return "refused: '%s' is not allowed via editor eval" % pattern

	# Multi-statement shapes can never compile inside a single return().
	if trimmed.contains("\n"):
		return SINGLE_EXPR_MSG
	if trimmed.ends_with(":"):
		return SINGLE_EXPR_MSG
	if _has_statement_separator(trimmed):
		return SINGLE_EXPR_MSG
	return ""


static func _has_statement_separator(expr: String) -> bool:
	var re := RegEx.new()
	if re.compile(_STRING_RE) != OK:
		return expr.contains(";")
	var stripped := expr
	var guard := 0
	while guard < 100:
		var m := re.search(stripped)
		if m == null:
			break
		stripped = stripped.left(m.get_start()) + stripped.substr(m.get_end())
		guard += 1
	var semis := stripped.find(";")
	while semis != -1:
		# A trailing ';' is legal style; ';' followed by more code is two statements.
		if not stripped.substr(semis + 1).strip_edges().is_empty():
			return true
		semis = stripped.find(";", semis + 1)
	return false
