extends RefCounted
## Road network on the tile grid. Each road tile stores the number of lanes per
## direction and a bitmask of the neighbours it is connected to.

const Cfg = preload("res://scripts/cfg.gd")
const W := Cfg.W
const H := Cfg.H

var world
var lanes := PackedByteArray()
var conn := PackedByteArray()
var astar := AStar2D.new()
var version := 1
var tiles := {}


func setup(w) -> void:
	world = w
	lanes.resize(W * H)
	lanes.fill(0)
	conn.resize(W * H)
	conn.fill(0)


func has(i: int) -> bool:
	return i >= 0 and lanes[i] > 0


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


func tile_cost(i: int) -> int:
	if world.water[i] == 1:
		return Cfg.COST_BRIDGE
	if world.steep[i] == 1:
		return Cfg.COST_STEEP
	return Cfg.COST_ROAD


func speed_factor(i: int) -> float:
	return Cfg.STEEP_SPEED if world.steep[i] == 1 else 1.0


func plan_cost(path: Array) -> int:
	var c := 0
	for i in path:
		if lanes[i] == 0:
			c += tile_cost(i)
	return c


func upgrade_cost(path: Array) -> int:
	var c := 0
	for i in path:
		if lanes[i] > 0 and lanes[i] < Cfg.MAX_LANES:
			c += tile_cost(i)
	return c


func build(path: Array) -> void:
	for k in path.size():
		var i: int = path[k]
		if lanes[i] == 0:
			lanes[i] = 1
			tiles[i] = true
			astar.add_point(i, Vector2(i % W, i / W), 1.0 / speed_factor(i))
		if k > 0:
			_connect(path[k - 1], i)
	version += 1


func _connect(a: int, b: int) -> void:
	var d := dir_between(a, b)
	if d < 0:
		return
	conn[a] = conn[a] | (1 << d)
	conn[b] = conn[b] | (1 << ((d + 2) % 4))
	if not astar.are_points_connected(a, b):
		astar.connect_points(a, b)


func upgrade(path: Array) -> Array:
	var changed := []
	for i in path:
		if lanes[i] > 0 and lanes[i] < Cfg.MAX_LANES:
			lanes[i] += 1
			changed.append(i)
	return changed


func remove(i: int) -> int:
	if lanes[i] == 0:
		return 0
	var refund := int(tile_cost(i) * lanes[i] * Cfg.REFUND)
	for d in 4:
		if conn[i] & (1 << d):
			var n := nbr(i, d)
			if n >= 0:
				conn[n] = conn[n] & (15 - (1 << ((d + 2) % 4)))
	conn[i] = 0
	lanes[i] = 0
	tiles.erase(i)
	astar.remove_point(i)
	version += 1
	return refund


func find_path(a: int, b: int) -> PackedInt64Array:
	if a < 0 or b < 0 or lanes[a] == 0 or lanes[b] == 0:
		return PackedInt64Array()
	return astar.get_id_path(a, b)
