extends RefCounted
## Public transport: bus stops, circular bus lines and their passengers.
## Buses drive on the player's roads, so they get stuck in the same jams as
## cars - but one bus replaces dozens of them.

const Cfg = preload("res://scripts/cfg.gd")
const Traffic = preload("res://scripts/traffic.gd")
const W := Cfg.W

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
	var seg: Array = []
	var cycle := 0.0
	var ok := true
	var alive := true
	var carried := 0


class Pax:
	var n := 1
	var line
	var from := 0
	var to := 0
	var w2 := 0.0
	var leg
	var t_wait := 0.0


class BusData:
	var line
	var si := 0
	var pax: Array = []
	var load := 0


var g
var roads
var traffic
var city
var stops := {}
var lines: Array = []
var next_id := 1
var check_timer := 0.0
var dirty := true


func setup(game) -> void:
	g = game
	roads = game.roads
	traffic = game.traffic


func add_stop(i: int) -> bool:
	if stops.has(i) or not roads.has(i):
		return false
	var s := Stop.new()
	s.idx = i
	stops[i] = s
	dirty = true
	return true


func remove_stop(i: int) -> void:
	var s = stops.get(i)
	if s == null:
		return
	for l in lines.duplicate():
		if l.stops.has(i):
			var keep := []
			for st in l.stops:
				if st != i:
					keep.append(st)
			# Drop consecutive duplicates that the removal may have created.
			var clean := []
			for st in keep:
				if clean.is_empty() or clean[-1] != st:
					clean.append(st)
			if clean.size() > 1 and clean[0] == clean[-1]:
				clean.pop_back()
			if clean.size() < 2:
				remove_line(l)
			else:
				l.stops = clean
				_reset_line(l)
	for p in s.waiting:
		city.finish_leg(p.leg, true)
	stops.erase(i)
	dirty = true


func create_line(stop_list: Array):
	var l := Line.new()
	l.id = next_id
	next_id += 1
	l.color = LINE_COLORS[(l.id - 1) % LINE_COLORS.size()]
	l.stops = stop_list.duplicate()
	lines.append(l)
	refresh_line(l)
	dirty = true
	return l


func remove_line(l) -> void:
	l.alive = false
	_clear_riders(l)
	for v in l.buses:
		v.alive = false
	l.buses.clear()
	l.pending.clear()
	lines.erase(l)
	dirty = true


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
	dirty = true


func _new_bus(l):
	var v := Traffic.Vehicle.new()
	v.kind = 1
	v.length = Cfg.BUS_LEN
	v.color = l.color
	var d := BusData.new()
	d.line = l
	v.data = d
	return v


func add_bus(l) -> void:
	l.pending.append(_new_bus(l))
	dirty = true


func remove_bus(l) -> bool:
	if not l.pending.is_empty():
		l.pending.pop_back()
		dirty = true
		return true
	if l.buses.is_empty():
		return false
	var v = l.buses.pop_back()
	for p in v.data.pax:
		city.finish_leg(p.leg, true)
	v.data.pax.clear()
	v.alive = false
	dirty = true
	return true


func bus_count(l) -> int:
	return l.buses.size() + l.pending.size()


func refresh_line(l) -> void:
	l.seg.clear()
	l.cycle = 0.0
	l.ok = true
	var n: int = l.stops.size()
	for k in n:
		var p: PackedInt64Array = roads.find_path(l.stops[k], l.stops[(k + 1) % n])
		if p.size() < 2:
			l.ok = false
			l.seg.append(-1.0)
		else:
			l.seg.append(float(p.size() - 1))
			l.cycle += p.size() - 1


func on_roads_changed() -> void:
	for l in lines:
		refresh_line(l)
	dirty = true


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


## Best direct bus connection between two buildings, or null.
func plan(from_b, to_b):
	var best = null
	for l in lines:
		if not l.ok or bus_count(l) == 0:
			continue
		var bi := -1
		var bj := -1
		var di := Cfg.WALK_RADIUS + 1
		var dj := Cfg.WALK_RADIUS + 1
		for k in l.stops.size():
			var s: int = l.stops[k]
			var sx := s % W
			var sy := s / W
			var d1: int = absi(sx - from_b.x) + absi(sy - from_b.y)
			var d2: int = absi(sx - to_b.x) + absi(sy - to_b.y)
			if d1 < di:
				di = d1
				bi = k
			if d2 < dj:
				dj = d2
				bj = k
		if bi < 0 or bj < 0 or l.stops[bi] == l.stops[bj]:
			continue
		var ride := 0.0
		var hops := 0
		var k2 := bi
		while k2 != bj:
			ride += l.seg[k2]
			hops += 1
			k2 = (k2 + 1) % l.stops.size()
		var cycle_t: float = l.cycle / Cfg.BUS_SPEED + l.stops.size() * 1.5
		var est: float = (di + dj) * Cfg.WALK_T + cycle_t / (2.0 * bus_count(l)) + ride / Cfg.BUS_SPEED + hops * 1.2
		if best == null or est < best.est:
			best = {"line": l, "from": l.stops[bi], "to": l.stops[bj], "w1": di, "w2": dj, "est": est}
	return best


func go(leg, pl) -> void:
	var p := Pax.new()
	p.n = leg.n
	p.line = pl.line
	p.from = pl.from
	p.to = pl.to
	p.w2 = pl.w2
	p.leg = leg
	g.schedule(g.now + pl.w1 * Cfg.WALK_T, _at_stop.bind(p))


func _at_stop(p) -> void:
	var s = stops.get(p.from)
	if s == null or not p.line.alive or not p.line.stops.has(p.to):
		city.finish_leg(p.leg, true)
		return
	p.t_wait = g.now
	s.waiting.append(p)


func tick(dt: float) -> void:
	for l in lines:
		if l.pending.is_empty() or not l.ok:
			continue
		var v = l.pending[0]
		var p: PackedInt64Array = roads.find_path(l.stops[0], l.stops[1])
		if p.size() < 2:
			continue
		v.path = p
		v.dest = l.stops[1]
		v.data.si = 1
		v.version = roads.version
		v.dwelling = false
		if traffic.try_spawn(v):
			l.pending.pop_front()
			l.buses.append(v)
	check_timer -= dt
	if check_timer <= 0.0:
		check_timer = 2.0
		for s in stops.values():
			var keep := []
			for p2 in s.waiting:
				if g.now - p2.t_wait > 100.0:
					city.finish_leg(p2.leg, false)   # gave up: counts as late
				else:
					keep.append(p2)
			s.waiting = keep


func on_bus_arrive(v) -> float:
	var d = v.data
	var l = d.line
	var s: int = v.dest
	var moved := 0
	var keep := []
	for p in d.pax:
		if p.to == s:
			moved += p.n
			d.load -= p.n
			l.carried += p.n
			g.schedule(g.now + p.w2 * Cfg.WALK_T, city.finish_leg.bind(p.leg, false))
		else:
			keep.append(p)
	d.pax = keep
	var st = stops.get(s)
	if st != null:
		var stay := []
		for p in st.waiting:
			if p.line == l and d.load + p.n <= Cfg.BUS_CAP:
				d.pax.append(p)
				d.load += p.n
				moved += p.n
			else:
				stay.append(p)
		st.waiting = stay
	return 0.8 + 0.06 * moved


func on_bus_depart(v) -> bool:
	var d = v.data
	var l = d.line
	if not l.alive or l.stops.size() < 2:
		return false
	var cur: int = v.link.b
	var nxt: int = (d.si + 1) % l.stops.size()
	if l.stops[d.si] != cur:
		# The line changed under the bus: head for the nearest valid stop.
		nxt = 0
	var p: PackedInt64Array = roads.find_path(cur, l.stops[nxt])
	if p.size() < 2:
		return false
	d.si = nxt
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
	dirty = true
