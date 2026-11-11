extends SceneTree
## Renders screenshots of an automatically built town (for docs / visual checks).
## Run:  godot --path . -s tests/shot.gd -- --seed=7 --out=/tmp/shots

const Cfg = preload("res://scripts/cfg.gd")
var game
var frame := 0
var out := "user://"
var hub := Vector2i.ZERO


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
	game = load("res://main.tscn").instantiate()
	root.add_child(game)


func _corridor(v: int) -> int:
	return v - 1 if v % 3 == 1 else v + 1


func _connect_all() -> void:
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


func _shot(name: String) -> void:
	root.get_texture().get_image().save_png(out + "/" + name + ".png")
	print("saved ", name)


func _process(_delta: float) -> bool:
	frame += 1
	var g = game
	if frame == 4:
		g.hud.show_menu(true)
	if frame == 8:
		_shot("01_menu")
		g.hud.menu.visible = false
		g.credits = 1000000
		var d0: Vector2i = g.world.districts[0].pos
		hub = Vector2i(d0.x - d0.x % 3, d0.y - d0.y % 3)
		_connect_all()
		var target: float = (3 * 24.0 - 6.0 + 7.9) / 24.0 * g.day_len
		var step := 0
		while g.now < target:
			g.sim_step(0.3)
			step += 1
			if step % 400 == 0:
				_connect_all()
			if step == 1500:
				var h = g.city.by_type[Cfg.HOUSE][0]
				for dest in [g.city.by_type[Cfg.FACTORY][0], g.city.by_type[Cfg.SHOP][0]]:
					g.line_draft = [h.access, dest.access]
					for s in g.line_draft:
						g.add_stop(s)
					g.finish_line()
					g.line_add_bus(g.transit.lines[-1])
				var hy: int = hub.y * Cfg.W
				g.add_bike_lanes(range(hy + hub.x - 12, hy + hub.x + 12))
				g.add_lanes(range(hy + hub.x - 6, hy + hub.x + 6))
				g.build_road(g.l_path((hub.y + 1) * Cfg.W + hub.x - 2, (hub.y + 6) * Cfg.W + hub.x - 2, false), true)
				g._apply_road_change()
		g.credits = 3480
		g.set_speed(1)
		g.selected = -1
		g.selected_line = null
		print("buildings ", g.city.buildings.size(), " cars ", g.traffic.count, " bikes ", g.traffic.bikes, " walkers ", g.walkers.size())
	if frame == 30:
		_shot("02_town")
		g.rig.focus(Vector3(hub.x, 0, hub.y), 13.0)
	if frame == 70:
		_shot("03_close")
		g.rig.goal_dist = 34.0
		g.set_overlay(2)
		g.hud.toggle_stats()
		g.select_line(g.transit.lines[0])
	if frame == 110:
		_shot("04_stats")
		g.hud.toggle_stats()
		g.set_overlay(1)
		g.set_tool(g.T_BULLDOZE)
		g.hover = hub.y * Cfg.W + hub.x + 2
		g._refresh_preview()
		for b in g.city.by_type[Cfg.HOUSE]:
			if g.city.problem(b, true) != null:
				g.set_tool(g.T_INSPECT)
				g.selected = b.idx
				g.rig.focus(Vector3(b.x, 0, b.y), 30.0)
				break
	if frame == 150:
		_shot("05_problem")
		quit(0)
		return true
	return false
