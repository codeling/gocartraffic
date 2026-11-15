extends RefCounted
## Validates a parsed save file before the game touches it. A save is untrusted
## input (it may have been edited or crafted), so every field the loaders read
## is checked for type, shape and range. Returns "" when fine, otherwise a
## short description of the first problem found.

const Cfg = preload("res://scripts/cfg.gd")

const MAX_BUILDINGS := 4000
const MAX_UNITS := 8
const MAX_RESIDENTS := 200
const MAX_CARS := 16
const MAX_JOBS := 32
const MAX_STOPS := 2000
const MAX_LINES := 200
const MAX_BUSES := 100
const MAX_DISTRICTS := 64
const MAX_COUNT := 1.0e9


static func check(d: Dictionary) -> String:
	for k in ["settings", "world", "stats", "roads", "transit", "city"]:
		if not d.has(k):
			return "missing '%s'" % k
	for k in ["now", "day", "credits"]:
		if not _num(d.get(k), -MAX_COUNT, MAX_COUNT):
			return "bad '%s'" % k
	if d.day < 0 or d.now < 0:
		return "bad clock"

	var err := _settings(d.settings)
	if err == "":
		err = _stats(d.stats)
	if err == "":
		err = _world(d.world)
	if err == "":
		err = _roads(d.roads)
	if err == "":
		err = _city(d.city)
	if err == "":
		err = _transit(d.transit, d.roads)
	return err


static func _num(v, lo: float, hi: float) -> bool:
	return (typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT) and is_finite(float(v)) and v >= lo and v <= hi


static func _int(v, lo: int, hi: int) -> bool:
	return _num(v, lo, hi) and float(v) == floorf(float(v))


static func _settings(s) -> String:
	if typeof(s) != TYPE_DICTIONARY:
		return "bad settings"
	if not (_num(s.get("compact"), 0.0, 1.0) and _num(s.get("cluster"), 0.0, 1.0)):
		return "bad settings"
	if not _num(s.get("day_len"), 60.0, 1.0e6):
		return "bad day length"
	if not _int(s.get("seed"), -MAX_COUNT, MAX_COUNT):
		return "bad seed"
	return ""


static func _stats(s) -> String:
	if typeof(s) != TYPE_DICTIONARY:
		return "bad stats"
	for k in ["delivered", "milestone"]:
		if not _int(s.get(k), 0, MAX_COUNT):
			return "bad stats"
	for k in ["ok_w", "tot_w", "delay"]:
		if not _num(s.get(k), 0.0, MAX_COUNT):
			return "bad stats"
	var m = s.get("modes")
	if typeof(m) != TYPE_ARRAY or m.size() != 4:
		return "bad stats"
	for v in m:
		if not _int(v, 0, MAX_COUNT):
			return "bad stats"
	return ""


static func _b64_size(v, bytes: int) -> bool:
	if typeof(v) != TYPE_STRING or v.length() > bytes * 2:
		return false
	return Marshalls.base64_to_raw(v).size() == bytes


static func _world(w) -> String:
	if typeof(w) != TYPE_DICTIONARY:
		return "bad world"
	if not _int(w.get("seed"), -MAX_COUNT, MAX_COUNT):
		return "bad world seed"
	if not _b64_size(w.get("corner"), (Cfg.W + 1) * (Cfg.H + 1) * 4):
		return "bad terrain"
	if not _b64_size(w.get("water"), Cfg.W * Cfg.H):
		return "bad water map"
	var corner := Marshalls.base64_to_raw(w.corner).to_float32_array()
	for v in corner:
		if not is_finite(v) or absf(v) > 100.0:
			return "bad terrain height"
	var rx = w.get("river_x")
	if typeof(rx) != TYPE_ARRAY or rx.size() != Cfg.H:
		return "bad river"
	for v in rx:
		if not _num(v, -1000.0, 1000.0):
			return "bad river"
	var ds = w.get("districts")
	if typeof(ds) != TYPE_ARRAY or ds.size() > MAX_DISTRICTS:
		return "bad districts"
	for e in ds:
		if typeof(e) != TYPE_ARRAY or e.size() != 3:
			return "bad districts"
		if not (_int(e[0], 0, 4) and _int(e[1], 0, Cfg.W - 1) and _int(e[2], 0, Cfg.H - 1)):
			return "bad districts"
	return ""


static func _roads(list) -> String:
	if typeof(list) != TYPE_ARRAY or list.size() > Cfg.W * Cfg.H:
		return "bad roads"
	var seen := {}
	for e in list:
		if typeof(e) != TYPE_ARRAY or e.size() != 4:
			return "bad roads"
		if not (_int(e[0], 0, Cfg.W * Cfg.H - 1) and _int(e[1], 0, Cfg.MAX_LANES) \
				and _int(e[2], 0, 2) and _int(e[3], 0, 15)):
			return "bad roads"
		if seen.has(int(e[0])):
			return "duplicate road tile"
		seen[int(e[0])] = true
	return ""


static func _city(c) -> String:
	if typeof(c) != TYPE_DICTIONARY:
		return "bad city"
	if not _num(c.get("spawn_timer"), -MAX_COUNT, MAX_COUNT):
		return "bad city"
	var rng = c.get("rng")
	if typeof(rng) != TYPE_STRING or not rng.is_valid_int():
		return "bad city"
	var list = c.get("buildings")
	if typeof(list) != TYPE_ARRAY or list.size() > MAX_BUILDINGS:
		return "bad buildings"
	var seen := {}
	for e in list:
		if typeof(e) != TYPE_DICTIONARY:
			return "bad buildings"
		if not (_int(e.get("t"), 0, 4) and _int(e.get("x"), 0, Cfg.W - 1) and _int(e.get("y"), 0, Cfg.H - 1)):
			return "bad buildings"
		if typeof(e.get("apt")) != TYPE_BOOL:
			return "bad buildings"
		if not (_int(e.get("units"), 1, MAX_UNITS) and _int(e.get("res"), 0, MAX_RESIDENTS)):
			return "bad buildings"
		var pos := int(e.y) * Cfg.W + int(e.x)
		if seen.has(pos):
			return "two buildings on one tile"
		seen[pos] = true
		var cars = e.get("cars")
		if typeof(cars) != TYPE_ARRAY or cars.size() > MAX_CARS:
			return "bad buildings"
		for col in cars:
			if typeof(col) != TYPE_STRING or col.length() != 6 or not col.is_valid_hex_number():
				return "bad car colour"
		var jobs = e.get("jobs")
		if typeof(jobs) != TYPE_ARRAY or jobs.size() > MAX_JOBS:
			return "bad buildings"
		for j in jobs:
			if not _int(j, -1, list.size() - 1):
				return "bad job reference"
	return ""


static func _transit(t, roads) -> String:
	if typeof(t) != TYPE_DICTIONARY:
		return "bad transit"
	var road_tiles := {}
	for e in roads:
		road_tiles[int(e[0])] = true
	var stops = t.get("stops")
	if typeof(stops) != TYPE_ARRAY or stops.size() > MAX_STOPS:
		return "bad bus stops"
	var stop_set := {}
	for s in stops:
		if not _int(s, 0, Cfg.W * Cfg.H - 1) or not road_tiles.has(int(s)):
			return "bus stop off the road"
		stop_set[int(s)] = true
	if not _int(t.get("next_id"), 1, MAX_COUNT):
		return "bad transit"
	var lines = t.get("lines")
	if typeof(lines) != TYPE_ARRAY or lines.size() > MAX_LINES:
		return "bad bus lines"
	for l in lines:
		if typeof(l) != TYPE_DICTIONARY:
			return "bad bus lines"
		if not (_int(l.get("id"), 1, MAX_COUNT) and _int(l.get("buses"), 0, MAX_BUSES) \
				and _int(l.get("carried"), 0, MAX_COUNT)):
			return "bad bus lines"
		var ls = l.get("stops")
		if typeof(ls) != TYPE_ARRAY or ls.size() > MAX_STOPS:
			return "bad bus lines"
		for s in ls:
			if not _int(s, 0, Cfg.W * Cfg.H - 1) or not stop_set.has(int(s)):
				return "bus line uses an unknown stop"
		var board = l.get("board")
		if typeof(board) != TYPE_DICTIONARY or board.size() > MAX_STOPS:
			return "bad bus lines"
		for k in board:
			if typeof(k) != TYPE_STRING or not k.is_valid_int() or not _int(board[k], 0, MAX_COUNT):
				return "bad bus lines"
	return ""
