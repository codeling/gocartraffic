extends RefCounted
## One place for everything the player should hear about: the history of
## notifications, the problems that are open right now (houses without a road,
## people who cannot travel, traffic jams) and the automatic pause.

const Cfg = preload("res://scripts/cfg.gd")

enum {INFO, NOTICE, PROBLEM}

## Remembered across new games and loading (the scene is reloaded for those).
static var pause_enabled := true

var g
var history: Array = []      # oldest first: {text, level, tile, kind, day, clock}
var open: Array = []         # problems open now: {key, kind, short, text, tile}
var version := 0             # changes whenever history or open changes
var unread := 0
var _known := {}             # problem key -> {seen: play time, told: bool}
var _last_pause := -1e9
var _open_sig := ""


func setup(game) -> void:
	g = game


## Adds a line to the history and shows it on screen. A level of PROBLEM may
## also pause the game (if the player left that switched on).
func notify(text: String, level: int = INFO, tile: int = -1, kind: String = "", pause: bool = false) -> void:
	var paused := pause and level == PROBLEM and _auto_pause()
	if paused:
		text += "  - game paused, press Space to go on"
	var h: float = g.hour()
	var e := {
		"text": text, "level": level, "tile": tile, "kind": kind,
		"day": g.day + 1, "clock": "%02d:%02d" % [int(h), int(fmod(h, 1.0) * 60.0)],
	}
	history.append(e)
	if history.size() > Cfg.LOG_MAX:
		history.pop_front()
	unread += 1
	version += 1
	if g.hud != null:
		g.hud.show_toast(e)


func _auto_pause() -> bool:
	if not pause_enabled or not g.started or g.speed_idx == 0:
		return false
	if g.ui_time - _last_pause < Cfg.PAUSE_COOLDOWN:
		return false
	_last_pause = g.ui_time
	g.set_speed(0)
	return true


func mark_read() -> void:
	unread = 0


## Looks for problems; announces each one once when it first appears.
func update() -> void:
	if not g.started:
		return
	var city = g.city
	var play: float = g.ui_time
	var found := []
	for b in city.buildings:
		if b.access < 0 and play - b.born > Cfg.PROBLEM_GRACE:
			found.append({
				"key": "road:%d" % b.id, "kind": "noroad", "short": "no road", "tile": b.idx,
				"text": "%s has no road next to it." % city.type_name(b)})
	var window: float = g.day_len * 0.25
	for b in city.by_type[Cfg.HOUSE]:
		if b.fail == null or b.access < 0:
			continue
		var f = city.problem(b, true)
		if f == null or g.now - f.time > window:
			continue
		if f.kind == "nocar" or f.kind == "noroute" or f.kind == "nobus":
			found.append({
				"key": "trip:%d:%s" % [b.id, f.kind], "kind": "trip", "short": "cannot travel", "tile": b.idx,
				"text": "People living here cannot travel: %s." % f.text})
	for d in g.issues:
		found.append({
			"key": "jam:%d:%s" % [d.tile, d.kind], "kind": "jam", "short": "traffic jam", "tile": d.tile,
			"text": "Traffic problem: %s (see the traffic advisor)." % d.title.to_lower()})

	var fresh := {}
	var live := {}
	var sig := ""
	for p in found:
		live[p.key] = true
		sig += p.key + ";"
		var k = _known.get(p.key)
		if k == null:
			_known[p.key] = {"seen": play, "told": true}
			if not fresh.has(p.kind):
				fresh[p.kind] = []
			fresh[p.kind].append(p)
		else:
			k.seen = play
	for key in _known.keys():
		if not live.has(key) and play - _known[key].seen > Cfg.PROBLEM_FORGET:
			_known.erase(key)
	open = found
	if sig != _open_sig:
		_open_sig = sig
		version += 1
	for kind in ["noroad", "trip", "jam"]:
		if not fresh.has(kind):
			continue
		var list: Array = fresh[kind]
		var text: String = list[0].text
		if list.size() > 1:
			match kind:
				"noroad":
					text = "%d buildings have no road next to them." % list.size()
				"trip":
					text = "People in %d houses cannot travel." % list.size()
				_:
					text = "%d new traffic problems (see the traffic advisor)." % list.size()
		notify(text, PROBLEM, list[0].tile, kind, true)
