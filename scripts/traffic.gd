extends RefCounted
## Microscopic traffic simulation.
##
## Every pair of connected tiles has two directed links. A link has one queue
## per car lane plus an optional bike queue; vehicles follow the one in front
## and can only enter the next link when there is room (otherwise the queue
## spills back). Junctions with three or more arms work like an actuated
## signal: the two road axes take turns. Bikes use the bike lane where one
## exists and otherwise ride in the right-hand car lane, holding up the cars
## behind them.

const Cfg = preload("res://scripts/cfg.gd")

const CAR := 0
const BUS := 1
const BIKE := 2


class Vehicle:
	var kind := 0
	var path: PackedInt64Array
	var pi := 0
	var pos := 0.0
	var lane := 0            # -1 = bike lane
	var speed := 0.0
	var length := 0.22
	var link = null
	var color := Color.WHITE
	var people := 1
	var data = null
	var dest := -1
	var blocked := 0.0
	var stamp := -1
	var version := 0
	var dwell := 0.0
	var dwelling := false
	var alive := true
	var yaw := 0.0
	var has_yaw := false


class Link:
	var a := 0
	var b := 0
	var dir := 0
	var sf := 1.0
	var lanes: Array = []
	var last_in: Array = []   # time the last vehicle entered each lane
	var bikeq: Array = []
	var bike_last_in := -100.0
	var has_bike := false
	var n := 0
	var speed_ema := 1.0
	var occ_ema := 0.0
	var sig_ema := 0.0
	var spill_ema := 0.0
	var bus_ema := 0.0
	var bike_ema := 0.0
	var flow_day := 0
	var flow_prev := 0
	var block_next = null


class NodeCtl:
	var phase := 0
	var green_since := 0.0
	var last_cross := -100.0
	var other_wait := -100.0


var roads
var links := {}
var link_list: Array = []
var ctl := {}
var now := 0.0
var stamp := 0
var count := 0
var bikes := 0
var on_arrive: Callable
var on_lost: Callable
var bus_arrive: Callable
var bus_depart: Callable

var _f_sig := false
var _f_spill := false
var _f_bus := false
var _f_bike := false
var _room := 0.0


func setup(r) -> void:
	roads = r


func _shape(l) -> void:
	var n: int = mini(roads.lanes[l.a], roads.lanes[l.b])
	l.has_bike = n == 0 or (roads.bike[l.a] > 0 and roads.bike[l.b] > 0)
	while l.lanes.size() < n:
		l.lanes.append([])
		l.last_in.append(-100.0)
	var lost := []
	while l.lanes.size() > n:
		var gone: Array = l.lanes.pop_back()
		l.last_in.pop_back()
		if n > 0:
			_merge(l.lanes[n - 1], gone, n - 1)
		else:
			for v in gone:
				if v.kind == BIKE:
					_merge(l.bikeq, [v], -1)
				else:
					lost.append(v)
	if not l.has_bike and not l.bikeq.is_empty():
		_merge(l.lanes[0], l.bikeq, 0)
		l.bikeq = []
	for v in lost:
		if v.alive:
			v.alive = false
			on_lost.call(v)


func _merge(target: Array, src: Array, lane_index: int) -> void:
	for v in src:
		v.lane = lane_index
		target.append(v)
	target.sort_custom(func(x, y): return x.pos > y.pos)


func get_link(a: int, d: int):
	var key := a * 4 + d
	var l = links.get(key)
	if l == null:
		l = Link.new()
		l.a = a
		l.b = roads.nbr(a, d)
		l.dir = d
		l.sf = (roads.speed_factor(l.a) + roads.speed_factor(l.b)) * 0.5
		_shape(l)
		links[key] = l
		link_list.append(l)
	return l


func _touching_keys(i: int) -> Array:
	var keys := []
	for d in 4:
		keys.append(i * 4 + d)
		var n: int = roads.nbr(i, d)
		if n >= 0:
			keys.append(n * 4 + (d + 2) % 4)
	return keys


## Call after the lanes or bike lanes of a tile changed.
func on_lanes_changed(i: int) -> void:
	for key in _touching_keys(i):
		var l = links.get(key)
		if l != null:
			_shape(l)


func _drop_links(keys: Array) -> void:
	var lost := []
	for key in keys:
		var l = links.get(key)
		if l != null:
			for lane in l.lanes:
				lost.append_array(lane)
			lost.append_array(l.bikeq)
			l.lanes.clear()
			l.bikeq.clear()
			links.erase(key)
			link_list.erase(l)
	for v in lost:
		if v.alive:
			v.alive = false
			on_lost.call(v)


func on_tile_removed(i: int) -> void:
	_drop_links(_touching_keys(i))
	ctl.erase(i)


func on_unlink(a: int, b: int) -> void:
	var d: int = roads.dir_between(a, b)
	if d >= 0:
		_drop_links([a * 4 + d, b * 4 + (d + 2) % 4])


## Chooses the queue a vehicle would join on link l. Returns the lane index
## (-1 = bike lane) or -2 when nothing is free; _room holds the spare room.
func _pick(l, v, entry: float) -> int:
	if v.kind == BIKE and l.has_bike:
		_room = 10.0
		if now - l.bike_last_in < Cfg.BIKE_HEADWAY:
			_room = -1.0
		elif not l.bikeq.is_empty():
			var t = l.bikeq[-1]
			_room = t.pos - entry - (t.length + v.length) * 0.5 - Cfg.GAP
		return -1
	var best := -2
	_room = -100.0
	var n: int = l.lanes.size()
	if v.kind == BIKE:
		n = mini(n, 1)   # bikes keep to the right-hand lane
	for k in n:
		var ln: Array = l.lanes[k]
		var room := 10.0
		if now - l.last_in[k] < Cfg.HEADWAY:
			room = -1.0
		elif not ln.is_empty():
			var t = ln[-1]
			room = t.pos - entry - (t.length + v.length) * 0.5 - Cfg.GAP
		if room > _room:
			_room = room
			best = k
	return best


func _enter(l, v, lane: int, pos: float) -> void:
	v.pos = pos
	v.lane = lane
	v.link = l
	v.blocked = 0.0
	if lane < 0:
		l.bikeq.append(v)
		l.bike_last_in = now
	else:
		l.lanes[lane].append(v)
		l.last_in[lane] = now
		l.flow_day += 1


func try_spawn(v) -> bool:
	if v.path.size() < 2:
		return false
	var a: int = v.path[0]
	var d: int = roads.dir_between(a, v.path[1])
	if d < 0 or not roads.connected(a, d):
		return false
	var l = get_link(a, d)
	var best := _pick(l, v, 0.0)
	if best == -2 or _room < 0.0:
		return false
	v.pi = 0
	v.speed = 0.0
	v.stamp = stamp
	_enter(l, v, best, 0.0)
	return true


func step(dt: float) -> void:
	now += dt
	stamp += 1
	var alpha := clampf(dt / Cfg.EMA_T, 0.0, 1.0)
	var total := 0
	var nb := 0
	for link in link_list:
		var sp := 0.0
		var n := 0
		_f_sig = false
		_f_spill = false
		_f_bus = false
		_f_bike = false
		for lane in link.lanes:
			var j := 0
			while j < lane.size():
				var v = lane[j]
				if v.stamp != stamp:
					v.stamp = stamp
					if not v.alive:
						lane.remove_at(j)
						continue
					if _advance(v, link, lane, j, dt):
						continue
				n += 1
				sp += v.speed
				j += 1
		var q: Array = link.bikeq
		var j2 := 0
		while j2 < q.size():
			var v2 = q[j2]
			if v2.stamp != stamp:
				v2.stamp = stamp
				if not v2.alive:
					q.remove_at(j2)
					continue
				if _advance(v2, link, q, j2, dt):
					continue
			j2 += 1
		nb += q.size()
		link.n = n
		total += n
		if link.lanes.is_empty():
			continue
		var cap: float = link.lanes.size() * 3.4
		link.occ_ema += (n / cap - link.occ_ema) * alpha
		var ratio := 1.0
		if n > 0:
			ratio = sp / (n * Cfg.CAR_SPEED * link.sf)
		link.speed_ema += (ratio - link.speed_ema) * alpha
		link.sig_ema += ((1.0 if _f_sig else 0.0) - link.sig_ema) * alpha
		link.spill_ema += ((1.0 if _f_spill else 0.0) - link.spill_ema) * alpha
		link.bus_ema += ((1.0 if _f_bus else 0.0) - link.bus_ema) * alpha
		link.bike_ema += ((1.0 if _f_bike else 0.0) - link.bike_ema) * alpha
	count = total
	bikes = nb


func _hold(v, dt: float) -> bool:
	v.pos = Cfg.STOP
	v.speed = 0.0
	v.blocked += dt
	return false


func _lose(v, queue: Array) -> bool:
	queue.remove_at(0)
	v.alive = false
	on_lost.call(v)
	return true


func _advance(v, link, queue: Array, j: int, dt: float) -> bool:
	var vm: float = Cfg.CAR_SPEED
	var acc: float = Cfg.ACCEL
	if v.kind == BUS:
		vm = Cfg.BUS_SPEED
	elif v.kind == BIKE:
		vm = Cfg.BIKE_SPEED
		acc = Cfg.BIKE_ACCEL
	vm *= link.sf
	v.speed = minf(vm, v.speed + acc * dt)
	var np: float = v.pos + v.speed * dt
	if j > 0:
		var ld = queue[j - 1]
		var lim: float = ld.pos - (ld.length + v.length) * 0.5 - Cfg.GAP
		if np > lim:
			np = maxf(v.pos, lim)
			v.speed = (np - v.pos) / dt
			if ld.kind == BIKE and v.kind != BIKE:
				_f_bike = true
		v.pos = np
		return false
	if np < Cfg.STOP:
		v.pos = np
		return false

	# Front vehicle at the stop line.
	var pth: PackedInt64Array = v.path
	if v.pi + 2 >= pth.size():
		if v.kind != BUS:
			queue.remove_at(0)
			v.alive = false
			on_arrive.call(v)
			return true
		# Bus at a stop: let people off and on, then continue to the next stop.
		if not v.dwelling:
			v.dwelling = true
			v.dwell = bus_arrive.call(v)
		v.dwell -= dt
		if v.dwell > 0.0:
			_f_bus = true
			return _hold(v, dt)
		if not bus_depart.call(v):
			v.dwell = 10.0
			return _hold(v, dt)
		v.dwelling = false
		pth = v.path
		if v.pi + 2 >= pth.size():
			return _hold(v, dt)

	var a2: int = pth[v.pi + 1]
	var b2: int = pth[v.pi + 2]
	if v.version != roads.version:
		# The road network changed: pick a new route from the next tile.
		v.version = roads.version
		var fresh: PackedInt64Array
		if v.kind == BIKE:
			fresh = roads.find_bike_path(a2, v.dest)
		else:
			fresh = roads.find_path(a2, v.dest)
		if fresh.is_empty():
			return _lose(v, queue)
		var p3 := PackedInt64Array([pth[v.pi]])
		p3.append_array(fresh)
		v.path = p3
		v.pi = 0
		return _hold(v, 0.0)

	var d2: int = roads.dir_between(a2, b2)
	if d2 < 0 or not roads.connected(a2, d2):
		return _lose(v, queue)
	var l2 = get_link(a2, d2)
	var best := _pick(l2, v, Cfg.ENTRY)
	if best == -2:
		return _lose(v, queue)
	var room := _room
	var has_room: bool = room >= 0.0 or v.blocked >= Cfg.FORCE_AFTER

	var c = null
	if roads.degree(a2) >= 3:
		c = ctl.get(a2)
		var phase: int = link.dir & 1
		if c == null:
			c = NodeCtl.new()
			c.phase = phase
			c.green_since = now
			ctl[a2] = c
		if c.phase == phase:
			# Our axis has green - but give way if the cross street has waited long enough.
			if now - c.other_wait < 2.0 and now - c.green_since > Cfg.MAX_GREEN:
				_f_sig = true
				return _hold(v, dt)
		else:
			c.other_wait = now
			if now - c.last_cross < Cfg.CLEARANCE or now - c.green_since < Cfg.MIN_GREEN:
				_f_sig = true
				return _hold(v, dt)
			if has_room:
				c.phase = phase
				c.green_since = now

	if not has_room:
		_f_spill = true
		link.block_next = l2
		return _hold(v, dt)
	if c != null:
		c.last_cross = now

	queue.remove_at(0)
	var e: float = Cfg.ENTRY + (np - Cfg.STOP)
	if room < 10.0:
		e = minf(e, Cfg.ENTRY + room)
	v.pi += 1
	_enter(l2, v, best, e)
	return true


## 0 = free flow, 1 = standing still.
func congestion(l) -> float:
	if l == null or l.occ_ema < 0.05:
		return 0.0
	return clampf(1.0 - l.speed_ema, 0.0, 1.0)


func tile_congestion(i: int) -> float:
	var c := 0.0
	for d in 4:
		var n: int = roads.nbr(i, d)
		if n >= 0:
			c = maxf(c, congestion(links.get(n * 4 + (d + 2) % 4)))
	return c


## Drivers prefer routes that are currently flowing.
func update_weights() -> void:
	for i in roads.tiles:
		if roads.lanes[i] > 0:
			var w: float = (1.0 + 2.5 * tile_congestion(i)) / roads.speed_factor(i)
			roads.astar.set_point_weight_scale(i, w)


func new_day() -> void:
	for l in link_list:
		l.flow_prev = l.flow_day
		l.flow_day = 0


## Vehicles that used a tile (both directions, today and yesterday).
func tile_flow(i: int) -> int:
	var f := 0
	for d in 4:
		var l = links.get(i * 4 + d)
		if l != null:
			f += l.flow_day + l.flow_prev
		var n: int = roads.nbr(i, d)
		if n >= 0:
			var l2 = links.get(n * 4 + (d + 2) % 4)
			if l2 != null:
				f += l2.flow_day + l2.flow_prev
	return f / 2
