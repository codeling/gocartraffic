extends Node3D
## Tilted top-down camera: pan with WASD / arrows / middle mouse, zoom with the
## wheel, rotate with Q and E.

const Cfg = preload("res://scripts/cfg.gd")

var cam: Camera3D
var target := Vector3(Cfg.W * 0.5, 0.0, Cfg.H * 0.5)
var yaw := 0.0
var pitch := deg_to_rad(52.0)
var dist := 34.0
var goal_dist := 34.0
var dragging := false


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


func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventMouseButton:
		if e.button_index == MOUSE_BUTTON_WHEEL_UP and e.pressed:
			goal_dist = maxf(7.0, goal_dist * 0.88)
		elif e.button_index == MOUSE_BUTTON_WHEEL_DOWN and e.pressed:
			goal_dist = minf(95.0, goal_dist / 0.88)
		elif e.button_index == MOUSE_BUTTON_MIDDLE:
			dragging = e.pressed
	elif e is InputEventMouseMotion and dragging:
		_pan(-e.relative * dist * 0.0022)
	elif e is InputEventPanGesture:
		goal_dist = clampf(goal_dist * (1.0 + e.delta.y * 0.05), 7.0, 95.0)
