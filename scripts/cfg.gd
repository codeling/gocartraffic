extends RefCounted
## Shared constants for the whole game.
##
## Scale: one tile is 20 m. A house is about 10 m wide, a traffic lane 3 m, a
## car 4.4 m long. Simulation time is in real seconds, so a car at 50 km/h
## covers 0.69 tiles per second.

const W := 72
const H := 56
const DX: Array[int] = [0, 1, 0, -1]
const DY: Array[int] = [-1, 0, 1, 0]
const TILE_M := 20.0

# Terrain
const WATER_Y := -0.12
const DECK_Y := 0.08
const ROAD_LIFT := 0.03
const FLAT_LIMIT := 0.2     # max corner difference for buildings
const STEEP_LIMIT := 0.34   # above this roads are expensive and slow

# Speeds in tiles per second
const CAR_SPEED := 50.0 / 3.6 / TILE_M
const BUS_SPEED := 40.0 / 3.6 / TILE_M
const BIKE_SPEED := CAR_SPEED * 0.5
const WALK_SPEED := 5.0 / 3.6 / TILE_M
const ACCEL := 0.11         # 2.2 m/s2
const BIKE_ACCEL := 0.06
const STEEP_SPEED := 0.6

# Traffic model
const STOP := 0.65          # stop line position on a link
const ENTRY := -0.35        # position a vehicle gets when it enters the next link
const GAP := 0.06
const HEADWAY := 2.2        # seconds between vehicles entering one lane (about 1600 vehicles/h)
const BIKE_HEADWAY := 0.7
const CAR_LEN := 0.22
const BUS_LEN := 0.5
const BIKE_LEN := 0.09
const BUS_CAP := 40
const MAX_LANES := 3
const MIN_GREEN := 5.0
const MAX_GREEN := 25.0
const CLEARANCE := 3.0
const FORCE_AFTER := 240.0  # gridlock breaker
const EMA_T := 20.0
const PARK_SEARCH := 30.0   # extra seconds when the car park is full

# Time. Physical processes run in real seconds; the daily routine of the
# inhabitants is squeezed into DAY_OPTIONS[n] seconds.
const DAY_OPTIONS: Array[float] = [1800.0, 7200.0, 86400.0]
const DAY_NAMES: Array[String] = ["30 minutes (busy, recommended)", "2 hours", "24 hours (true to life, light traffic)"]
const SPEEDS: Array[float] = [0.0, 4.0, 12.0, 40.0, 120.0]
const SPEED_NAMES: Array[String] = ["II", "1x", "3x", "10x", "30x"]
const START_HOUR := 6.0
const MAX_STEP := 0.35

# Economy
const START_CREDITS := 2000
const COST_ROAD := 10
const COST_STEEP := 30
const COST_BRIDGE := 60
# A separate cycle path costs roughly a quarter of a two-lane road in real
# life, a painted lane on an existing road only a few percent.
const COST_BIKEPATH := 3
const COST_BIKEPATH_STEEP := 8
const COST_BIKEPATH_BRIDGE := 20
const COST_BIKELANE := 1
const COST_STOP := 40
const COST_BUS := 150
const REFUND_ROAD := 0.5
const REFUND_STOP := 0.75
const UNDO_SECONDS := 15.0

# Travel behaviour
const WALK_RADIUS := 5       # tiles people walk to a bus stop
const WALK_LIKELY := 5
const WALK_MAX := 10
const BIKE_LIKELY := 10
const BIKE_MID := 20
const BIKE_MAX := 30
const MAX_TRANSFERS := 2
const TIME_FACTOR := 2.5     # allowed time = 2.5 x empty-road time by car
const WAIT_GIVE_UP := 600.0

enum {HOUSE, FACTORY, SHOP, FUN, OFFICE}
const TYPE_NAMES: Array[String] = ["House", "Factory", "Shop", "Entertainment venue", "Office"]
const ZONE: Array[int] = [0, 1, 2, 3, 2]
enum {D_RES, D_IND, D_COM, D_FUN}
enum {M_CAR, M_BUS, M_BIKE, M_WALK}
const MODE_NAMES: Array[String] = ["car", "bus", "bike", "on foot"]

static func half_width(lanes: int) -> float:
	return 0.17 + float(lanes - 1) * 0.15

static func lane_offset(lane: int) -> float:
	return 0.085 + float(lane) * 0.15

static func fmt_time(sec: float) -> String:
	var s := int(round(sec))
	if s < 60:
		return "%d s" % s
	return "%d:%02d min" % [s / 60, s % 60]

static func fmt_dist(tiles: float) -> String:
	var m := tiles * TILE_M
	if m < 1000.0:
		return "%d m" % int(round(m / 10.0) * 10)
	return "%.1f km" % (m / 1000.0)
