extends Node3D
## Main scene script: owns the simulation, the tools and the game clock.

const Cfg = preload("res://scripts/cfg.gd")
const World = preload("res://scripts/world.gd")
const Roads = preload("res://scripts/roads.gd")
const Traffic = preload("res://scripts/traffic.gd")
const City = preload("res://scripts/city.gd")
const Transit = preload("res://scripts/transit.gd")
const Advisor = preload("res://scripts/advisor.gd")
const View = preload("res://scripts/view.gd")
const CameraRig = preload("res://scripts/camera_rig.gd")
const Hud = preload("res://scripts/hud.gd")
const W := Cfg.W
const H := Cfg.H
const SAVE_VERSION := 1

enum {T_INSPECT, T_ROAD, T_LANE, T_BIKEPATH, T_BIKELANE, T_STOP, T_LINE, T_BULLDOZE}

## Settings handed from one scene load to the next:
## {seed, compact, cluster, day_len, play, load}
static var boot := {}

var world
var roads
var traffic
var city
var transit
var advisor
var view
var rig
var hud

# Settings of this game
var compact := 0.6     # 0 = buildings appear anywhere, 1 = right next to the town
var cluster := 0.7     # 0 = all building types mixed, 1 = strict zoning
var day_len := 1800.0
var started := false

var now := 0.0
var ui_time := 0.0
var speed_idx := 1
var last_speed := 1
var credits: int = Cfg.START_CREDITS
var day := 0
var events: Array = []
var walkers: Array = []

var tool := T_INSPECT
var hover := -1
var drag_start := -1
var drag_path: Array = []
var drag_kind := ""
var line_draft: Array = []
var edit_line = null
var overlay_mode := 0
var overlay_auto := false
var selected := -1
var selected_line = null
var undo_stack: Array = []

var ok_w := 0.0
var tot_w := 0.0
var delay_ema := 1.0
var delivered := 0
var earned_today := 0
var unserved_today := 0
var late_today := 0
var ok_today := 0
var mode_today: Array = [0, 0, 0, 0]
var mode_total: Array = [0, 0, 0, 0]
var issues: Array = []
var next_milestone := 100

var _t_hud := 0.0
var _t_overlay := 0.0
var _t_advisor := 0.0
var _t_weights := 0.0
var _roads_dirty := false


func _ready() -> void:
	var b := boot
	boot = {}
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--seed="):
			b["seed"] = int(a.substr(7))
			b["play"] = true
	var save = b.get("load")
	if save != null:
		b = save.settings
		b["play"] = true
	compact = float(b.get("compact", compact))
	cluster = float(b.get("cluster", cluster))
	day_len = float(b.get("day_len", day_len))
	started = bool(b.get("play", false))
	var s := int(b.get("seed", 0))
	if s == 0:
		s = randi() % 1000000 + 1

	world = World.new()
	if save != null:
		world.from_save(save.world)
	else:
		world.generate(s)
	roads = Roads.new()
	roads.setup(world)
	traffic = Traffic.new()
	traffic.setup(roads)
	transit = Transit.new()
	transit.setup(self)
	city = City.new()
	city.setup(self)
	transit.city = city
	advisor = Advisor.new()
	traffic.on_arrive = city.on_vehicle_arrive
	traffic.on_lost = _on_vehicle_lost
	traffic.bus_arrive = transit.on_bus_arrive
	traffic.bus_depart = transit.on_bus_depart

	view = View.new()
	add_child(view)
	view.setup(self)
	rig = CameraRig.new()
	add_child(rig)
	if save != null:
		_apply_save(save)
	else:
		city.start()
	_frame_town()
	hud = Hud.new()
	add_child(hud)
	hud.setup(self)
	set_tool(T_INSPECT)
	get_window().files_dropped.connect(_on_files_dropped)
	if not started:
		hud.show_menu(true)


func _frame_town() -> void:
	if city.buildings.is_empty():
		return
	var c := Vector2.ZERO
	for b in city.buildings:
		c += Vector2(b.x, b.y)
	c /= city.buildings.size()
	rig.focus(Vector3(c.x, 0, c.y), 40.0)
	rig.dist = 40.0


func _on_vehicle_lost(v) -> void:
	if v.kind == Traffic.BUS:
		transit.on_bus_lost(v)
	else:
		city.on_vehicle_lost(v)


# --------------------------------------------------------------------- time

func hour() -> float:
	return fmod(Cfg.START_HOUR + now / day_len * 24.0, 24.0)


func day_start() -> float:
	return (day * 24.0 - Cfg.START_HOUR) / 24.0 * day_len


func phase_name() -> String:
	var h := hour()
	if h < 5.0 or h >= 22.0:
		return "night"
	if h < 9.5:
		return "morning rush"
	if h < 15.0:
		return "daytime"
	if h < 18.5:
		return "evening rush"
	return "evening"


func schedule(t: float, c: Callable) -> void:
	var lo := 0
	var hi := events.size()
	while lo < hi:
		var mid := (lo + hi) >> 1
		if events[mid][0] > t:
			lo = mid + 1
		else:
			hi = mid
	events.insert(lo, [t, c])


func add_walker(pts: PackedVector2Array, n: int, dur: float) -> void:
	if walkers.size() < 600 and dur > 0.5:
		walkers.append([pts, n, now, dur, randi() % 8])


func sim_step(dt: float) -> void:
	now += dt
	while not events.is_empty() and events[-1][0] <= now:
		var e = events.pop_back()
		e[1].call()
	city.tick(dt)
	transit.tick(dt)
	traffic.step(dt)
	_t_weights -= dt
	if _t_weights <= 0.0:
		_t_weights = 20.0
		traffic.update_weights()
	var d := int(floor((Cfg.START_HOUR + now / day_len * 24.0) / 24.0))
	if d > day:
		day = d
		hud.toast("Day %d - yesterday: %d on time, %d late, %d could not travel, %d credits earned" % [day + 1, ok_today, late_today, unserved_today, earned_today])
		earned_today = 0
		unserved_today = 0
		late_today = 0
		ok_today = 0
		mode_today = [0, 0, 0, 0]
		city.new_day()
		transit.new_day()
		traffic.new_day()


func running() -> bool:
	return started and speed_idx > 0 and not hud.menu.visible


func _process(delta: float) -> void:
	delta = minf(delta, 0.1)
	if running():
		ui_time += delta
		var gs: float = delta * Cfg.SPEEDS[speed_idx]
		var steps := clampi(int(ceil(gs / Cfg.MAX_STEP)), 1, 14)
		for k in steps:
			sim_step(gs / steps)
	if _roads_dirty:
		_apply_road_change()
	if transit.dirty:
		transit.dirty = false
		view.rebuild_transit()
	view.update_vehicles(delta)
	view.set_time_of_day(hour())
	_t_hud -= delta
	if _t_hud <= 0.0:
		_t_hud = 0.25
		hud.refresh()
		view.update_stop_labels()
		view.update_marks()
		_update_route()
	_t_overlay -= delta
	if overlay_mode > 0 and _t_overlay <= 0.0:
		_t_overlay = 0.4 if overlay_mode == 1 else 1.5
		view.rebuild_overlay(overlay_mode)
	_t_advisor -= delta
	if _t_advisor <= 0.0:
		_t_advisor = 1.5
		issues = advisor.analyze(self)


# -------------------------------------------------------------------- stats

func on_time_ratio() -> float:
	return 1.0 if tot_w < 1.0 else ok_w / tot_w


func record_leg(leg, elapsed: float, ok: bool) -> void:
	ok_w = ok_w * 0.992 + (leg.n if ok else 0)
	tot_w = tot_w * 0.992 + leg.n
	if leg.mode == Cfg.M_CAR:
		delay_ema += (clampf(elapsed / maxf(leg.ff, 1.0), 0.5, 6.0) - delay_ema) * 0.04
	mode_today[leg.mode] += leg.n
	mode_total[leg.mode] += leg.n
	if ok:
		var reward := int(round(leg.n * (4.0 + 0.5 * leg.dist)))
		credits += reward
		earned_today += reward
		delivered += leg.n
		ok_today += leg.n
		if delivered >= next_milestone:
			hud.toast("%d people moved on time!" % next_milestone)
			next_milestone *= 5 if str(next_milestone)[0] == "1" else 2
	else:
		late_today += leg.n


func record_unserved(leg) -> void:
	ok_w = ok_w * 0.992
	tot_w = tot_w * 0.992 + leg.n
	unserved_today += leg.n


func on_building_added(b) -> void:
	view.add_building(b, now > 0.5 and not city.loading)


# -------------------------------------------------------------------- tools

func set_tool(t: int) -> void:
	tool = t
	drag_start = -1
	drag_path.clear()
	line_draft.clear()
	edit_line = null
	_end_auto_overlay()
	_refresh_preview()


func set_speed(idx: int) -> void:
	if idx > 0:
		last_speed = idx
	speed_idx = idx


func set_overlay(mode: int) -> void:
	overlay_mode = mode
	overlay_auto = false
	view.overlay_mi.visible = mode > 0
	_t_overlay = 0.0


func cycle_overlay() -> void:
	set_overlay((overlay_mode + 1) % 3)


func _end_auto_overlay() -> void:
	if overlay_auto:
		set_overlay(0)


func focus_issue(i: int) -> void:
	rig.focus(Vector3(i % W + 0.5, 0, i / W + 0.5), minf(rig.goal_dist, 22.0))
	selected = i
	selected_line = null
	if overlay_mode != 1:
		# Show the jam colours while the player looks at the problem; they go
		# away again with the selection.
		set_overlay(1)
		overlay_auto = true
	_refresh_preview()


func select_line(l) -> void:
	selected_line = l
	selected = -1
	_refresh_preview()


func spend(cost: int) -> bool:
	if cost > credits:
		hud.toast("Not enough credits (%d needed)" % cost)
		return false
	credits -= cost
	return true


func _apply_road_change() -> void:
	_roads_dirty = false
	city.update_access()
	transit.on_roads_changed()
	view.rebuild_roads()
	if overlay_mode > 0:
		view.rebuild_overlay(overlay_mode)


func path_blocked(path: Array) -> bool:
	for i in path:
		if city.bmap.has(i):
			return true
	return false


func _push_undo(entry: Dictionary) -> void:
	entry["t"] = ui_time
	undo_stack.append(entry)
	if undo_stack.size() > 40:
		undo_stack.pop_front()


func undo_left() -> float:
	while not undo_stack.is_empty() and ui_time - undo_stack[-1].t > Cfg.UNDO_SECONDS:
		undo_stack.pop_back()
	if undo_stack.is_empty():
		return 0.0
	return Cfg.UNDO_SECONDS - (ui_time - undo_stack[-1].t)


## Ctrl+Z: takes back the last thing built, at no cost, if it is recent enough.
func undo() -> void:
	if undo_left() <= 0.0:
		undo_stack.clear()
		hud.toast("Nothing to undo - undo works for %d seconds after building. Use the bulldozer instead." % int(Cfg.UNDO_SECONDS))
		return
	var e: Dictionary = undo_stack.pop_back()
	credits += int(e.get("cost", 0))
	match e.kind:
		"build":
			var res: Dictionary = roads.revert(e.rec)
			for c in res.unlinked:
				traffic.on_unlink(c[0], c[1])
			for i in res.removed:
				if transit.stops.has(i):
					transit.remove_stop(i)
				traffic.on_tile_removed(i)
			for i in res.changed:
				traffic.on_lanes_changed(i)
			_roads_dirty = true
		"lanes":
			for i in e.tiles:
				if roads.remove_lane(i):
					traffic.on_lanes_changed(i)
			view.rebuild_roads()
		"bikelanes":
			for i in e.tiles:
				if roads.remove_bike_lane(i):
					traffic.on_lanes_changed(i)
			_roads_dirty = true
		"stop":
			transit.remove_stop(e.tile)
			if not line_draft.is_empty() and line_draft[-1] == e.tile:
				line_draft.pop_back()
		"draft":
			if not line_draft.is_empty() and line_draft[-1] == e.tile:
				line_draft.pop_back()
		"line":
			if transit.lines.has(e.line):
				credits += transit.bus_count(e.line) * Cfg.COST_BUS - int(e.get("cost", 0))
				if selected_line == e.line:
					selected_line = null
				transit.remove_line(e.line)
	hud.toast("Undone - %d credits returned" % int(e.get("cost", 0)) if int(e.get("cost", 0)) > 0 else "Undone")
	_refresh_preview()


func build_road(path: Array, bike_path: bool = false) -> bool:
	if path.is_empty() or path_blocked(path):
		hud.toast("Buildings are in the way")
		return false
	var cost: int = roads.plan_cost(path, bike_path)
	if not spend(cost):
		return false
	var rec: Dictionary = roads.build(path, bike_path)
	if rec.tiles.is_empty() and rec.conns.is_empty():
		return false
	for i in path:
		view.clear_trees(i)
		traffic.on_lanes_changed(i)
	_push_undo({"kind": "build", "rec": rec, "cost": cost})
	_roads_dirty = true
	return true


func add_lanes(path: Array) -> bool:
	var cost: int = roads.upgrade_cost(path)
	if cost == 0 or not spend(cost):
		return false
	var changed: Array = roads.add_lanes(path)
	for i in changed:
		traffic.on_lanes_changed(i)
	_push_undo({"kind": "lanes", "tiles": changed, "cost": cost})
	view.rebuild_roads()
	return true


func add_bike_lanes(path: Array) -> bool:
	var cost: int = roads.bikelane_cost(path)
	if cost == 0 or not spend(cost):
		return false
	var changed: Array = roads.add_bike_lanes(path)
	for i in changed:
		traffic.on_lanes_changed(i)
	_push_undo({"kind": "bikelanes", "tiles": changed, "cost": cost})
	_roads_dirty = true
	return true


## What a click with the bulldozer removes on a tile: the topmost layer.
func bulldoze_target(i: int) -> Dictionary:
	if i < 0:
		return {}
	if transit.stops.has(i):
		return {"kind": "stop", "name": "the bus stop", "refund": int(Cfg.COST_STOP * Cfg.REFUND_STOP)}
	if roads.lanes[i] > 0 and roads.bike[i] == 1:
		return {"kind": "bikelane", "name": "the bike lanes", "refund": 0}
	if roads.lanes[i] > 1:
		return {"kind": "lane", "name": "one lane per direction", "refund": int(roads.road_cost(i) * Cfg.REFUND_ROAD)}
	if roads.lanes[i] == 1:
		return {"kind": "road", "name": "the road", "refund": int(roads.road_cost(i) * Cfg.REFUND_ROAD)}
	if roads.bike[i] == 2:
		return {"kind": "bikepath", "name": "the cycle path", "refund": int(roads.bikepath_cost(i) * Cfg.REFUND_ROAD)}
	return {}


func bulldoze(i: int, only_kind: String = "") -> void:
	var t := bulldoze_target(i)
	if t.is_empty() or (only_kind != "" and t.kind != only_kind):
		return
	credits += t.refund
	match t.kind:
		"stop":
			transit.remove_stop(i)
		"bikelane":
			roads.remove_bike_lane(i)
			traffic.on_lanes_changed(i)
			_roads_dirty = true
		"lane":
			roads.remove_lane(i)
			traffic.on_lanes_changed(i)
			view.rebuild_roads()
		_:
			roads.remove(i)
			traffic.on_tile_removed(i)
			if selected == i:
				selected = -1
			_roads_dirty = true


func add_stop(i: int, for_draft: bool = false) -> bool:
	if not roads.has(i):
		hud.toast("Bus stops must be placed on a road")
		return false
	if transit.stops.has(i):
		if for_draft:
			_push_undo({"kind": "draft", "tile": i})
		return true
	if not spend(Cfg.COST_STOP):
		return false
	transit.add_stop(i)
	_push_undo({"kind": "stop", "tile": i, "cost": Cfg.COST_STOP})
	return true


func finish_line() -> void:
	if edit_line != null:
		edit_line = null
		_refresh_preview()
		return
	if line_draft.size() < 2:
		if not line_draft.is_empty():
			hud.toast("A bus line needs at least two stops")
		line_draft.clear()
		_refresh_preview()
		return
	var l = transit.create_line(line_draft)
	line_draft.clear()
	var cost := 0
	if credits >= Cfg.COST_BUS:
		credits -= Cfg.COST_BUS
		cost = Cfg.COST_BUS
		transit.add_bus(l)
		hud.toast("Line %d opened with one bus. It serves all stops in both directions." % l.id)
	else:
		hud.toast("Line %d created without a bus - not enough credits (%d)" % [l.id, Cfg.COST_BUS])
	if not l.ok:
		hud.toast("Line %d: its stops are not connected by road" % l.id)
	_push_undo({"kind": "line", "line": l, "cost": cost})
	select_line(l)


func line_add_bus(l) -> void:
	if spend(Cfg.COST_BUS):
		transit.add_bus(l)


func line_remove_bus(l) -> void:
	if transit.remove_bus(l):
		credits += Cfg.COST_BUS


func line_delete(l) -> void:
	credits += transit.bus_count(l) * Cfg.COST_BUS
	if selected_line == l:
		selected_line = null
	if edit_line == l:
		edit_line = null
	transit.remove_line(l)


func line_edit(l) -> void:
	set_tool(T_LINE)
	edit_line = l
	selected_line = l
	selected = -1
	_refresh_preview()


# -------------------------------------------------------------------- input

func pick_tile(mp: Vector2) -> int:
	var cam: Camera3D = rig.cam
	var from := cam.project_ray_origin(mp)
	var dir := cam.project_ray_normal(mp)
	var t := 0.0
	var step := 0.3
	var prev := 0.0
	while t < 400.0:
		var p := from + dir * t
		if p.y <= maxf(world.height_at(p.x, p.z), Cfg.WATER_Y):
			var lo := prev
			var hi := t
			for k in 8:
				var m := (lo + hi) * 0.5
				var q := from + dir * m
				if q.y <= maxf(world.height_at(q.x, q.z), Cfg.WATER_Y):
					hi = m
				else:
					lo = m
			var hit := from + dir * hi
			if hit.x < 0.0 or hit.z < 0.0 or hit.x >= W or hit.z >= H:
				return -1
			return int(hit.z) * W + int(hit.x)
		prev = t
		t += step
	return -1


func l_path(a: int, b: int, x_first: bool) -> Array:
	var out := [a]
	var x := a % W
	var y := a / W
	var bx := b % W
	var by := b / W
	for pass_i in 2:
		if (pass_i == 0) == x_first:
			while x != bx:
				x += signi(bx - x)
				out.append(y * W + x)
		else:
			while y != by:
				y += signi(by - y)
				out.append(y * W + x)
	return out


## L-shaped path between two tiles. If buildings block the natural bend, the
## bend on the other side is used instead.
func plan_path(a: int, b: int) -> Array:
	var x_first: bool = absi(b % W - a % W) >= absi(b / W - a / W)
	var p := l_path(a, b, x_first)
	if path_blocked(p):
		var q := l_path(a, b, not x_first)
		if not path_blocked(q):
			return q
	return p


func _unhandled_input(e: InputEvent) -> void:
	if hud.menu.visible:
		return
	if e is InputEventMouseMotion:
		var h := pick_tile(e.position)
		if h != hover:
			hover = h
			if drag_start >= 0 and hover >= 0:
				if tool == T_BULLDOZE:
					bulldoze(hover, drag_kind)
				else:
					drag_path = plan_path(drag_start, hover)
			_refresh_preview()
	elif e is InputEventMouseButton:
		if e.button_index == MOUSE_BUTTON_LEFT:
			hover = pick_tile(e.position)
			if e.pressed:
				_press()
			else:
				_release()
			_refresh_preview()
		elif e.button_index == MOUSE_BUTTON_RIGHT and e.pressed:
			_cancel()
	elif e is InputEventKey and e.pressed and not e.echo:
		if e.ctrl_pressed or e.meta_pressed:
			match e.keycode:
				KEY_Z:
					undo()
				KEY_S:
					save_game()
				KEY_O:
					request_load()
			return
		match e.keycode:
			KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7, KEY_8:
				set_tool(e.keycode - KEY_1)
			KEY_T:
				cycle_overlay()
			KEY_G:
				hud.toggle_stats()
			KEY_SPACE:
				set_speed(last_speed if speed_idx == 0 else 0)
			KEY_EQUAL, KEY_PLUS, KEY_KP_ADD:
				set_speed(mini(Cfg.SPEEDS.size() - 1, speed_idx + 1))
			KEY_MINUS, KEY_KP_SUBTRACT:
				set_speed(maxi(1, speed_idx - 1))
			KEY_F1, KEY_H:
				hud.toggle_help()
			KEY_ENTER, KEY_KP_ENTER:
				if tool == T_LINE:
					finish_line()
			KEY_ESCAPE:
				if hud.help.visible:
					hud.toggle_help()
				elif drag_start >= 0 or not line_draft.is_empty() or edit_line != null or selected >= 0 or selected_line != null:
					_cancel()
				else:
					hud.show_menu(true)
			KEY_M:
				hud.show_menu(true)


func _press() -> void:
	if hover < 0:
		return
	match tool:
		T_INSPECT:
			selected = hover
			selected_line = null
			_end_auto_overlay()
		T_ROAD, T_LANE, T_BIKEPATH, T_BIKELANE:
			drag_start = hover
			drag_path = [hover]
		T_BULLDOZE:
			drag_start = hover
			drag_kind = bulldoze_target(hover).get("kind", "")
			bulldoze(hover)
		T_STOP:
			add_stop(hover)
		T_LINE:
			if edit_line != null:
				if edit_line.stops.has(hover):
					if not transit.remove_from_line(edit_line, hover):
						hud.toast("A line needs at least two stops")
				elif add_stop(hover):
					transit.insert_stop(edit_line, hover)
			elif not line_draft.has(hover):
				if add_stop(hover, true):
					line_draft.append(hover)


func _release() -> void:
	if drag_start < 0:
		return
	match tool:
		T_ROAD:
			build_road(drag_path, false)
		T_BIKEPATH:
			build_road(drag_path, true)
		T_LANE:
			add_lanes(drag_path)
		T_BIKELANE:
			add_bike_lanes(drag_path)
	drag_start = -1
	drag_path.clear()


func _cancel() -> void:
	if drag_start >= 0:
		drag_start = -1
		drag_path.clear()
	elif tool == T_LINE and (not line_draft.is_empty() or edit_line != null):
		finish_line()
	else:
		selected = -1
		selected_line = null
		_end_auto_overlay()
	_refresh_preview()


func _refresh_preview() -> void:
	if hud == null:
		return
	var good := Color(0.3, 0.95, 0.4, 0.55)
	var bad := Color(0.95, 0.25, 0.2, 0.55)
	var neutral := Color(1, 1, 1, 0.3)
	var one: Array = [hover] if hover >= 0 else []
	var dragging := drag_start >= 0
	var path: Array = drag_path if dragging else one
	match tool:
		T_INSPECT:
			var sel: Array = [selected] if selected >= 0 else []
			var marks: Array = []
			if selected_line != null:
				marks = selected_line.stops
			view.set_preview(one, Color(1, 1, 1, 0.18), sel if marks.is_empty() else marks, Color(1.0, 0.95, 0.4, 0.5))
			hud.set_hint("Inspect: click a building, road or bus stop.   H = help")
		T_ROAD, T_BIKEPATH:
			var bp := tool == T_BIKEPATH
			var cost: int = roads.plan_cost(path, bp)
			var ok: bool = not path_blocked(path) and cost <= credits
			view.set_preview(path, good if ok else bad)
			var what := "Cycle path" if bp else "Road"
			var msg := "%s: drag to draw; ends join neighbouring roads automatically." % what
			if bp:
				msg += " For bikes only. %d per tile, bridges %d." % [Cfg.COST_BIKEPATH, Cfg.COST_BIKEPATH_BRIDGE]
			else:
				msg += " Bridges cost %d, steep hills %d per tile." % [Cfg.COST_BRIDGE, Cfg.COST_STEEP]
			if dragging:
				msg = "%s: %s, cost %d credits%s   (right-click cancels)" % [what, Cfg.fmt_dist(path.size()), cost, "" if ok else "  - not possible"]
			hud.set_hint(msg)
		T_LANE:
			var cost2: int = roads.upgrade_cost(path)
			view.set_preview(path, good if cost2 > 0 and cost2 <= credits else neutral)
			hud.set_hint("Add lane: drag along an existing road. Cost %d credits." % cost2 if dragging else "Add lane: drag along an existing road to add one lane in each direction (max %d)." % Cfg.MAX_LANES)
		T_BIKELANE:
			var cost3: int = roads.bikelane_cost(path)
			view.set_preview(path, good if cost3 > 0 and cost3 <= credits else neutral)
			hud.set_hint("Bike lanes: drag along an existing road. Cost %d credits." % cost3 if dragging else "Bike lanes: drag along a road (%d per tile). Cyclists then no longer hold up the cars, and more people cycle." % Cfg.COST_BIKELANE)
		T_BULLDOZE:
			var t := bulldoze_target(hover)
			var custom := []
			var msg2 := "Bulldoze: click a road, lane, cycle path or bus stop. Drag to remove more of the same kind."
			if not t.is_empty():
				var strong := Color(1.0, 0.2, 0.15, 0.8)
				match t.kind:
					"stop":
						custom.append([hover, 0.7, 0.0, 1.0, 0.3, strong])
					"bikelane", "lane":
						# Only the outer strips go.
						var hw := minf(Cfg.half_width(roads.lanes[hover]) + 0.07, 0.5)
						var c: int = roads.conn[hover]
						var ns: bool = (c & 5) != 0 or (c & 10) == 0
						var ew: bool = (c & 10) != 0
						if ns:
							custom.append([hover, 0.5 - hw, 0.0, 0.5 - hw + 0.1, 1.0, strong])
							custom.append([hover, 0.5 + hw - 0.1, 0.0, 0.5 + hw, 1.0, strong])
						if ew:
							custom.append([hover, 0.0, 0.5 - hw, 1.0, 0.5 - hw + 0.1, strong])
							custom.append([hover, 0.0, 0.5 + hw - 0.1, 1.0, 0.5 + hw, strong])
					_:
						custom.append([hover, 0.04, 0.04, 0.96, 0.96, strong])
				msg2 = "Bulldoze: click removes %s here (refund %d credits)." % [t.name, t.refund]
				if t.kind != "road" and t.kind != "bikepath":
					msg2 += " The road itself stays until you click again."
			view.set_preview([] if not t.is_empty() else one, neutral, [], Color.WHITE, custom)
			hud.set_hint(msg2)
		T_STOP:
			view.set_preview(one, good if hover >= 0 and roads.has(hover) else bad)
			hud.set_hint("Bus stop: click a road tile (%d credits). People walk up to %d tiles (%s) to a stop." % [Cfg.COST_STOP, Cfg.WALK_RADIUS, Cfg.fmt_dist(Cfg.WALK_RADIUS)])
		T_LINE:
			var ok_tile: bool = hover >= 0 and roads.has(hover)
			if edit_line != null:
				var removing: bool = hover >= 0 and edit_line.stops.has(hover)
				view.set_preview(one, bad if removing or not ok_tile else good, edit_line.stops, Color(edit_line.color, 0.8))
				hud.set_hint("Editing line %d: click a road to add a stop there (it is put where it fits the route best), click one of its stops to take it off the line. Enter or right-click when done." % edit_line.id)
			else:
				view.set_preview(one, good if ok_tile else bad, line_draft, Color(1.0, 0.85, 0.2, 0.75))
				if line_draft.is_empty():
					hud.set_hint("Bus line: click the stops in the order the bus should visit them (new stops are built as needed).")
				else:
					hud.set_hint("Bus line: %d stop%s selected. Enter or right-click to finish. The bus runs to the last stop and back the same way." % [line_draft.size(), "" if line_draft.size() == 1 else "s"])


## Shows the route of the selected building's last problem on the map.
func _update_route() -> void:
	var b = city.bmap.get(selected) if selected >= 0 else null
	if b != null:
		var f = city.problem(b, true)
		if f != null:
			view.set_route(f.path, f.from.idx, f.to.idx, Color(1.0, 0.45, 0.1, 0.85))
			return
	view.set_route([], -1, -1, Color.WHITE)


# ---------------------------------------------------------------- inspector

func inspect_text() -> String:
	if selected_line != null and transit.lines.has(selected_line):
		return _line_text(selected_line)
	var i := selected
	if i < 0:
		return "[color=#9fb0c0]Nothing selected.[/color]\nToday: %d on time, %d late, %d could not travel. Earned %d." % [ok_today, late_today, unserved_today, earned_today]
	var b = city.bmap.get(i)
	if b != null:
		var s := "[b]%s[/b]\n" % city.type_name(b)
		if b.type == Cfg.HOUSE:
			s += "%d residents%s, %d of %d cars at home\n" % [b.residents, " in %d flats" % b.units if b.apt else "", b.home_cars.size(), b.cars]
		else:
			s += "%d visitors and workers inside\n" % b.visitors
			s += "Car park: %d of %d spaces taken\n" % [mini(b.parked.size(), b.slots), b.slots]
			if b.parked.size() > b.slots:
				s += "[color=#ffb347]%d more cars are circling for a space, which makes their trips %s longer. Buses and bikes need no parking.[/color]\n" % [b.parked.size() - b.slots, Cfg.fmt_time(Cfg.PARK_SEARCH)]
		if b.access < 0:
			s += "[color=#ff6655]No road next to this building.[/color] Build a road on one of the four tiles beside it (diagonal does not count).\n"
		if b.type == Cfg.HOUSE:
			s += "Today: %d travellers on time, %d failed\n" % [b.ok_today, b.fail_today]
			var f = city.problem(b, true)
			if f != null:
				s += "[color=#ffb347]Last problem (%s ago): %s[/color]\n" % [Cfg.fmt_time(now - f.time), f.text]
				s += "[color=#9fb0c0]The orange line on the map shows where they wanted to go.[/color]\n"
		if not b.queue.is_empty():
			s += "[color=#ffb347]%d vehicles waiting to get onto the road - the street outside is full.[/color]\n" % b.queue.size()
		return s
	if roads.any(i):
		var n: int = roads.lanes[i]
		var kind := "Road"
		if n == 0:
			kind = "Cycle path"
		elif world.water[i] == 1:
			kind = "Bridge"
		elif world.steep[i] == 1:
			kind = "Steep road (slow)"
		var deg: int = roads.degree(i)
		var s2 := "[b]%s[/b]" % kind
		if n > 0:
			s2 += ", %d lane%s each way" % [n, "" if n == 1 else "s"]
			if roads.bike[i] == 1:
				s2 += " + bike lanes"
		if deg >= 3:
			s2 += ", %d-way junction" % deg
		elif deg <= 1:
			s2 += ", dead end"
		s2 += "\n"
		if n > 0:
			s2 += "%d vehicles used it today and yesterday\n" % traffic.tile_flow(i)
		if transit.stops.has(i):
			s2 += "Bus stop: %d waiting" % transit.waiting_at(i)
			var names := []
			for l in transit.lines_at.get(i, []):
				names.append(str(l.id))
			s2 += ", served by line %s\n" % ", ".join(names) if not names.is_empty() else ", no line stops here yet\n"
		if n == 0:
			return s2
		var l2 = advisor.worst_link(self, i)
		if l2 == null or traffic.congestion(l2) < 0.25:
			s2 += "[color=#7fdc7f]Traffic is flowing freely.[/color]\n"
		else:
			var d: Dictionary = advisor.diagnose(self, l2)
			s2 += "Speed %d km/h (%d%% of free flow), %d%% full\n" % [int(l2.speed_ema * 50.0 * l2.sf), int(l2.speed_ema * 100.0), int(minf(l2.occ_ema, 1.0) * 100.0)]
			s2 += "[color=#ff9966][b]%s[/b][/color]\n%s\n" % [d.title, d.text]
		return s2
	var t := "Water" if world.water[i] == 1 else ("Steep hillside" if world.steep[i] == 1 else "Open land")
	return "[b]%s[/b]\nA road costs %d credits per tile here, a cycle path %d." % [t, roads.road_cost(i), roads.bikepath_cost(i)]


func _line_text(l) -> String:
	var tr = transit
	var s := "[b]Bus line %d[/b]\n" % l.id
	s += "%d stops, %s long (one way), %d bus%s\n" % [l.stops.size(), Cfg.fmt_dist(l.length), tr.bus_count(l), "" if tr.bus_count(l) == 1 else "es"]
	s += "A bus passes about every %s\n" % Cfg.fmt_time(tr.avg_wait(l) * 2.0)
	s += "Now: %d on board, %d waiting\n" % [tr.riders(l), tr.waiting_for(l)]
	s += "Passengers: %d today, %d yesterday, %d in total\n" % [l.carried_today, l.carried_yesterday, l.carried]
	if l.wait_n > 0:
		s += "Average wait %s" % Cfg.fmt_time(l.wait_sum / l.wait_n)
		if l.left_behind > 0:
			s += ", %d gave up waiting" % l.left_behind
		s += "\n"
	if l.load_n > 0:
		s += "Average load %d%% of %d seats\n" % [int(l.load_sum / l.load_n / Cfg.BUS_CAP * 100.0), Cfg.BUS_CAP]
	s += "Boardings per stop (today / total):\n"
	for k in l.stops.size():
		var bd = l.board.get(l.stops[k], [0, 0])
		s += "  stop %d: %d / %d, %d waiting\n" % [k + 1, bd[0], bd[1], tr.waiting_at(l.stops[k])]
	for a in advisor.line_advice(self, l):
		s += "[color=#ffd866]%s[/color]\n" % a
	return s


func stats_text() -> String:
	var s := "[b]How people travel[/b] (today / all time)\n"
	var tt := 0
	var ta := 0
	for m in 4:
		tt += mode_today[m]
		ta += mode_total[m]
	for m in 4:
		s += "  %-8s %3d%%  /  %3d%%\n" % [Cfg.MODE_NAMES[m], int(round(100.0 * mode_today[m] / maxi(1, tt))), int(round(100.0 * mode_total[m] / maxi(1, ta)))]
	s += "  could not travel today: %d of %d\n" % [unserved_today, tt + unserved_today]
	s += "\n[b]Today[/b]\n  %d on time, %d late, %d credits earned\n" % [ok_today, late_today, earned_today]
	s += "  on the road now: %d cars and buses, %d bikes, %d groups on foot\n" % [traffic.count, traffic.bikes, walkers.size()]
	var road_tiles := 0
	var lane_tiles := 0
	var path_tiles := 0
	var bikelane_tiles := 0
	for i in roads.tiles:
		if roads.lanes[i] > 0:
			road_tiles += 1
			lane_tiles += roads.lanes[i]
			if roads.bike[i] == 1:
				bikelane_tiles += 1
		else:
			path_tiles += 1
	var nb: int = city.buildings.size()
	s += "\n[b]Network[/b]\n  roads %s (%s of lanes)\n" % [Cfg.fmt_dist(road_tiles), Cfg.fmt_dist(lane_tiles * 2)]
	s += "  cycle paths %s, bike lanes on %s of road\n" % [Cfg.fmt_dist(path_tiles), Cfg.fmt_dist(bikelane_tiles)]
	s += "  %d buildings, %d residents\n" % [nb, city.population]
	s += "  road per building: %.1f tiles (%d m) - lower means a more compact, cheaper network\n" % [float(road_tiles) / maxi(1, nb), int(float(road_tiles) / maxi(1, nb) * Cfg.TILE_M)]
	if not transit.lines.is_empty():
		s += "\n[b]Bus lines[/b] (click a line on the right for details)\n"
		for l in transit.lines:
			var load := 0
			if l.load_n > 0:
				load = int(l.load_sum / l.load_n / Cfg.BUS_CAP * 100.0)
			s += "  line %d: %s, %d buses, %d today, %d total, load %d%%\n" % [l.id, Cfg.fmt_dist(l.length), transit.bus_count(l), l.carried_today, l.carried, load]
	s += "\n[color=#9fb0c0]Press T twice for the volume view: it colours every road by how many vehicles used it, which shows the typical routes through town.[/color]"
	return s


# -------------------------------------------------------------- save / load

func save_data() -> Dictionary:
	return {
		"app": "gocartraffic", "version": SAVE_VERSION,
		"settings": {"compact": compact, "cluster": cluster, "day_len": day_len, "seed": world.seed_value},
		"world": world.to_save(),
		"now": now, "day": day, "credits": credits,
		"stats": {"delivered": delivered, "ok_w": ok_w, "tot_w": tot_w, "delay": delay_ema, "modes": mode_total, "milestone": next_milestone},
		"roads": roads.to_save(),
		"transit": transit.to_save(),
		"city": city.to_save(),
	}


func _apply_save(d: Dictionary) -> void:
	now = float(d.now)
	traffic.now = now
	day = int(d.day)
	credits = int(d.credits)
	delivered = int(d.stats.delivered)
	ok_w = float(d.stats.ok_w)
	tot_w = float(d.stats.tot_w)
	delay_ema = float(d.stats.delay)
	next_milestone = int(d.stats.milestone)
	for m in 4:
		mode_total[m] = int(d.stats.modes[m])
	roads.from_save(d.roads)
	transit.from_save(d.transit)
	city.from_save(d.city)
	for i in roads.tiles:
		view.clear_trees(i)
	_roads_dirty = true


func save_text() -> String:
	return JSON.stringify(save_data())


## Desktop: file dialog. Web: the browser downloads the file. Both write the
## same JSON, so a save from one edition loads in the other.
func save_game() -> void:
	var fname := "gocartraffic-day%d.json" % (day + 1)
	if OS.has_feature("web"):
		JavaScriptBridge.download_buffer(save_text().to_utf8_buffer(), fname, "application/json")
		hud.toast("Game saved to your downloads folder as %s" % fname)
	else:
		hud.ask_save_path(fname)


func save_to(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		hud.toast("Could not write %s" % path)
		return
	f.store_string(save_text())
	f.close()
	hud.toast("Game saved to %s" % path)


func request_load() -> void:
	hud.ask_load()


func load_from(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		hud.toast("Could not read %s" % path)
		return
	load_text(f.get_as_text())


func load_text(text: String) -> void:
	var d = JSON.parse_string(text)
	if typeof(d) != TYPE_DICTIONARY or d.get("app") != "gocartraffic":
		hud.toast("This file is not a GoCarTraffic save game")
		return
	if int(d.get("version", 0)) > SAVE_VERSION:
		hud.toast("This save was made with a newer version of the game")
		return
	boot = {"load": d}
	get_tree().reload_current_scene()


func _on_files_dropped(files: PackedStringArray) -> void:
	if not files.is_empty():
		load_from(files[0])


func start_new(settings: Dictionary) -> void:
	settings["play"] = true
	boot = settings
	get_tree().reload_current_scene()
