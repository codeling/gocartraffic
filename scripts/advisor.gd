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
