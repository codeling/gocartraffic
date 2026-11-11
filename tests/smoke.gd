extends SceneTree
## Headless end-to-end test.
## Run:  godot --headless --path . -s tests/smoke.gd -- --seed=7
##
## Builds a road network automatically, opens two bus lines that share a stop,
## fast-forwards three days and checks that people get around by every mode.
## Also exercises the tools, undo, layered bulldozing and save / load.

const Cfg = preload("res://scripts/cfg.gd")
const Game = preload("res://scripts/game.gd")
var game
var frame := 0
var failures := 0
var stage := 0
var saved_text := ""
var expect := {}


func _initialize() -> void:
	game = load("res://main.tscn").instantiate()
	root.add_child(game)


func check(cond: bool, what: String) -> void:
	if cond:
		print("  ok: ", what)
	else:
		failures += 1
		print("  FAIL: ", what)


func _corridor(v: int) -> int:
	return v - 1 if v % 3 == 1 else v + 1


## Connects every building to a main street through the first district.
func _connect_all(hub: Vector2i) -> void:
	var g = game
	for b in g.city.buildings:
		if b.access >= 0:
			continue
		var cx := _corridor(b.x)
		var a: int = b.y * Cfg.W + cx
		var mid: int = hub.y * Cfg.W + cx
		var path: Array = g.l_path(a, mid, false)
		var rest: Array = g.l_path(mid, hub.y * Cfg.W + hub.x, true)
		rest.pop_front()
		path.append_array(rest)
		g.build_road(path)
	g._apply_road_change()
	g.undo_stack.clear()


func _free_strip(n: int) -> Vector2i:
	var g = game
	var c := Vector2i(int(g.rig.target.x), int(g.rig.target.z))
	for y in range(c.y - 8, c.y + 8):
		for x in range(c.x - 10, c.x + 4):
			var free := true
			for dy in [-1, 0, 1]:
				for k in range(-1, n + 1):
					var i: int = (y + dy) * Cfg.W + x + k
					if g.world.water[i] == 1 or g.city.bmap.has(i) or g.roads.any(i):
						free = false
			if free:
				return Vector2i(x, y)
	return Vector2i(-1, -1)


func _mouse(pos: Vector2, button: int, pressed: bool) -> void:
	var ev: InputEvent
	if button == 0:
		ev = InputEventMouseMotion.new()
	else:
		ev = InputEventMouseButton.new()
		ev.button_index = button
		ev.pressed = pressed
	ev.position = pos
	game._unhandled_input(ev)


func _screen(x: int, y: int) -> Vector2:
	return game.rig.cam.unproject_position(Vector3(x + 0.5, game.world.tile_h(x, y), y + 0.5))


func _tool_tests() -> void:
	var g = game
	print("tools:")
	var a := _free_strip(6)
	if a.x < 0:
		print("  skipped: no free strip of land")
		return
	var i0: int = a.y * Cfg.W + a.x
	check(g.pick_tile(_screen(a.x, a.y)) == i0, "mouse picking hits the right tile")

	# Draw a road with the mouse.
	g.set_tool(g.T_ROAD)
	var before: int = g.roads.tiles.size()
	var credits0: int = g.credits
	_mouse(_screen(a.x, a.y), MOUSE_BUTTON_LEFT, true)
	_mouse(_screen(a.x + 4, a.y), 0, false)
	_mouse(_screen(a.x + 4, a.y), MOUSE_BUTTON_LEFT, false)
	check(g.roads.tiles.size() == before + 5, "road tool builds 5 tiles")
	check(g.credits == credits0 - 5 * Cfg.COST_ROAD, "road costs credits")

	# A second road that stops beside the first one joins it automatically.
	g.build_road(g.l_path((a.y + 1) * Cfg.W + a.x + 2, (a.y + 1) * Cfg.W + a.x + 2, true))
	check(g.roads.degree(a.y * Cfg.W + a.x + 2) == 3, "a road ending next to another road connects to it")
	g.undo()
	check(g.roads.degree(a.y * Cfg.W + a.x + 2) == 2 and not g.roads.any((a.y + 1) * Cfg.W + a.x + 2), "undo removes the stub and its junction")

	# Lanes, bike lanes, stop - then bulldoze layer by layer.
	g.add_lanes([i0])
	g.add_bike_lanes([i0])
	g.add_stop(i0)
	g._apply_road_change()
	check(g.roads.lanes[i0] == 2 and g.roads.bike[i0] == 1 and g.transit.stops.has(i0), "lane, bike lanes and stop added")
	var kinds := []
	for k in 4:
		kinds.append(g.bulldoze_target(i0).get("kind", ""))
		g.bulldoze(i0)
	check(kinds == ["stop", "bikelane", "lane", "road"], "bulldozer removes stop, bike lanes, lane, road in that order: %s" % [kinds])
	check(not g.roads.any(i0), "tile is empty after four clicks")

	# Undo gives everything back for free.
	g.set_tool(g.T_INSPECT)
	var credits1: int = g.credits
	var tiles1: int = g.roads.tiles.size()
	g.build_road(g.l_path(i0, i0, true))
	g.add_bike_lanes([i0])
	g.undo()
	g.undo()
	check(g.credits == credits1 and g.roads.tiles.size() == tiles1, "two undos restore credits and tiles")
	g.ui_time += Cfg.UNDO_SECONDS + 1.0
	g.build_road(g.l_path(i0, i0, true))
	g.ui_time += Cfg.UNDO_SECONDS + 1.0
	g.undo()
	check(g.roads.any(i0), "undo expires after %d seconds" % int(Cfg.UNDO_SECONDS))

	# Cycle path next to the road; routing for bikes but not for cars.
	var p0: int = (a.y - 1) * Cfg.W + a.x
	g.build_road(g.l_path(p0, p0 + 3, true), true)
	check(g.roads.bike[p0 + 1] == 2 and g.roads.lanes[p0 + 1] == 0, "cycle path built")
	check(g.roads.find_path(i0, p0 + 3).is_empty() and not g.roads.find_bike_path(i0 + 1, p0 + 3).is_empty(), "cycle path carries bikes, not cars")
	for k in 4:
		g.bulldoze(p0 + k)
	for k in range(0, 5):
		g.bulldoze(i0 + k)
	g._apply_road_change()
	g.undo_stack.clear()

	# A drag that would run through a building bends the other way round.
	var b = g.city.buildings[0]
	var from_i: int = (b.y - 1) * Cfg.W + b.x - 1
	var to_i: int = (b.y + 1) * Cfg.W + b.x + 1
	var blocked := 0
	for x_first in [true, false]:
		if g.path_blocked(g.l_path(from_i, to_i, x_first)):
			blocked += 1
	if blocked < 2:
		check(not g.path_blocked(g.plan_path(from_i, to_i)), "road planning avoids buildings where one of the two bends is free")


func _process(_delta: float) -> bool:
	frame += 1
	if frame < 3:
		return false
	if stage == 0:
		_run_main()
		stage = 1
		# Reload from the save.
		Game.boot = {"load": JSON.parse_string(saved_text)}
		game.queue_free()
		game = load("res://main.tscn").instantiate()
		root.add_child(game)
		frame = 0
		return false
	_check_loaded()
	print("SMOKE TEST ", "PASSED" if failures == 0 else "FAILED (%d)" % failures)
	quit(failures)
	return true


func _run_main() -> void:
	var g = game
	g.credits = 1000000
	check(g.started and not g.hud.menu.visible, "--seed starts the game directly")
	_tool_tests()

	print("simulation:")
	var d0: Vector2i = g.world.districts[0].pos
	var hub := Vector2i(d0.x - d0.x % 3, d0.y - d0.y % 3)
	_connect_all(hub)
	var max_cars := 0
	var max_bikes := 0
	var jams := {}
	var dt := 0.3
	var steps := int(3.0 * g.day_len / dt)
	for step in steps:
		g.sim_step(dt)
		max_cars = maxi(max_cars, g.traffic.count)
		max_bikes = maxi(max_bikes, g.traffic.bikes)
		if step % 400 == 0:
			_connect_all(hub)
			g.issues = g.advisor.analyze(g)
			for i in g.issues:
				jams[i.title] = true
		if step == 1500:
			# Two bus lines that meet at the first house: house <-> factory and house <-> shop.
			var h = g.city.by_type[Cfg.HOUSE][0]
			var f = g.city.by_type[Cfg.FACTORY][0]
			var s = g.city.by_type[Cfg.SHOP][0]
			for dest in [f, s]:
				g.set_tool(g.T_LINE)
				g.hover = h.access
				g._press()
				g.hover = dest.access
				g._press()
				g.finish_line()
				g.line_add_bus(g.transit.lines[-1])
			g.set_tool(g.T_INSPECT)
			check(g.transit.lines.size() == 2 and g.transit.lines[0].stops.size() == 2, "two bus lines created with the line tool")
			# Workers at the factory can reach the shop by changing at the house.
			var pl = g.transit._plan(f, s)
			check(pl != null and pl.legs.size() == 2, "trip planner finds a connection with one change")
		if step == 3000:
			g.add_lanes(g.roads.tiles.keys().slice(0, 40))
			g.add_bike_lanes(g.roads.tiles.keys().slice(0, 200))
			g._apply_road_change()
			g.undo_stack.clear()
		if step % 4000 == 2000:
			print("  day %d %-12s buildings=%d cars=%d bikes=%d walkers=%d on-time=%.2f delay=%.2f moved=%d" % [
				g.day + 1, g.phase_name(), g.city.buildings.size(), g.traffic.count, g.traffic.bikes, g.walkers.size(), g.on_time_ratio(), g.delay_ema, g.delivered])
	print("  modes (car, bus, bike, walk): ", g.mode_total, "  max cars ", max_cars, "  jams seen: ", jams.keys())
	check(g.delivered > 300, "people are delivered on time (%d)" % g.delivered)
	check(max_cars >= 10, "cars drive (%d at once)" % max_cars)
	check(g.mode_total[Cfg.M_BUS] > 0, "buses carry passengers (%d)" % g.mode_total[Cfg.M_BUS])
	check(g.mode_total[Cfg.M_BIKE] > 0 and max_bikes > 0, "people cycle (%d)" % g.mode_total[Cfg.M_BIKE])
	check(g.mode_total[Cfg.M_WALK] > 0, "people walk (%d)" % g.mode_total[Cfg.M_WALK])
	check(g.on_time_ratio() > 0.4, "most trips are on time (%.2f)" % g.on_time_ratio())
	var apts := 0
	for b in g.city.buildings:
		if b.apt:
			apts += 1
	check(apts > 0, "apartment blocks appear (%d)" % apts)

	# Line editing: add a third stop, then take it off again.
	var l = g.transit.lines[0]
	var extra: int = g.city.by_type[Cfg.HOUSE][2].access
	if extra >= 0 and not l.stops.has(extra):
		g.line_edit(l)
		g.hover = extra
		g._press()
		check(l.stops.size() == 3, "editing a line adds a stop")
		g._press()
		check(l.stops.size() == 2, "clicking the stop again takes it off the line")
		g.finish_line()

	# Everything the HUD shows must render without errors.
	g.hud.refresh()
	g.selected = g.roads.tiles.keys()[0]
	g.inspect_text()
	g.selected = g.city.buildings[0].idx
	g.inspect_text()
	g._update_route()
	g.select_line(l)
	check(g.inspect_text().contains("Bus line"), "line statistics are shown")
	check(g.stats_text().contains("How people travel"), "statistics panel has content")
	for mode in [1, 2]:
		g.view.rebuild_overlay(mode)
	g.view.update_vehicles(0.016)
	g.view.update_marks()

	# Remove part of the network while traffic is running.
	var keys: Array = g.roads.tiles.keys()
	for k in range(0, keys.size(), 9):
		g.bulldoze(keys[k])
	g._apply_road_change()
	for step in 600:
		g.sim_step(dt)
	g.view.update_vehicles(0.016)

	print("save / load:")
	saved_text = g.save_text()
	expect = {
		"tiles": g.roads.tiles.size(), "buildings": g.city.buildings.size(), "credits": g.credits,
		"lines": g.transit.lines.size(), "stops": g.transit.stops.size(), "day": g.day,
		"population": g.city.population, "corner": g.world.corner[1234], "delivered": g.delivered,
	}
	print("  save file is %d kB" % (saved_text.length() / 1024))


func _check_loaded() -> void:
	var g = game
	check(g.started, "a loaded game starts right away")
	check(g.roads.tiles.size() == expect.tiles, "roads restored (%d tiles)" % expect.tiles)
	check(g.city.buildings.size() == expect.buildings, "buildings restored (%d)" % expect.buildings)
	check(g.city.population == expect.population, "population restored")
	check(g.credits == expect.credits and g.day == expect.day and g.delivered == expect.delivered, "credits, day and score restored")
	check(g.transit.lines.size() == expect.lines and g.transit.stops.size() == expect.stops, "bus lines and stops restored")
	check(g.world.corner[1234] == expect.corner, "terrain restored exactly")
	var moved0: int = g.delivered
	for step in int(g.day_len / 0.3):
		g.sim_step(0.3)
	check(g.delivered > moved0, "the loaded town keeps running (%d more people moved)" % (g.delivered - moved0))
	g.hud.refresh()
	g.view.update_vehicles(0.016)
