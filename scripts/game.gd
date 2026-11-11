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

enum {T_INSPECT, T_ROAD, T_LANE, T_BULLDOZE, T_STOP, T_LINE}

static var next_seed := 0

var world
var roads
var traffic
var city
var transit
var advisor
var view
var rig
var hud

var now := 0.0
var speed := 1.0
var last_speed := 1.0
var credits: int = Cfg.START_CREDITS
var day := 0
var events: Array = []

var tool := T_INSPECT
var hover := -1
var drag_start := -1
var drag_path: Array = []
var line_draft: Array = []
var overlay_on := false
var selected := -1

var ok_w := 0.0
var tot_w := 0.0
var delay_ema := 1.0
var delivered := 0
var earned_today := 0
var unserved_today := 0
var late_today := 0
var ok_today := 0
var bus_today := 0
var issues: Array = []
var next_milestone := 100

var _t_hud := 0.0
var _t_overlay := 0.0
var _t_advisor := 0.0
var _t_weights := 0.0
var _roads_dirty := false


func _ready() -> void:
	var s := next_seed
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--seed="):
			s = int(a.substr(7))
	if s == 0:
		s = randi() % 1000000 + 1
	next_seed = 0
	world = World.new()
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
	city.start()
	if not world.districts.is_empty():
		var c := Vector2.ZERO
		var n := mini(3, world.districts.size())
		for k in n:
			c += Vector2(world.districts[k].pos)
		c /= n
		rig.focus(Vector3(c.x, 0, c.y), 40.0)
		rig.dist = 40.0
	hud = Hud.new()
	add_child(hud)
	hud.setup(self)
	set_tool(T_INSPECT)


func _on_vehicle_lost(v) -> void:
	if v.kind == 0:
		city.on_vehicle_lost(v)
	else:
		transit.on_bus_lost(v)


# --------------------------------------------------------------------- time

func hour() -> float:
	return fmod(Cfg.START_HOUR + now / Cfg.SEC_PER_HOUR, 24.0)


func day_start() -> float:
	return (day * 24.0 - Cfg.START_HOUR) * Cfg.SEC_PER_HOUR


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
		_t_weights = 3.0
		traffic.update_weights()
	var d := int(floor((Cfg.START_HOUR + now / Cfg.SEC_PER_HOUR) / 24.0))
	if d > day:
		day = d
		hud.toast("Day %d - yesterday: %d on time, %d late, %d could not travel, %d credits earned" % [day + 1, ok_today, late_today, unserved_today, earned_today])
		earned_today = 0
		unserved_today = 0
		late_today = 0
		ok_today = 0
		bus_today = 0
		city.new_day()


func _process(delta: float) -> void:
	delta = minf(delta, 0.1)
	if speed > 0.0:
		var steps := 1 if speed <= 2.0 else 2
		var dt: float = delta * speed / steps
		for k in steps:
			sim_step(dt)
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
	_t_overlay -= delta
	if overlay_on and _t_overlay <= 0.0:
		_t_overlay = 0.4
		view.rebuild_overlay()
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
	delay_ema += (clampf(elapsed / maxf(leg.ff, 0.5), 0.5, 6.0) - delay_ema) * 0.04
	if leg.mode == 1:
		bus_today += leg.n
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


func record_unserved(leg, _why: String) -> void:
	ok_w = ok_w * 0.992
	tot_w = tot_w * 0.992 + leg.n
	unserved_today += leg.n


func on_building_added(b) -> void:
	view.add_building(b, now > 0.5)


# -------------------------------------------------------------------- tools

func set_tool(t: int) -> void:
	tool = t
	drag_start = -1
	drag_path.clear()
	line_draft.clear()
	_refresh_preview()


func set_speed(s: float) -> void:
	if s > 0.0:
		last_speed = s
	speed = s


func toggle_overlay() -> void:
	overlay_on = not overlay_on
	view.overlay_mi.visible = overlay_on
	_t_overlay = 0.0


func new_map() -> void:
	next_seed = randi() % 1000000 + 1
	get_tree().reload_current_scene()


func focus_issue(i: int) -> void:
	rig.focus(Vector3(i % W + 0.5, 0, i / W + 0.5), minf(rig.goal_dist, 22.0))
	selected = i
	if not overlay_on:
		toggle_overlay()
	_refresh_preview()


func spend(cost: int) -> bool:
	if cost > credits:
		hud.toast("Not enough credits (%d needed)" % cost)
		return false
	credits -= cost
	return true


func _mark_roads_dirty() -> void:
	_roads_dirty = true


func _apply_road_change() -> void:
	_roads_dirty = false
	city.update_access()
	transit.on_roads_changed()
	view.rebuild_roads()
	if overlay_on:
		view.rebuild_overlay()


func path_blocked(path: Array) -> bool:
	for i in path:
		if city.bmap.has(i):
			return true
	return false


func build_road(path: Array) -> bool:
	if path.is_empty() or path_blocked(path):
		hud.toast("Buildings are in the way")
		return false
	if path.size() == 1 and roads.has(path[0]):
		return false
	if not spend(roads.plan_cost(path)):
		return false
	roads.build(path)
	for i in path:
		view.clear_trees(i)
		traffic.on_lanes_changed(i)
	_mark_roads_dirty()
	return true


func add_lanes(path: Array) -> bool:
	var cost: int = roads.upgrade_cost(path)
	if cost == 0:
		return false
	if not spend(cost):
		return false
	for i in roads.upgrade(path):
		traffic.on_lanes_changed(i)
	view.rebuild_roads()
	return true


func bulldoze(i: int) -> void:
	if i < 0:
		return
	if transit.stops.has(i):
		transit.remove_stop(i)
		credits += int(Cfg.COST_STOP * Cfg.REFUND)
		return
	if not roads.has(i):
		return
	credits += roads.remove(i)
	traffic.on_tile_removed(i)
	if selected == i:
		selected = -1
	_mark_roads_dirty()


func add_stop(i: int) -> bool:
	if not roads.has(i):
		hud.toast("Bus stops must be placed on a road")
		return false
	if transit.stops.has(i):
		return true
	if not spend(Cfg.COST_STOP):
		return false
	transit.add_stop(i)
	return true


func finish_line() -> void:
	if line_draft.size() < 2:
		if not line_draft.is_empty():
			hud.toast("A bus line needs at least two stops")
		line_draft.clear()
		_refresh_preview()
		return
	var l = transit.create_line(line_draft)
	line_draft.clear()
	if not l.ok:
		hud.toast("Line %d created, but its stops are not connected by road" % l.id)
	if credits >= Cfg.COST_BUS:
		credits -= Cfg.COST_BUS
		transit.add_bus(l)
		hud.toast("Line %d opened with one bus. Add more buses in the panel on the right." % l.id)
	else:
		hud.toast("Line %d created without a bus - not enough credits (%d)" % [l.id, Cfg.COST_BUS])
	_refresh_preview()


func line_add_bus(l) -> void:
	if spend(Cfg.COST_BUS):
		transit.add_bus(l)


func line_remove_bus(l) -> void:
	if transit.remove_bus(l):
		credits += int(Cfg.COST_BUS * Cfg.REFUND)


func line_delete(l) -> void:
	credits += int(transit.bus_count(l) * Cfg.COST_BUS * Cfg.REFUND)
	transit.remove_line(l)


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


func l_path(a: int, b: int) -> Array:
	var out := [a]
	var x := a % W
	var y := a / W
	var bx := b % W
	var by := b / W
	var x_first: bool = absi(bx - x) >= absi(by - y)
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


func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventMouseMotion:
		var h := pick_tile(e.position)
		if h != hover:
			hover = h
			if drag_start >= 0 and hover >= 0:
				if tool == T_BULLDOZE:
					bulldoze(hover)
				else:
					drag_path = l_path(drag_start, hover)
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
		match e.keycode:
			KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6:
				set_tool(e.keycode - KEY_1)
			KEY_T:
				toggle_overlay()
			KEY_SPACE:
				set_speed(last_speed if speed == 0.0 else 0.0)
			KEY_EQUAL, KEY_PLUS, KEY_KP_ADD:
				set_speed(minf(4.0, maxf(1.0, speed * 2.0)))
			KEY_MINUS, KEY_KP_SUBTRACT:
				set_speed(maxf(1.0, speed * 0.5))
			KEY_F1:
				hud.toggle_help()
			KEY_ENTER, KEY_KP_ENTER:
				if tool == T_LINE:
					finish_line()
			KEY_ESCAPE:
				if hud.help.visible:
					hud.toggle_help()
				else:
					_cancel()


func _press() -> void:
	if hover < 0:
		return
	match tool:
		T_INSPECT:
			selected = hover
		T_ROAD, T_LANE:
			drag_start = hover
			drag_path = [hover]
		T_BULLDOZE:
			drag_start = hover
			bulldoze(hover)
		T_STOP:
			add_stop(hover)
		T_LINE:
			if line_draft.is_empty() or line_draft[-1] != hover:
				if add_stop(hover):
					line_draft.append(hover)


func _release() -> void:
	if drag_start < 0:
		return
	match tool:
		T_ROAD:
			build_road(drag_path)
		T_LANE:
			add_lanes(drag_path)
	drag_start = -1
	drag_path.clear()


func _cancel() -> void:
	if drag_start >= 0:
		drag_start = -1
		drag_path.clear()
	elif tool == T_LINE and not line_draft.is_empty():
		finish_line()
	else:
		selected = -1
	_refresh_preview()


func _refresh_preview() -> void:
	if hud == null:
		return
	var good := Color(0.3, 0.95, 0.4, 0.55)
	var bad := Color(0.95, 0.25, 0.2, 0.55)
	var neutral := Color(1, 1, 1, 0.3)
	var one: Array = [hover] if hover >= 0 else []
	match tool:
		T_INSPECT:
			var sel: Array = [selected] if selected >= 0 else []
			view.set_preview(one, Color(1, 1, 1, 0.18), sel, Color(1.0, 0.95, 0.4, 0.5))
			hud.set_hint("Inspect: click a building, road or bus stop.   F1 = help")
		T_ROAD:
			var path: Array = drag_path if drag_start >= 0 else one
			var cost: int = roads.plan_cost(path)
			var ok: bool = not path_blocked(path) and cost <= credits
			view.set_preview(path, good if ok else bad)
			var msg := "Road: drag to draw. Bridges cost %d, steep hills %d per tile." % [Cfg.COST_BRIDGE, Cfg.COST_STEEP]
			if drag_start >= 0:
				msg = "Road: %d tiles, cost %d credits%s   (right-click cancels)" % [path.size(), cost, "" if ok else "  - not possible"]
			hud.set_hint(msg)
		T_LANE:
			var path2: Array = drag_path if drag_start >= 0 else one
			var cost2: int = roads.upgrade_cost(path2)
			view.set_preview(path2, good if cost2 > 0 and cost2 <= credits else neutral)
			hud.set_hint("Add lane: drag along an existing road. Cost %d credits." % cost2 if drag_start >= 0 else "Add lane: drag along an existing road to add one lane in each direction (max %d)." % Cfg.MAX_LANES)
		T_BULLDOZE:
			view.set_preview(one, bad)
			hud.set_hint("Bulldoze: click or drag over roads and bus stops. Half the cost is refunded.")
		T_STOP:
			view.set_preview(one, good if hover >= 0 and roads.has(hover) else bad)
			hud.set_hint("Bus stop: click a road tile (%d credits). People walk up to %d tiles to a stop." % [Cfg.COST_STOP, Cfg.WALK_RADIUS])
		T_LINE:
			view.set_preview(one, good if hover >= 0 and roads.has(hover) else bad, line_draft, Color(1.0, 0.85, 0.2, 0.75))
			if line_draft.is_empty():
				hud.set_hint("Bus line: click the stops in the order the bus should visit them (new stops are built as needed).")
			else:
				hud.set_hint("Bus line: %d stop%s selected. Enter or right-click to finish, the bus loops back to the first stop." % [line_draft.size(), "" if line_draft.size() == 1 else "s"])


# ---------------------------------------------------------------- inspector

func inspect_text() -> String:
	var i := selected
	if i < 0:
		return "[color=#9fb0c0]Nothing selected.[/color]\nToday: %d on time, %d late, %d could not travel, %d by bus. Earned %d." % [ok_today, late_today, unserved_today, bus_today, earned_today]
	var b = city.bmap.get(i)
	if b != null:
		var s := "[b]%s[/b]\n" % Cfg.TYPE_NAMES[b.type]
		if b.type == Cfg.HOUSE:
			s += "%d residents, %d of %d cars at home\n" % [b.residents, b.cars_home, b.cars]
		else:
			s += "%d visitors and workers inside\n" % b.visitors
		if b.access < 0:
			s += "[color=#ff6655]No road next to this building.[/color] Build a road on an adjacent tile.\n"
		if b.type == Cfg.HOUSE:
			s += "Today: %d travellers on time, %d failed\n" % [b.ok_today, b.fail_today]
			if b.fail_reason != "" and now - b.fail_time < 120.0:
				s += "[color=#ffb347]Last problem: %s[/color]\n" % b.fail_reason
		if not b.queue.is_empty():
			s += "[color=#ffb347]%d cars waiting to get onto the road - the street outside is full.[/color]\n" % b.queue.size()
		return s
	if roads.has(i):
		var n: int = roads.lanes[i]
		var kind := "Road"
		if world.water[i] == 1:
			kind = "Bridge"
		elif world.steep[i] == 1:
			kind = "Steep road (slow)"
		var deg: int = roads.degree(i)
		var s2 := "[b]%s[/b], %d lane%s each way" % [kind, n, "" if n == 1 else "s"]
		if deg >= 3:
			s2 += ", %d-way junction" % deg
		elif deg <= 1:
			s2 += ", dead end"
		s2 += "\n"
		if transit.stops.has(i):
			s2 += "Bus stop: %d waiting\n" % transit.waiting_at(i)
		var l = advisor.worst_link(self, i)
		if l == null or traffic.congestion(l) < 0.25:
			s2 += "[color=#7fdc7f]Traffic is flowing freely.[/color]\n"
		else:
			var d: Dictionary = advisor.diagnose(self, l)
			s2 += "Speed %d%% of free flow, %d%% full\n" % [int(l.speed_ema * 100.0), int(minf(l.occ_ema, 1.0) * 100.0)]
			s2 += "[color=#ff9966][b]%s[/b][/color]\n%s\n" % [d.title, d.text]
		return s2
	var t := "Water" if world.water[i] == 1 else ("Steep hillside" if world.steep[i] == 1 else "Open land")
	return "[b]%s[/b]\nRoad cost here: %d credits per tile." % [t, roads.tile_cost(i)]
