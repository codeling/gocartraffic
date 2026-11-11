extends RefCounted
## Shared constants for the whole game.

const W := 72
const H := 56
const DX: Array[int] = [0, 1, 0, -1]
const DY: Array[int] = [-1, 0, 1, 0]

# Terrain
const WATER_Y := -0.12
const DECK_Y := 0.08
const ROAD_LIFT := 0.03
const FLAT_LIMIT := 0.2     # max corner difference for buildings
const STEEP_LIMIT := 0.34   # above this roads are expensive and slow

# Traffic (distances in tiles, times in simulation seconds)
const CAR_SPEED := 1.6
const BUS_SPEED := 1.5
const ACCEL := 3.5
const STOP := 0.65          # stop line position on a link
const ENTRY := -0.35        # position a vehicle gets when it enters the next link
const GAP := 0.06
const HEADWAY := 1.1        # seconds between vehicles entering one lane: the lane's capacity
const CAR_LEN := 0.22
const BUS_LEN := 0.44
const BUS_CAP := 40
const MAX_LANES := 3
const MAX_GREEN := 4.0
const CLEARANCE := 1.0
const STEEP_SPEED := 0.6

# Time
const SEC_PER_HOUR := 15.0
const START_HOUR := 6.0

# Economy
const START_CREDITS := 2000
const COST_ROAD := 10
const COST_STEEP := 30
const COST_BRIDGE := 60
const COST_STOP := 40
const COST_BUS := 150
const REFUND := 0.5

# Public transport
const WALK_RADIUS := 5
const WALK_T := 1.2

enum {HOUSE, FACTORY, SHOP, FUN, OFFICE}
const TYPE_NAMES: Array[String] = ["House", "Factory", "Shop", "Entertainment venue", "Office"]
enum {D_RES, D_IND, D_COM, D_FUN}

static func half_width(lanes: int) -> float:
	return 0.17 + float(lanes - 1) * 0.15

static func lane_offset(lane: int) -> float:
	return 0.085 + float(lane) * 0.15
