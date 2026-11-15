extends Node3D
## Tilted top-down camera. Pan with WASD / arrows, by dragging with the right
## or middle mouse button, or Shift + left button (laptops have no middle
## button); zoom with the wheel; rotate with Q and E.

const Cfg = preload("res://scripts/cfg.gd")

const DEFAULT_DIST := 40.0
const DEFAULT_PITCH := 52.0

var cam: Camera3D
var target := Vector3(Cfg.W * 0.5, 0.0, Cfg.H * 0.5)
var yaw := 0.0
var pitch := deg_to_rad(DEFAULT_PITCH)
var dist := 34.0
var goal_dist := 34.0
var dragging := false        # middle button
var left_pan := false        # Shift + left button
var right_down := false
var right_moved := 0.0
var right_dragged := false   # the right button was used to pan (not to cancel)


func _ready() -> void:
	cam = Camera3D.new()
	cam.fov = 32.0
	cam.near = 0.5
	cam.far = 400.0
	add_child(cam)
	cam.current = true
	_apply()


func focus(p: Vector3, d: float = -1.0) -> void:
	target = Vector3(p.x, 0.0, p.z)
	if d > 0.0:
		goal_dist = d


## Back to the default angle and zoom, looking at p.
func reset(p: Vector3, d: float = DEFAULT_DIST) -> void:
	target = Vector3(p.x, 0.0, p.z)
	goal_dist = d
	dist = d
	yaw = 0.0
	pitch = deg_to_rad(DEFAULT_PITCH)
	_apply()


func _apply() -> void:
	var back := Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
	cam.position = target + back * dist
	cam.look_at(target, Vector3.UP)


func _process(delta: float) -> void:
	var mv := Vector2.ZERO
	var typing := get_viewport().gui_get_focus_owner() is LineEdit
	if not typing:
		if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
			mv.y -= 1.0
		if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
			mv.y += 1.0
		if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
			mv.x -= 1.0
		if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
			mv.x += 1.0
		if Input.is_key_pressed(KEY_Q):
			yaw -= delta * 1.4
		if Input.is_key_pressed(KEY_E):
			yaw += delta * 1.4
	if mv != Vector2.ZERO:
		_pan(mv.normalized() * delta * dist * 0.9)
	dist = lerpf(dist, goal_dist, minf(1.0, delta * 10.0))
	_apply()


func _pan(v: Vector2) -> void:
	var right := Vector3(cos(yaw), 0.0, -sin(yaw))
	var fwd := Vector3(sin(yaw), 0.0, cos(yaw))
	target += right * v.x + fwd * v.y
	target.x = clampf(target.x, 0.0, Cfg.W)
	target.z = clampf(target.z, 0.0, Cfg.H)


## Moves the view so that the map point (x, z) in tile units is in the centre.
func look_at_tile(x: float, z: float) -> void:
	target = Vector3(clampf(x, 0.0, Cfg.W), 0.0, clampf(z, 0.0, Cfg.H))


## The part of the ground the camera sees, as up to four map points (tile units).
func ground_footprint() -> PackedVector2Array:
	var out := PackedVector2Array()
	var vp := get_viewport().get_visible_rect().size
	for c in [Vector2(0, 0), Vector2(vp.x, 0), Vector2(vp.x, vp.y), Vector2(0, vp.y)]:
		var o: Vector3 = cam.project_ray_origin(c)
		var d: Vector3 = cam.project_ray_normal(c)
		var t := 400.0
		if d.y < -0.001:
			t = minf(400.0, -o.y / d.y)
		var p := o + d * t
		out.append(Vector2(p.x, p.z))
	return out


func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventMouseButton:
		if e.button_index == MOUSE_BUTTON_WHEEL_UP and e.pressed:
			goal_dist = maxf(7.0, goal_dist * 0.88)
		elif e.button_index == MOUSE_BUTTON_WHEEL_DOWN and e.pressed:
			goal_dist = minf(95.0, goal_dist / 0.88)
		elif e.button_index == MOUSE_BUTTON_MIDDLE:
			dragging = e.pressed
		elif e.button_index == MOUSE_BUTTON_RIGHT:
			right_down = e.pressed
			if e.pressed:
				right_moved = 0.0
				right_dragged = false
		elif e.button_index == MOUSE_BUTTON_LEFT:
			left_pan = e.pressed and e.shift_pressed
	elif e is InputEventMouseMotion:
		var m: int = e.button_mask
		if (m & MOUSE_BUTTON_MASK_RIGHT) == 0:
			right_down = false
		if (m & MOUSE_BUTTON_MASK_LEFT) == 0:
			left_pan = false
		var pan := dragging or left_pan
		if right_down:
			# A short right click is still a "cancel"; moving the mouse pans.
			right_moved += e.relative.length()
			if right_moved > 8.0:
				right_dragged = true
			pan = pan or right_dragged
		if pan:
			_pan(-e.relative * dist * 0.0022)
	elif e is InputEventPanGesture:
		goal_dist = clampf(goal_dist * (1.0 + e.delta.y * 0.05), 7.0, 95.0)
