extends RefCounted
## Terrain: corner height map, rivers, steep hills and district seeds.

const Cfg = preload("res://scripts/cfg.gd")
const W := Cfg.W
const H := Cfg.H

var corner := PackedFloat32Array()
var water := PackedByteArray()
var shore := PackedByteArray()
var steep := PackedByteArray()
var flat := PackedByteArray()
var wdist := PackedInt32Array()
var river_x := PackedFloat32Array()
var districts: Array = []
var rng := RandomNumberGenerator.new()
var seed_value := 0


func in_bounds(x: int, y: int) -> bool:
	return x >= 0 and y >= 0 and x < W and y < H


func generate(s: int) -> void:
	seed_value = s
	rng.seed = s
	water.resize(W * H)
	water.fill(0)
	shore.resize(W * H)
	shore.fill(0)
	steep.resize(W * H)
	steep.fill(0)
	flat.resize(W * H)
	flat.fill(0)
	wdist.resize(W * H)
	corner.resize((W + 1) * (H + 1))
	river_x.resize(H)
	districts.clear()

	var n1 := FastNoiseLite.new()
	n1.seed = s
	n1.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n1.frequency = 0.02

	# Main river: top to bottom, meandering.
	var base := rng.randf_range(W * 0.4, W * 0.6)
	var hw := rng.randf_range(1.0, 1.5)
	var prev := -1.0
	for y in H:
		var cx: float = base + n1.get_noise_2d(y * 2.2, 100.0) * 9.0 + n1.get_noise_2d(y * 6.0, 300.0) * 2.0
		river_x[y] = cx
		var lo: float = cx if prev < 0.0 else minf(cx, prev)
		var hi: float = cx if prev < 0.0 else maxf(cx, prev)
		for x in range(int(floor(lo - hw + 0.5)), int(floor(hi + hw + 0.5)) + 1):
			if in_bounds(x, y):
				water[y * W + x] = 1
		prev = cx

	# Tributary from one side.
	var from_left := rng.randf() < 0.5
	var y0 := rng.randf_range(H * 0.25, H * 0.75)
	var x := 0 if from_left else W - 1
	var prev_y := -1
	while x >= 0 and x < W:
		var fx := float(x)
		var cy := int(round(y0 + n1.get_noise_2d(fx * 2.6, 500.0) * 7.0))
		cy = clampi(cy, 1, H - 2)
		var a := cy if prev_y < 0 else mini(cy, prev_y)
		var b := cy if prev_y < 0 else maxi(cy, prev_y)
		var hit := false
		for yy in range(a, b + 1):
			if water[yy * W + x] == 1:
				hit = true
			water[yy * W + x] = 1
		if hit and prev_y >= 0:
			break
		prev_y = cy
		x += 1 if from_left else -1

	# A pond or two.
	for k in 2:
		var px := rng.randi_range(6, W - 7)
		var py := rng.randi_range(6, H - 7)
		var pr := rng.randf_range(1.6, 2.8)
		for yy in range(py - 4, py + 5):
			for xx in range(px - 4, px + 5):
				var d := Vector2(xx - px, yy - py).length() + n1.get_noise_2d(xx * 9.0, yy * 9.0) * 1.2
				if d < pr and in_bounds(xx, yy):
					water[yy * W + xx] = 1

	_compute_water_distance()

	var n2 := FastNoiseLite.new()
	n2.seed = s + 7
	n2.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n2.frequency = 0.04
	n2.fractal_octaves = 3
	for cy2 in H + 1:
		for cx2 in W + 1:
			var any_water := false
			var dmin := 999
			for oy in [-1, 0]:
				for ox in [-1, 0]:
					var tx: int = cx2 + ox
					var ty: int = cy2 + oy
					if in_bounds(tx, ty):
						if water[ty * W + tx] == 1:
							any_water = true
						dmin = mini(dmin, wdist[ty * W + tx])
			var h := -0.45
			if not any_water:
				var n: float = n2.get_noise_2d(cx2, cy2)
				var hill: float = pow(maxf(0.0, n + 0.02), 1.4) * 5.0
				var f: float = smoothstep(2.0, 9.0, float(dmin))
				h = 0.14 + hill * f + 0.03 * n1.get_noise_2d(cx2 * 11.0, cy2 * 11.0)
			corner[cy2 * (W + 1) + cx2] = h

	_classify()
	_place_districts()


func _classify() -> void:
	shore.fill(0)
	steep.fill(0)
	flat.fill(0)
	for ty2 in H:
		for tx2 in W:
			var i := ty2 * W + tx2
			if water[i] == 1:
				continue
			var h00 := corner[ty2 * (W + 1) + tx2]
			var h10 := corner[ty2 * (W + 1) + tx2 + 1]
			var h01 := corner[(ty2 + 1) * (W + 1) + tx2]
			var h11 := corner[(ty2 + 1) * (W + 1) + tx2 + 1]
			var lo2: float = minf(minf(h00, h10), minf(h01, h11))
			var hi2: float = maxf(maxf(h00, h10), maxf(h01, h11))
			if lo2 < 0.0:
				shore[i] = 1
			elif hi2 - lo2 > Cfg.STEEP_LIMIT:
				steep[i] = 1
			elif hi2 - lo2 <= Cfg.FLAT_LIMIT:
				flat[i] = 1


func _compute_water_distance() -> void:
	wdist.fill(999)
	var queue: Array[int] = []
	for i in W * H:
		if water[i] == 1:
			wdist[i] = 0
			queue.append(i)
	var head := 0
	while head < queue.size():
		var i: int = queue[head]
		head += 1
		var x := i % W
		var y := i / W
		for d in 4:
			var nx: int = x + Cfg.DX[d]
			var ny: int = y + Cfg.DY[d]
			if in_bounds(nx, ny):
				var j := ny * W + nx
				if wdist[j] > wdist[i] + 1:
					wdist[j] = wdist[i] + 1
					queue.append(j)


func side_of_river(x: int, y: int) -> int:
	return 1 if float(x) > river_x[clampi(y, 0, H - 1)] else -1


func _flat_score(x: int, y: int) -> int:
	var n := 0
	for yy in range(y - 3, y + 4):
		for xx in range(x - 3, x + 4):
			if in_bounds(xx, yy) and flat[yy * W + xx] == 1:
				n += 1
	return n


func _place_districts() -> void:
	var types := [Cfg.D_RES, Cfg.D_IND, Cfg.D_COM, Cfg.D_RES, Cfg.D_FUN, Cfg.D_RES, Cfg.D_COM, Cfg.D_RES, Cfg.D_IND]
	for k in types.size():
		var best := Vector2i(-1, -1)
		var best_score := -1e9
		for attempt in 60:
			var x := rng.randi_range(6, W - 7)
			var y := rng.randi_range(6, H - 7)
			var fs := _flat_score(x, y)
			if fs < 36:
				continue
			var dmin := 99.0
			for d in districts:
				dmin = minf(dmin, Vector2(d.pos - Vector2i(x, y)).length())
			if dmin < 11.0:
				continue
			var score: float = minf(dmin, 22.0) + fs * 0.1
			if k == 0:
				# Start near the river so the first bridge matters early.
				score = -absf(float(x) - river_x[y]) * 0.5 + fs * 0.2
				if absf(float(x) - river_x[y]) < 6.0:
					score -= 50.0
			elif k == 1:
				if side_of_river(x, y) != side_of_river(districts[0].pos.x, districts[0].pos.y):
					score += 30.0
				score -= Vector2(districts[0].pos - Vector2i(x, y)).length() * 0.6
			elif k == 2:
				score -= Vector2(districts[0].pos - Vector2i(x, y)).length() * 0.8
			if score > best_score:
				best_score = score
				best = Vector2i(x, y)
		if best.x >= 0:
			districts.append({"type": types[k], "pos": best, "count": 0})


func corner_h(cx: int, cy: int) -> float:
	return corner[cy * (W + 1) + cx]


## Exact height of the rendered terrain (each tile is split along its NW-SE diagonal).
func height_at(fx: float, fz: float) -> float:
	fx = clampf(fx, 0.0, W - 0.0001)
	fz = clampf(fz, 0.0, H - 0.0001)
	var tx := int(fx)
	var ty := int(fz)
	var u := fx - tx
	var v := fz - ty
	var r := ty * (W + 1) + tx
	var h00 := corner[r]
	var h10 := corner[r + 1]
	var h01 := corner[r + W + 1]
	var h11 := corner[r + W + 2]
	if u >= v:
		return h00 + (h10 - h00) * u + (h11 - h10) * v
	return h00 + (h11 - h01) * u + (h01 - h00) * v


## Height of a road / bridge deck at this point.
func road_h(fx: float, fz: float) -> float:
	return maxf(height_at(fx, fz), Cfg.DECK_Y) + Cfg.ROAD_LIFT


func tile_h(x: int, y: int) -> float:
	return height_at(x + 0.5, y + 0.5)


func can_build(x: int, y: int) -> bool:
	if x < 1 or y < 1 or x >= W - 1 or y >= H - 1:
		return false
	return flat[y * W + x] == 1


func dry_line(ax: float, ay: float, bx: float, by: float) -> bool:
	var n := int(maxf(absf(bx - ax), absf(by - ay)) * 2.0) + 1
	for k in n + 1:
		var t := float(k) / n
		var x := int(lerpf(ax, bx, t))
		var y := int(lerpf(ay, by, t))
		if in_bounds(x, y) and water[y * W + x] == 1:
			return false
	return true


func to_save() -> Dictionary:
	var ds := []
	for d in districts:
		ds.append([d.type, d.pos.x, d.pos.y])
	return {
		"seed": seed_value,
		"corner": Marshalls.raw_to_base64(corner.to_byte_array()),
		"water": Marshalls.raw_to_base64(water),
		"river_x": Array(river_x),
		"districts": ds,
	}


func from_save(d: Dictionary) -> void:
	seed_value = int(d.seed)
	rng.seed = seed_value
	corner = Marshalls.base64_to_raw(d.corner).to_float32_array()
	water = Marshalls.base64_to_raw(d.water)
	shore.resize(W * H)
	steep.resize(W * H)
	flat.resize(W * H)
	wdist.resize(W * H)
	river_x = PackedFloat32Array(d.river_x)
	_compute_water_distance()
	_classify()
	districts.clear()
	for e in d.districts:
		districts.append({"type": int(e[0]), "pos": Vector2i(int(e[1]), int(e[2])), "count": 0})
