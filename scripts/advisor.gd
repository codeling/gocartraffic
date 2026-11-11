extends RefCounted
## Explains *why* a road is jammed, so the player can learn to fix the cause
## instead of the symptom.

const Cfg = preload("res://scripts/cfg.gd")

const TEXT := {
	"junction": ["Overloaded junction",
		"Two crossing streams have to take turns here, so each direction only gets part of the time. Fixes: add lanes on the approaches, build a bypass so through-traffic avoids this junction, or spread trips over parallel roads."],
	"merge": ["Merge bottleneck",
		"Several roads feed into one here - more cars arrive than the single exit can carry away. Fixes: widen the road after the merge, or give some of the traffic another way out."],
	"lanedrop": ["Lane drop",
		"The road gets narrower here. Cars from several lanes squeeze into fewer lanes and the queue grows backwards. Fix: keep the same number of lanes until traffic has split up."],
	"saturated": ["Road at capacity",
		"More vehicles want to use this road than fit on it. Fixes: add a lane, build a second route, or move people into buses - one bus carries the passengers of about 15 cars."],
	"hill": ["Slow climb",
		"Vehicles crawl on the steep grade and everybody behind them has to slow down too. Fixes: add a lane on the hill or route the road around it."],
	"bus": ["Bus stopping in the lane",
		"While the bus loads passengers the cars behind it wait. Fix: give this road a second lane so cars can pass - the bus still removes far more cars than it delays."],
	"bike": ["Cyclists sharing the lane",
		"Bikes ride at half the speed of cars, and on a road without bike lanes everybody behind them has to slow down. Fixes: add bike lanes to this road (tool 5), build a separate cycle path (tool 4), or add a second car lane so cars can pass."],
	"spill": ["Queue spilling back",
		"This is not the cause: the road ahead is full, so cars cannot leave this section. Follow the red line in the direction of travel to the front of the queue and fix it there."],
	"slow": ["Dense traffic",
		"Traffic is heavy and slow, but still moving. A small increase in demand will turn this into a jam."],
}
const BRIDGE_NOTE := " This is a river crossing: every trip between the two banks is funnelled through it. A second bridge somewhere else splits the load."


func diagnose(g, l) -> Dictionary:
	var kind := "slow"
	var root := false
	var nxt = l.block_next
	if nxt != null and not g.traffic.links.has(nxt.a * 4 + nxt.dir):
		nxt = null
	if l.bus_ema > 0.2 and l.bus_ema >= l.sig_ema and l.bus_ema >= l.spill_ema:
		kind = "bus"
		root = true
	elif l.bike_ema > 0.3 and l.bike_ema >= l.sig_ema and l.bike_ema >= l.spill_ema:
		kind = "bike"
		root = true
	elif l.spill_ema > 0.12 and l.spill_ema >= l.sig_ema:
		if nxt != null and g.traffic.congestion(nxt) > 0.5 and nxt.occ_ema > 0.3:
			kind = "spill"
		else:
			root = true
			if nxt != null and nxt.lanes.size() < l.lanes.size():
				kind = "lanedrop"
			elif g.roads.degree(l.b) >= 3:
				kind = "merge"
			elif nxt != null and nxt.sf < 1.0:
				kind = "hill"
			else:
				kind = "saturated"
	elif l.sig_ema > 0.12:
		kind = "junction"
		root = true
	elif l.sf < 1.0:
		kind = "hill"
		root = true
	var text: String = TEXT[kind][1]
	if root and (g.world.water[l.b] == 1 or g.world.water[l.a] == 1):
		text += BRIDGE_NOTE
	return {
		"tile": l.b, "kind": kind, "root": root, "title": TEXT[kind][0], "text": text,
		"severity": (1.0 - l.speed_ema) * l.occ_ema * l.lanes.size(),
	}


## The worst root causes on the map, most severe first.
func analyze(g) -> Array:
	var found := []
	for l in g.traffic.link_list:
		if l.occ_ema < 0.3 or l.speed_ema > 0.5:
			continue
		var d := diagnose(g, l)
		if d.root:
			found.append(d)
	found.sort_custom(func(x, y): return x.severity > y.severity)
	var out := []
	var seen := {}
	for d in found:
		if seen.has(d.tile):
			continue
		seen[d.tile] = true
		for k in 4:
			var n: int = g.roads.nbr(d.tile, k)
			if n >= 0:
				seen[n] = true
		out.append(d)
		if out.size() >= 4:
			break
	return out


## Worst link arriving at a tile, or null.
func worst_link(g, i: int):
	var best = null
	var best_c := 0.0
	for d in 4:
		var n: int = g.roads.nbr(i, d)
		if n < 0:
			continue
		for key in [n * 4 + (d + 2) % 4, i * 4 + d]:
			var l = g.traffic.links.get(key)
			if l != null:
				var c: float = g.traffic.congestion(l) * minf(1.0, l.occ_ema * 3.0)
				if c > best_c:
					best_c = c
					best = l
	return best


const BUS_TIPS := """[b]Laying out bus lines[/b]
- People walk at most 5 tiles (100 m) to a stop: put stops in the middle of housing areas and right next to factories, offices, shops and venues.
- A line serves every stop in both directions, so one line along a corridor is enough - do not build a second one for the way back.
- Keep lines fairly straight. Every detour costs all passengers time and they are only paid for if they arrive within the time limit.
- Let lines cross at a shared stop: passengers change there (up to two changes).
- Waiting time is the round trip divided by the number of buses. Long line = more buses needed.
- A stopped bus blocks its lane. Give busy bus roads a second lane.
- Check a line's numbers by clicking its name: an empty line is in the wrong place, a full one needs more buses."""


## Concrete hints for one bus line, based on how it is doing.
func line_advice(g, l) -> Array:
	var tr = g.transit
	var out := []
	if not l.ok:
		out.append("Some of its stops are not connected by road, so no bus can run.")
		return out
	if tr.bus_count(l) == 0:
		out.append("It has no bus. Add one with the + button.")
		return out
	var load: float = l.load_sum / maxf(1.0, l.load_n) / Cfg.BUS_CAP
	if l.load_n >= 12 and load < 0.06:
		out.append("Buses run almost empty. Few people live or work within 5 tiles of its stops, or the stops do not link homes with jobs and shops. Move or add stops.")
	if load > 0.75 or l.left_behind > 0 or tr.waiting_for(l) > 25:
		out.append("Buses are overcrowded and leave people behind. Add buses.")
	if l.wait_n > 5 and l.wait_sum / l.wait_n > 240.0:
		out.append("Passengers wait %s on average. Add a bus or split the line into two shorter ones." % Cfg.fmt_time(l.wait_sum / l.wait_n))
	if tr.lines.size() > 1:
		var shared := false
		for s in l.stops:
			if tr.lines_at.get(s, []).size() > 1:
				shared = true
		if not shared:
			out.append("It shares no stop with another line, so nobody can change between them.")
	for k in l.seg.size():
		if l.seg[k] >= 0.0 and l.seg[k] < 3.0:
			out.append("Two of its stops are less than 60 m apart - every extra stop slows the bus down.")
			break
	if out.is_empty():
		out.append("Running fine.")
	return out
