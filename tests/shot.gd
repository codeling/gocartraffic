extends SceneTree
## Renders a few screenshots of an automatically built town (for docs / visual checks).
## Run:  godot --path . -s tests/shot.gd -- --seed=7 --out=/tmp/shots

const Cfg = preload("res://scripts/cfg.gd")
var game
var frame := 0
var out := "user://"
var hub := Vector2i.ZERO
var stage := 0


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
	game = load("res://main.tscn").instantiate()
	root.add_child(game)


func _corridor(v: int) -> int:
	return v - 1 if v % 3 == 1 else v + 1


func _connect_all() -> void:
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


func _shot(name: String) -> void:
	var img := root.get_texture().get_image()
	img.save_png(out + "/" + name + ".png")
	print("saved ", name)


func _process(_delta: float) -> bool:
	frame += 1
	var g = game
	if frame == 5:
		_shot("01_start")
		g.hud.toggle_help()
		g.credits = 1000000
		var d0: Vector2i = g.world.districts[0].pos
		hub = Vector2i(d0.x - d0.x % 3, d0.y - d0.y % 3)
		_connect_all()
		var target := (4 * 24.0 - 6.0 + 7.6) * 15.0   # day 5, morning rush hour
		var step := 0
		while g.now < target:
			g.sim_step(0.1)
			step += 1
			if step % 300 == 0:
				_connect_all()
			if step == 600:
				var h = g.city.by_type[Cfg.HOUSE][0]
				var f = g.city.by_type[Cfg.FACTORY][0]
				g.line_draft = [h.access, f.access]
				for s in g.line_draft:
					g.add_stop(s)
				g.finish_line()
				g.line_add_bus(g.transit.lines[0])
		g.credits = 3480
		g.set_speed(1.0)
		print("buildings ", g.city.buildings.size(), " cars ", g.traffic.count, " ontime ", g.on_time_ratio())
	if frame == 40:
		_shot("02_town")
		g.toggle_overlay()
		if not g.issues.is_empty():
			g.focus_issue(g.issues[0].tile)
			g.toggle_overlay()
			g.toggle_overlay()
		else:
			g.rig.focus(Vector3(hub.x, 0, hub.y), 20.0)
			g.selected = hub.y * Cfg.W + hub.x
	if frame == 80:
		_shot("03_jam")
		g.rig.goal_dist = 11.0
		g.rig.yaw = 0.5
	if frame == 120:
		_shot("04_close")
		quit(0)
		return true
	return false
