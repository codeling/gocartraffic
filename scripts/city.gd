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
const MAX_BUILDINGS := 260


class Building:
	var id := 0
	var type := 0
	var x := 0
	var y := 0
	var idx := 0
	var access := -1
	var residents := 0
	var cars := 0
	var cars_home := 0
	var jobs: Array = []
	var queue: Array = []
	var node = null
	var visitors := 0
	var ok_today := 0
	var fail_today := 0
	var fail_reason := ""
	var fail_time := -1000.0


class Leg:
	var from
	var to
	var home
	var n := 1
	var mode := 0        # 0 car, 1 public transport
	var t0 := 0.0
	var ff := 1.0        # free-flow travel time by car
	var dist := 1.0
	var back := false
	var stay := 1.0
	var purpose := ""


var g
var world
var roads
var traffic
var transit
var rng := RandomNumberGenerator.new()
var buildings: Array = []
var by_type: Array = [[], [], [], [], []]
var bmap := {}
var queued := {}
var spawn_timer := 6.0
var population := 0


func setup(game) -> void:
	g = game
	world = game.world
	roads = game.roads
	traffic = game.traffic
	transit = game.transit
	rng.seed = world.seed_value + 99


func start() -> void:
	for k in 5:
		_spawn_in(Cfg.HOUSE, 0)
	if world.districts.size() > 1:
		_spawn_in(Cfg.FACTORY, 1)
		_spawn_in(Cfg.FACTORY, 1)
	if world.districts.size() > 2:
		_spawn_in(Cfg.SHOP, 2)


func tick(dt: float) -> void:
	spawn_timer -= dt
	if spawn_timer <= 0.0:
		var slow: float = 2.0 if g.on_time_ratio() < 0.5 and buildings.size() > 20 else 1.0
		spawn_timer = (7.0 + buildings.size() * 0.06) * slow
		if buildings.size() < MAX_BUILDINGS:
			spawn_next()
	if not queued.is_empty():
		for b in queued.keys():
			_drain_queue(b)


func _drain_queue(b) -> void:
	while not b.queue.is_empty():
		var v = b.queue[0]
		if b.access < 0:
			b.queue.pop_front()
			finish_leg(v.data, true)
			continue
		if v.version != roads.version or v.path[0] != b.access:
			v.version = roads.version
			var p: PackedInt64Array = roads.find_path(b.access, v.dest)
			if p.is_empty():
				b.queue.pop_front()
				finish_leg(v.data, true)
				continue
			if p.size() < 2:
				b.queue.pop_front()
				g.schedule(g.now + 1.0, finish_leg.bind(v.data, false))
				continue
			v.path = p
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
	var best := 0
	var best_def := -1e9
	for t in 5:
		var deficit: float = targets[t] * total - by_type[t].size()
		if deficit > best_def:
			best_def = deficit
			best = t
	var want := Cfg.D_RES
	match best:
		Cfg.FACTORY:
			want = Cfg.D_IND
		Cfg.SHOP:
			want = Cfg.D_RES if rng.randf() < 0.3 else Cfg.D_COM
		Cfg.OFFICE:
			want = Cfg.D_COM
		Cfg.FUN:
			want = Cfg.D_FUN
	var cands := []
	for k in world.districts.size():
		if world.districts[k].type == want:
			cands.append(k)
	if cands.is_empty():
		cands.append(0)
	# Prefer districts that are still small so the town spreads over the map.
	var pick: int = cands[rng.randi() % cands.size()]
	var other: int = cands[rng.randi() % cands.size()]
	if world.districts[other].count > 0 and world.districts[other].count < world.districts[pick].count:
		pick = other
	if world.districts[pick].count == 0 and buildings.size() < 14 * (1 + _active_districts()):
		# Do not open a new district too early.
		for k in cands:
			if world.districts[k].count > 0:
				pick = k
				break
	_spawn_in(best, pick)


func _active_districts() -> int:
	var n := 0
	for d in world.districts:
		if d.count > 0:
			n += 1
	return n - 3


func _spawn_in(type: int, district: int) -> void:
	if district >= world.districts.size():
		return
	var d = world.districts[district]
	var sigma: float = 1.6 + sqrt(float(d.count)) * 0.85
	for attempt in 40:
		var x := int(round(d.pos.x + rng.randfn(0.0, sigma)))
		var y := int(round(d.pos.y + rng.randfn(0.0, sigma)))
		if not world.can_build(x, y):
			continue
		# Keep every third row and column free so there is always room for streets.
		if x % 3 == 0 or y % 3 == 0:
			continue
		var i := y * W + x
		if bmap.has(i) or roads.lanes[i] > 0:
			continue
		d.count += 1
		_add_building(type, x, y)
		return


func _add_building(type: int, x: int, y: int) -> void:
	var b := Building.new()
	b.id = buildings.size()
	b.type = type
	b.x = x
	b.y = y
	b.idx = y * W + x
	if type == Cfg.HOUSE:
		b.residents = rng.randi_range(3, 4)
		b.cars = rng.randi_range(1, 2)
		b.cars_home = b.cars
		population += b.residents
	buildings.append(b)
	by_type[type].append(b)
	bmap[b.idx] = b
	_update_access(b)
	g.on_building_added(b)
	if type == Cfg.HOUSE:
		plan_house(b, g.hour() + 0.3)


func _update_access(b) -> void:
	b.access = -1
	var best_deg := -1
	for d in 4:
		var n: int = roads.nbr(b.idx, d)
		if n >= 0 and roads.lanes[n] > 0:
			var deg: int = roads.degree(n)
			if deg > best_deg:
				best_deg = deg
				b.access = n


func update_access() -> void:
	for b in buildings:
		_update_access(b)


# ------------------------------------------------------------------- demand

func new_day() -> void:
	for b in buildings:
		b.ok_today = 0
		b.fail_today = 0
	for b in by_type[Cfg.HOUSE]:
		plan_house(b, 0.0)


func plan_house(b, from_hour: float) -> void:
	_plan(b, from_hour, clampf(rng.randfn(7.4, 0.6), 5.5, 9.5), "work", rng.randi_range(1, 2), rng.randf_range(8.0, 9.2))
	if rng.randf() < (0.7 if b.cars >= 2 else 0.3):
		_plan(b, from_hour, clampf(rng.randfn(7.8, 0.7), 5.5, 10.0), "work2", 1, rng.randf_range(7.0, 9.0))
	if rng.randf() < 0.75:
		_plan(b, from_hour, rng.randf_range(9.5, 19.5), "shop", rng.randi_range(1, 3), rng.randf_range(0.6, 1.4))
	if rng.randf() < 0.5:
		_plan(b, from_hour, rng.randf_range(10.0, 16.0), "shop", 1, rng.randf_range(0.4, 1.0))
	if rng.randf() < 0.6:
		_plan(b, from_hour, rng.randf_range(17.5, 21.0), "fun", rng.randi_range(2, b.residents), rng.randf_range(1.8, 3.0))


func _plan(b, from_hour: float, hour: float, purpose: String, n: int, stay: float) -> void:
	if hour < from_hour:
		return
	g.schedule(g.day_start() + hour * Cfg.SEC_PER_HOUR, start_outing.bind(b, purpose, n, stay))


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


func start_outing(b, purpose: String, n: int, stay: float, tries: int = 0) -> void:
	# Shopping and leisure can wait until a car is back home.
	if b.cars_home == 0 and tries < 3 and not purpose.begins_with("work") and b.access >= 0:
		g.schedule(g.now + Cfg.SEC_PER_HOUR, start_outing.bind(b, purpose, n, stay, tries + 1))
		return
	var dest = null
	match purpose:
		"work":
			dest = _pick_job(b, 0)
		"work2":
			dest = _pick_job(b, 1)
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
	start_leg(leg)


func car_estimate(path: PackedInt64Array) -> float:
	var t := 0.0
	for i in path:
		t += roads.astar.get_point_weight_scale(i)
	return t / Cfg.CAR_SPEED


func start_leg(leg) -> void:
	leg.t0 = g.now
	if leg.back:
		leg.from.visitors = maxi(0, leg.from.visitors - leg.n)
	var a: int = leg.from.access
	var c: int = leg.to.access
	var path: PackedInt64Array = roads.find_path(a, c)
	var man: float = absf(leg.from.x - leg.to.x) + absf(leg.from.y - leg.to.y)
	leg.dist = float(path.size() - 1) if path.size() > 1 else maxf(1.0, man * 1.2)
	leg.ff = leg.dist / Cfg.CAR_SPEED
	var has_road := not path.is_empty()
	var plan = transit.plan(leg.from, leg.to)
	var use_bus := false
	if leg.back:
		if leg.mode == 0:
			if not has_road:
				_fail(leg, "Road home was removed")
				leg.home.cars_home += 1
				return
		else:
			if plan == null:
				_fail(leg, "Bus line home was removed")
				return
			use_bus = true
	else:
		var car_ok: bool = has_road and leg.home.cars_home > 0
		if car_ok and plan != null:
			use_bus = plan.est < car_estimate(path) * 1.2 + 2.0
		elif plan != null:
			use_bus = true
		elif not car_ok:
			var why := "No free car at home and no public transport nearby"
			if a < 0:
				why = "No road next to this building"
			elif c < 0:
				why = "Destination (%s) has no road" % Cfg.TYPE_NAMES[leg.to.type]
			elif not has_road:
				why = "No road route to the %s" % Cfg.TYPE_NAMES[leg.to.type].to_lower()
			_fail(leg, why)
			return

	if use_bus:
		leg.mode = 1
		transit.go(leg, plan)
		return

	leg.mode = 0
	if not leg.back:
		leg.home.cars_home -= 1
	if path.size() < 2:
		g.schedule(g.now + 1.0, finish_leg.bind(leg, false))
		return
	var v := Traffic.Vehicle.new()
	v.path = path
	v.dest = c
	v.people = leg.n
	v.data = leg
	v.color = CAR_COLORS[rng.randi() % CAR_COLORS.size()]
	v.version = roads.version
	leg.from.queue.append(v)
	queued[leg.from] = true


func _fail(leg, why: String) -> void:
	leg.home.fail_today += leg.n
	leg.home.fail_reason = why
	leg.home.fail_time = g.now
	g.record_unserved(leg, why)


func time_limit(leg) -> float:
	if leg.mode == 0:
		return leg.ff * 1.3 + 3.0
	return leg.ff * 2.2 + 14.0


func finish_leg(leg, lost: bool) -> void:
	var elapsed: float = g.now - leg.t0
	var ok: bool = not lost and elapsed <= time_limit(leg)
	if ok:
		leg.home.ok_today += leg.n
	else:
		leg.home.fail_today += leg.n
		leg.home.fail_reason = "Trip cancelled: route was removed" if lost else "Arrived late (%d min, limit %d min)" % [int(elapsed * 4.0), int(time_limit(leg) * 4.0)]
		leg.home.fail_time = g.now
	g.record_leg(leg, elapsed, ok)
	if not leg.back:
		leg.to.visitors += leg.n
		var r := Leg.new()
		r.from = leg.to
		r.to = leg.home
		r.home = leg.home
		r.n = leg.n
		r.mode = leg.mode
		r.back = true
		r.purpose = leg.purpose
		g.schedule(g.now + leg.stay * Cfg.SEC_PER_HOUR, start_leg.bind(r))
	elif leg.mode == 0:
		leg.home.cars_home = mini(leg.home.cars, leg.home.cars_home + 1)


func on_vehicle_arrive(v) -> void:
	finish_leg(v.data, false)


func on_vehicle_lost(v) -> void:
	finish_leg(v.data, true)
