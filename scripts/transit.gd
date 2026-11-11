extends RefCounted
## Public transport: bus stops, bus lines and their passengers.
##
## A line is an ordered list of stops. Buses run along it to the last stop and
## then back the same way, serving every stop in both directions. Passengers
## may change lines up to twice at stops that two lines share. Buses drive on
## the player's roads, so they get stuck in the same jams as cars - but one
## bus replaces dozens of them.

const Cfg = preload("res://scripts/cfg.gd")
const Traffic = preload("res://scripts/traffic.gd")
const W := Cfg.W
const DWELL := 6.0
const DWELL_PER_PERSON := 0.8

const LINE_COLORS: Array[Color] = [
	Color(0.95, 0.3, 0.25), Color(0.2, 0.55, 0.95), Color(0.98, 0.75, 0.1),
	Color(0.6, 0.35, 0.85), Color(0.15, 0.75, 0.6), Color(0.95, 0.5, 0.75),
	Color(1.0, 0.55, 0.15), Color(0.4, 0.8, 0.25),
]


class Stop:
	var idx := 0
	var waiting: Array = []


class Line:
	var id := 0
	var color := Color.WHITE
	var stops: Array = []
	var buses: Array = []
	var pending: Array = []
	var seg: Array = []        # road distance between consecutive stops
	var length := 0.0
	var ok := true
	var alive := true
	var carried := 0
	var carried_today := 0
	var carried_yesterday := 0
	var board := {}            # stop tile -> [today, total]
	var wait_sum := 0.0
	var wait_n := 0
	var load_sum := 0.0
	var load_n := 0
	var left_behind := 0


class Pax:
	var n := 1
	var legs: Array = []
	var li := 0
	var line
	var from := 0
	var to := 0
	var w2 := 0.0
	var leg
	var t_wait := 0.0
	var dest_pos := Vector2.ZERO


class BusData:
	var line
	var si := 0
	var dirn := 1
	var pax: Array = []
	var load := 0


var g
var roads
var traffic
var city
var world
var stops := {}
var lines: Array = []
var lines_at := {}
var next_id := 1
var check_timer := 0.0
var dirty := true
var _cache := {}


func setup(game) -> void:
	g = game
	roads = game.roads
	traffic = game.traffic
	world = game.world


func _changed() -> void:
	dirty = true
	_cache.clear()
	lines_at.clear()
	for l in lines:
		for s in l.stops:
			if not lines_at.has(s):
				lines_at[s] = []
			lines_at[s].append(l)


# -------------------------------------------------------------------- stops

func add_stop(i: int) -> bool:
	if stops.has(i) or not roads.has(i):
		return false
	var s := Stop.new()
	s.idx = i
	stops[i] = s
	_changed()
	return true


func remove_stop(i: int) -> void:
	var s = stops.get(i)
	if s == null:
		return
	for l in lines.duplicate():
		if l.stops.has(i):
			if l.stops.size() <= 2:
				remove_line(l)
			else:
				l.stops.erase(i)
				_reset_line(l)
	for p in s.waiting:
		city.finish_leg(p.leg, true)
	stops.erase(i)
	_changed()


# -------------------------------------------------------------------- lines

func create_line(stop_list: Array):
	var l := Line.new()
	l.id = next_id
	next_id += 1
	l.color = LINE_COLORS[(l.id - 1) % LINE_COLORS.size()]
	for s in stop_list:
		if not l.stops.has(s):
			l.stops.append(s)
	lines.append(l)
	refresh_line(l)
	_changed()
	return l


func remove_line(l) -> void:
	l.alive = false
	_clear_riders(l)
	for v in l.buses:
		v.alive = false
	l.buses.clear()
	l.pending.clear()
	lines.erase(l)
	_changed()


func _clear_riders(l) -> void:
	for v in l.buses:
		for p in v.data.pax:
			city.finish_leg(p.leg, true)
		v.data.pax.clear()
		v.data.load = 0
	for s in stops.values():
		var keep := []
		for p in s.waiting:
			if p.line == l:
				city.finish_leg(p.leg, true)
			else:
				keep.append(p)
		s.waiting = keep


## Puts all buses of a line back to its first stop (after the line was edited).
func _reset_line(l) -> void:
	_clear_riders(l)
	var n: int = l.buses.size() + l.pending.size()
	for v in l.buses:
		v.alive = false
	l.buses.clear()
	l.pending.clear()
	for k in n:
		l.pending.append(_new_bus(l))
	refresh_line(l)
	_changed()


func _dist(a: int, b: int) -> float:
	var p: PackedInt64Array = roads.find_path(a, b)
	return -1.0 if p.is_empty() else float(p.size() - 1)


## Adds a stop where it lengthens the route least (so a stop beyond the end
## extends the line and a stop between two others is put between them).
func insert_stop(l, tile: int) -> bool:
	if l.stops.has(tile):
		return false
	var best: int = l.stops.size()
	var best_add := 1e18
	for k in l.stops.size() + 1:
		var add := 0.0
		var d1 := 0.0
		var d2 := 0.0
		if k > 0:
			d1 = _dist(l.stops[k - 1], tile)
		if k < l.stops.size():
			d2 = _dist(tile, l.stops[k])
		if d1 < 0.0 or d2 < 0.0:
			continue
		add = d1 + d2
		if k > 0 and k < l.stops.size():
			add -= maxf(0.0, l.seg[k - 1])
		if add < best_add:
			best_add = add
			best = k
	l.stops.insert(best, tile)
	_reset_line(l)
	return true


func remove_from_line(l, tile: int) -> bool:
	if not l.stops.has(tile) or l.stops.size() <= 2:
		return false
	l.stops.erase(tile)
	_reset_line(l)
	return true


func _new_bus(l):
	var v := Traffic.Vehicle.new()
	v.kind = Traffic.BUS
	v.length = Cfg.BUS_LEN
	v.color = l.color
	var d := BusData.new()
	d.line = l
	v.data = d
	return v


func add_bus(l) -> void:
	l.pending.append(_new_bus(l))
	_changed()


func remove_bus(l) -> bool:
	if not l.pending.is_empty():
		l.pending.pop_back()
		_changed()
		return true
	if l.buses.is_empty():
		return false
	var v = l.buses.pop_back()
	for p in v.data.pax:
		city.finish_leg(p.leg, true)
	v.data.pax.clear()
	v.alive = false
	_changed()
	return true


func bus_count(l) -> int:
	return l.buses.size() + l.pending.size()


func refresh_line(l) -> void:
	l.seg.clear()
	l.length = 0.0
	l.ok = true
	for k in l.stops.size() - 1:
		var d := _dist(l.stops[k], l.stops[k + 1])
		if d < 1.0:
			l.ok = false
		l.seg.append(d)
		l.length += maxf(d, 0.0)


func on_roads_changed() -> void:
	for l in lines:
		refresh_line(l)
	_changed()


func riders(l) -> int:
	var n := 0
	for v in l.buses:
		n += v.data.load
	return n


func waiting_at(i: int) -> int:
	var s = stops.get(i)
	if s == null:
		return 0
	var n := 0
	for p in s.waiting:
		n += p.n
	return n


func waiting_for(l) -> int:
	var n := 0
	for s in l.stops:
		var st = stops.get(s)
		if st != null:
			for p in st.waiting:
				if p.line == l:
					n += p.n
	return n


## Seconds for one bus to go there and back.
func round_trip(l) -> float:
	return 2.0 * (l.length / Cfg.BUS_SPEED + (l.stops.size() - 1) * (DWELL + 4.0))


func avg_wait(l) -> float:
	return round_trip(l) / (2.0 * maxi(1, bus_count(l)))


func ride_time(l, i: int, j: int) -> float:
	var d := 0.0
	for k in range(mini(i, j), maxi(i, j)):
		d += l.seg[k]
	return d / Cfg.BUS_SPEED + absi(j - i) * (DWELL + 4.0)


func new_day() -> void:
	for l in lines:
		l.carried_yesterday = l.carried_today
		l.carried_today = 0
		for s in l.board:
			l.board[s][0] = 0


# ----------------------------------------------------------------- planning

func _near_stops(b) -> Array:
	var out := []
	for s in stops:
		var sx: int = s % W
		var sy: int = s / W
		var d: int = absi(sx - b.x) + absi(sy - b.y)
		if d <= Cfg.WALK_RADIUS and lines_at.has(s) and world.dry_line(b.x + 0.5, b.y + 0.5, sx + 0.5, sy + 0.5):
			out.append([s, d])
	return out


## Fastest bus connection between two buildings with at most two changes, or null.
func plan(from_b, to_b):
	if lines.is_empty():
		return null
	var key: int = from_b.id * 4096 + to_b.id
	if _cache.has(key):
		return _cache[key]
	var res = _plan(from_b, to_b)
	_cache[key] = res
	return res


func _plan(from_b, to_b):
	var origins := _near_stops(from_b)
	if origins.is_empty():
		return null
	var dests := {}
	for e in _near_stops(to_b):
		dests[e[0]] = e[1]
	if dests.is_empty():
		return null
	var max_rides: int = Cfg.MAX_TRANSFERS + 1
	# Label-setting search over (stop, rides used).
	var cost := {}
	var prev := {}
	var open := []
	for e in origins:
		var k0: int = e[0] * 4
		cost[k0] = e[1] / Cfg.WALK_SPEED
		open.append(k0)
	var done := {}
	var best_key := -1
	var best_cost := 1e18
	while not open.is_empty():
		var bi := 0
		for q in range(1, open.size()):
			if cost[open[q]] < cost[open[bi]]:
				bi = q
		var cur: int = open[bi]
		open.remove_at(bi)
		if done.has(cur):
			continue
		done[cur] = true
		var s: int = cur / 4
		var rides: int = cur % 4
		var c: float = cost[cur]
		if c >= best_cost:
			break
		if rides > 0 and dests.has(s):
			var total: float = c + dests[s] / Cfg.WALK_SPEED
			if total < best_cost:
				best_cost = total
				best_key = cur
		if rides >= max_rides:
			continue
		for l in lines_at.get(s, []):
			if not l.ok or bus_count(l) == 0:
				continue
			if prev.has(cur) and prev[cur][1] == l:
				continue
			var i: int = l.stops.find(s)
			var w: float = avg_wait(l)
			for j in l.stops.size():
				if j == i:
					continue
				var nk: int = l.stops[j] * 4 + rides + 1
				var nc: float = c + w + ride_time(l, i, j)
				if not cost.has(nk) or nc < cost[nk]:
					cost[nk] = nc
					prev[nk] = [cur, l]
					open.append(nk)
	if best_key < 0:
		return null
	var legs := []
	var free := 0.0
	var k: int = best_key
	while prev.has(k):
		var p = prev[k]
		var l2 = p[1]
		legs.push_front({"line": l2, "from": p[0] / 4, "to": k / 4})
		free += ride_time(l2, l2.stops.find(p[0] / 4), l2.stops.find(k / 4))
		k = p[0]
	var w1: float = 0.0
	for e in origins:
		if e[0] == k / 4:
			w1 = e[1]
	var w2: float = dests[best_key / 4]
	return {"legs": legs, "w1": w1, "w2": w2, "est": best_cost, "free": free + (w1 + w2) / Cfg.WALK_SPEED}


func go(leg, pl) -> void:
	leg.mode = Cfg.M_BUS
	leg.plan = pl
	leg.limit = maxf(Cfg.TIME_FACTOR * leg.ff, pl.free * 1.3 + pl.legs.size() * 180.0) + 20.0
	var p := Pax.new()
	p.n = leg.n
	p.legs = pl.legs
	p.w2 = pl.w2
	p.leg = leg
	p.dest_pos = Vector2(leg.to.x + 0.5, leg.to.y + 0.5)
	_set_ride(p)
	var t: float = pl.w1 / Cfg.WALK_SPEED
	var s: int = p.from
	g.add_walker(PackedVector2Array([Vector2(leg.from.x + 0.5, leg.from.y + 0.5), Vector2(s % W + 0.8, s / W + 0.2)]), p.n, t)
	g.schedule(g.now + t, _at_stop.bind(p))


func _set_ride(p) -> void:
	var r = p.legs[p.li]
	p.line = r.line
	p.from = r.from
	p.to = r.to


func _at_stop(p) -> void:
	var s = stops.get(p.from)
	if s == null or not p.line.alive or not p.line.stops.has(p.to) or not p.line.stops.has(p.from):
		city.finish_leg(p.leg, true)
		return
	p.t_wait = g.now
	s.waiting.append(p)


func tick(dt: float) -> void:
	for l in lines:
		if l.pending.is_empty() or not l.ok or l.stops.size() < 2:
			continue
		var v = l.pending[0]
		var p: PackedInt64Array = roads.find_path(l.stops[0], l.stops[1])
		if p.size() < 2:
			continue
		v.path = p
		v.dest = l.stops[1]
		v.data.si = 1
		v.data.dirn = 1
		v.version = roads.version
		v.dwelling = false
		if traffic.try_spawn(v):
			l.pending.pop_front()
			l.buses.append(v)
	check_timer -= dt
	if check_timer <= 0.0:
		check_timer = 10.0
		for s in stops.values():
			var keep := []
			for p2 in s.waiting:
				if g.now - p2.t_wait > Cfg.WAIT_GIVE_UP:
					p2.line.left_behind += p2.n
					city.finish_leg(p2.leg, false)   # gave up: counts as late
				else:
					keep.append(p2)
			s.waiting = keep


func on_bus_arrive(v) -> float:
	var d = v.data
	var l = d.line
	var s: int = v.dest
	var si: int = l.stops.find(s)
	var moved := 0
	var keep := []
	for p in d.pax:
		if p.to == s or si < 0:
			moved += p.n
			d.load -= p.n
			l.carried += p.n
			l.carried_today += p.n
			if p.li + 1 < p.legs.size():
				p.li += 1
				_set_ride(p)
				_at_stop(p)
			else:
				var t: float = p.w2 / Cfg.WALK_SPEED
				g.add_walker(PackedVector2Array([Vector2(s % W + 0.8, s / W + 0.2), p.dest_pos]), p.n, t)
				g.schedule(g.now + t, city.finish_leg.bind(p.leg, false))
		else:
			keep.append(p)
	d.pax = keep
	if si < 0:
		return DWELL
	d.si = si
	if si == l.stops.size() - 1:
		d.dirn = -1
	elif si == 0:
		d.dirn = 1
	var st = stops.get(s)
	if st != null:
		var stay := []
		for p in st.waiting:
			var ti: int = l.stops.find(p.to)
			if p.line == l and ti >= 0 and signi(ti - si) == d.dirn and d.load + p.n <= Cfg.BUS_CAP:
				d.pax.append(p)
				d.load += p.n
				moved += p.n
				l.wait_sum += (g.now - p.t_wait) * p.n
				l.wait_n += p.n
				if not l.board.has(s):
					l.board[s] = [0, 0]
				l.board[s][0] += p.n
				l.board[s][1] += p.n
			else:
				stay.append(p)
		st.waiting = stay
	l.load_sum += d.load
	l.load_n += 1
	return minf(40.0, DWELL + DWELL_PER_PERSON * moved)


func on_bus_depart(v) -> bool:
	var d = v.data
	var l = d.line
	if not l.alive or l.stops.size() < 2:
		return false
	var cur: int = v.link.b
	var nxt: int = clampi(d.si + d.dirn, 0, l.stops.size() - 1)
	if l.stops[nxt] == cur:
		nxt = 1 if nxt == 0 else nxt - 1
	var p: PackedInt64Array = roads.find_path(cur, l.stops[nxt])
	if p.size() < 2:
		return false
	v.dest = l.stops[nxt]
	var p3 := PackedInt64Array([v.link.a])
	p3.append_array(p)
	v.path = p3
	v.pi = 0
	v.version = roads.version
	return true


func on_bus_lost(v) -> void:
	var l = v.data.line
	for p in v.data.pax:
		city.finish_leg(p.leg, true)
	v.data.pax.clear()
	if l.alive and l.buses.has(v):
		l.buses.erase(v)
		l.pending.append(_new_bus(l))
	_changed()


# ------------------------------------------------------------------- saving

func to_save() -> Dictionary:
	var ls := []
	for l in lines:
		var board := {}
		for s in l.board:
			board[str(s)] = l.board[s][1]
		ls.append({"id": l.id, "stops": l.stops, "buses": bus_count(l), "carried": l.carried, "board": board})
	return {"stops": stops.keys(), "lines": ls, "next_id": next_id}


func from_save(d: Dictionary) -> void:
	for s in d.stops:
		add_stop(int(s))
	for e in d.lines:
		var list := []
		for s in e.stops:
			list.append(int(s))
		next_id = int(e.id)
		var l = create_line(list)
		l.carried = int(e.carried)
		for s in e.board:
			l.board[int(s)] = [0, int(e.board[s])]
		for k in int(e.buses):
			add_bus(l)
	next_id = int(d.next_id)
