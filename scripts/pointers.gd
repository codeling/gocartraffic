extends Control
## Arrows along the edge of the screen that point at open problems which are not
## currently in view. Clicking an arrow moves the camera there.

const Cfg = preload("res://scripts/cfg.gd")
const W := Cfg.W
const MAX_MARKERS := 5
const COLORS := {
	"noroad": Color(1.0, 0.4, 0.3),
	"trip": Color(1.0, 0.7, 0.2),
	"jam": Color(0.95, 0.35, 0.65),
}


class Marker extends Control:
	var angle := 0.0
	var color := Color.WHITE
	var label := ""
	var tile := -1
	var kind := ""
	var game

	func _init() -> void:
		custom_minimum_size = Vector2(150, 28)
		size = Vector2(150, 28)
		mouse_filter = Control.MOUSE_FILTER_STOP
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.08, 0.1, 0.13, 0.85))
		draw_rect(Rect2(Vector2.ZERO, size), color, false, 2.0)
		var c := Vector2(15, 14)
		var dir := Vector2(cos(angle), sin(angle))
		var side := Vector2(-dir.y, dir.x)
		draw_colored_polygon(PackedVector2Array([c + dir * 9.0, c - dir * 6.0 + side * 7.0, c - dir * 6.0 - side * 7.0]), color)
		var font := get_theme_default_font()
		draw_string(font, Vector2(30, 19), label, HORIZONTAL_ALIGNMENT_LEFT, 116, 13, Color(0.95, 0.95, 0.95))

	func _gui_input(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			game.goto_tile(tile, kind)
			accept_event()


var g
var markers: Array = []
## Area of the screen that is free of panels; problems inside it count as visible.
var margin_left := 200.0
var margin_right := 360.0
var margin_top := 78.0
var margin_bottom := 56.0


func setup(game) -> void:
	g = game
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for k in MAX_MARKERS:
		var m := Marker.new()
		m.game = g
		m.visible = false
		add_child(m)
		markers.append(m)


func _process(_delta: float) -> void:
	var cam: Camera3D = g.rig.cam
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var area := Rect2(margin_left, margin_top, maxf(vp.x - margin_left - margin_right, 50.0), maxf(vp.y - margin_top - margin_bottom, 50.0))
	var centre := area.get_center()
	# Group problems of one kind that lie close together into one arrow.
	var groups := {}
	for p in g.alerts.open:
		var tx: int = p.tile % W
		var ty: int = p.tile / W
		var wp := Vector3(tx + 0.5, g.world.tile_h(tx, ty), ty + 0.5)
		var sp := cam.unproject_position(wp)
		if cam.is_position_behind(wp):
			sp = centre * 2.0 - sp
		elif area.has_point(sp):
			continue
		var key := "%s/%d/%d" % [p.kind, tx / 8, ty / 8]
		if not groups.has(key):
			groups[key] = {"p": p, "n": 0, "pos": sp, "d": sp.distance_to(centre)}
		groups[key].n += 1
	var list: Array = groups.values()
	list.sort_custom(func(a, b): return a.d < b.d)
	for k in markers.size():
		var m: Marker = markers[k]
		if k >= list.size():
			m.visible = false
			continue
		var e: Dictionary = list[k]
		var dir: Vector2 = (e.pos - centre)
		if dir.length() < 1.0:
			dir = Vector2.UP
		dir = dir.normalized()
		# Where the ray from the centre towards the problem leaves the free area.
		var half := area.size * 0.5 - Vector2(80.0, 16.0)
		var s := minf(half.x / maxf(absf(dir.x), 0.0001), half.y / maxf(absf(dir.y), 0.0001))
		var at := centre + dir * s
		m.angle = dir.angle()
		m.color = COLORS.get(e.p.kind, Color.WHITE)
		m.label = ("%d x " % e.n if e.n > 1 else "") + e.p.short
		m.tile = e.p.tile
		m.kind = e.p.kind
		m.tooltip_text = "Click to jump to the problem"
		m.position = at - m.size * 0.5
		m.visible = true
		m.queue_redraw()
