# GoCarTraffic

A traffic-planning game made with **Godot 4** (GDScript, no external assets).

A town grows on a landscape of rivers and hills. Houses, factories, shops,
offices and entertainment venues appear one after another, and the people who
live there want to travel between them on their own schedules. You build the
streets and the public transport. **Every trip that arrives within its time
limit earns credits** – the goal is to move as many people as fast as possible
and to understand (and remove) the reasons for traffic jams.

## Run it

1. Install [Godot 4.3 or newer](https://godotengine.org/download) (standard build, not .NET).
2. Open this folder in the Godot project manager (*Import* → `project.godot`) and press **F5**,
   or start it from a terminal:

   ```
   godot --path .
   ```

Works on Windows and Linux. The project uses the **Forward+ renderer, i.e. the
Vulkan backend**. On machines without Vulkan, Godot 4.4+ falls back to OpenGL
automatically; with 4.3 start it with `godot --path . --rendering-driver opengl3`.

To build standalone executables use *Project → Export* – presets for Windows and
Linux are included (`export_presets.cfg`) – or:

```
godot --headless --path . --export-release "Windows Desktop"
godot --headless --path . --export-release "Linux"
```

## How to play

| Key | Tool | |
|---|---|---|
| `1` | Inspect | Click a building, road or bus stop to see what is happening there |
| `2` | Road | Drag to draw a street with one lane per direction (10 credits per tile, steep hills 30, bridges 60) |
| `3` | Add lane | Drag along a road to add a lane in both directions (up to 3 each way) |
| `4` | Bulldoze | Remove roads and bus stops, half the cost is refunded |
| `5` | Bus stop | Place stops on roads; people walk up to 5 tiles |
| `6` | Bus line | Click stops in order, finish with `Enter` or right-click; buses loop along the stops |

`T` traffic view · `Space` pause · `+` / `-` game speed · `F1` help ·
`WASD` / arrows / middle-mouse drag to pan · mouse wheel to zoom · `Q` / `E` to rotate.

### The simulation

* A day lasts six minutes at 1x speed. Rush hours are around 7:00 and 16:00.
* Each household has 3–4 people but only 1–2 cars. People share cars; whoever
  finds no car at home takes a bus if a line connects origin and destination –
  otherwise the trip cannot be made (a `!` appears above the house).
* A trip earns `people × (4 + distance / 2)` credits if it arrives within
  1.3 × the empty-road travel time (buses get more slack). Late trips earn nothing.
* Cars are simulated individually: they keep their distance, queue lane by lane,
  and can only enter a road section when there is room – so queues spill back
  through junctions. Junctions alternate between their two axes like a traffic
  light. Drivers choose the currently fastest route when they set off and
  re-plan when you change the network.
* Buses use the same roads and stop in the lane, but one bus replaces dozens of cars.

### Learning why jams happen

Turn on the traffic view (`T`) and look at the **Traffic advisor** panel. It
finds the *front* of each queue and names the cause – overloaded junction, merge
bottleneck, lane drop, road at capacity, steep climb, bus stopping in the lane,
single river crossing – together with ways to fix it. Clicking an entry jumps
to the spot. Inspecting any red road tells you whether it is a cause or merely
a queue spilling back from a problem further ahead.

## Project layout

```
project.godot        engine settings (Forward+ / Vulkan)
main.tscn            the single scene; everything else is created in code
scripts/cfg.gd       constants and tuning values
scripts/world.gd     terrain, rivers, hills, district seeds
scripts/roads.gd     road grid, lanes, route finding
scripts/traffic.gd   vehicle simulation (links, lanes, junction control)
scripts/city.gd      buildings, households, daily schedules, trip rewards
scripts/transit.gd   bus stops, lines, buses and passengers
scripts/advisor.gd   jam diagnosis
scripts/view.gd      all 3D meshes (terrain, roads, buildings, vehicles)
scripts/hud.gd       user interface
scripts/game.gd      main loop, tools, input, statistics
tests/smoke.gd       headless end-to-end test
tests/shot.gd        renders screenshots of an automatically built town
```

## Tests

```
godot --headless --path . -s tests/smoke.gd -- --seed=7
```

builds a road network and a bus line automatically, fast-forwards five days and
checks that people get delivered, buses carry passengers and the road tool
reacts to mouse input. `-- --seed=N` also selects the map when running the game.
