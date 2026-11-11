extends CanvasLayer
## Heads-up display, built entirely in code.

const Cfg = preload("res://scripts/cfg.gd")

const HELP := """[font_size=22][b]GoCarTraffic[/b][/font_size]
A town is growing on this map. People want to drive to work, to the shops and out in the evening. [b]Every trip that arrives within its time limit earns credits[/b] - late trips and trips that cannot be made earn nothing. Move as many people as fast as you can.

[b]Build[/b]
[color=#ffd866]2 Road[/color]  drag to draw a street (one lane each way). Bridges and steep hills cost more; hills are slow.
[color=#ffd866]3 Add lane[/color]  drag along a road to widen it (up to 3 lanes each way).
[color=#ffd866]4 Bulldoze[/color]  remove roads or bus stops (50% refund).
[color=#ffd866]5 Bus stop[/color]  place stops on roads; people walk up to 5 tiles to a stop.
[color=#ffd866]6 Bus line[/color]  click stops in order, then Enter or right-click. Buses loop along the stops. Households own only 1-2 cars for 3-4 people - buses carry everyone who has no car free, and take cars off the road.
[color=#ffd866]1 Inspect[/color]  click a building, road or stop to see what is going on there.

[b]Why do jams happen?[/b]  Press [color=#ffd866]T[/color] for the traffic view and read the [i]Traffic advisor[/i].
- [b]Junctions[/b]: crossing streams must take turns, so a junction carries less than the roads leading to it.
- [b]Merges and lane drops[/b]: more lanes flowing in than out.
- [b]Spillback[/b]: a full road blocks the junction behind it - the red line you see is usually the symptom, the cause is at its front end.
- [b]Single crossings[/b]: one bridge for the whole town.
- [b]Peaks[/b]: everybody commutes at the same time (around 7:00 and 16:00).
Drivers avoid congested roads if you give them an alternative.

[b]Camera[/b]  WASD / arrows or middle-mouse drag to pan, wheel to zoom, Q / E to rotate.
[b]Time[/b]  Space pauses, + and - change speed.   [b]F1[/b] shows this help again."""

var g
var labels := {}
var tool_buttons: Array = []
var speed_buttons: Array = []
var overlay_btn: Button
var inspector: RichTextLabel
var advisor_box: VBoxContainer
var advisor_sig := "?"
var lines_box: VBoxContainer
var lines_sig := "?"
var line_labels := {}
var hint: Label
var toast_lbl: Label
var toast_tween: Tween
var help: PanelContainer


func _panel_style(alpha: float = 0.88) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.1, 0.13, alpha)
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(10)
	return sb


func _panel() -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _panel_style())
	return p


func _button(text: String, cb: Callable, toggle: bool = false) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.toggle_mode = toggle
	b.pressed.connect(cb)
	return b


func _stat(box: HBoxContainer, key: String, title: String, tip: String) -> void:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	v.tooltip_text = tip
	var t := Label.new()
	t.text = title
	t.add_theme_font_size_override("font_size", 11)
	t.add_theme_color_override("font_color", Color(0.65, 0.72, 0.8))
	var l := Label.new()
	l.text = "-"
	l.add_theme_font_size_override("font_size", 18)
	v.add_child(t)
	v.add_child(l)
	box.add_child(v)
	labels[key] = l


func setup(game) -> void:
	g = game
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
	bar.add_theme_constant_override("separation", 22)
	top.add_child(bar)
	_stat(bar, "credits", "CREDITS", "Earned by every trip that arrives within its time limit.")
	_stat(bar, "time", "TIME", "Rush hours are around 7:00 and 16:00.")
	_stat(bar, "pop", "POPULATION", "People living in town / vehicles on the road right now.")
	_stat(bar, "ontime", "ON TIME", "Share of recent travellers who arrived within the limit. Unserved trips count as failed.")
	_stat(bar, "delay", "TRAVEL TIME", "Recent travel time compared with an empty road. 1.0x = no delay at all.")
	_stat(bar, "score", "PEOPLE MOVED", "Your score: travellers delivered on time since the start.")
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_child(sp)
	var speeds := HBoxContainer.new()
	speeds.add_theme_constant_override("separation", 2)
	bar.add_child(speeds)
	for s in [["II", 0.0], ["1x", 1.0], ["2x", 2.0], ["4x", 4.0]]:
		var b := _button(s[0], g.set_speed.bind(s[1]), true)
		b.custom_minimum_size = Vector2(38, 0)
		b.set_meta("speed", s[1])
		speeds.add_child(b)
		speed_buttons.append(b)
	overlay_btn = _button("Traffic view (T)", g.toggle_overlay, true)
	bar.add_child(overlay_btn)
	bar.add_child(_button("Help (F1)", toggle_help))
	bar.add_child(_button("New map", g.new_map))

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
		"1  Inspect", "2  Road  (%d / tile)" % Cfg.COST_ROAD, "3  Add lane", "4  Bulldoze",
		"5  Bus stop  (%d)" % Cfg.COST_STOP, "6  Bus line  (%d / bus)" % Cfg.COST_BUS,
	]
	for k in names.size():
		var b := _button(names[k], g.set_tool.bind(k), true)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size = Vector2(170, 34)
		tv.add_child(b)
		tool_buttons.append(b)

	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mid.add_child(gap)

	var right := _panel()
	right.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	right.custom_minimum_size = Vector2(330, 0)
	mid.add_child(right)
	var rv := VBoxContainer.new()
	rv.add_theme_constant_override("separation", 6)
	right.add_child(rv)
	rv.add_child(_heading("Inspector"))
	inspector = RichTextLabel.new()
	inspector.bbcode_enabled = true
	inspector.fit_content = true
	inspector.scroll_active = false
	inspector.custom_minimum_size = Vector2(310, 40)
	inspector.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inspector.add_theme_font_size_override("normal_font_size", 13)
	inspector.add_theme_font_size_override("bold_font_size", 13)
	rv.add_child(inspector)
	rv.add_child(HSeparator.new())
	rv.add_child(_heading("Traffic advisor"))
	advisor_box = VBoxContainer.new()
	rv.add_child(advisor_box)
	rv.add_child(HSeparator.new())
	rv.add_child(_heading("Bus lines"))
	lines_box = VBoxContainer.new()
	rv.add_child(lines_box)

	# ---- bottom hint
	var hp := _panel()
	hp.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	col.add_child(hp)
	hint = Label.new()
	hint.add_theme_font_size_override("font_size", 14)
	hp.add_child(hint)

	# ---- toast
	toast_lbl = Label.new()
	toast_lbl.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	toast_lbl.position.y = 86
	toast_lbl.grow_horizontal = Control.GROW_DIRECTION_BOTH
	toast_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast_lbl.add_theme_font_size_override("font_size", 20)
	toast_lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	toast_lbl.add_theme_constant_override("outline_size", 6)
	toast_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	toast_lbl.modulate.a = 0.0
	add_child(toast_lbl)

	# ---- help
	help = PanelContainer.new()
	help.add_theme_stylebox_override("panel", _panel_style(0.96))
	help.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	help.grow_horizontal = Control.GROW_DIRECTION_BOTH
	help.grow_vertical = Control.GROW_DIRECTION_BOTH
	add_child(help)
	var hv := VBoxContainer.new()
	help.add_child(hv)
	var rt := RichTextLabel.new()
	rt.bbcode_enabled = true
	rt.fit_content = true
	rt.scroll_active = false
	rt.custom_minimum_size = Vector2(760, 0)
	rt.add_theme_font_size_override("normal_font_size", 14)
	rt.add_theme_font_size_override("bold_font_size", 14)
	rt.add_theme_font_size_override("italics_font_size", 14)
	rt.text = HELP
	hv.add_child(rt)
	var ok := _button("Start building", toggle_help)
	ok.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	ok.custom_minimum_size = Vector2(180, 36)
	hv.add_child(ok)
	refresh()


func _heading(text: String) -> Label:
	var l := Label.new()
	l.text = text.to_upper()
	l.add_theme_font_size_override("font_size", 11)
	l.add_theme_color_override("font_color", Color(0.65, 0.72, 0.8))
	return l


func toggle_help() -> void:
	help.visible = not help.visible


func toast(text: String) -> void:
	toast_lbl.text = text
	if toast_tween != null:
		toast_tween.kill()
	toast_lbl.modulate.a = 1.0
	toast_tween = create_tween()
	toast_tween.tween_interval(2.2)
	toast_tween.tween_property(toast_lbl, "modulate:a", 0.0, 0.8)


func set_hint(text: String) -> void:
	hint.text = text


func refresh() -> void:
	labels["credits"].text = str(g.credits)
	var h: float = g.hour()
	labels["time"].text = "Day %d  %02d:%02d" % [g.day + 1, int(h), int(fmod(h, 1.0) * 60.0)]
	labels["pop"].text = "%d / %d" % [g.city.population, g.traffic.count]
	var r: float = g.on_time_ratio()
	labels["ontime"].text = "%d%%" % int(round(r * 100.0))
	labels["ontime"].add_theme_color_override("font_color", Color(0.95, 0.35, 0.3).lerp(Color(0.45, 0.9, 0.45), clampf((r - 0.4) / 0.5, 0.0, 1.0)))
	labels["delay"].text = "%.1fx" % g.delay_ema
	labels["score"].text = str(g.delivered)
	for b in speed_buttons:
		b.set_pressed_no_signal(is_equal_approx(b.get_meta("speed"), g.speed))
	for k in tool_buttons.size():
		tool_buttons[k].set_pressed_no_signal(k == g.tool)
	overlay_btn.set_pressed_no_signal(g.overlay_on)
	inspector.text = g.inspect_text()
	_refresh_advisor()
	_refresh_lines()


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
		var l := Label.new()
		l.text = "No jams right now. Watch the rush hours\n(7:00 and 16:00)."
		l.add_theme_font_size_override("font_size", 13)
		l.add_theme_color_override("font_color", Color(0.6, 0.85, 0.6))
		advisor_box.add_child(l)
		return
	for d in g.issues:
		var b := _button("> " + d.title, g.focus_issue.bind(d.tile))
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.add_theme_color_override("font_color", Color(1.0, 0.6, 0.4))
		b.tooltip_text = "Click to jump there"
		advisor_box.add_child(b)
		var l := Label.new()
		l.text = d.text
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size = Vector2(310, 0)
		l.add_theme_font_size_override("font_size", 12)
		advisor_box.add_child(l)


func _refresh_lines() -> void:
	var tr = g.transit
	var sig := ""
	for l in tr.lines:
		sig += "%d:%d:%d:%s;" % [l.id, tr.bus_count(l), l.stops.size(), l.ok]
	if sig != lines_sig:
		lines_sig = sig
		line_labels.clear()
		for c in lines_box.get_children():
			c.queue_free()
		if tr.lines.is_empty():
			var e := Label.new()
			e.text = "None yet. Place bus stops (5), then\nconnect them with a bus line (6)."
			e.add_theme_font_size_override("font_size", 13)
			e.add_theme_color_override("font_color", Color(0.7, 0.75, 0.8))
			lines_box.add_child(e)
		for l in tr.lines:
			var row := HBoxContainer.new()
			var sw := ColorRect.new()
			sw.color = l.color
			sw.custom_minimum_size = Vector2(12, 12)
			sw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			row.add_child(sw)
			var lab := Label.new()
			lab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			lab.add_theme_font_size_override("font_size", 13)
			row.add_child(lab)
			line_labels[l.id] = lab
			var plus := _button("+bus", g.line_add_bus.bind(l))
			plus.tooltip_text = "Buy another bus (%d credits)" % Cfg.COST_BUS
			row.add_child(plus)
			row.add_child(_button("-", g.line_remove_bus.bind(l)))
			var del := _button("x", g.line_delete.bind(l))
			del.tooltip_text = "Delete this line"
			row.add_child(del)
			lines_box.add_child(row)
	for l in tr.lines:
		var lab: Label = line_labels.get(l.id)
		if lab != null:
			var txt := "Line %d: %d bus%s, %d riding" % [l.id, tr.bus_count(l), "" if tr.bus_count(l) == 1 else "es", tr.riders(l)]
			if not l.ok:
				txt = "Line %d: stops not connected by road!" % l.id
			lab.text = txt
