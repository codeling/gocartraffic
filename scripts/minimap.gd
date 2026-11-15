extends Control
## Overview of the whole map: terrain, roads, buildings, problems and the part
## of the map the camera is looking at. Click or drag to move the camera there.

const Cfg = preload("res://scripts/cfg.gd")
const W := Cfg.W
const H := Cfg.H
const PX := 3                 # pixels per tile

const BUILDING_COLORS: Array[Color] = [
	Color(0.97, 0.88, 0.45),   # house
	Color(0.72, 0.74, 0.8),    # factory
	Color(0.95, 0.5, 0.4),     # shop
	Color(0.78, 0.5, 0.95),    # entertainment
	Color(0.45, 0.7, 0.98),    # office
]

var g
var img: Image
var tex: ImageTexture
var _t := 0.0


func setup(game) -> void:
	g = game
	custom_minimum_size = Vector2(W * PX, H * PX)
	mouse_filter = Control.MOUSE_FILTER_STOP
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	tooltip_text = "Map overview. Click or drag to move the view."
	img = Image.create(W, H, false, Image.FORMAT_RGB8)
	tex = ImageTexture.create_from_image(img)
	_rebuild()


func _rebuild() -> void:
	var world = g.world
	var roads = g.roads
	var grass := Color(0.33, 0.55, 0.27)
	var water := Color(0.2, 0.47, 0.78)
	var sand := Color(0.74, 0.69, 0.5)
	var steep := Color(0.55, 0.52, 0.46)
	for i in W * H:
		var c := grass
		if world.water[i] == 1:
			c = water
		elif world.shore[i] == 1:
			c = sand
		elif world.steep[i] == 1:
			c = steep
		img.set_pixel(i % W, i / W, c)
	for i in roads.tiles:
		img.set_pixel(i % W, i / W, Color(0.1, 0.1, 0.12) if roads.lanes[i] > 0 else Color(0.7, 0.35, 0.28))
	for b in g.city.buildings:
		img.set_pixel(b.x, b.y, BUILDING_COLORS[b.type])
	for p in g.alerts.open:
		img.set_pixel(p.tile % W, p.tile / W, Color(1.0, 0.2, 0.15))
	tex.update(img)


func _process(delta: float) -> void:
	_t -= delta
	if _t <= 0.0:
		_t = 0.8
		_rebuild()
	queue_redraw()


func _point(p: Vector2) -> Vector2:
	return Vector2(clampf(p.x, 0.0, W) / W * size.x, clampf(p.y, 0.0, H) / H * size.y)


func _draw() -> void:
	draw_texture_rect(tex, Rect2(Vector2.ZERO, size), false)
	var fp: PackedVector2Array = g.rig.ground_footprint()
	if fp.size() == 4:
		var pts := PackedVector2Array()
		for p in fp:
			pts.append(_point(p))
		var area := 0.0
		for k in 4:
			var a: Vector2 = pts[k]
			var b: Vector2 = pts[(k + 1) % 4]
			area += a.x * b.y - b.x * a.y
		if absf(area) > 4.0:
			draw_colored_polygon(pts, Color(1, 1, 1, 0.16))
		pts.append(pts[0])
		draw_polyline(pts, Color(1, 1, 1, 0.95), 1.5)
	var c := _point(Vector2(g.rig.target.x, g.rig.target.z))
	draw_circle(c, 2.0, Color(1, 1, 1, 0.95))
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.7), false, 1.0)


func _go(pos: Vector2) -> void:
	g.rig.look_at_tile(pos.x / maxf(size.x, 1.0) * W, pos.y / maxf(size.y, 1.0) * H)


func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		if e.pressed:
			_go(e.position)
		accept_event()
	elif e is InputEventMouseMotion and (e.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		_go(e.position)
		accept_event()
