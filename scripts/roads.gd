extends RefCounted
## Road network on the tile grid.
##
## Every tile stores the number of car lanes per direction (0 = no road), a
## bike flag (1 = bike lanes beside the road, 2 = stand-alone cycle path) and
## a bitmask of the neighbours it is connected to. Cars are routed on the
## road graph only, bikes on roads and cycle paths.

const Cfg = preload("res://scripts/cfg.gd")
const W := Cfg.W
const H := Cfg.H

var world
var lanes := PackedByteArray()
var bike := PackedByteArray()
var conn := PackedByteArray()
var astar := AStar2D.new()
var astar_bike := AStar2D.new()
var version := 1
var tiles := {}


func setup(w) -> void:
	world = w
	lanes.resize(W * H)
	lanes.fill(0)
	bike.resize(W * H)
	bike.fill(0)
	conn.resize(W * H)
	conn.fill(0)


## Car road?
func has(i: int) -> bool:
	return i >= 0 and lanes[i] > 0


## Road or cycle path?
func any(i: int) -> bool:
	return i >= 0 and (lanes[i] > 0 or bike[i] == 2)


func nbr(i: int, d: int) -> int:
	var x: int = i % W + Cfg.DX[d]
	var y: int = i / W + Cfg.DY[d]
	if x < 0 or y < 0 or x >= W or y >= H:
		return -1
	return y * W + x


func dir_between(a: int, b: int) -> int:
	var diff := b - a
	if diff == -W:
		return 0
	if diff == 1 and a % W != W - 1:
		return 1
	if diff == W:
		return 2
	if diff == -1 and a % W != 0:
		return 3
	return -1


func degree(i: int) -> int:
	var c := conn[i]
	return (c & 1) + ((c >> 1) & 1) + ((c >> 2) & 1) + ((c >> 3) & 1)


func connected(a: int, d: int) -> bool:
	return (conn[a] & (1 << d)) != 0


# -------------------------------------------------------------------- costs

func road_cost(i: int) -> int:
	if world.water[i] == 1:
		return Cfg.COST_BRIDGE
	if world.steep[i] == 1:
		return Cfg.COST_STEEP
	return Cfg.COST_ROAD


func bikepath_cost(i: int) -> int:
	if world.water[i] == 1:
		return Cfg.COST_BIKEPATH_BRIDGE
	if world.steep[i] == 1:
		return Cfg.COST_BIKEPATH_STEEP
	return Cfg.COST_BIKEPATH


func speed_factor(i: int) -> float:
	return Cfg.STEEP_SPEED if world.steep[i] == 1 else 1.0


func plan_cost(path: Array, bike_path: bool) -> int:
	var c := 0
	for i in path:
		if bike_path:
			if lanes[i] == 0 and bike[i] == 0:
				c += bikepath_cost(i)
		elif lanes[i] == 0:
			c += road_cost(i)
	return c


func upgrade_cost(path: Array) -> int:
	var c := 0
	for i in path:
		if lanes[i] > 0 and lanes[i] < Cfg.MAX_LANES:
			c += road_cost(i)
	return c


func bikelane_cost(path: Array) -> int:
	var c := 0
	for i in path:
		if lanes[i] > 0 and bike[i] == 0:
			c += Cfg.COST_BIKELANE
	return c


# ----------------------------------------------------------------- building

func _bike_weight(i: int) -> void:
	var w := 1.0 if bike[i] > 0 else 1.5
	astar_bike.set_point_weight_scale(i, w / speed_factor(i))


func _place(i: int, bike_path: bool, rec: Dictionary) -> void:
	var pos := Vector2(i % W, i / W)
	if bike_path:
		if lanes[i] == 0 and bike[i] == 0:
			rec.tiles.append([i, 0, 0])
			bike[i] = 2
			tiles[i] = true
			astar_bike.add_point(i, pos)
			_bike_weight(i)
		return
	if lanes[i] > 0:
		return
	rec.tiles.append([i, 0, bike[i]])
	var was_path := bike[i] == 2
	lanes[i] = 1
	astar.add_point(i, pos, 1.0 / speed_factor(i))
	if was_path:
		# A cycle path that becomes a road keeps its bike lanes.
		bike[i] = 1
		for d in 4:
			if connected(i, d) and lanes[nbr(i, d)] > 0:
				astar.connect_points(i, nbr(i, d))
	else:
		tiles[i] = true
		astar_bike.add_point(i, pos)
	_bike_weight(i)


func _link(a: int, b: int, rec: Dictionary) -> void:
	var d := dir_between(a, b)
	if d < 0 or connected(a, d):
		return
	conn[a] = conn[a] | (1 << d)
	conn[b] = conn[b] | (1 << ((d + 2) % 4))
	astar_bike.connect_points(a, b)
	if lanes[a] > 0 and lanes[b] > 0:
		astar.connect_points(a, b)
	rec.conns.append([a, b])


## A freshly drawn end joins the road it runs into.
func _auto_end(end: int, prev: int, rec: Dictionary) -> void:
	if degree(end) != 1:
		return
	var d := dir_between(prev, end)
	if d < 0:
		return
	var ahead := nbr(end, d)
	if any(ahead):
		_link(end, ahead, rec)
		return
	for s in [(d + 1) % 4, (d + 3) % 4]:
		var n := nbr(end, s)
		if any(n):
			_link(end, n, rec)


## Builds a road (or cycle path) along 4-connected tiles. Returns a record
## that revert() can undo.
func build(path: Array, bike_path: bool = false) -> Dictionary:
	var rec := {"tiles": [], "conns": []}
	for k in path.size():
		_place(path[k], bike_path, rec)
		if k > 0:
			_link(path[k - 1], path[k], rec)
	if path.size() == 1:
		if degree(path[0]) == 0:
			for d in 4:
				if any(nbr(path[0], d)):
					_link(path[0], nbr(path[0], d), rec)
	elif path.size() > 1:
		_auto_end(path[0], path[1], rec)
		_auto_end(path[-1], path[-2], rec)
	version += 1
	return rec


func unlink(a: int, b: int) -> void:
	var d := dir_between(a, b)
	if d < 0 or not connected(a, d):
		return
	conn[a] = conn[a] & (15 - (1 << d))
	conn[b] = conn[b] & (15 - (1 << ((d + 2) % 4)))
	if astar_bike.has_point(a) and astar_bike.has_point(b) and astar_bike.are_points_connected(a, b):
		astar_bike.disconnect_points(a, b)
	if astar.has_point(a) and astar.has_point(b) and astar.are_points_connected(a, b):
		astar.disconnect_points(a, b)
	version += 1


## Removes everything on a tile.
func remove(i: int) -> void:
	if not any(i):
		return
	for d in 4:
		if connected(i, d):
			var n := nbr(i, d)
			conn[n] = conn[n] & (15 - (1 << ((d + 2) % 4)))
	conn[i] = 0
	if lanes[i] > 0:
		astar.remove_point(i)
	astar_bike.remove_point(i)
	lanes[i] = 0
	bike[i] = 0
	tiles.erase(i)
	version += 1


## Turns a road back into the cycle path it was built over.
func downgrade_to_path(i: int) -> void:
	if lanes[i] == 0:
		return
	astar.remove_point(i)
	lanes[i] = 0
	bike[i] = 2
	_bike_weight(i)
	version += 1


## Undo for build(). Returns {"removed": [tiles], "unlinked": [[a, b]], "changed": [tiles]}.
func revert(rec: Dictionary) -> Dictionary:
	var out := {"removed": [], "unlinked": [], "changed": []}
	for c in rec.conns:
		if any(c[0]) and any(c[1]) and connected(c[0], dir_between(c[0], c[1])):
			unlink(c[0], c[1])
			out.unlinked.append(c)
	for t in rec.tiles:
		var i: int = t[0]
		if not any(i):
			continue
		if t[1] == 0 and t[2] == 2:
			downgrade_to_path(i)
			out.changed.append(i)
		else:
			remove(i)
			out.removed.append(i)
	version += 1
	return out


func add_lanes(path: Array) -> Array:
	var changed := []
	for i in path:
		if lanes[i] > 0 and lanes[i] < Cfg.MAX_LANES:
			lanes[i] += 1
			changed.append(i)
	return changed


func remove_lane(i: int) -> bool:
	if lanes[i] <= 1:
		return false
	lanes[i] -= 1
	return true


func add_bike_lanes(path: Array) -> Array:
	var changed := []
	for i in path:
		if lanes[i] > 0 and bike[i] == 0:
			bike[i] = 1
			_bike_weight(i)
			changed.append(i)
	if not changed.is_empty():
		version += 1
	return changed


func remove_bike_lane(i: int) -> bool:
	if lanes[i] == 0 or bike[i] != 1:
		return false
	bike[i] = 0
	_bike_weight(i)
	version += 1
	return true


# ------------------------------------------------------------------ routing

func find_path(a: int, b: int) -> PackedInt64Array:
	if a < 0 or b < 0 or lanes[a] == 0 or lanes[b] == 0:
		return PackedInt64Array()
	return astar.get_id_path(a, b)


func find_bike_path(a: int, b: int) -> PackedInt64Array:
	if not any(a) or not any(b):
		return PackedInt64Array()
	return astar_bike.get_id_path(a, b)


func path_cost(astar_ref: AStar2D, path: PackedInt64Array) -> float:
	var t := 0.0
	for i in path:
		t += astar_ref.get_point_weight_scale(i)
	return t


# ------------------------------------------------------------------- saving

func to_save() -> Array:
	var out := []
	for i in tiles:
		out.append([i, lanes[i], bike[i], conn[i]])
	return out


func from_save(list: Array) -> void:
	for e in list:
		var i := int(e[0])
		var pos := Vector2(i % W, i / W)
		lanes[i] = int(e[1])
		bike[i] = int(e[2])
		conn[i] = int(e[3])
		tiles[i] = true
		astar_bike.add_point(i, pos)
		_bike_weight(i)
		if lanes[i] > 0:
			astar.add_point(i, pos, 1.0 / speed_factor(i))
	for i in tiles:
		for d in [1, 2]:
			if connected(i, d):
				var n := nbr(i, d)
				if n < 0 or not tiles.has(n):
					continue
				astar_bike.connect_points(i, n)
				if lanes[i] > 0 and lanes[n] > 0:
					astar.connect_points(i, n)
	version += 1
