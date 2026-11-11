extends RefCounted
## Buildings, households and their daily travel demand.

const Cfg = preload("res://scripts/cfg.gd")
const Traffic = preload("res://scripts/traffic.gd")
const W := Cfg.W
const H := Cfg.H

const CAR_COLORS: Array[Color] = [
	Color(0.85, 0.2, 0.18), Color(0.95, 0.95, 0.95), Color(0.15, 0.2, 0.3),
	Color(0.2, 0.45, 0.8), Color(0.95, 0.75, 0.2), Color(0.55, 0.58, 0.62),
	Color(0.2, 0.6, 0.4), Color(0.9, 0.5, 0.2), Color(0.5, 0.25, 0.6),
]
const BIKE_COLORS: Array[Color] = [
	Color(0.95, 0.85, 0.2), Color(0.3, 0.8, 0.9), Color(0.95, 0.4, 0.6), Color(0.6, 0.9, 0.3),
]
const MAX_BUILDINGS := 300
const SLOTS: Array[int] = [2, 9, 6, 9, 12]


class Building:
	var id := 0
	var type := 0
	var apt := false
	var units := 1
	var x := 0
	var y := 0
	var idx := 0
	var access := -1
	var access_list: Array = []
	var bike_list: Array = []
	var residents := 0
	var cars := 0
	var car_colors: Array = []
	var home_cars: Array = []
	var jobs: Array = []
	var queue: Array = []
	var node = null
	var visitors := 0
	var parked: Array = []
	var slots := 2
	var ok_today := 0
	var fail_today := 0
	var fail = null          # last problem: {kind, text, time, from, to, path}


class Leg:
	var from
	var to
	var home
	var n := 1
	var mode := 0
	var t0 := 0.0
	var ff := 1.0            # free-flow travel time by car
	var dist := 1.0
	var limit := 60.0
	var back := false
	var stay := 1.0
	var purpose := ""
	var color := Color.WHITE
	var pending := 0
	var lost_any := false
	var path: Array = []
	var plan = null


var g
var world
var roads
var traffic
var transit
var rng := RandomNumberGenerator.new()
var buildings: Array = []
var by_type: Array = [[], [], [], [], []]
var by_zone: Array = [[], [], [], []]
var bmap := {}
var queued := {}
var spawn_timer := 0.0
var population := 0
var loading := false


func setup(game) -> void:
	g = game
	world = game.world
	roads = game.roads
	traffic = game.traffic
	transit = game.transit
	rng.seed = world.seed_value + 99
	spawn_timer = 6.0 / 360.0 * g.day_len


func start() -> void:
	var ds: Array = world.districts
	if ds.is_empty():
		return
	var clustered: bool = g.cluster >= 0.4
	for k in 5:
		_spawn_at(Cfg.HOUSE, ds[0].pos, 2.0)
	var ind: Vector2i = ds[1].pos if clustered and ds.size() > 1 else ds[0].pos
	var com: Vector2i = ds[2].pos if clustered and ds.size() > 2 else ds[0].pos
	_spawn_at(Cfg.FACTORY, ind, 2.0 if clustered else 7.0)
	_spawn_at(Cfg.FACTORY, ind, 2.0 if clustered else 7.0)
	_spawn_at(Cfg.SHOP, com, 2.0 if clustered else 5.0)


func tick(dt: float) -> void:
	spawn_timer -= dt
	if spawn_timer <= 0.0:
		var slow: float = 2.0 if g.on_time_ratio() < 0.5 and buildings.size() > 20 else 1.0
		spawn_timer = (7.0 + buildings.size() * 0.06) / 360.0 * g.day_len * slow
		if buildings.size() < MAX_BUILDINGS:
			spawn_next()
	if not queued.is_empty():
		for b in queued.keys():
			_drain_queue(b)


func _drain_queue(b) -> void:
	while not b.queue.is_empty():
		var v = b.queue[0]
		if v.version != roads.version:
			v.version = roads.version
			var leg = v.data
			var p: PackedInt64Array = bike_route(leg.from, leg.to) if v.kind == Traffic.BIKE else car_route(leg.from, leg.to)
			if p.size() < 2:
				b.queue.pop_front()
				_vehicle_done(v, p.is_empty())
				continue
			v.path = p
			v.dest = p[-1]
		if traffic.try_spawn(v):
			b.queue.pop_front()
		else:
			break
	if b.queue.is_empty():
		queued.erase(b)


# ---------------------------------------------------------------- buildings

func spawn_next() -> void:
	var targets := [0.58, 0.10, 0.14, 0.09, 0.09]
	var total := buildings.size() + 1
	var type := 0
	var best_def := -1e9
	for t in 5:
		var deficit: float = targets[t] * total - by_type[t].size()
		if deficit > best_def:
			best_def = deficit
			type = t
	var zone: int = Cfg.ZONE[type]
	# How tightly new buildings hug the existing town.
	var sigma: float = lerpf(11.0, 2.2, g.compact) + sqrt(float(by_zone[zone].size())) * 0.3
	var same: Array = by_zone[zone]
	for attempt in 3:
		var anchor := Vector2i(-1, -1)
		if rng.randf() < g.cluster:
			# Zoning: stay with buildings of the same kind.
			if not same.is_empty():
				var b = same[rng.randi() % same.size()]
				anchor = Vector2i(b.x, b.y)
			else:
				anchor = _district_seed(zone)
		if anchor.x < 0:
			var b2 = buildings[rng.randi() % buildings.size()]
			anchor = Vector2i(b2.x, b2.y)
		if _spawn_at(type, anchor, sigma * (1.0 + attempt)):
			return


func _district_seed(zone: int) -> Vector2i:
	var want := [Cfg.D_RES, Cfg.D_IND, Cfg.D_COM, Cfg.D_FUN]
	for d in world.districts:
		if d.type == want[zone]:
			return d.pos
	return Vector2i(-1, -1)


func _spawn_at(type: int, anchor: Vector2i, sigma: float) -> bool:
	for attempt in 40:
		var x := int(round(anchor.x + rng.randfn(0.0, sigma)))
		var y := int(round(anchor.y + rng.randfn(0.0, sigma)))
		if not world.can_build(x, y):
			continue
		# Keep every third row and column free so there is always room for streets.
		if x % 3 == 0 or y % 3 == 0:
			continue
		var i := y * W + x
		if bmap.has(i) or roads.any(i):
			continue
		var b = _new_building(type, x, y)
		if type == Cfg.HOUSE:
			if buildings.size() > 30 and rng.randf() < 0.25:
				b.apt = true
				b.units = rng.randi_range(4, 6)
			for u in b.units:
				b.residents += rng.randi_range(3, 4)
				for c in rng.randi_range(1, 2):
					b.car_colors.append(CAR_COLORS[rng.randi() % CAR_COLORS.size()])
			b.cars = b.car_colors.size()
			b.home_cars = b.car_colors.duplicate()
		_register(b)
		if type == Cfg.HOUSE:
			plan_house(b, g.hour() + 0.3)
		return true
	return false


func _new_building(type: int, x: int, y: int):
	var b := Building.new()
	b.id = buildings.size()
	b.type = type
	b.x = x
	b.y = y
	b.idx = y * W + x
	return b


func _register(b) -> void:
	b.slots = 9 if b.apt else SLOTS[b.type]
	population += b.residents
	buildings.append(b)
	by_type[b.type].append(b)
	by_zone[Cfg.ZONE[b.type]].append(b)
	bmap[b.idx] = b
	_update_access(b)
	g.on_building_added(b)


func type_name(b) -> String:
	return "Apartment block" if b.apt else Cfg.TYPE_NAMES[b.type]


func _update_access(b) -> void:
	b.access = -1
	b.access_list.clear()
	b.bike_list.clear()
	var best_deg := -1
	for d in 4:
		var n: int = roads.nbr(b.idx, d)
		if n < 0:
			continue
		if roads.any(n):
			b.bike_list.append(n)
		if roads.lanes[n] > 0:
			b.access_list.append(n)
			var deg: int = roads.degree(n)
			if deg > best_deg:
				best_deg = deg
				b.access = n


func update_access() -> void:
	for b in buildings:
		_update_access(b)


# ------------------------------------------------------------------- routes

func _best_route(from_list: Array, to_list: Array, bike: bool) -> PackedInt64Array:
	var best := PackedInt64Array()
	var best_c := 1e18
	var a: AStar2D = roads.astar_bike if bike else roads.astar
	for s in from_list:
		for e in to_list:
			var p: PackedInt64Array = a.get_id_path(s, e)
			if p.is_empty():
				continue
			var c: float = roads.path_cost(a, p)
			if c < best_c:
				best_c = c
				best = p
	return best


## Fastest road route between two buildings (empty if there is none).
func car_route(a, b) -> PackedInt64Array:
	return _best_route(a.access_list, b.access_list, false)


func bike_route(a, b) -> PackedInt64Array:
	return _best_route(a.bike_list, b.bike_list, true)


func walk_points(a, b) -> PackedVector2Array:
	var pa := Vector2(a.x + 0.5, a.y + 0.5)
	var pb := Vector2(b.x + 0.5, b.y + 0.5)
	if world.dry_line(pa.x, pa.y, pb.x, pb.y):
		return PackedVector2Array([pa, pb])
	var p := bike_route(a, b)
	if p.is_empty() or p.size() > Cfg.WALK_MAX + 4:
		return PackedVector2Array()
	var pts := PackedVector2Array([pa])
	for i in p:
		pts.append(Vector2(i % W + 0.5, i / W + 0.5))
	pts.append(pb)
	return pts


static func polyline_length(pts: PackedVector2Array) -> float:
	var l := 0.0
	for k in range(1, pts.size()):
		l += pts[k - 1].distance_to(pts[k])
	return l


func bike_share(path: PackedInt64Array) -> float:
	if path.is_empty():
		return 0.0
	var n := 0
	for i in path:
		if roads.bike[i] > 0:
			n += 1
	return float(n) / path.size()


# ------------------------------------------------------------------- demand

func new_day() -> void:
	for b in buildings:
		b.ok_today = 0
		b.fail_today = 0
		if b.fail != null and g.now - b.fail.time > g.day_len * 0.5:
			b.fail = null
	for b in by_type[Cfg.HOUSE]:
		plan_house(b, 0.0)


func plan_house(b, from_hour: float) -> void:
	for u in b.units:
		var res: int = b.residents / b.units
		var two_cars: bool = b.cars >= b.units * 2 or (b.cars > b.units and u % 2 == 0)
		_plan(b, from_hour, clampf(rng.randfn(7.4, 0.6), 5.5, 9.5), "work", rng.randi_range(1, 2), rng.randf_range(8.0, 9.2))
		if rng.randf() < (0.7 if two_cars else 0.3):
			_plan(b, from_hour, clampf(rng.randfn(7.8, 0.7), 5.5, 10.0), "work2", 1, rng.randf_range(7.0, 9.0))
		if rng.randf() < 0.75:
			_plan(b, from_hour, rng.randf_range(9.5, 19.5), "shop", rng.randi_range(1, 3), rng.randf_range(0.6, 1.4))
		if rng.randf() < 0.5:
			_plan(b, from_hour, rng.randf_range(10.0, 16.0), "shop", 1, rng.randf_range(0.4, 1.0))
		if rng.randf() < 0.6:
			_plan(b, from_hour, rng.randf_range(17.5, 21.0), "fun", rng.randi_range(2, res), rng.randf_range(1.8, 3.0))


func _plan(b, from_hour: float, hour: float, purpose: String, n: int, stay: float) -> void:
	if hour < from_hour:
		return
	g.schedule(g.day_start() + hour / 24.0 * g.day_len, start_outing.bind(b, purpose, n, stay, 0))


func _pick_job(b, slot: int):
	while b.jobs.size() <= slot:
		b.jobs.append(null)
	if b.jobs[slot] == null:
		var pool := []
		for t in [Cfg.FACTORY, Cfg.FACTORY, Cfg.FACTORY, Cfg.OFFICE, Cfg.OFFICE, Cfg.OFFICE, Cfg.SHOP, Cfg.FUN]:
			if not by_type[t].is_empty():
				pool.append(t)
		if pool.is_empty():
			return null
		var t2: int = pool[rng.randi() % pool.size()]
		b.jobs[slot] = by_type[t2][rng.randi() % by_type[t2].size()]
	return b.jobs[slot]


func _pick_near(b, type: int):
	var list: Array = by_type[type]
	if list.is_empty():
		return null
	var best = null
	var best_d := 1e9
	for k in 3:
		var c = list[rng.randi() % list.size()]
		var d: float = absf(c.x - b.x) + absf(c.y - b.y) + rng.randf() * 6.0
		if d < best_d:
			best_d = d
			best = c
	return best


func start_outing(b, purpose: String, n: int, stay: float, tries: int) -> void:
	var dest = null
	match purpose:
		"work":
			dest = _pick_job(b, rng.randi() % (b.units * 2))
		"work2":
			dest = _pick_job(b, rng.randi() % (b.units * 2))
		"shop":
			dest = _pick_near(b, Cfg.SHOP)
		"fun":
			dest = _pick_near(b, Cfg.FUN)
	if dest == null:
		return
	var leg := Leg.new()
	leg.from = b
	leg.to = dest
	leg.home = b
	leg.n = n
	leg.stay = stay
	leg.purpose = purpose
	if not _choose_and_go(leg, tries < 3 and not purpose.begins_with("work")):
		# Shopping and leisure can wait until a car is back home.
		g.schedule(g.now + g.day_len / 24.0, start_outing.bind(b, purpose, n, stay, tries + 1))


static func walk_prob(d: float) -> float:
	if d <= Cfg.WALK_LIKELY:
		return 0.85
	return maxf(0.0, 0.85 * (Cfg.WALK_MAX - d) / (Cfg.WALK_MAX - Cfg.WALK_LIKELY))


static func bike_prob(d: float, share: float) -> float:
	var p := 0.0
	if d <= Cfg.BIKE_LIKELY:
		p = 0.7
	elif d <= Cfg.BIKE_MID:
		p = lerpf(0.7, 0.3, (d - Cfg.BIKE_LIKELY) / (Cfg.BIKE_MID - Cfg.BIKE_LIKELY))
	elif d <= Cfg.BIKE_MAX:
		p = lerpf(0.3, 0.0, (d - Cfg.BIKE_MID) / (Cfg.BIKE_MAX - Cfg.BIKE_MID))
	# Safe cycle routes make people far more willing to ride.
	return p * (0.7 + 0.5 * share)


## Picks a mode for an outgoing leg and starts it. Returns false if the trip
## should be retried later (no car at home right now).
func _choose_and_go(leg, may_wait: bool) -> bool:
	var a = leg.from
	var b = leg.to
	leg.t0 = g.now
	var man: float = absf(a.x - b.x) + absf(a.y - b.y)
	var car: PackedInt64Array = car_route(a, b)
	leg.dist = float(car.size() - 1) if car.size() > 1 else maxf(1.0, man * 1.2)
	leg.ff = leg.dist / Cfg.CAR_SPEED

	if man <= Cfg.WALK_MAX and rng.randf() < walk_prob(man):
		var pts := walk_points(a, b)
		if not pts.is_empty():
			_go_walk(leg, pts)
			return true
	var bp: PackedInt64Array = bike_route(a, b)
	var blen: float = bp.size() - 1
	if bp.size() > 1 and blen <= Cfg.BIKE_MAX and rng.randf() < bike_prob(blen, bike_share(bp)):
		_go_bike(leg, bp)
		return true

	var car_ok: bool = not car.is_empty() and not leg.home.home_cars.is_empty()
	var plan = transit.plan(a, b)
	if car_ok and plan != null:
		# Some people prefer the bus anyway - more of them when the roads are
		# congested or the car park at the destination is full.
		var slow: float = roads.path_cost(roads.astar, car) / maxf(1.0, float(car.size()))
		var p := 0.3 + 0.4 * clampf(slow - 1.0, 0.0, 1.0)
		if b.parked.size() >= b.slots:
			p += 0.3
		if plan.est > leg.ff * 4.0 + 300.0:
			p = 0.0
		if rng.randf() < p:
			transit.go(leg, plan)
		else:
			_go_car(leg, car)
		return true
	if car_ok:
		_go_car(leg, car)
		return true
	if plan != null:
		transit.go(leg, plan)
		return true
	# No car and no bus: fall back on bike or feet if the distance allows it.
	if bp.size() > 1 and blen <= Cfg.BIKE_MAX:
		_go_bike(leg, bp)
		return true
	if man <= Cfg.WALK_MAX:
		var pts2 := walk_points(a, b)
		if not pts2.is_empty():
			_go_walk(leg, pts2)
			return true
	if not car.is_empty() and may_wait:
		return false
	var kind := "nocar"
	var why := "No car left at home, and no bus, cycle route or walkable way to the %s" % type_name(b).to_lower()
	if a.access < 0:
		kind = "noroad_home"
		why = "No road next to this building"
	elif b.access < 0:
		kind = "noroad_dest"
		why = "The %s they wanted to reach has no road" % type_name(b).to_lower()
	elif car.is_empty():
		kind = "noroute"
		why = "No road connection to the %s" % type_name(b).to_lower()
	_fail(leg, kind, why)
	return true


func start_return(leg) -> void:
	leg.t0 = g.now
	leg.from.visitors = maxi(0, leg.from.visitors - leg.n)
	var a = leg.from
	var b = leg.to
	var car: PackedInt64Array = car_route(a, b)
	var man: float = absf(a.x - b.x) + absf(a.y - b.y)
	leg.dist = float(car.size() - 1) if car.size() > 1 else maxf(1.0, man * 1.2)
	leg.ff = leg.dist / Cfg.CAR_SPEED
	match leg.mode:
		Cfg.M_CAR:
			a.parked.erase(leg.color)
			if car.is_empty():
				leg.home.home_cars.append(leg.color)
				_fail(leg, "noroute", "The road home was removed")
			else:
				_go_car(leg, car)
		Cfg.M_BIKE:
			var bp := bike_route(a, b)
			if bp.size() < 2:
				_fail(leg, "noroute", "The cycle route home was removed")
			else:
				_go_bike(leg, bp)
		Cfg.M_WALK:
			var pts := walk_points(a, b)
			if pts.is_empty():
				pts = PackedVector2Array([Vector2(a.x + 0.5, a.y + 0.5), Vector2(b.x + 0.5, b.y + 0.5)])
			_go_walk(leg, pts)
		Cfg.M_BUS:
			var plan = transit.plan(a, b)
			if plan == null:
				_fail(leg, "nobus", "The bus connection home was removed")
			else:
				transit.go(leg, plan)


func _go_walk(leg, pts: PackedVector2Array) -> void:
	leg.mode = Cfg.M_WALK
	var t: float = polyline_length(pts) / Cfg.WALK_SPEED
	leg.limit = maxf(Cfg.TIME_FACTOR * leg.ff, t * 1.3) + 20.0
	g.add_walker(pts, leg.n, t)
	g.schedule(g.now + t, finish_leg.bind(leg, false))


func _go_bike(leg, path: PackedInt64Array) -> void:
	leg.mode = Cfg.M_BIKE
	leg.path = Array(path)
	leg.limit = maxf(Cfg.TIME_FACTOR * leg.ff, (path.size() - 1) / Cfg.BIKE_SPEED * 1.3) + 20.0
	leg.pending = leg.n
	leg.lost_any = false
	for k in leg.n:
		var v := Traffic.Vehicle.new()
		v.kind = Traffic.BIKE
		v.length = Cfg.BIKE_LEN
		v.path = path
		v.dest = path[-1]
		v.data = leg
		v.color = BIKE_COLORS[rng.randi() % BIKE_COLORS.size()]
		v.version = roads.version
		leg.from.queue.append(v)
	queued[leg.from] = true


func _go_car(leg, path: PackedInt64Array) -> void:
	leg.mode = Cfg.M_CAR
	leg.path = Array(path)
	leg.limit = Cfg.TIME_FACTOR * leg.ff + 20.0
	if not leg.back:
		leg.color = leg.home.home_cars.pop_back()
	var v := Traffic.Vehicle.new()
	v.data = leg
	v.people = leg.n
	v.color = leg.color
	if path.size() < 2:
		g.schedule(g.now + 5.0, _vehicle_done.bind(v, false))
		return
	v.path = path
	v.dest = path[-1]
	v.version = roads.version
	leg.from.queue.append(v)
	queued[leg.from] = true


func _vehicle_done(v, lost: bool) -> void:
	var leg = v.data
	if v.kind == Traffic.BIKE:
		leg.pending -= 1
		leg.lost_any = leg.lost_any or lost
		if leg.pending <= 0:
			finish_leg(leg, leg.lost_any)
		return
	if leg.back:
		leg.home.home_cars.append(leg.color)
		finish_leg(leg, lost)
		return
	leg.to.parked.append(leg.color)
	if not lost and leg.to.parked.size() > leg.to.slots:
		# Car park full: the driver circles the block looking for a space.
		g.schedule(g.now + Cfg.PARK_SEARCH, finish_leg.bind(leg, false))
	else:
		finish_leg(leg, lost)


func on_vehicle_arrive(v) -> void:
	_vehicle_done(v, false)


func on_vehicle_lost(v) -> void:
	_vehicle_done(v, true)


func _set_fail(leg, kind: String, text: String) -> void:
	leg.home.fail_today += leg.n
	leg.home.fail = {"kind": kind, "text": text, "time": g.now, "from": leg.from, "to": leg.to, "path": leg.path, "mode": leg.mode}


func _fail(leg, kind: String, why: String) -> void:
	_set_fail(leg, kind, why)
	g.record_unserved(leg)


## Is the last recorded problem of a building still relevant?
func problem(b, full_check: bool):
	var f = b.fail
	if f == null:
		return null
	match f.kind:
		"noroad_home":
			if b.access >= 0:
				b.fail = null
		"noroad_dest":
			if f.to.access >= 0:
				b.fail = null
		"noroute":
			if full_check and not car_route(f.from, f.to).is_empty():
				b.fail = null
	return b.fail


func finish_leg(leg, lost: bool) -> void:
	var elapsed: float = g.now - leg.t0
	var ok: bool = not lost and elapsed <= leg.limit
	if ok:
		leg.home.ok_today += leg.n
	elif lost:
		_set_fail(leg, "removed", "Trip cancelled: the route was removed while they were travelling")
	else:
		var extra := ""
		if leg.mode == Cfg.M_CAR and not leg.back and leg.to.parked.size() > leg.to.slots:
			extra = " The car park at the destination was full."
		_set_fail(leg, "late", "Arrived late by %s: %s instead of at most %s.%s" % [
			Cfg.MODE_NAMES[leg.mode], Cfg.fmt_time(elapsed), Cfg.fmt_time(leg.limit), extra])
	g.record_leg(leg, elapsed, ok)
	if not leg.back:
		leg.to.visitors += leg.n
		var r := Leg.new()
		r.from = leg.to
		r.to = leg.home
		r.home = leg.home
		r.n = leg.n
		r.mode = leg.mode
		r.color = leg.color
		r.back = true
		r.purpose = leg.purpose
		g.schedule(g.now + leg.stay / 24.0 * g.day_len, start_return.bind(r))


# ------------------------------------------------------------------- saving

func to_save() -> Dictionary:
	var list := []
	for b in buildings:
		var cols := []
		for c in b.car_colors:
			cols.append(c.to_html(false))
		var jobs := []
		for j in b.jobs:
			jobs.append(-1 if j == null else j.id)
		list.append({"t": b.type, "x": b.x, "y": b.y, "apt": b.apt, "units": b.units, "res": b.residents, "cars": cols, "jobs": jobs})
	return {"buildings": list, "rng": str(rng.state), "spawn_timer": spawn_timer}


## Rebuilds the town. Everybody starts at home; the rest of the day is re-planned.
func from_save(d: Dictionary) -> void:
	loading = true
	for e in d.buildings:
		var b = _new_building(int(e.t), int(e.x), int(e.y))
		b.apt = bool(e.apt)
		b.units = int(e.units)
		b.residents = int(e.res)
		for c in e.cars:
			b.car_colors.append(Color.html(c))
		b.cars = b.car_colors.size()
		b.home_cars = b.car_colors.duplicate()
		_register(b)
	for k in buildings.size():
		for j in d.buildings[k].jobs:
			buildings[k].jobs.append(null if int(j) < 0 else buildings[int(j)])
	rng.state = int(d.rng)
	spawn_timer = float(d.spawn_timer)
	loading = false
	for b in by_type[Cfg.HOUSE]:
		plan_house(b, g.hour())
