extends Node

# CrateSkipper — adds a "Recycle N Crates" button to the end-of-wave crate
# screen. Holding it (mouse click-and-hold, or the keyboard/controller hotkey)
# fills a reroll-style progress bar; on completion it discards every offered
# crate for gold (the vanilla "recycle" action) and skips through the screen.
#
# Fully self-contained: glyph icons are loaded at runtime from this mod's own
# assets/ folder via Image.load (no .import dependency, no other mod required).

const MOD_DIR = "PapiLeem-CrateSkipper"
const MOD_LOG = "PapiLeem-CrateSkipper"
const ACTION_NAME = "crate_skip"
# Seconds the hotkey/click must be held before the skip fires. Matches the
# reroll button's hold-to-confirm duration (RerollButton.TIME_LOADING).
const HOLD_DURATION = 0.5

const RECYCLE_BTN_NAME = "CrateSkipperRecycleAll"
const PROGRESS_NODE_NAME = "CrateSkipperProgress"
const GLYPH_NODE_NAME = "CrateSkipperGlyph"
# Reroll-fill gold, copied from progress_reroll.modulate in the scene.
const PROGRESS_COLOR = Color(1, 0.796078, 0, 1)

const UpgradesDetector = preload("res://mods-unpacked/PapiLeem-CrateSkipper/scripts/upgrades_detector.gd")

const ASSET_DIR = "res://mods-unpacked/PapiLeem-CrateSkipper/assets/"
# Bound-input → glyph filename. Only the bindings we ship art for; anything
# else simply shows no icon (the text label still names the action).
const KEYBOARD_GLYPHS = {71: "key_g.png"}
const XBOX_GLYPHS = {10: "key_xbox_back.png"}
const PS_GLYPHS = {10: "key_ps_share.png"}
const SWITCH_GLYPHS = {10: "key_switch_minus.png"}

var _key_scancode: int = 71
var _joy_button: int = 10

var _active_uis = []

# Per-player hold state (keyed by player_index).
var _hold_time: Dictionary = {}
var _hold_fired: Dictionary = {}
var _mouse_down: Dictionary = {}

# Runtime-loaded glyph textures, keyed by asset filename.
var _glyph_cache: Dictionary = {}

# Guards the discard-all coroutine so a held key can't start it more than once.
var _discarding: bool = false


func _init():
	ModLoaderLog.info("Init", MOD_LOG)


func _ready():
	_add_translations()
	_register_input_action()
	if not get_tree().is_connected("node_added", self, "_on_node_added"):
		get_tree().connect("node_added", self, "_on_node_added")
	if not UIService.is_connected("change_device", self, "_on_device_changed"):
		UIService.connect("change_device", self, "_on_device_changed")
	ModLoaderLog.info("Ready", MOD_LOG)


# ─── translations ───────────────────────────────────────────────────────
# In-code translations (same approach as PapiLeem-Arenas). {0} = crate count.
# tr() falls back to "en" for any locale not listed here.

func _add_translations() -> void:
	# {0} = number of remaining crates. No gold shown — crate items are rolled
	# when opened, so the player just gets whatever the rolls give.
	var translations = {
		"en": {
			"CRATESKIPPER_RECYCLE_CRATE": "Recycle {0} Crate",
			"CRATESKIPPER_RECYCLE_CRATES": "Recycle {0} Crates",
		},
		"fr": {
			"CRATESKIPPER_RECYCLE_CRATE": "Recycler {0} caisse",
			"CRATESKIPPER_RECYCLE_CRATES": "Recycler {0} caisses",
		},
		"de": {
			"CRATESKIPPER_RECYCLE_CRATE": "{0} Kiste recyceln",
			"CRATESKIPPER_RECYCLE_CRATES": "{0} Kisten recyceln",
		},
		"es": {
			"CRATESKIPPER_RECYCLE_CRATE": "Reciclar {0} caja",
			"CRATESKIPPER_RECYCLE_CRATES": "Reciclar {0} cajas",
		},
		"it": {
			"CRATESKIPPER_RECYCLE_CRATE": "Ricicla {0} cassa",
			"CRATESKIPPER_RECYCLE_CRATES": "Ricicla {0} casse",
		},
		"pt": {
			"CRATESKIPPER_RECYCLE_CRATE": "Reciclar {0} caixa",
			"CRATESKIPPER_RECYCLE_CRATES": "Reciclar {0} caixas",
		},
		"ru": {
			"CRATESKIPPER_RECYCLE_CRATE": "Переработать {0} ящик",
			"CRATESKIPPER_RECYCLE_CRATES": "Переработать ящиков: {0}",
		},
		"pl": {
			"CRATESKIPPER_RECYCLE_CRATE": "Odzyskaj {0} skrzynię",
			"CRATESKIPPER_RECYCLE_CRATES": "Odzyskaj skrzynie: {0}",
		},
		"tr": {
			"CRATESKIPPER_RECYCLE_CRATE": "{0} sandığı geri dönüştür",
			"CRATESKIPPER_RECYCLE_CRATES": "{0} sandığı geri dönüştür",
		},
		"ja": {
			"CRATESKIPPER_RECYCLE_CRATE": "木箱を{0}個リサイクル",
			"CRATESKIPPER_RECYCLE_CRATES": "木箱を{0}個リサイクル",
		},
		"ko": {
			"CRATESKIPPER_RECYCLE_CRATE": "상자 {0}개 재활용",
			"CRATESKIPPER_RECYCLE_CRATES": "상자 {0}개 재활용",
		},
		"zh": {
			"CRATESKIPPER_RECYCLE_CRATE": "回收{0}个木箱",
			"CRATESKIPPER_RECYCLE_CRATES": "回收{0}个木箱",
		},
		"zh_TW": {
			"CRATESKIPPER_RECYCLE_CRATE": "回收{0}個木箱",
			"CRATESKIPPER_RECYCLE_CRATES": "回收{0}個木箱",
		},
	}
	for locale in translations:
		var t = Translation.new()
		t.locale = locale
		for key in translations[locale]:
			t.add_message(key, translations[locale][key])
		TranslationServer.add_translation(t)


# ─── input action registration ──────────────────────────────────────────

func _register_input_action() -> void:
	_key_scancode = 71
	_joy_button = 10
	_apply_input_binding(_key_scancode, _joy_button)

	var config = ModLoaderConfig.get_current_config(MOD_DIR)
	if config == null or config.data == null:
		ModLoaderLog.info("Bindings: key=" + str(_key_scancode) + " btn=" + str(_joy_button), MOD_LOG)
		return
	if config.data.has("keyboard_scancode"):
		_key_scancode = int(config.data["keyboard_scancode"])
	if config.data.has("joypad_button_index"):
		_joy_button = int(config.data["joypad_button_index"])
	_apply_input_binding(_key_scancode, _joy_button)
	ModLoaderLog.info("Bindings: key=" + str(_key_scancode) + " btn=" + str(_joy_button), MOD_LOG)


# Registers the base action in the InputMap so it shows up in any rebinding
# UI. Hotkey detection itself uses raw input polling in _process (not the
# InputMap), so this is purely cosmetic / for config interop.
func _apply_input_binding(scancode: int, button_index: int) -> void:
	if not InputMap.has_action(ACTION_NAME):
		InputMap.add_action(ACTION_NAME)
	InputMap.action_erase_events(ACTION_NAME)

	var key_event = InputEventKey.new()
	key_event.scancode = scancode
	key_event.physical_scancode = scancode
	InputMap.action_add_event(ACTION_NAME, key_event)

	var btn_event = InputEventJoypadButton.new()
	btn_event.button_index = button_index
	btn_event.device = -1
	InputMap.action_add_event(ACTION_NAME, btn_event)


# ─── crate-screen tracking / button injection ───────────────────────────

func _on_node_added(node: Node) -> void:
	if not UpgradesDetector.is_upgrades_ui(node):
		return
	# Two UpgradesUI instances exist (coop + non-coop); only the one matching
	# the current run wires itself up, so ignore the other.
	if node.is_coop_ui != RunData.is_coop_run:
		return
	if _active_uis.has(node):
		return
	_active_uis.append(node)
	node.connect("tree_exited", self, "_on_ui_exited", [node])
	call_deferred("_setup_ui", node)


func _on_ui_exited(ui) -> void:
	_active_uis.erase(ui)


func _setup_ui(ui) -> void:
	if not is_instance_valid(ui) or not ui.is_inside_tree():
		return
	for player_index in RunData.get_player_count():
		_build_recycle_button(ui, player_index)


# Builds our "Recycle N Crates" button by cloning the vanilla Discard button
# (identical theme/SFX) WITHOUT its signal connections, stripping the ui_info
# glyph, and adding a reroll-style progress overlay + our own hotkey glyph.
func _build_recycle_button(ui, player_index: int) -> void:
	var container = _get_player_container(ui, player_index)
	if container == null:
		return
	var discard = container.find_node("DiscardButton", true, false)
	if discard == null:
		return
	var parent = discard.get_parent()
	if parent == null or parent.has_node(RECYCLE_BTN_NAME):
		return

	# DUPLICATE_GROUPS | DUPLICATE_SCRIPTS (omit DUPLICATE_SIGNALS) so the clone
	# keeps styling + script but inherits no connections (notably not the
	# pressed→_on_DiscardButton_pressed one). my_menu_button._ready re-adds its
	# own internal SFX/focus connections cleanly.
	var btn = discard.duplicate(Node.DUPLICATE_GROUPS | Node.DUPLICATE_SCRIPTS)
	btn.name = RECYCLE_BTN_NAME
	btn.set("unique_name_in_owner", false)
	btn.focus_mode = Control.FOCUS_NONE
	btn.text = ""

	var stray_icon = btn.get_node_or_null("button_y_icon")
	if stray_icon != null:
		stray_icon.queue_free()

	var progress = _make_progress_overlay(container)
	if progress != null:
		btn.add_child(progress)

	var glyph = _make_glyph_rect(_device_type_for_player(player_index))
	btn.add_child(glyph)

	btn.connect("button_down", self, "_on_recycle_button_down", [player_index])
	btn.connect("button_up", self, "_on_recycle_button_up", [player_index])

	parent.add_child(btn)


# Duplicates the reroll button's progress bar (the "stat reroll" hold-to-confirm
# fill). Its anchors are full, so it stretches to our button. Falls back to the
# ban progress bar, then to a plain ProgressBar.
func _make_progress_overlay(container):
	var src = container.find_node("progress_reroll", true, false)
	if src == null:
		src = container.find_node("progress_ban", true, false)
	var progress
	if src != null:
		progress = src.duplicate()
	else:
		progress = ProgressBar.new()
		progress.anchor_right = 1.0
		progress.anchor_bottom = 1.0
		progress.max_value = 1.0
		progress.percent_visible = false
	progress.name = PROGRESS_NODE_NAME
	progress.value = 0
	progress.modulate = PROGRESS_COLOR
	progress.mouse_filter = Control.MOUSE_FILTER_IGNORE
	progress.show()
	return progress


func _make_glyph_rect(device_type: int) -> TextureRect:
	var rect = TextureRect.new()
	rect.name = GLYPH_NODE_NAME
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.expand = true
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.anchor_top = 0.5
	rect.anchor_bottom = 0.5
	rect.margin_left = 8
	rect.margin_top = -25
	rect.margin_right = 59
	rect.margin_bottom = 25
	rect.rect_min_size = Vector2(51, 51)
	var tex = _glyph_texture(device_type)
	if tex != null:
		rect.texture = tex
	return rect


# ─── glyph loading (runtime, no .import needed) ──────────────────────────

func _glyph_filename(device_type: int) -> String:
	if device_type == CoopService.PlayerType.KEYBOARD_AND_MOUSE:
		return KEYBOARD_GLYPHS.get(_key_scancode, "")
	elif device_type == CoopService.PlayerType.GAMEPAD_XBOX:
		return XBOX_GLYPHS.get(_joy_button, "")
	elif device_type == CoopService.PlayerType.GAMEPAD_PLAYSTATION:
		return PS_GLYPHS.get(_joy_button, "")
	elif device_type == CoopService.PlayerType.GAMEPAD_SWITCH:
		return SWITCH_GLYPHS.get(_joy_button, "")
	return ""


func _glyph_texture(device_type: int):
	var filename = _glyph_filename(device_type)
	if filename == "":
		return null
	if _glyph_cache.has(filename):
		return _glyph_cache[filename]
	var image = Image.new()
	if image.load(ASSET_DIR + filename) != OK:
		_glyph_cache[filename] = null
		return null
	var texture = ImageTexture.new()
	texture.create_from_image(image, Texture.FLAG_FILTER)
	_glyph_cache[filename] = texture
	return texture


func _on_device_changed() -> void:
	for ui in _active_uis:
		if not is_instance_valid(ui) or not ui.is_inside_tree():
			continue
		for player_index in RunData.get_player_count():
			var btn = _get_recycle_button(ui, player_index)
			if btn == null:
				continue
			var glyph = btn.get_node_or_null(GLYPH_NODE_NAME)
			if glyph != null:
				glyph.texture = _glyph_texture(_device_type_for_player(player_index))


# ─── node lookups ────────────────────────────────────────────────────────

func _get_player_container(ui, player_index: int):
	if not ui.has_method("_get_player_container"):
		return null
	return ui._get_player_container(player_index)


func _get_discard_button(ui, player_index: int):
	var container = _get_player_container(ui, player_index)
	if container == null:
		return null
	return container.find_node("DiscardButton", true, false)


func _get_recycle_button(ui, player_index: int):
	var container = _get_player_container(ui, player_index)
	if container == null:
		return null
	return container.find_node(RECYCLE_BTN_NAME, true, false)


# A crate is discardable when its Recycle/Discard button is visible in the tree
# (it lives inside ItemsContainer, hidden except while a crate is being shown).
func _any_discardable(ui) -> bool:
	for player_index in RunData.get_player_count():
		var discard = _get_discard_button(ui, player_index)
		if discard != null and discard.is_visible_in_tree():
			return true
	return false


# Returns the active UpgradesUI only while it is actually showing a discardable
# crate (so everything is inert between waves and during level-up upgrades).
func _get_current_ui():
	for ui in _active_uis:
		if not is_instance_valid(ui) or not ui.is_inside_tree() or not ui.visible:
			continue
		if _any_discardable(ui):
			return ui
	return null


# ─── hold-to-confirm polling ────────────────────────────────────────────

func _process(delta: float) -> void:
	var ui = _get_current_ui()
	if ui == null:
		_hold_time.clear()
		_hold_fired.clear()
		return
	if get_tree().paused:
		return

	for player_index in RunData.get_player_count():
		var container = _get_player_container(ui, player_index)
		if container == null:
			continue
		var discard = container.find_node("DiscardButton", true, false)
		var btn = container.find_node(RECYCLE_BTN_NAME, true, false)
		var crate_showing = discard != null and discard.is_visible_in_tree()
		if btn == null or not crate_showing:
			_hold_time[player_index] = 0.0
			_hold_fired[player_index] = false
			continue

		_update_button_label(ui, container, player_index, btn)

		if _is_hold_input_active(player_index):
			var t = _hold_time.get(player_index, 0.0) + delta
			_hold_time[player_index] = t
			var progress01 = t / HOLD_DURATION
			if progress01 > 1.0:
				progress01 = 1.0
			_set_progress(btn, progress01)
			if t >= HOLD_DURATION and not _hold_fired.get(player_index, false):
				_hold_fired[player_index] = true
				_discard_all(ui, player_index)
		else:
			_hold_time[player_index] = 0.0
			_hold_fired[player_index] = false
			_set_progress(btn, 0.0)


func _is_hold_input_active(player_index: int) -> bool:
	if Input.is_key_pressed(_key_scancode) and _keyboard_player_index() == player_index:
		return true
	for device in Input.get_connected_joypads():
		if Input.is_joy_button_pressed(device, _joy_button) and _joypad_player_index(device) == player_index:
			return true
	return _mouse_down.get(player_index, false)


func _on_recycle_button_down(player_index: int) -> void:
	_mouse_down[player_index] = true


func _on_recycle_button_up(player_index: int) -> void:
	_mouse_down[player_index] = false


func _set_progress(btn, progress01: float) -> void:
	var progress = btn.get_node_or_null(PROGRESS_NODE_NAME)
	if progress != null:
		progress.value = progress01


# ─── label ───────────────────────────────────────────────────────────────

func _update_button_label(ui, container, player_index: int, btn) -> void:
	var count = _count_crates(ui, container, player_index)
	var key = "CRATESKIPPER_RECYCLE_CRATE" if count == 1 else "CRATESKIPPER_RECYCLE_CRATES"
	btn.text = Text.text(key, [str(count)])


func _count_crates(ui, container, player_index: int) -> int:
	var n = 0
	var discard = container.find_node("DiscardButton", true, false)
	if discard != null and discard.is_visible_in_tree():
		n += 1
	var consumables = ui.get("_consumables_to_process")
	if typeof(consumables) == TYPE_ARRAY and player_index < consumables.size() and typeof(consumables[player_index]) == TYPE_ARRAY:
		n += consumables[player_index].size()
	var extras = ui.get("_extra_items_to_process")
	if typeof(extras) == TYPE_ARRAY and player_index < extras.size() and typeof(extras[player_index]) == TYPE_ARRAY:
		n += extras[player_index].size()
	return n


# ─── discard-all ───────────────────────────────────────────────────────────
# Recycles every offered crate for the given player in ONE synchronous pass, so
# the whole batch resolves in a single frame instead of visibly cycling crate by
# crate. We call the container's discard handler directly (rather than pressing
# the button) so the button's click SFX never fires, and clear its _button_pressed
# debounce each step so no press is dropped. The vanilla handler still rolls each
# crate's item and adds the recycle gold (RunData.add_gold) — players get what the
# rolls give.
func _discard_all(ui, only_player_index: int = -1) -> void:
	if _discarding:
		return
	_discarding = true
	for player_index in RunData.get_player_count():
		if only_player_index >= 0 and player_index != only_player_index:
			continue
		var container = _get_player_container(ui, player_index)
		if container == null or not container.has_method("_on_DiscardButton_pressed"):
			continue
		var safety = 0
		while safety < 500:
			safety += 1
			if not is_instance_valid(container) or not container.is_inside_tree():
				break
			var discard = container.find_node("DiscardButton", true, false)
			if discard == null or not discard.is_visible_in_tree():
				break
			container.set("_button_pressed", false)  # clear the ButtonDelayTimer debounce
			container._on_DiscardButton_pressed()
	_discarding = false


# ─── device / player routing ─────────────────────────────────────────────

func _keyboard_player_index() -> int:
	if not RunData.is_coop_run:
		return 0
	for i in RunData.get_player_count():
		if CoopService.get_player_input_type(i) == CoopService.PlayerType.KEYBOARD_AND_MOUSE:
			return i
	return -1


func _joypad_player_index(device: int) -> int:
	if not RunData.is_coop_run:
		return 0
	for i in RunData.get_player_count():
		var t = CoopService.get_player_input_type(i)
		if t == CoopService.PlayerType.KEYBOARD_AND_MOUSE:
			continue
		var remapped = CoopService.get_remapped_player_device(i)
		var expected = remapped
		if remapped == CoopService.GAMEPAD_REMAPPED_DEVICE_ID:
			expected = 0
		if device == expected:
			return i
	return -1


func _device_type_for_player(player_index: int) -> int:
	if RunData.is_coop_run and player_index < CoopService.connected_players.size():
		return CoopService.get_player_input_type(player_index)
	return UIService.current_device
