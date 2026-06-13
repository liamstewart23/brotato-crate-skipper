extends Reference

# Identifies Brotato's end-of-wave crate / upgrade selection screen (UpgradesUI)
# by walking the script inheritance chain. Works regardless of whether other
# mods have extended upgrades_ui.gd, because their extensions still inherit
# from the vanilla class.

const UPGRADES_UI_SCRIPT_PATHS = [
	"res://ui/menus/ingame/upgrades_ui.gd",
]


static func is_upgrades_ui(node: Node) -> bool:
	var script = node.get_script()
	while script != null:
		if UPGRADES_UI_SCRIPT_PATHS.has(script.resource_path):
			return true
		script = script.get_base_script()
	return false


# Fallback for when node_added missed the screen (e.g. it existed before the
# signal was connected). Returns the active UpgradesUI for the current run
# (coop vs non-coop) if one is in the current scene, else null.
static func find_upgrades_ui_in_tree(tree: SceneTree):
	var current_scene = tree.current_scene
	if current_scene == null:
		return null
	if is_upgrades_ui(current_scene) and _matches_run(current_scene):
		return current_scene
	return _find_recursive(current_scene)


static func _find_recursive(node: Node):
	for child in node.get_children():
		if is_upgrades_ui(child) and _matches_run(child):
			return child
		var found = _find_recursive(child)
		if found != null:
			return found
	return null


# Two UpgradesUI instances exist (coop + non-coop); only the one whose
# is_coop_ui matches the current run actually wires itself up in _ready().
static func _matches_run(node: Node) -> bool:
	if not ("is_coop_ui" in node):
		return true
	return node.is_coop_ui == RunData.is_coop_run
