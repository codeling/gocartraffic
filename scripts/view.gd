extends Node3D
## Everything that is drawn in the 3D world. All meshes are generated in code,
## the game ships without any art assets.

const Cfg = preload("res://scripts/cfg.gd")
const W := Cfg.W
const H := Cfg.H
const MAX_CARS := 4096
const MAX_BUSES := 256
const MAX_BIKES := 1024
const MAX_WALKERS := 1024


class MB:
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var c := PackedColorArray()

	func tri(a: Vector3, b: Vector3, cc: Vector3, col: Color) -> void:
		var nn := (cc - a).cross(b - a).normalized()
		v.append(a)
		v.append(b)
		v.append(cc)
		n.append(nn)
		n.append(nn)
		n.append(nn)
		c.append(col)
		c.append(col)
		c.append(col)

	func quad(a: Vector3, b: Vector3, cc: Vector3, d: Vector3, col: Color) -> void:
		tri(a, b, cc, col)
		tri(a, cc, d, col)

	func box(ctr: Vector3, size: Vector3, col: Color) -> void:
		var h := size * 0.5
		var p := []
		for dy in [-1, 1]:
			for dz in [-1, 1]:
				for dx in [-1, 1]:
					p.append(ctr + Vector3(h.x * dx, h.y * dy, h.z * dz))
		quad(p[4], p[5], p[7], p[6], col)   # top
		quad(p[0], p[2], p[3], p[1], col)   # bottom
		quad(p[0], p[1], p[5], p[4], col)
		quad(p[2], p[6], p[7], p[3], col)
		quad(p[0], p[4], p[6], p[2], col)
		quad(p[1], p[3], p[7], p[5], col)

	func build() -> ArrayMesh:
		var m := ArrayMesh.new()
		if v.is_empty():
			return m
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = v
		arr[Mesh.ARRAY_NORMAL] = n
		arr[Mesh.ARRAY_COLOR] = c
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		return m


var g
var world
var roads
var mat_lit: StandardMaterial3D
var mat_flat: StandardMaterial3D
var mat_overlay: StandardMaterial3D
var route_mi: MeshInstance3D
var bike_mm: MultiMesh
var walker_mm: MultiMesh
var _slot_cache := {}
var terrain_mi: MeshInstance3D
var road_mi: MeshInstance3D
var overlay_mi: MeshInstance3D
var preview_mi: MeshInstance3D
var lines_mi: MeshInstance3D
var cars_mm: MultiMesh
var bus_mm: MultiMesh
var tree_mm: MultiMesh
var tree_mmi: MultiMeshInstance3D
var trees := {}
var trees_dirty := false
var buildings_root: Node3D
var stops_root: Node3D
var stop_labels := {}
var sun: DirectionalLight3D
var env: Environment
var _mats := {}
var _meshes := {}


func setup(game) -> void:
	g = game
	world = game.world
	roads = game.roads
	mat_lit = StandardMaterial3D.new()
	mat_lit.vertex_color_use_as_albedo = true
	mat_lit.vertex_color_is_srgb = true
	mat_lit.roughness = 0.95
	mat_lit.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat_flat = StandardMaterial3D.new()
	mat_flat.vertex_color_use_as_albedo = true
	mat_flat.vertex_color_is_srgb = true
	mat_flat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat_flat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat_flat.cull_mode = BaseMaterial3D.CULL_DISABLED

	# The traffic overlay is opaque so that vehicles always stay visible on top of it.
	mat_overlay = StandardMaterial3D.new()
	mat_overlay.vertex_color_use_as_albedo = true
	mat_overlay.vertex_color_is_srgb = true
	mat_overlay.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat_overlay.cull_mode = BaseMaterial3D.CULL_DISABLED

	_setup_light()
	terrain_mi = _mesh_node(mat_lit)
	road_mi = _mesh_node(mat_lit)
	overlay_mi = _mesh_node(mat_overlay)
	overlay_mi.visible = false
	lines_mi = _mesh_node(mat_flat)
	route_mi = _mesh_node(mat_flat)
	preview_mi = _mesh_node(mat_flat)
	for mi in [overlay_mi, lines_mi, preview_mi, road_mi, route_mi]:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	buildings_root = Node3D.new()
	add_child(buildings_root)
	stops_root = Node3D.new()
	add_child(stops_root)

	build_terrain()
	_build_water()
	_build_trees()
	cars_mm = _vehicle_multimesh(_car_mesh(), MAX_CARS)
	bus_mm = _vehicle_multimesh(_bus_mesh(), MAX_BUSES)
	bike_mm = _vehicle_multimesh(_bike_mesh(), MAX_BIKES)
	walker_mm = _vehicle_multimesh(_walker_mesh(), MAX_WALKERS)


func _mesh_node(mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.material_override = mat
	add_child(mi)
	return mi


func _setup_light() -> void:
	sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52.0, -38.0, 0.0)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 110.0
	sun.light_energy = 0.8
	add_child(sun)
	env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.55, 0.72, 0.86)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.78, 0.84, 0.95)
	env.ambient_light_energy = 0.36
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)


func set_time_of_day(hour: float) -> void:
	var day: float = smoothstep(3.5, 6.0, hour) * (1.0 - smoothstep(18.5, 21.5, hour))
	sun.light_energy = lerpf(0.08, 0.8, day)
	sun.light_color = Color(1.0, 0.86, 0.7).lerp(Color(1.0, 0.98, 0.94), day)
	env.ambient_light_energy = lerpf(0.3, 0.36, day)
	env.ambient_light_color = Color(0.45, 0.52, 0.8).lerp(Color(0.78, 0.84, 0.95), day)
	env.background_color = Color(0.1, 0.13, 0.25).lerp(Color(0.55, 0.72, 0.86), day)


# ------------------------------------------------------------------ terrain

func _hash(i: int) -> float:
	var x := (i * 2654435761) & 0xffffffff
	x = ((x >> 13) ^ x) * 1274126177 & 0xffffffff
	return float(x & 0xffff) / 65535.0


func build_terrain() -> void:
	var mb := MB.new()
	for y in H:
		for x in W:
			var i := y * W + x
			var a := Vector3(x, world.corner_h(x, y), y)
			var b := Vector3(x + 1, world.corner_h(x + 1, y), y)
			var c := Vector3(x + 1, world.corner_h(x + 1, y + 1), y + 1)
			var d := Vector3(x, world.corner_h(x, y + 1), y + 1)
			var col: Color
			var r := _hash(i)
			if world.water[i] == 1:
				col = Color(0.3, 0.36, 0.3)
			elif world.shore[i] == 1:
				col = Color(0.74, 0.69, 0.5).lerp(Color(0.45, 0.62, 0.32), 0.25 + r * 0.2)
			else:
				var hh: float = (a.y + c.y) * 0.5
				col = Color(0.33, 0.55, 0.27).lerp(Color(0.5, 0.52, 0.3), clampf(hh / 3.0, 0.0, 1.0))
				if world.steep[i] == 1:
					col = col.lerp(Color(0.55, 0.52, 0.46), 0.6)
				col = col.darkened(r * 0.07)
			mb.tri(a, b, c, col)
			mb.tri(a, c, d, col.darkened(0.015))
	# Skirt so the map looks like a solid slab.
	var earth := Color(0.42, 0.34, 0.26)
	var bottom := -1.2
	for x in W:
		for y in [0, H]:
			var p := Vector3(x, world.corner_h(x, y), y)
			var q := Vector3(x + 1, world.corner_h(x + 1, y), y)
			mb.quad(p, q, Vector3(q.x, bottom, q.z), Vector3(p.x, bottom, p.z), earth)
	for y in H:
		for x in [0, W]:
			var p := Vector3(x, world.corner_h(x, y), y)
			var q := Vector3(x, world.corner_h(x, y + 1), y + 1)
			mb.quad(p, q, Vector3(q.x, bottom, q.z), Vector3(p.x, bottom, p.z), earth)
	terrain_mi.mesh = mb.build()


func _build_water() -> void:
	var mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(W, H)
	mi.mesh = pm
	mi.position = Vector3(W * 0.5, Cfg.WATER_Y, H * 0.5)
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.2, 0.47, 0.78, 0.82)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.roughness = 0.15
	m.metallic = 0.3
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


func _build_trees() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = world.seed_value + 5
	for i in W * H:
		if world.water[i] == 1 or world.shore[i] == 1:
			continue
		var p := 0.06
		if world.steep[i] == 1:
			p = 0.5
		elif world.flat[i] == 0:
			p = 0.3
		for d in world.districts:
			if Vector2(d.pos - Vector2i(i % W, i / W)).length() < 5.0:
				p *= 0.3
		if rng.randf() > p:
			continue
		var list := []
		for k in rng.randi_range(1, 3):
			var x := i % W + rng.randf_range(0.15, 0.85)
			var z := i / W + rng.randf_range(0.15, 0.85)
			var s := rng.randf_range(0.7, 1.3)
			var t := Transform3D(Basis().scaled(Vector3(s, s * rng.randf_range(0.9, 1.4), s)), Vector3(x, world.height_at(x, z), z))
			list.append([t, Color(0.16, 0.42, 0.2).lerp(Color(0.3, 0.52, 0.2), rng.randf())])
		trees[i] = list
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.0
	mesh.bottom_radius = 0.17
	mesh.height = 0.5
	mesh.radial_segments = 6
	mesh.rings = 1
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.vertex_color_is_srgb = true
	m.roughness = 1.0
	mesh.material = m
	tree_mm = MultiMesh.new()
	tree_mm.transform_format = MultiMesh.TRANSFORM_3D
	tree_mm.use_colors = true
	tree_mm.mesh = mesh
	tree_mmi = MultiMeshInstance3D.new()
	tree_mmi.multimesh = tree_mm
	add_child(tree_mmi)
	_fill_trees()


func _fill_trees() -> void:
	var n := 0
	for i in trees:
		n += trees[i].size()
	tree_mm.instance_count = n
	var k := 0
	for i in trees:
		for t in trees[i]:
			var tr: Transform3D = t[0]
			tr.origin.y += 0.25 * tr.basis.y.y
			tree_mm.set_instance_transform(k, tr)
			tree_mm.set_instance_color(k, t[1])
			k += 1
	trees_dirty = false


func clear_trees(i: int) -> void:
	if trees.has(i):
		trees.erase(i)
		trees_dirty = true


# -------------------------------------------------------------------- roads

func _rect(mb: MB, x0: float, z0: float, x1: float, z1: float, lift: float, col: Color) -> void:
	mb.quad(
		Vector3(x0, world.road_h(x0, z0) + lift, z0),
		Vector3(x1, world.road_h(x1, z0) + lift, z0),
		Vector3(x1, world.road_h(x1, z1) + lift, z1),
		Vector3(x0, world.road_h(x0, z1) + lift, z1), col)


func _arm(mb: MB, tx: int, ty: int, d: int, hw: float, inner: float, lift: float, col: Color) -> void:
	var cx := tx + 0.5
	var cz := ty + 0.5
	match d:
		0:
			_rect(mb, cx - hw, ty, cx + hw, cz - inner, lift, col)
		1:
			_rect(mb, cx + inner, cz - hw, tx + 1.0, cz + hw, lift, col)
		2:
			_rect(mb, cx - hw, cz + inner, cx + hw, ty + 1.0, lift, col)
		3:
			_rect(mb, tx, cz - hw, cx - inner, cz + hw, lift, col)


func _center(mb: MB, tx: int, ty: int, hw: float, lift: float, col: Color) -> void:
	var cx := tx + 0.5
	var cz := ty + 0.5
	var c := Vector3(cx, world.road_h(cx, cz) + lift, cz)
	var p := [
		Vector3(cx - hw, world.road_h(cx - hw, cz - hw) + lift, cz - hw),
		Vector3(cx + hw, world.road_h(cx + hw, cz - hw) + lift, cz - hw),
		Vector3(cx + hw, world.road_h(cx + hw, cz + hw) + lift, cz + hw),
		Vector3(cx - hw, world.road_h(cx - hw, cz + hw) + lift, cz + hw),
	]
	for k in 4:
		mb.tri(c, p[k], p[(k + 1) % 4], col)


func rebuild_roads() -> void:
	var mb := MB.new()
	var asphalt := Color(0.2, 0.21, 0.23)
	var deck := Color(0.36, 0.36, 0.38)
	var cycle := Color(0.62, 0.28, 0.22)
	var yellow := Color(0.92, 0.8, 0.35)
	var white := Color(0.85, 0.85, 0.85)
	var path_hw := 0.085
	_slot_cache.clear()
	for i in roads.tiles:
		var tx: int = i % W
		var ty: int = i / W
		var n: int = roads.lanes[i]
		var bridge: bool = world.water[i] == 1
		var c: int = roads.conn[i]
		var deg: int = roads.degree(i)
		var tw := path_hw
		if n == 0:
			# Stand-alone cycle path.
			_center(mb, tx, ty, path_hw, 0.0, cycle)
			for d in 4:
				if c & (1 << d):
					_arm(mb, tx, ty, d, path_hw, path_hw, 0.0, cycle)
		else:
			var hw := Cfg.half_width(n)
			tw = hw
			var col := deck if bridge else asphalt
			if roads.bike[i] == 1:
				tw = minf(hw + 0.06, 0.5)
				_center(mb, tx, ty, tw, 0.0, cycle)
			_center(mb, tx, ty, hw, 0.006, col)
			for d in 4:
				if not (c & (1 << d)):
					continue
				if roads.lanes[roads.nbr(i, d)] == 0:
					_arm(mb, tx, ty, d, path_hw, hw, 0.0, cycle)
					continue
				if roads.bike[i] == 1:
					_arm(mb, tx, ty, d, tw, tw, 0.0, cycle)
				_arm(mb, tx, ty, d, hw, hw, 0.006, col)
				var inner := hw if deg >= 3 else 0.0
				_arm(mb, tx, ty, d, 0.012, inner, 0.014, yellow)
				for k in range(1, n):
					var o := 0.01 + k * 0.15
					for sgn in [-1.0, 1.0]:
						_lane_line(mb, tx, ty, d, o * sgn, hw, white)
		if bridge:
			var top := Cfg.DECK_Y + Cfg.ROAD_LIFT - 0.01
			mb.box(Vector3(tx + 0.5, (top - 0.5) * 0.5, ty + 0.5), Vector3(0.2 if n > 0 else 0.08, top + 0.5, 0.2 if n > 0 else 0.08), Color(0.55, 0.55, 0.55))
			mb.box(Vector3(tx + 0.5, top - 0.035, ty + 0.5), Vector3(tw * 2.0 + 0.06, 0.05, tw * 2.0 + 0.06), Color(0.5, 0.5, 0.52))
			for d in 4:
				if c & (1 << d):
					var len := 0.5 - tw
					if len <= 0.001:
						continue
					var along := Vector3(Cfg.DX[d], 0, Cfg.DY[d])
					var ctr := Vector3(tx + 0.5, top - 0.035, ty + 0.5) + along * (tw + len * 0.5)
					var size := Vector3(tw * 2.0 + 0.06, 0.05, len) if d % 2 == 0 else Vector3(len, 0.05, tw * 2.0 + 0.06)
					mb.box(ctr, size, Color(0.5, 0.5, 0.52))
	road_mi.mesh = mb.build()


func _lane_line(mb: MB, tx: int, ty: int, d: int, off: float, inner: float, col: Color) -> void:
	var cx := tx + 0.5
	var cz := ty + 0.5
	var w := 0.008
	match d:
		0:
			_rect(mb, cx + off - w, ty, cx + off + w, cz - inner, 0.014, col)
		1:
			_rect(mb, cx + inner, cz + off - w, tx + 1.0, cz + off + w, 0.014, col)
		2:
			_rect(mb, cx + off - w, cz + inner, cx + off + w, ty + 1.0, 0.014, col)
		3:
			_rect(mb, tx, cz + off - w, cx - inner, cz + off + w, 0.014, col)


static func heat(c: float) -> Color:
	if c < 0.5:
		return Color(0.25, 0.8, 0.3).lerp(Color(0.98, 0.85, 0.2), c * 2.0)
	return Color(0.98, 0.85, 0.2).lerp(Color(0.92, 0.15, 0.12), (c - 0.5) * 2.0)


static func volume_color(f: float) -> Color:
	if f < 0.5:
		return Color(0.55, 0.62, 0.7).lerp(Color(0.25, 0.55, 0.95), f * 2.0)
	return Color(0.25, 0.55, 0.95).lerp(Color(0.85, 0.2, 0.85), (f - 0.5) * 2.0)


## mode 1: congestion (grey = no traffic, green = flowing, red = standing)
## mode 2: volume (how many vehicles used each road today and yesterday)
func rebuild_overlay(mode: int) -> void:
	var mb := MB.new()
	var tr = g.traffic
	var idle := Color(0.45, 0.47, 0.5)
	var lift := 0.016
	var max_flow := 1.0
	if mode == 2:
		for i in roads.tiles:
			max_flow = maxf(max_flow, tr.tile_flow(i))
	for i in roads.tiles:
		if roads.lanes[i] == 0:
			continue
		var tx: int = i % W
		var ty: int = i / W
		var hw := Cfg.half_width(roads.lanes[i])
		var c: int = roads.conn[i]
		if mode == 2:
			var col := volume_color(sqrt(tr.tile_flow(i) / max_flow))
			for d in 4:
				if c & (1 << d) and roads.lanes[roads.nbr(i, d)] > 0:
					_arm(mb, tx, ty, d, hw, hw, lift, col)
			_center(mb, tx, ty, hw, lift, col)
			continue
		var worst := 0.0
		var used := false
		for d in 4:
			if c & (1 << d):
				var n: int = roads.nbr(i, d)
				if roads.lanes[n] == 0:
					continue
				var l1 = tr.links.get(i * 4 + d)
				var l2 = tr.links.get(n * 4 + (d + 2) % 4)
				var cg: float = maxf(tr.congestion(l1), tr.congestion(l2))
				var busy: bool = (l1 != null and l1.occ_ema > 0.02) or (l2 != null and l2.occ_ema > 0.02)
				used = used or busy
				worst = maxf(worst, cg)
				_arm(mb, tx, ty, d, hw, hw, lift, heat(cg) if busy else idle)
		_center(mb, tx, ty, hw, lift, heat(worst) if used else idle)
	overlay_mi.mesh = mb.build()


## custom: [[tile, x0, z0, x1, z1, Color], ...] rectangles inside a tile.
func set_preview(tile_list: Array, col: Color, extra: Array = [], extra_col: Color = Color.WHITE, custom: Array = []) -> void:
	var mb := MB.new()
	for i in tile_list:
		var tx: int = i % W
		var ty: int = i / W
		_rect(mb, tx + 0.08, ty + 0.08, tx + 0.92, ty + 0.92, 0.07, col)
	for i in extra:
		var tx: int = i % W
		var ty: int = i / W
		_rect(mb, tx + 0.2, ty + 0.2, tx + 0.8, ty + 0.8, 0.1, extra_col)
	for e in custom:
		var tx: int = e[0] % W
		var ty: int = e[0] / W
		_rect(mb, tx + e[1], ty + e[2], tx + e[3], ty + e[4], 0.12, e[5])
	preview_mi.mesh = mb.build()


## Highlights a route (list of tiles) and its two end buildings.
func set_route(path: Array, from_idx: int, to_idx: int, col: Color) -> void:
	var mb := MB.new()
	if from_idx >= 0:
		for e in [[from_idx, Color(1, 1, 1, 0.6)], [to_idx, col]]:
			var tx: int = e[0] % W
			var ty: int = e[0] / W
			for r in [[0.0, 0.0, 1.0, 0.1], [0.0, 0.9, 1.0, 1.0], [0.0, 0.1, 0.1, 0.9], [0.9, 0.1, 1.0, 0.9]]:
				_rect(mb, tx + r[0], ty + r[1], tx + r[2], ty + r[3], 0.1, e[1])
		if path.is_empty():
			# No route exists: dotted beeline to show where they wanted to go.
			var a := Vector2(from_idx % W + 0.5, from_idx / W + 0.5)
			var b := Vector2(to_idx % W + 0.5, to_idx / W + 0.5)
			var n := int(a.distance_to(b) * 2.0)
			for k in range(1, n):
				var p := a.lerp(b, float(k) / n)
				_rect(mb, p.x - 0.08, p.y - 0.08, p.x + 0.08, p.y + 0.08, 0.1, col)
	for q in range(1, path.size()):
		var a2: int = path[q - 1]
		var b2: int = path[q]
		_ribbon(mb, a2, roads.dir_between(a2, b2), 0.0, col, 0.06, 0.05)
		_ribbon(mb, b2, roads.dir_between(b2, a2), 0.0, col, 0.06, 0.05)
	route_mi.mesh = mb.build()


# ---------------------------------------------------------------- buildings

func _mat(col: Color, metallic: float = 0.0, rough: float = 0.9) -> StandardMaterial3D:
	var key := "%s/%.1f/%.1f" % [col.to_html(), metallic, rough]
	if not _mats.has(key):
		var m := StandardMaterial3D.new()
		m.albedo_color = col
		m.metallic = metallic
		m.roughness = rough
		_mats[key] = m
	return _mats[key]


## While a building is assembled, its parts are collected here (one MB per
## surface finish) and turned into a single mesh. Hundreds of buildings made of
## separate nodes add up to thousands of draw calls, and beyond roughly 2500 the
## web renderer stops drawing the 3D scene altogether.
var _acc := {}
var _acc_on := false


func _acc_mb(metallic: float, rough: float) -> MB:
	var key := "%.1f/%.1f" % [metallic, rough]
	if not _acc.has(key):
		_acc[key] = [MB.new(), metallic, rough]
	return _acc[key][0]


func _acc_cyl(top: float, bottom: float, height: float, pos: Vector3, col: Color) -> void:
	var mb := _acc_mb(0.0, 0.9)
	var n := 12
	var yt := pos.y + height * 0.5
	var yb := pos.y - height * 0.5
	for k in n:
		var a0 := TAU * k / n
		var a1 := TAU * (k + 1) / n
		var t0 := pos + Vector3(cos(a0) * top, yt - pos.y, sin(a0) * top)
		var t1 := pos + Vector3(cos(a1) * top, yt - pos.y, sin(a1) * top)
		var b0 := pos + Vector3(cos(a0) * bottom, yb - pos.y, sin(a0) * bottom)
		var b1 := pos + Vector3(cos(a1) * bottom, yb - pos.y, sin(a1) * bottom)
		mb.quad(b0, b1, t1, t0, col)
		if top > 0.0:
			mb.tri(pos + Vector3(0, yt - pos.y, 0), t0, t1, col)
		if bottom > 0.0:
			mb.tri(pos + Vector3(0, yb - pos.y, 0), b1, b0, col)


## Triangular prism (the roof): triangle in the XY plane, extruded along Z.
func _acc_prism(size: Vector3, pos: Vector3, col: Color) -> void:
	var mb := _acc_mb(0.0, 0.9)
	var hx := size.x * 0.5
	var hy := size.y * 0.5
	var hz := size.z * 0.5
	var l0 := pos + Vector3(-hx, -hy, -hz)
	var r0 := pos + Vector3(hx, -hy, -hz)
	var a0 := pos + Vector3(0, hy, -hz)
	var l1 := pos + Vector3(-hx, -hy, hz)
	var r1 := pos + Vector3(hx, -hy, hz)
	var a1 := pos + Vector3(0, hy, hz)
	mb.tri(l0, r0, a0, col)
	mb.tri(l1, a1, r1, col)
	mb.quad(l0, a0, a1, l1, col)
	mb.quad(r0, r1, a1, a0, col)
	mb.quad(l0, l1, r1, r0, col)


func _acc_finish(parent: Node3D) -> void:
	var m := ArrayMesh.new()
	var mats: Array[Material] = []
	for key in _acc:
		var e: Array = _acc[key]
		var mb: MB = e[0]
		if mb.v.is_empty():
			continue
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = mb.v
		arr[Mesh.ARRAY_NORMAL] = mb.n
		arr[Mesh.ARRAY_COLOR] = mb.c
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		mats.append(_part_mat(e[1], e[2]))
	for i in mats.size():
		m.surface_set_material(i, mats[i])
	var mi := MeshInstance3D.new()
	mi.mesh = m
	parent.add_child(mi)
	_acc.clear()
	_acc_on = false


func _part_mat(metallic: float, rough: float) -> StandardMaterial3D:
	var key := "pm%.1f/%.1f" % [metallic, rough]
	if not _mats.has(key):
		var mt := StandardMaterial3D.new()
		mt.vertex_color_use_as_albedo = true
		mt.vertex_color_is_srgb = true
		mt.metallic = metallic
		mt.roughness = rough
		mt.cull_mode = BaseMaterial3D.CULL_DISABLED
		_mats[key] = mt
	return _mats[key]


func _box(parent: Node3D, size: Vector3, pos: Vector3, col: Color, metallic: float = 0.0, rough: float = 0.9) -> MeshInstance3D:
	if _acc_on:
		_acc_mb(metallic, rough).box(pos, size, col)
		return null
	var key := "b%s" % size
	if not _meshes.has(key):
		var bm := BoxMesh.new()
		bm.size = size
		_meshes[key] = bm
	return _part(parent, _meshes[key], pos, col, metallic, rough)


func _cyl(parent: Node3D, top: float, bottom: float, height: float, pos: Vector3, col: Color) -> MeshInstance3D:
	if _acc_on:
		_acc_cyl(top, bottom, height, pos, col)
		return null
	var key := "c%.2f/%.2f/%.2f" % [top, bottom, height]
	if not _meshes.has(key):
		var cm := CylinderMesh.new()
		cm.top_radius = top
		cm.bottom_radius = bottom
		cm.height = height
		cm.radial_segments = 12
		cm.rings = 1
		_meshes[key] = cm
	return _part(parent, _meshes[key], pos, col, 0.0, 0.9)


func _part(parent: Node3D, mesh: Mesh, pos: Vector3, col: Color, metallic: float, rough: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _mat(col, metallic, rough)
	mi.position = pos
	parent.add_child(mi)
	return mi


func add_building(b, animate: bool = true) -> void:
	clear_trees(b.idx)
	var root := Node3D.new()
	root.position = Vector3(b.x + 0.5, world.tile_h(b.x, b.y), b.y + 0.5)
	var body := Node3D.new()
	body.rotation.y = ((b.id * 7 + b.x) % 4) * PI * 0.5
	root.add_child(body)
	var r := _hash(b.id * 31 + 7)
	_acc_on = true
	_box(root, Vector3(0.92, 0.5, 0.92), Vector3(0, -0.21, 0), Color(0.5, 0.5, 0.47))
	match b.type:
		Cfg.HOUSE when b.apt:
			var tones: Array[Color] = [Color(0.86, 0.78, 0.66), Color(0.8, 0.72, 0.68), Color(0.78, 0.8, 0.76)]
			var hh: float = 0.5 + 0.1 * b.units
			_box(body, Vector3(0.56, 1.0, 0.5), Vector3(0, hh - 0.46, 0), tones[b.id % 3])
			_box(body, Vector3(0.6, 0.05, 0.54), Vector3(0, hh + 0.06, 0), Color(0.4, 0.33, 0.3))
			for fl in int(hh / 0.2):
				_box(body, Vector3(0.5, 0.06, 0.51), Vector3(0, 0.18 + fl * 0.2, 0), Color(0.4, 0.55, 0.7), 0.3, 0.3)
		Cfg.HOUSE:
			var walls: Array[Color] = [Color(0.95, 0.9, 0.78), Color(0.9, 0.82, 0.7), Color(0.85, 0.88, 0.9), Color(0.96, 0.93, 0.86)]
			var roofs: Array[Color] = [Color(0.7, 0.28, 0.2), Color(0.55, 0.25, 0.2), Color(0.35, 0.36, 0.42)]
			_box(body, Vector3(0.5, 0.3, 0.44), Vector3(0, 0.2, 0), walls[int(r * 3.99)])
			_acc_prism(Vector3(0.58, 0.2, 0.5), Vector3(0, 0.45, 0), roofs[b.id % 3])
			_box(body, Vector3(0.06, 0.14, 0.06), Vector3(0.14, 0.5, 0.1), Color(0.5, 0.3, 0.25))
		Cfg.FACTORY:
			_box(body, Vector3(0.66, 0.3, 0.56), Vector3(0, 0.2, 0), Color(0.62, 0.64, 0.68))
			_box(body, Vector3(0.68, 0.05, 0.58), Vector3(0, 0.37, 0), Color(0.38, 0.4, 0.45))
			_box(body, Vector3(0.3, 0.16, 0.3), Vector3(-0.18, 0.46, 0.08), Color(0.7, 0.55, 0.3))
			_cyl(body, 0.045, 0.06, 0.55, Vector3(0.2, 0.62, -0.14), Color(0.62, 0.3, 0.24))
			_cyl(body, 0.045, 0.06, 0.42, Vector3(0.2, 0.56, 0.08), Color(0.62, 0.3, 0.24))
		Cfg.SHOP:
			var awn: Array[Color] = [Color(0.1, 0.62, 0.6), Color(0.86, 0.32, 0.3), Color(0.25, 0.5, 0.85)]
			_box(body, Vector3(0.6, 0.26, 0.5), Vector3(0, 0.18, 0), Color(0.94, 0.92, 0.86))
			_box(body, Vector3(0.62, 0.04, 0.12), Vector3(0, 0.24, 0.27), awn[b.id % 3])
			_box(body, Vector3(0.42, 0.13, 0.05), Vector3(0, 0.38, 0.22), Color(0.98, 0.8, 0.2))
			_box(body, Vector3(0.5, 0.12, 0.02), Vector3(0, 0.12, 0.255), Color(0.45, 0.7, 0.85), 0.3, 0.2)
		Cfg.FUN:
			_cyl(body, 0.3, 0.3, 0.26, Vector3(0, 0.18, 0), Color(0.62, 0.32, 0.76))
			_cyl(body, 0.0, 0.34, 0.26, Vector3(0, 0.44, 0), Color(0.98, 0.78, 0.2))
			_cyl(body, 0.01, 0.01, 0.2, Vector3(0, 0.66, 0), Color(0.3, 0.3, 0.3))
			_box(body, Vector3(0.12, 0.07, 0.01), Vector3(0.06, 0.72, 0), Color(0.9, 0.2, 0.25))
		Cfg.OFFICE:
			var hgt := 0.7 + r * 0.6
			_box(body, Vector3(0.52, 1.0, 0.52), Vector3(0, hgt - 0.45, 0), Color(0.42, 0.6, 0.8), 0.5, 0.25)
			_box(body, Vector3(0.56, 0.05, 0.56), Vector3(0, hgt + 0.07, 0), Color(0.3, 0.33, 0.4))
			_box(body, Vector3(0.56, 0.05, 0.56), Vector3(0, 0.08, 0), Color(0.3, 0.33, 0.4))
	_acc_finish(body)
	var mark := Label3D.new()
	mark.text = "!"
	mark.font_size = 96
	mark.pixel_size = 0.006
	mark.modulate = Color(1.0, 0.25, 0.2)
	mark.outline_modulate = Color(1, 1, 1)
	mark.outline_size = 18
	mark.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	mark.no_depth_test = true
	mark.position = Vector3(0, 1.7 if b.type == Cfg.OFFICE or b.apt else 1.1, 0)
	mark.visible = false
	root.add_child(mark)
	root.set_meta("mark", mark)
	buildings_root.add_child(root)
	b.node = root
	if animate:
		body.scale = Vector3(1, 0.05, 1)
		var tw := create_tween()
		tw.tween_property(body, "scale", Vector3.ONE, 0.5).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func update_marks() -> void:
	var window: float = maxf(60.0, g.day_len * 0.04)
	for b in g.city.buildings:
		var mark: Label3D = b.node.get_meta("mark")
		var no_road: bool = b.access < 0
		var f = g.city.problem(b, false)
		var failing: bool = f != null and g.now - f.time < window
		mark.visible = no_road or failing
		if mark.visible:
			mark.modulate = Color(1.0, 0.25, 0.2) if no_road else Color(1.0, 0.7, 0.1)


# ----------------------------------------------------------------- vehicles

func _vehicle_multimesh(mesh: Mesh, cap: int) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = cap
	mm.visible_instance_count = 0
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat_lit
	mmi.custom_aabb = AABB(Vector3(-5, -5, -5), Vector3(W + 10, 20, H + 10))
	add_child(mmi)
	return mm


func _car_mesh() -> Mesh:
	var mb := MB.new()
	mb.box(Vector3(0, 0.035, 0), Vector3(0.105, 0.05, 0.21), Color.WHITE)
	mb.box(Vector3(0, 0.075, -0.012), Vector3(0.09, 0.04, 0.11), Color(0.32, 0.36, 0.42))
	return mb.build()


func _bus_mesh() -> Mesh:
	var mb := MB.new()
	mb.box(Vector3(0, 0.07, 0), Vector3(0.125, 0.12, 0.48), Color.WHITE)
	mb.box(Vector3(0, 0.085, 0), Vector3(0.13, 0.04, 0.44), Color(0.25, 0.3, 0.38))
	mb.box(Vector3(0, 0.135, 0), Vector3(0.11, 0.012, 0.42), Color(0.92, 0.92, 0.92))
	return mb.build()


func _bike_mesh() -> Mesh:
	var mb := MB.new()
	mb.box(Vector3(0, 0.025, 0), Vector3(0.016, 0.03, 0.085), Color(0.2, 0.2, 0.22))
	mb.box(Vector3(0, 0.07, -0.005), Vector3(0.034, 0.06, 0.034), Color.WHITE)
	mb.box(Vector3(0, 0.11, -0.005), Vector3(0.026, 0.026, 0.026), Color(0.95, 0.8, 0.68))
	return mb.build()


func _walker_mesh() -> Mesh:
	var mb := MB.new()
	mb.box(Vector3(0, 0.035, 0), Vector3(0.032, 0.07, 0.032), Color.WHITE)
	mb.box(Vector3(0, 0.083, 0), Vector3(0.026, 0.026, 0.026), Color(0.95, 0.8, 0.68))
	return mb.build()


## Where the k-th parked car of a building stands: along the edges of its plot,
## starting on the side that faces the road.
func _slots(b) -> Array:
	var e = _slot_cache.get(b.id)
	if e != null and e[0] == b.access:
		return e[1]
	var base := 2
	if b.access >= 0:
		base = roads.dir_between(b.idx, b.access)
	var out := []
	var y: float = world.tile_h(b.x, b.y) + 0.045
	for k in 12:
		var side: int = (base + [0, 1, 3, 2][k / 3]) % 4
		var dv := Vector3(Cfg.DX[side], 0, Cfg.DY[side])
		var tv := Vector3(-dv.z, 0, dv.x)
		var p := Vector3(b.x + 0.5, y, b.y + 0.5) + dv * 0.4 + tv * ((k % 3) - 1) * 0.24
		out.append(Transform3D(Basis(Vector3.UP, atan2(tv.x, tv.z)), p))
	_slot_cache[b.id] = [b.access, out]
	return out


func update_vehicles(delta: float) -> void:
	var ci := 0
	var bi := 0
	var ki := 0
	var T := 0.35
	var turn_rate: float = minf(1.0, delta * 14.0)
	for l in g.traffic.link_list:
		var ax: float = l.a % W + 0.5
		var az: float = l.a / W + 0.5
		var dx: float = Cfg.DX[l.dir]
		var dz: float = Cfg.DY[l.dir]
		var rx := -dz
		var rz := dx
		var straight_yaw := atan2(dx, dz)
		var nl: int = l.lanes.size()
		var bike_off: float = minf(Cfg.half_width(nl) + 0.03, 0.47) if nl > 0 else 0.04
		for qi in nl + 1:
			var queue: Array = l.lanes[qi] if qi < nl else l.bikeq
			for v in queue:
				var off := bike_off
				if v.lane >= 0:
					off = Cfg.lane_offset(v.lane)
					if v.kind == 2:
						off += 0.045
				var x: float
				var z: float
				var yaw := straight_yaw
				var pos: float = v.pos
				var pd: int = l.dir
				if v.pi > 0 and pos < T:
					pd = roads.dir_between(v.path[v.pi - 1], l.a)
					if pd < 0:
						pd = l.dir
				if pd != l.dir:
					var pdx: float = Cfg.DX[pd]
					var pdz: float = Cfg.DY[pd]
					var prx := -pdz
					var prz := pdx
					var t: float = clampf((pos + T) / (2.0 * T), 0.0, 1.0)
					var p0x := ax - pdx * T + prx * off
					var p0z := az - pdz * T + prz * off
					var p1x := ax + (prx + rx) * off
					var p1z := az + (prz + rz) * off
					var p2x := ax + dx * T + rx * off
					var p2z := az + dz * T + rz * off
					var u := 1.0 - t
					x = u * u * p0x + 2.0 * u * t * p1x + t * t * p2x
					z = u * u * p0z + 2.0 * u * t * p1z + t * t * p2z
					var tx := u * (p1x - p0x) + t * (p2x - p1x)
					var tz := u * (p1z - p0z) + t * (p2z - p1z)
					if absf(tx) + absf(tz) > 0.0001:
						yaw = atan2(tx, tz)
				else:
					x = ax + dx * pos + rx * off
					z = az + dz * pos + rz * off
				if v.has_yaw:
					v.yaw = lerp_angle(v.yaw, yaw, turn_rate)
				else:
					v.yaw = yaw
					v.has_yaw = true
				var tr := Transform3D(Basis(Vector3.UP, v.yaw), Vector3(x, world.road_h(x, z) + 0.012, z))
				if v.kind == 0:
					if ci < MAX_CARS:
						cars_mm.set_instance_transform(ci, tr)
						cars_mm.set_instance_color(ci, v.color)
						ci += 1
				elif v.kind == 1:
					if bi < MAX_BUSES:
						bus_mm.set_instance_transform(bi, tr)
						bus_mm.set_instance_color(bi, v.color)
						bi += 1
				elif ki < MAX_BIKES:
					bike_mm.set_instance_transform(ki, tr)
					bike_mm.set_instance_color(ki, v.color)
					ki += 1
	# Parked cars.
	for b in g.city.buildings:
		var list: Array = b.home_cars if b.type == Cfg.HOUSE else b.parked
		if list.is_empty():
			continue
		var slots: Array = _slots(b)
		for k in mini(list.size(), mini(b.slots, 12)):
			if ci >= MAX_CARS:
				break
			cars_mm.set_instance_transform(ci, slots[k])
			cars_mm.set_instance_color(ci, list[k])
			ci += 1
	cars_mm.visible_instance_count = ci
	bus_mm.visible_instance_count = bi
	bike_mm.visible_instance_count = ki
	_update_walkers()
	if trees_dirty:
		_fill_trees()


const CLOTHES: Array[Color] = [
	Color(0.85, 0.25, 0.25), Color(0.2, 0.4, 0.8), Color(0.95, 0.8, 0.25), Color(0.25, 0.65, 0.4),
	Color(0.9, 0.9, 0.92), Color(0.55, 0.3, 0.65), Color(0.95, 0.55, 0.2), Color(0.2, 0.2, 0.25),
]


## Pedestrians: g.walkers holds [points, people, start time, duration, colour seed].
func _update_walkers() -> void:
	var ws: Array = g.walkers
	var wi := 0
	var k := 0
	while k < ws.size():
		var w = ws[k]
		var f: float = (g.now - w[2]) / w[3]
		if f >= 1.0:
			ws[k] = ws[-1]
			ws.pop_back()
			continue
		k += 1
		var pts: PackedVector2Array = w[0]
		var p: Vector2
		var dir: Vector2
		if pts.size() == 2:
			p = pts[0].lerp(pts[1], f)
			dir = pts[1] - pts[0]
		else:
			var total := 0.0
			for q in range(1, pts.size()):
				total += pts[q - 1].distance_to(pts[q])
			var want := total * f
			p = pts[-1]
			dir = pts[-1] - pts[-2]
			for q in range(1, pts.size()):
				var seg := pts[q - 1].distance_to(pts[q])
				if want <= seg:
					p = pts[q - 1].lerp(pts[q], want / maxf(seg, 0.001))
					dir = pts[q] - pts[q - 1]
					break
				want -= seg
		dir = dir.normalized()
		var side := Vector2(-dir.y, dir.x)
		for m in w[1]:
			if wi >= MAX_WALKERS:
				break
			var q2: Vector2 = p + side * (0.05 * (m % 2) - 0.025) - dir * 0.06 * (m / 2)
			var y: float = maxf(world.height_at(q2.x, q2.y), Cfg.DECK_Y) + 0.045
			walker_mm.set_instance_transform(wi, Transform3D(Basis(Vector3.UP, atan2(dir.x, dir.y)), Vector3(q2.x, y, q2.y)))
			walker_mm.set_instance_color(wi, CLOTHES[(w[4] + m * 3) % CLOTHES.size()])
			wi += 1
	walker_mm.visible_instance_count = wi


# ---------------------------------------------------------- public transport

func rebuild_transit() -> void:
	for c in stops_root.get_children():
		c.queue_free()
	stop_labels.clear()
	for i in g.transit.stops:
		var tx: int = i % W
		var ty: int = i / W
		var root := Node3D.new()
		var px := tx + 0.88
		var pz := ty + 0.12
		root.position = Vector3(px, world.road_h(px, pz), pz)
		_cyl(root, 0.015, 0.015, 0.34, Vector3(0, 0.17, 0), Color(0.3, 0.3, 0.32))
		_box(root, Vector3(0.16, 0.12, 0.03), Vector3(0, 0.36, 0), Color(0.15, 0.4, 0.85))
		_box(root, Vector3(0.2, 0.02, 0.12), Vector3(0, 0.02, 0.06), Color(0.85, 0.8, 0.3))
		var lab := Label3D.new()
		lab.font_size = 48
		lab.pixel_size = 0.005
		lab.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		lab.no_depth_test = true
		lab.outline_size = 12
		lab.position = Vector3(0, 0.6, 0)
		lab.text = ""
		root.add_child(lab)
		stop_labels[i] = lab
		stops_root.add_child(root)
	var mb := MB.new()
	for l in g.transit.lines:
		var o: float = ((l.id % 3) - 1) * 0.045
		var col: Color = l.color
		col.a = 0.9
		for k in l.stops.size() - 1:
			var p: PackedInt64Array = roads.find_path(l.stops[k], l.stops[k + 1])
			for q in range(1, p.size()):
				var a: int = p[q - 1]
				var b: int = p[q]
				_ribbon(mb, a, roads.dir_between(a, b), o, col)
				_ribbon(mb, b, roads.dir_between(b, a), o, col)
	lines_mi.mesh = mb.build()


func _ribbon(mb: MB, i: int, d: int, o: float, col: Color, w: float = 0.028, lift: float = 0.035) -> void:
	var cx := i % W + 0.5 + o
	var cz := i / W + 0.5 + o
	var tx := float(i % W)
	var ty := float(i / W)
	match d:
		0:
			_rect(mb, cx - w, ty, cx + w, cz + w, lift, col)
		1:
			_rect(mb, cx - w, cz - w, tx + 1.0, cz + w, lift, col)
		2:
			_rect(mb, cx - w, cz - w, cx + w, ty + 1.0, lift, col)
		3:
			_rect(mb, tx, cz - w, cx + w, cz + w, lift, col)


func update_stop_labels() -> void:
	for i in stop_labels:
		var n: int = g.transit.waiting_at(i)
		stop_labels[i].text = str(n) if n > 0 else ""
