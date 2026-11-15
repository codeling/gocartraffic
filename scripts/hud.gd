extends CanvasLayer
## Heads-up display, start menu and file dialogs - built entirely in code.

const Cfg = preload("res://scripts/cfg.gd")
const Advisor = preload("res://scripts/advisor.gd")
const Alerts = preload("res://scripts/alerts.gd")
const MiniMap = preload("res://scripts/minimap.gd")
const Pointers = preload("res://scripts/pointers.gd")

const HELP := """[font_size=20][b]GoCarTraffic[/b][/font_size]
A town is growing on this map. People want to get to work, to the shops and out in the evening. [b]Every trip that arrives within its time limit earns credits[/b] (2.5 times what the trip takes by car on empty roads). Late trips and trips that cannot be made earn nothing. Everything is to scale: one tile is 20 m and cars drive at most 50 km/h.

[b]Build[/b]  (Ctrl+Z takes back what you just built, free of charge, for 15 seconds)
[color=#ffd866]2 Road[/color]  drag to draw a street with one lane each way. Ends join neighbouring roads by themselves.
[color=#ffd866]3 Add lane[/color]  drag along a road to widen it (up to 3 lanes each way).
[color=#ffd866]4 Cycle path[/color]  a cheap path for bikes only.   [color=#ffd866]5 Bike lanes[/color]  add them to an existing road.
[color=#ffd866]6 Bus stop[/color]  on roads; people walk up to 5 tiles to a stop.   [color=#ffd866]7 Bus line[/color]  click stops in order, then Enter.
[color=#ffd866]8 Bulldoze[/color]  removes one layer per click: bus stop, bike lanes, extra lanes, then the road.
[color=#ffd866]1 Inspect[/color]  click anything to see what is going on there.

[b]How people travel[/b]
Short trips are walked (up to 10 tiles), medium ones cycled (up to 30 tiles, far more often where there are bike lanes or cycle paths). A household has only 1-2 cars for 3-4 people; whoever finds no car takes the bus, changing lines up to twice. Cyclists on a road without bike lanes slow down the cars behind them.

[b]Why do jams happen?[/b]  Press [color=#ffd866]T[/color] for the traffic view and read the [i]Traffic advisor[/i].
- [b]Junctions[/b]: crossing streams take turns, so a junction carries less than the roads leading to it.
- [b]Merges and lane drops[/b]: more lanes flowing in than out.
- [b]Spillback[/b]: a full road blocks the junction behind it - the red line is the symptom, the cause is at its front.
- [b]Single crossings[/b], [b]rush hours[/b], [b]cyclists and buses in the lane[/b], [b]full car parks[/b].

[b]Controls[/b]  WASD / arrows: move.  Drag with the right or middle mouse button, or hold Shift and drag with the left one: move (the mini-map in the corner works too).  Wheel: zoom.  Q / E: rotate.  C: centre the view on the town (twice: whole map).
Space: pause (the game starts paused).  + / -: speed.  T: traffic view (jams, then volume).  G: statistics.  L: notifications and problem history.  M or Esc: menu (save, load, new game); Esc closes it again.  H: this help.

[b]Problems[/b]  Houses without a road, people who cannot travel and traffic jams are announced at the top of the screen, stay in the notification log (L) and are pointed out by arrows at the screen edge when they are out of view. By default the game pauses when a new problem appears; switch that off in the log."""

var g
var labels := {}
var day_bar: ProgressBar
var tool_buttons: Array = []
var speed_buttons: Array = []
var overlay_btn: Button
var right_scroll: ScrollContainer
var right_box: VBoxContainer
var inspector: RichTextLabel
var advisor_box: VBoxContainer
var advisor_sig := "?"
var lines_box: VBoxContainer
var lines_sig := "?"
var line_labels := {}
var hint: Label
var toast_box: VBoxContainer
var toasts: Array = []       # {node, age, hold, fade}
var paused_lbl: Label
var cost_tag: PanelContainer
var cost_lbl: Label
var cost_text := ""
var minimap
var minimap_panel: PanelContainer
var pointers
var log_btn: Button
var log_panel: PanelContainer
var log_open_box: VBoxContainer
var log_hist_box: VBoxContainer
var log_ver := -1
var pause_check: CheckButton
var menu_pause_check: CheckBox
var help: PanelContainer
var menu: PanelContainer
var stats: PanelContainer
var stats_text: RichTextLabel
var seed_edit: LineEdit
var compact_slider: HSlider
var cluster_slider: HSlider
var day_option: OptionButton
var resume_row: HBoxContainer
var file_dialog: FileDialog
var _js_callback


func _panel_style(alpha: float = 0.88) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.1, 0.13, alpha)
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(10)
	return sb


func _panel(alpha: float = 0.88) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _panel_style(alpha))
	return p


func _button(text: String, cb: Callable, toggle: bool = false) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.toggle_mode = toggle
	b.pressed.connect(cb)
	return b


func _small(text: String, col: Color = Color(0.65, 0.72, 0.8)) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", col)
	return l


func _heading(text: String) -> Label:
	var l := _small(text.to_upper())
	l.add_theme_font_size_override("font_size", 11)
	return l


func _stat(box: HBoxContainer, key: String, title: String, tip: String) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	v.tooltip_text = tip
	var l := Label.new()
	l.text = "-"
	l.add_theme_font_size_override("font_size", 18)
	v.add_child(_heading(title))
	v.add_child(l)
	box.add_child(v)
	labels[key] = l
	return v


func _rich(width: float, font: int) -> RichTextLabel:
	var rt := RichTextLabel.new()
	rt.bbcode_enabled = true
	rt.fit_content = true
	rt.scroll_active = false
	rt.custom_minimum_size = Vector2(width, 0)
	rt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for f in ["normal_font_size", "bold_font_size", "italics_font_size", "mono_font_size"]:
		rt.add_theme_font_size_override(f, font)
	return rt


func setup(game) -> void:
	g = game
	pointers = Pointers.new()
	add_child(pointers)
	pointers.setup(g)
	var root := MarginContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["left", "right", "top", "bottom"]:
		root.add_theme_constant_override("margin_" + side, 8)
	add_child(root)
	var col := VBoxContainer.new()
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(col)

	# ---- top bar
	var top := _panel()
	col.add_child(top)
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 18)
	top.add_child(bar)
	_stat(bar, "credits", "CREDITS", "Earned by every trip that arrives within its time limit.")
	var tv2 := _stat(bar, "time", "TIME", "Distances, speeds and travel times are to scale (1 tile = 20 m, cars up to 50 km/h). The inhabitants' daily routine is squeezed into the day length chosen at the start; rush hours are in the morning and late afternoon.")
	day_bar = ProgressBar.new()
	day_bar.show_percentage = false
	day_bar.custom_minimum_size = Vector2(120, 4)
	day_bar.max_value = 24.0
	day_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tv2.add_child(day_bar)
	_stat(bar, "pop", "PEOPLE / VEHICLES", "People living in town / vehicles on the road right now.")
	_stat(bar, "ontime", "ON TIME", "Share of recent travellers who arrived within the limit. Trips that could not be made count as failed.")
	_stat(bar, "delay", "CAR TRAVEL TIME", "Recent car travel time compared with an empty road. 1.0x = no delay at all, 2.5x is the limit.")
	_stat(bar, "score", "MOVED", "Your score: travellers delivered on time since the start.")
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_child(sp)
	var speeds := HBoxContainer.new()
	speeds.add_theme_constant_override("separation", 2)
	bar.add_child(speeds)
	for k in Cfg.SPEEDS.size():
		var b := _button(Cfg.SPEED_NAMES[k], g.set_speed.bind(k), true)
		b.custom_minimum_size = Vector2(36, 0)
		b.tooltip_text = "Pause" if k == 0 else "%d seconds of game time per second" % int(Cfg.SPEEDS[k])
		speeds.add_child(b)
		speed_buttons.append(b)
	var btns := HBoxContainer.new()
	btns.add_theme_constant_override("separation", 4)
	bar.add_child(btns)
	overlay_btn = _button("Traffic: off (T)", g.cycle_overlay)
	overlay_btn.tooltip_text = "Colours the roads: first by congestion, then by how many vehicles use them."
	btns.add_child(overlay_btn)
	btns.add_child(_button("Stats (G)", toggle_stats))
	btns.add_child(_button("Help (H)", toggle_help))
	btns.add_child(_button("Menu (M)", show_menu.bind(true)))

	# ---- middle row
	var mid := HBoxContainer.new()
	mid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(mid)

	var tools := _panel()
	tools.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mid.add_child(tools)
	var tv := VBoxContainer.new()
	tools.add_child(tv)
	var names := [
		"1  Inspect", "2  Road  (%d / tile)" % Cfg.COST_ROAD, "3  Add lane",
		"4  Cycle path  (%d / tile)" % Cfg.COST_BIKEPATH, "5  Bike lanes  (%d / tile)" % Cfg.COST_BIKELANE,
		"6  Bus stop  (%d)" % Cfg.COST_STOP, "7  Bus line  (%d / bus)" % Cfg.COST_BUS, "8  Bulldoze",
	]
	for k in names.size():
		var b := _button(names[k], g.set_tool.bind(k), true)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size = Vector2(176, 31)
		tv.add_child(b)
		tool_buttons.append(b)
	labels["undo"] = _small("")
	tv.add_child(labels["undo"])

	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mid.add_child(gap)

	var right := _panel()
	right.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	mid.add_child(right)
	right_scroll = ScrollContainer.new()
	right_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right_scroll.custom_minimum_size = Vector2(338, 100)
	right.add_child(right_scroll)
	right_box = VBoxContainer.new()
	right_box.add_theme_constant_override("separation", 6)
	right_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_scroll.add_child(right_box)
	right_box.add_child(_heading("Inspector"))
	inspector = _rich(320, 13)
	right_box.add_child(inspector)
	right_box.add_child(HSeparator.new())
	right_box.add_child(_heading("Traffic advisor"))
	advisor_box = VBoxContainer.new()
	right_box.add_child(advisor_box)
	right_box.add_child(HSeparator.new())
	right_box.add_child(_heading("Bus lines"))
	lines_box = VBoxContainer.new()
	right_box.add_child(lines_box)

	# ---- bottom hint
	var hp := _panel()
	hp.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	col.add_child(hp)
	hint = Label.new()
	hint.add_theme_font_size_override("font_size", 14)
	hp.add_child(hint)

	# ---- notifications: a stack of lines that fade out slowly
	paused_lbl = Label.new()
	paused_lbl.text = "PAUSED  -  press Space or pick a speed to start"
	paused_lbl.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	paused_lbl.position.y = 80
	paused_lbl.grow_horizontal = Control.GROW_DIRECTION_BOTH
	paused_lbl.add_theme_font_size_override("font_size", 16)
	paused_lbl.add_theme_color_override("font_color", Color(1.0, 0.9, 0.45))
	paused_lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	paused_lbl.add_theme_constant_override("outline_size", 5)
	paused_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(paused_lbl)
	toast_box = VBoxContainer.new()
	toast_box.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	toast_box.position.y = 110
	toast_box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	toast_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	toast_box.add_theme_constant_override("separation", 4)
	add_child(toast_box)

	# ---- price tag next to the cursor
	cost_tag = _panel(0.93)
	cost_tag.visible = false
	cost_tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cost_lbl = Label.new()
	cost_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	cost_lbl.custom_minimum_size = Vector2(280, 0)
	cost_lbl.add_theme_font_size_override("font_size", 13)
	cost_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cost_tag.add_child(cost_lbl)
	add_child(cost_tag)

	# ---- mini-map
	minimap_panel = _panel()
	var mv := VBoxContainer.new()
	mv.add_theme_constant_override("separation", 4)
	minimap_panel.add_child(mv)
	minimap = MiniMap.new()
	mv.add_child(minimap)
	minimap.setup(g)
	var mrow := HBoxContainer.new()
	mrow.add_theme_constant_override("separation", 4)
	mv.add_child(mrow)
	var center_btn := _button("Centre (C)", g.reset_view)
	center_btn.tooltip_text = "Back to the town with the default angle and zoom. Press again to see the whole map."
	center_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mrow.add_child(center_btn)
	log_btn = _button("Log (L)", toggle_log)
	log_btn.tooltip_text = "All notifications and the problems that are open right now."
	log_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mrow.add_child(log_btn)
	minimap_panel.anchor_left = 1.0
	minimap_panel.anchor_right = 1.0
	minimap_panel.anchor_top = 1.0
	minimap_panel.anchor_bottom = 1.0
	minimap_panel.offset_right = -8.0
	minimap_panel.offset_bottom = -52.0
	minimap_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	minimap_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	add_child(minimap_panel)

	# ---- statistics
	stats = _panel(0.94)
	stats.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	stats.grow_vertical = Control.GROW_DIRECTION_BEGIN
	stats.position = Vector2(8, -60)
	stats.visible = false
	add_child(stats)
	var sv := VBoxContainer.new()
	stats.add_child(sv)
	stats_text = _rich(440, 13)
	sv.add_child(stats_text)
	var sc := _button("Close", toggle_stats)
	sc.size_flags_horizontal = Control.SIZE_SHRINK_END
	sv.add_child(sc)

	_build_help()
	_build_log()
	_build_menu()

	file_dialog = FileDialog.new()
	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	file_dialog.use_native_dialog = true
	file_dialog.filters = PackedStringArray(["*.json ; GoCarTraffic save game"])
	file_dialog.file_selected.connect(_on_file_selected)
	add_child(file_dialog)
	refresh()


func _build_help() -> void:
	help = _panel(0.97)
	help.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	help.grow_horizontal = Control.GROW_DIRECTION_BOTH
	help.grow_vertical = Control.GROW_DIRECTION_BOTH
	help.visible = false
	add_child(help)
	var hv := VBoxContainer.new()
	help.add_child(hv)
	var tabs := TabContainer.new()
	tabs.custom_minimum_size = Vector2(800, 560)
	hv.add_child(tabs)
	for page in [["How to play", HELP], ["Bus lines", Advisor.BUS_TIPS]]:
		var rt := _rich(780, 14)
		rt.name = page[0]
		rt.text = page[1]
		tabs.add_child(rt)
	var ok := _button("Close", toggle_help)
	ok.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	ok.custom_minimum_size = Vector2(160, 34)
	hv.add_child(ok)


func _slider(box: VBoxContainer, title: String, left: String, right: String, value: float) -> HSlider:
	box.add_child(_small(title, Color(0.9, 0.92, 0.95)))
	var row := HBoxContainer.new()
	var l := _small(left)
	l.custom_minimum_size = Vector2(150, 0)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(l)
	var s := HSlider.new()
	s.min_value = 0.0
	s.max_value = 1.0
	s.step = 0.05
	s.value = value
	s.custom_minimum_size = Vector2(200, 20)
	s.focus_mode = Control.FOCUS_NONE
	row.add_child(s)
	row.add_child(_small(right))
	box.add_child(row)
	return s


func _build_menu() -> void:
	menu = _panel(0.97)
	menu.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	menu.grow_horizontal = Control.GROW_DIRECTION_BOTH
	menu.grow_vertical = Control.GROW_DIRECTION_BOTH
	menu.visible = false
	add_child(menu)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	menu.add_child(v)
	var title := Label.new()
	title.text = "GoCarTraffic"
	title.add_theme_font_size_override("font_size", 26)
	v.add_child(title)
	v.add_child(_small("Build roads, cycle paths and bus lines so that a growing town keeps moving.", Color(0.85, 0.88, 0.92)))

	resume_row = HBoxContainer.new()
	resume_row.add_theme_constant_override("separation", 8)
	v.add_child(resume_row)
	var resume := _button("Resume", show_menu.bind(false))
	resume.custom_minimum_size = Vector2(120, 34)
	resume_row.add_child(resume)
	var save := _button("Save game ...", g.save_game)
	save.tooltip_text = "Ctrl+S. In the browser the save is downloaded as a file; it also loads in the desktop edition."
	resume_row.add_child(save)
	var load_btn := _button("Load game ...", g.request_load)
	load_btn.tooltip_text = "Ctrl+O. You can also drop a save file onto the window."
	v.add_child(load_btn)
	load_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	v.add_child(_small("Saves keep the map, roads, buildings, bus lines and credits. Vehicles on the road are not stored: after loading everybody starts from home.", Color(0.6, 0.66, 0.72)))

	menu_pause_check = CheckBox.new()
	menu_pause_check.text = "Pause the game when a new problem appears"
	menu_pause_check.focus_mode = Control.FOCUS_NONE
	menu_pause_check.button_pressed = Alerts.pause_enabled
	menu_pause_check.toggled.connect(_on_pause_toggled)
	v.add_child(menu_pause_check)

	v.add_child(HSeparator.new())
	v.add_child(_heading("New game"))
	var row := HBoxContainer.new()
	row.add_child(_small("Map number", Color(0.9, 0.92, 0.95)))
	seed_edit = LineEdit.new()
	seed_edit.text = str(g.world.seed_value)
	seed_edit.custom_minimum_size = Vector2(110, 0)
	row.add_child(seed_edit)
	row.add_child(_button("Random", func(): seed_edit.text = str(randi() % 1000000 + 1)))
	v.add_child(row)
	compact_slider = _slider(v, "Where do new buildings appear?", "anywhere on the map", "close to the town", g.compact)
	cluster_slider = _slider(v, "How are building types arranged?", "mixed all over town", "one district per type", g.cluster)
	var row2 := HBoxContainer.new()
	row2.add_child(_small("Length of a day", Color(0.9, 0.92, 0.95)))
	day_option = OptionButton.new()
	day_option.focus_mode = Control.FOCUS_NONE
	for k in Cfg.DAY_NAMES.size():
		day_option.add_item(Cfg.DAY_NAMES[k])
		if is_equal_approx(Cfg.DAY_OPTIONS[k], g.day_len):
			day_option.selected = k
	row2.add_child(day_option)
	v.add_child(row2)
	v.add_child(_small("Travel is always to scale (1 tile = 20 m, cars up to 50 km/h). The day length only sets how tightly\nthe inhabitants' daily routine is packed: shorter days mean more trips at once and heavier traffic.", Color(0.6, 0.66, 0.72)))
	var start := _button("Start new game", _on_start)
	start.custom_minimum_size = Vector2(200, 38)
	start.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	v.add_child(start)


func _on_start() -> void:
	g.start_new({
		"seed": int(seed_edit.text) if seed_edit.text.is_valid_int() else 0,
		"compact": compact_slider.value,
		"cluster": cluster_slider.value,
		"day_len": Cfg.DAY_OPTIONS[day_option.selected],
	})


func show_menu(on: bool) -> void:
	if not on and not g.started:
		return
	menu.visible = on
	resume_row.visible = g.started
	if on:
		help.visible = false
		log_panel.visible = false
		set_cost_tag("")


func toggle_help() -> void:
	help.visible = not help.visible


func _on_pause_toggled(on: bool) -> void:
	Alerts.pause_enabled = on
	if pause_check != null:
		pause_check.set_pressed_no_signal(on)
	if menu_pause_check != null:
		menu_pause_check.set_pressed_no_signal(on)


# ------------------------------------------------------------ notifications

func _build_log() -> void:
	log_panel = _panel(0.97)
	log_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	log_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	log_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	log_panel.visible = false
	add_child(log_panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	log_panel.add_child(v)
	var title := Label.new()
	title.text = "Notifications and problems"
	title.add_theme_font_size_override("font_size", 20)
	v.add_child(title)
	pause_check = CheckButton.new()
	pause_check.text = "Pause the game when a new problem appears"
	pause_check.focus_mode = Control.FOCUS_NONE
	pause_check.button_pressed = Alerts.pause_enabled
	pause_check.toggled.connect(_on_pause_toggled)
	v.add_child(pause_check)
	v.add_child(_heading("Open problems"))
	log_open_box = VBoxContainer.new()
	v.add_child(log_open_box)
	v.add_child(HSeparator.new())
	v.add_child(_heading("History, newest first"))
	var sc := ScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.custom_minimum_size = Vector2(620, 250)
	v.add_child(sc)
	log_hist_box = VBoxContainer.new()
	log_hist_box.add_theme_constant_override("separation", 3)
	log_hist_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(log_hist_box)
	var close := _button("Close", toggle_log)
	close.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	close.custom_minimum_size = Vector2(160, 34)
	v.add_child(close)


func toggle_log() -> void:
	log_panel.visible = not log_panel.visible
	if log_panel.visible:
		help.visible = false
		g.alerts.mark_read()
		_rebuild_log()


func _level_color(level: int) -> Color:
	return [Color(0.82, 0.88, 0.95), Color(1.0, 0.9, 0.5), Color(1.0, 0.62, 0.45)][level]


func _log_row(box: VBoxContainer, stamp: String, text: String, col: Color, tile: int, kind: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var st := _small(stamp)
	st.custom_minimum_size = Vector2(78, 0)
	row.add_child(st)
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(420, 0)
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", col)
	row.add_child(l)
	if tile >= 0:
		var b := _button("Show", g.goto_tile.bind(tile, kind))
		b.tooltip_text = "Move the view there"
		row.add_child(b)
	box.add_child(row)


func _rebuild_log() -> void:
	log_ver = g.alerts.version
	for c in log_open_box.get_children():
		c.queue_free()
	for c in log_hist_box.get_children():
		c.queue_free()
	if g.alerts.open.is_empty():
		log_open_box.add_child(_small("None. Everybody has a road and can get where they want to go.", Color(0.6, 0.85, 0.6)))
	for p in g.alerts.open:
		_log_row(log_open_box, p.short, p.text, Pointers.COLORS.get(p.kind, Color.WHITE), p.tile, p.kind)
	var hist: Array = g.alerts.history
	for k in range(hist.size() - 1, -1, -1):
		var e: Dictionary = hist[k]
		_log_row(log_hist_box, "Day %d %s" % [e.day, e.clock], e.text, _level_color(e.level), e.tile, e.kind)


func _toast_style(level: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.1, 0.13, 0.88)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	if level > 0:
		sb.border_color = _level_color(level)
		sb.set_border_width_all(2)
	return sb


## One line of the notification stack. It stays for a while (longer for
## problems), then fades out slowly. Everything also goes into the log.
func show_toast(e: Dictionary) -> void:
	var lvl: int = e.level
	for k in range(toasts.size() - 1, -1, -1):
		if toasts[k].node.text == e.text:
			toasts[k].node.queue_free()
			toasts.remove_at(k)
	var b := Button.new()
	b.text = e.text
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", 16)
	b.add_theme_color_override("font_color", _level_color(lvl))
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	for st in ["normal", "hover", "pressed", "focus"]:
		b.add_theme_stylebox_override(st, _toast_style(lvl))
	b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	if e.tile >= 0:
		b.tooltip_text = "Click to jump there"
		b.pressed.connect(g.goto_tile.bind(e.tile, e.kind))
	else:
		b.mouse_filter = Control.MOUSE_FILTER_IGNORE
	toast_box.add_child(b)
	toasts.append({"node": b, "age": 0.0, "hold": Cfg.TOAST_HOLD[lvl], "fade": Cfg.TOAST_FADE[lvl]})
	while toasts.size() > 5:
		toasts[0].node.queue_free()
		toasts.remove_at(0)


## Plain message (build errors, daily summary, ...): goes through the same
## notification system.
func toast(text: String) -> void:
	g.alerts.notify(text)


func set_cost_tag(text: String) -> void:
	cost_text = text
	_update_cost_tag()


## The tag follows the cursor, but only while the cursor is over the map.
func _update_cost_tag() -> void:
	var on_map: bool = get_viewport().get_mouse_position().distance_to(g.last_map_mouse) <= 4.0 and not menu.visible
	var want: bool = cost_text != "" and on_map
	if want and cost_lbl.text != cost_text:
		cost_lbl.text = cost_text
		cost_tag.reset_size()
	cost_tag.visible = want
	if want:
		var vp := get_viewport().get_visible_rect().size
		var p := get_viewport().get_mouse_position() + Vector2(22, 26)
		p.x = clampf(p.x, 4.0, maxf(4.0, vp.x - cost_tag.size.x - 4.0))
		p.y = clampf(p.y, 4.0, maxf(4.0, vp.y - cost_tag.size.y - 4.0))
		cost_tag.position = p


func _process(delta: float) -> void:
	var k := 0
	while k < toasts.size():
		var t: Dictionary = toasts[k]
		if not t.node.is_hovered():
			t.age += delta
		var over: float = t.age - t.hold
		if over > t.fade:
			t.node.queue_free()
			toasts.remove_at(k)
			continue
		t.node.modulate.a = 1.0 if over <= 0.0 else 1.0 - over / t.fade
		k += 1
	_update_cost_tag()


func toggle_stats() -> void:
	stats.visible = not stats.visible
	if stats.visible:
		stats_text.text = g.stats_text()


func set_hint(text: String) -> void:
	hint.text = text


# -------------------------------------------------------------------- files

func ask_save_path(fname: String) -> void:
	file_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	file_dialog.title = "Save game"
	file_dialog.current_file = fname
	file_dialog.popup_centered_ratio(0.6)


func ask_load() -> void:
	if OS.has_feature("web"):
		# Let the browser show its own file picker and hand the text back.
		_js_callback = JavaScriptBridge.create_callback(_on_web_file)
		JavaScriptBridge.get_interface("window").gocartrafficLoaded = _js_callback
		JavaScriptBridge.eval("""
			(function () {
				var input = document.createElement('input');
				input.type = 'file';
				input.accept = '.json,application/json';
				input.onchange = function () {
					var file = input.files[0];
					if (!file) { return; }
					var reader = new FileReader();
					reader.onload = function () { window.gocartrafficLoaded(reader.result); };
					reader.readAsText(file);
				};
				input.click();
			})();
		""", true)
		return
	file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	file_dialog.title = "Load game"
	file_dialog.popup_centered_ratio(0.6)


func _on_web_file(args: Array) -> void:
	g.load_text(str(args[0]))


func _on_file_selected(path: String) -> void:
	if file_dialog.file_mode == FileDialog.FILE_MODE_SAVE_FILE:
		g.save_to(path if path.get_extension() != "" else path + ".json")
	else:
		g.load_from(path)


# ------------------------------------------------------------------ refresh

func refresh() -> void:
	labels["credits"].text = str(g.credits)
	var h: float = g.hour()
	if g.day_len >= 86000.0:
		labels["time"].text = "Day %d  %02d:%02d" % [g.day + 1, int(h), int(fmod(h, 1.0) * 60.0)]
	else:
		labels["time"].text = "Day %d, %s" % [g.day + 1, g.phase_name()]
	day_bar.value = h
	labels["pop"].text = "%d / %d" % [g.city.population, g.traffic.count + g.traffic.bikes]
	var r: float = g.on_time_ratio()
	labels["ontime"].text = "%d%%" % int(round(r * 100.0))
	labels["ontime"].add_theme_color_override("font_color", Color(0.95, 0.35, 0.3).lerp(Color(0.45, 0.9, 0.45), clampf((r - 0.4) / 0.5, 0.0, 1.0)))
	labels["delay"].text = "%.1fx" % g.delay_ema
	labels["score"].text = str(g.delivered)
	var left: float = g.undo_left()
	labels["undo"].text = "Ctrl+Z: free undo, %d s left" % int(ceil(left)) if left > 0.0 else ""
	for k in speed_buttons.size():
		speed_buttons[k].set_pressed_no_signal(k == g.speed_idx)
	for k in tool_buttons.size():
		tool_buttons[k].set_pressed_no_signal(k == g.tool)
	overlay_btn.text = "Traffic: %s (T)" % ["off", "jams", "volume"][g.overlay_mode]
	inspector.text = g.inspect_text()
	_refresh_advisor()
	_refresh_lines()
	if stats.visible:
		stats_text.text = g.stats_text()
	paused_lbl.visible = g.started and g.speed_idx == 0 and not menu.visible
	log_btn.text = "Log (L)" if g.alerts.unread == 0 else "Log (L) - %d new" % g.alerts.unread
	if log_panel.visible:
		g.alerts.mark_read()
		if log_ver != g.alerts.version:
			_rebuild_log()
	var room: float = get_viewport().get_visible_rect().size.y - 170.0 - minimap_panel.get_combined_minimum_size().y - 12.0
	right_scroll.custom_minimum_size.y = clampf(right_box.get_combined_minimum_size().y, 60.0, maxf(room, 60.0))


func _refresh_advisor() -> void:
	var sig := ""
	for d in g.issues:
		sig += "%d%s;" % [d.tile, d.kind]
	if sig == advisor_sig:
		return
	advisor_sig = sig
	for c in advisor_box.get_children():
		c.queue_free()
	if g.issues.is_empty():
		advisor_box.add_child(_small("No jams right now. Watch the rush hours.", Color(0.6, 0.85, 0.6)))
		return
	for d in g.issues:
		var b := _button("> " + d.title, g.focus_issue.bind(d.tile))
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.add_theme_color_override("font_color", Color(1.0, 0.6, 0.4))
		b.tooltip_text = "Click to jump there"
		advisor_box.add_child(b)
		var l := _small(d.text, Color(0.9, 0.9, 0.9))
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size = Vector2(318, 0)
		advisor_box.add_child(l)


func _refresh_lines() -> void:
	var tr = g.transit
	var sig := ""
	for l in tr.lines:
		sig += "%d;" % l.id
	if sig != lines_sig:
		lines_sig = sig
		line_labels.clear()
		for c in lines_box.get_children():
			c.queue_free()
		if tr.lines.is_empty():
			lines_box.add_child(_small("None yet. Place bus stops (6), then connect\nthem with a bus line (7). Help has layout tips."))
		for l in tr.lines:
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 3)
			var sw := ColorRect.new()
			sw.color = l.color
			sw.custom_minimum_size = Vector2(10, 10)
			sw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			row.add_child(sw)
			var lab := _button("", g.select_line.bind(l))
			lab.flat = true
			lab.alignment = HORIZONTAL_ALIGNMENT_LEFT
			lab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			lab.add_theme_font_size_override("font_size", 13)
			lab.tooltip_text = "Show this line's statistics"
			row.add_child(lab)
			line_labels[l.id] = lab
			var ed := _button("edit", g.line_edit.bind(l))
			ed.tooltip_text = "Add or remove stops"
			row.add_child(ed)
			var plus := _button("+", g.line_add_bus.bind(l))
			plus.tooltip_text = "Buy another bus (%d credits)" % Cfg.COST_BUS
			row.add_child(plus)
			var minus := _button("-", g.line_remove_bus.bind(l))
			minus.tooltip_text = "Sell a bus (full refund)"
			row.add_child(minus)
			var del := _button("x", g.line_delete.bind(l))
			del.tooltip_text = "Delete this line (buses are refunded in full)"
			row.add_child(del)
			lines_box.add_child(row)
	for l in tr.lines:
		var lab: Button = line_labels.get(l.id)
		if lab != null:
			var n: int = tr.bus_count(l)
			var txt := "Line %d: %d bus%s, %d riding" % [l.id, n, "" if n == 1 else "es", tr.riders(l)]
			if not l.ok:
				txt = "Line %d: not connected!" % l.id
			lab.text = txt
