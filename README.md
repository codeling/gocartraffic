# GoCarTraffic

A traffic-planning game made with **Godot 4** (GDScript, no external assets).

A town grows on a landscape of rivers and hills. Houses, factories, shops,
offices and entertainment venues appear one after another, and the people who
live there want to travel between them on their own schedules. You build the
streets, cycle paths and public transport. **Every trip that arrives within its time
limit earns credits** – the goal is to move as many people as fast as possible
and to understand (and remove) the reasons for traffic jams.

## Play in the browser

Every push to `main` is exported for the web and published with GitHub Pages
(`.github/workflows/web.yml`): **https://codeling.github.io/gocartraffic/**

One-time setup: in the repository settings open *Pages* and set *Source* to
*GitHub Actions*. The web build uses WebGL 2 (Godot's Compatibility renderer)
because browsers cannot run the Vulkan renderer; the desktop version uses Vulkan.

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
godot --headless --path . --export-release "Web" build/web/index.html
```

## How to play

The start screen lets you choose the map, how new buildings spread (close to
the town or anywhere, zoned by type or mixed) and the length of a day. `M`
or `Esc` brings the menu back for **saving and loading**.

| Key | Tool | |
|---|---|---|
| `1` | Inspect | Click a building, road, bus stop or bus line to see what is happening there |
| `2` | Road | Drag to draw a street with one lane per direction (10 credits per tile, steep hills 30, bridges 60). Ends join neighbouring roads automatically; if buildings block the bend, the other bend is used |
| `3` | Add lane | Drag along a road to add a lane in both directions (up to 3 each way) |
| `4` | Cycle path | A separate path for bikes only (3 per tile) |
| `5` | Bike lanes | Add bike lanes to an existing road (1 per tile) |
| `6` | Bus stop | Place stops on roads; people walk up to 5 tiles |
| `7` | Bus line | Click stops in order, finish with `Enter` or right-click. *edit* in the line list adds or removes stops later |
| `8` | Bulldoze | Removes one layer per click: bus stop (75 % refund), bike lanes, extra lanes, then the road (50 %). The highlight shows what goes |

`Ctrl+Z` undo (free for 15 s after building) · `T` traffic view (jams, then
volume) · `G` statistics · `Space` pause · `+` / `-` game speed · `H` help ·
`Ctrl+S` / `Ctrl+O` save / load · `WASD` / arrows / middle-mouse drag to pan ·
mouse wheel to zoom · `Q` / `E` to rotate.

### Scale and time

One tile is 20 m (a house is about 10 m wide, a lane 3 m). Cars drive at most
50 km/h, buses 40, bikes 25, pedestrians 5, and the simulation runs in real
seconds, so distances, speeds and travel times fit together. What is compressed
is the inhabitants' daily routine: by default a "day" of commuting, shopping
and going out is squeezed into 30 minutes, which gives a small town the rush
hours of a big one. The start screen also offers 2-hour and true 24-hour days
(with light traffic). Game speed runs from 1x (4 game seconds per second) to 30x.

### The simulation

* Each household has 3–4 people but only 1–2 cars; later, apartment blocks
  with several households appear.
* For every trip people choose how to travel: on foot (very likely up to
  5 tiles, never beyond 10), by bike (likely up to 10 tiles, less so up to 20,
  never beyond 30 – and more often where the route has bike lanes or cycle
  paths), otherwise by car or bus. Whoever finds no car at home takes the bus,
  cycles or walks if possible – otherwise the trip cannot be made (a `!`
  appears above the house; inspecting it shows the wanted route on the map).
* A trip earns `people × (4 + distance / 2)` credits if it arrives within
  2.5 × the empty-road travel time by car. Late trips earn nothing.
* Cars are simulated individually: they keep their distance, queue lane by lane,
  and can only enter a road section when there is room – so queues spill back
  through junctions. Junctions alternate between their two axes like a traffic
  light. Drivers choose the currently fastest route when they set off and
  re-plan when you change the network.
* Bikes ride in the car lane and hold up the cars behind them unless the road
  has bike lanes.
* Cars park at their destination. When a car park is full, drivers circle for
  a space and lose time.
* Bus lines serve their stops in both directions. Passengers change lines up to
  twice at shared stops. Buses stop in the lane, but one bus replaces dozens of
  cars. The line inspector shows passengers per day and per stop, waiting
  times and load, and says what is wrong with a line.

Cost of cycle infrastructure: published figures put a painted bike lane on an
existing street at roughly 5,000–50,000 USD per mile and a protected lane at
about 70,000–300,000 USD, against upwards of 3 million USD per mile for a new
two-lane road. The game uses 1 (lane) and 3 (separate path) against 10 for a road.

### Saving

A save is one JSON file. On the desktop a file dialog asks where to put it; in
the browser it is downloaded, and *Load game* opens the browser's file picker
(dropping the file onto the window works too). Both editions read each other's
files. A save holds the map, roads, buildings, bus lines, credits and
statistics – vehicles on the road are not stored, after loading everybody
starts from home.

### Learning why jams happen

Turn on the traffic view (`T`) and look at the **Traffic advisor** panel. It
finds the *front* of each queue and names the cause – overloaded junction, merge
bottleneck, lane drop, road at capacity, steep climb, bus stopping in the lane,
cyclists sharing the lane, single river crossing – together with ways to fix
it. Clicking an entry jumps to the spot. Inspecting any red road tells you
whether it is a cause or merely a queue spilling back from a problem further
ahead. Pressing `T` again shows traffic *volume*, i.e. the routes most
vehicles take; `G` shows the split between car, bus, bike and walking.

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

builds a road network and two bus lines automatically, fast-forwards three
days and checks every travel mode, the tools, undo, bulldozing and a
save / load round trip. `-- --seed=N` also selects the map when running the game.
