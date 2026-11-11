extends SceneTree
## Headless smoke test: builds a road network automatically, opens a bus line,
## fast-forwards five days and checks that people actually get around.
## Run:  godot --headless --path . -s tests/smoke.gd -- --seed=7

const Cfg = preload("res://scripts/cfg.gd")
var game
var frame := 0
var failures_in := 0


func _initialize() -> void:
	game = load("res://main.tscn").instantiate()
	root.add_child(game)


func _corridor(v: int) -> int:
	return v - 1 if v % 3 == 1 else v + 1


func _connect_all(hub: Vector2i) -> void:
	for b in game.city.buildings:
		if b.access >= 0:
			continue
		var cx := _corridor(b.x)
		var a: int = b.y * Cfg.W + cx
		var mid: int = hub.y * Cfg.W + cx
		var path: Array = game.l_path(a, mid)
		var rest: Array = game.l_path(mid, hub.y * Cfg.W + hub.x)
		rest.pop_front()
		path.append_array(rest)
		game.build_road(path)
	game._apply_road_change()


func _process(_delta: float) -> bool:
	frame += 1
	if frame < 3:
		return false
	var g = game
	g.credits = 1000000
	failures_in += _input_test()
	var d0: Vector2i = g.world.districts[0].pos
	var hub := Vector2i(d0.x - d0.x % 3, d0.y - d0.y % 3)
	_connect_all(hub)
	var failures := failures_in
	var max_cars := 0
	var line = null
	for step in 18000:
		g.sim_step(0.1)
		max_cars = maxi(max_cars, g.traffic.count)
		if step % 300 == 0:
			_connect_all(hub)
			g.issues = g.advisor.analyze(g)
		if step == 600:
			# Bus line between the first house and the first factory.
			var h = g.city.by_type[Cfg.HOUSE][0]
			var f = g.city.by_type[Cfg.FACTORY][0]
			g.line_draft = [h.access, f.access, g.city.by_type[Cfg.SHOP][0].access]
			for s in g.line_draft:
				g.add_stop(s)
			g.finish_line()
			line = g.transit.lines[0]
			g.line_add_bus(line)
		if step % 600 == 300:
			print("t=%5.0f  hour=%4.1f  buildings=%d  cars=%d  on-time=%.2f  delay=%.2f  delivered=%d  issues=%d" % [
				g.now, g.hour(), g.city.buildings.size(), g.traffic.count, g.on_time_ratio(), g.delay_ema, g.delivered, g.issues.size()])
			for i in g.issues:
				print("     jam: ", i.title, " @", i.tile)
	g.hud.refresh()
	g.selected = g.roads.tiles.keys()[0]
	g.inspect_text()
	g.view.rebuild_overlay()
	g.view.update_vehicles(0.016)
	# Bulldoze part of the network while traffic is running.
	var keys: Array = g.roads.tiles.keys()
	for k in range(0, keys.size(), 7):
		g.bulldoze(keys[k])
	g._apply_road_change()
	for step in 600:
		g.sim_step(0.1)
	g.view.update_vehicles(0.016)
	print("max cars on road: ", max_cars, "  bus carried: ", line.carried if line != null else -1)
	if g.delivered < 100:
		failures += 1
		print("FAIL: too few people delivered")
	if line == null or line.carried <= 0:
		failures += 1
		print("FAIL: bus line carried nobody")
	if max_cars < 5:
		failures += 1
		print("FAIL: no traffic")
	print("SMOKE TEST ", "PASSED" if failures == 0 else "FAILED")
	quit(failures)
	return true


## Drives the road tool with synthetic mouse events.
func _input_test() -> int:
	var g = game
	var cam: Camera3D = g.rig.cam
	var a := Vector2i(-1, -1)
	# Find a free horizontal strip of land near the camera target.
	var c := Vector2i(int(g.rig.target.x), int(g.rig.target.z))
	for y in range(c.y - 6, c.y + 6):
		for x in range(c.x - 8, c.x + 4):
			var free := true
			for k in 5:
				var i: int = y * Cfg.W + x + k
				if g.world.water[i] == 1 or g.city.bmap.has(i) or g.roads.has(i):
					free = false
			if free and a.x < 0:
				a = Vector2i(x, y)
	if a.x < 0:
		print("input test skipped: no free strip")
		return 0
	var p0: Vector2 = cam.unproject_position(Vector3(a.x + 0.5, g.world.tile_h(a.x, a.y), a.y + 0.5))
	var p1: Vector2 = cam.unproject_position(Vector3(a.x + 4.5, g.world.tile_h(a.x + 4, a.y), a.y + 0.5))
	if g.pick_tile(p0) != a.y * Cfg.W + a.x:
		print("FAIL: pick_tile returned ", g.pick_tile(p0), " expected ", a.y * Cfg.W + a.x)
		return 1
	g.set_tool(g.T_ROAD)
	var before: int = g.roads.tiles.size()
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = p0
	g._unhandled_input(down)
	var mv := InputEventMouseMotion.new()
	mv.position = p1
	g._unhandled_input(mv)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = p1
	g._unhandled_input(up)
	g.set_tool(g.T_INSPECT)
	if g.roads.tiles.size() != before + 5:
		print("FAIL: road tool built ", g.roads.tiles.size() - before, " tiles, expected 5")
		return 1
	print("input test ok")
	return 0
