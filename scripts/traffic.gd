extends RefCounted
## Microscopic traffic simulation.
##
## Every pair of connected road tiles has two directed links. A link has one
## queue per lane; vehicles follow the one in front and can only enter the next
## link when there is room (otherwise the queue spills back). Junctions with
## three or more arms work like an actuated signal: the two road axes take turns.

const Cfg = preload("res://scripts/cfg.gd")

const R_NONE := 0
const R_SIGNAL := 1
const R_SPILL := 2
const R_BUS := 3


class Vehicle:
	var kind := 0            # 0 car, 1 bus
	var path: PackedInt64Array
	var pi := 0
	var pos := 0.0
	var lane := 0
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
	var n := 0
	var speed_ema := 1.0
	var occ_ema := 0.0
	var sig_ema := 0.0
	var spill_ema := 0.0
	var bus_ema := 0.0
	var flow := 0
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
var on_arrive: Callable
var on_lost: Callable
var bus_arrive: Callable
var bus_depart: Callable

var _f_sig := false
var _f_spill := false
var _f_bus := false


func setup(r) -> void:
	roads = r


func get_link(a: int, d: int):
	var key := a * 4 + d
	var l = links.get(key)
	if l == null:
		l = Link.new()
		l.a = a
		l.b = roads.nbr(a, d)
		l.dir = d
		l.sf = (roads.speed_factor(l.a) + roads.speed_factor(l.b)) * 0.5
		var n: int = mini(roads.lanes[l.a], roads.lanes[l.b])
		for k in maxi(n, 1):
			l.lanes.append([])
			l.last_in.append(-100.0)
		links[key] = l
		link_list.append(l)
	return l


func peek_link(a: int, d: int):
	return links.get(a * 4 + d)


func _touching_keys(i: int) -> Array:
	var keys := []
	for d in 4:
		keys.append(i * 4 + d)
		var n: int = roads.nbr(i, d)
		if n >= 0:
			keys.append(n * 4 + (d + 2) % 4)
	return keys


func on_lanes_changed(i: int) -> void:
	for key in _touching_keys(i):
		var l = links.get(key)
		if l != null:
			var n: int = mini(roads.lanes[l.a], roads.lanes[l.b])
			while l.lanes.size() < n:
				l.lanes.append([])
				l.last_in.append(-100.0)


func on_tile_removed(i: int) -> void:
	var lost := []
	for key in _touching_keys(i):
		var l = links.get(key)
		if l != null:
			for lane in l.lanes:
				for v in lane:
					lost.append(v)
			l.lanes.clear()
			links.erase(key)
			link_list.erase(l)
	ctl.erase(i)
	for v in lost:
		if v.alive:
			v.alive = false
			on_lost.call(v)


func try_spawn(v) -> bool:
	if v.path.size() < 2:
		return false
	var a: int = v.path[0]
	var d: int = roads.dir_between(a, v.path[1])
	if d < 0 or (roads.conn[a] & (1 << d)) == 0:
		return false
	var l = get_link(a, d)
	var best := -1
	var best_room := -1.0
	for k in l.lanes.size():
		var ln: Array = l.lanes[k]
		var room := 10.0
		if now - l.last_in[k] < Cfg.HEADWAY:
			room = -1.0
		elif not ln.is_empty():
			var t = ln[-1]
			room = t.pos - (t.length + v.length) * 0.5 - Cfg.GAP
		if room > best_room:
			best_room = room
			best = k
	if best_room < 0.0:
		return false
	v.pi = 0
	v.pos = 0.0
	v.speed = 0.0
	v.lane = best
	v.link = l
	v.stamp = stamp
	v.blocked = 0.0
	l.lanes[best].append(v)
	l.last_in[best] = now
	l.flow += 1
	return true


func step(dt: float) -> void:
	now += dt
	stamp += 1
	var alpha := clampf(dt / 4.0, 0.0, 1.0)
	var total := 0
	for link in link_list:
		var sp := 0.0
		var n := 0
		_f_sig = false
		_f_spill = false
		_f_bus = false
		var vmax: float = Cfg.CAR_SPEED * link.sf
		for lane in link.lanes:
			var j := 0
			while j < lane.size():
				var v = lane[j]
				if v.stamp != stamp:
					v.stamp = stamp
					if not v.alive:
						lane.remove_at(j)
						continue
					if _advance(v, link, lane, j, dt, vmax):
						continue
				n += 1
				sp += v.speed
				j += 1
		link.n = n
		total += n
		var cap: float = link.lanes.size() * 3.4
		link.occ_ema += (n / cap - link.occ_ema) * alpha
		var ratio := 1.0
		if n > 0:
			ratio = sp / (n * vmax)
		link.speed_ema += (ratio - link.speed_ema) * alpha
		link.sig_ema += ((1.0 if _f_sig else 0.0) - link.sig_ema) * alpha
		link.spill_ema += ((1.0 if _f_spill else 0.0) - link.spill_ema) * alpha
		link.bus_ema += ((1.0 if _f_bus else 0.0) - link.bus_ema) * alpha
	count = total


func _hold(v, dt: float) -> bool:
	v.pos = Cfg.STOP
	v.speed = 0.0
	v.blocked += dt
	return false


func _advance(v, link, lane: Array, j: int, dt: float, vmax: float) -> bool:
	var vm: float = vmax if v.kind == 0 else vmax * (Cfg.BUS_SPEED / Cfg.CAR_SPEED)
	v.speed = minf(vm, v.speed + Cfg.ACCEL * dt)
	var np: float = v.pos + v.speed * dt
	if j > 0:
		var ld = lane[j - 1]
		var lim: float = ld.pos - (ld.length + v.length) * 0.5 - Cfg.GAP
		if np > lim:
			np = maxf(v.pos, lim)
			v.speed = (np - v.pos) / dt
		v.pos = np
		return false
	if np < Cfg.STOP:
		v.pos = np
		return false

	# Front vehicle at the stop line.
	var pth: PackedInt64Array = v.path
	if v.pi + 2 >= pth.size():
		if v.kind == 0:
			lane.remove_at(0)
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
			v.dwell = 2.0
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
		var fresh: PackedInt64Array = roads.find_path(a2, v.dest)
		if fresh.is_empty():
			lane.remove_at(0)
			v.alive = false
			on_lost.call(v)
			return true
		var p3 := PackedInt64Array([pth[v.pi]])
		p3.append_array(fresh)
		v.path = p3
		v.pi = 0
		return _hold(v, 0.0)

	var d2: int = roads.dir_between(a2, b2)
	var l2 = get_link(a2, d2)
	var best := -1
	var best_room := -100.0
	for k in l2.lanes.size():
		var ln: Array = l2.lanes[k]
		var room := 10.0
		if now - l2.last_in[k] < Cfg.HEADWAY:
			room = -1.0
		elif not ln.is_empty():
			var t = ln[-1]
			room = t.pos - Cfg.ENTRY - (t.length + v.length) * 0.5 - Cfg.GAP
		if room > best_room:
			best_room = room
			best = k
	var has_room: bool = best >= 0 and (best_room >= 0.0 or v.blocked >= 30.0)

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
			if now - c.other_wait < 0.5 and now - c.green_since > Cfg.MAX_GREEN:
				_f_sig = true
				return _hold(v, dt)
		else:
			c.other_wait = now
			if now - c.last_cross < Cfg.CLEARANCE or now - c.green_since < 1.0:
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

	lane.remove_at(0)
	var e: float = Cfg.ENTRY + (np - Cfg.STOP)
	if best_room < 10.0:
		e = minf(e, Cfg.ENTRY + best_room)
	v.pos = e
	v.pi += 1
	v.lane = best
	v.link = l2
	v.blocked = 0.0
	l2.lanes[best].append(v)
	l2.last_in[best] = now
	l2.flow += 1
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
		var w: float = (1.0 + 2.5 * tile_congestion(i)) / roads.speed_factor(i)
		roads.astar.set_point_weight_scale(i, w)
