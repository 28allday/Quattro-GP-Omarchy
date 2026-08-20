.pragma library

//
// Quattro GP -- track geometry and the pseudo-3D projection.
//
// This file is the single source of truth for where the road is. The road
// itself is painted by shaders/road.frag on the GPU and every sprite is placed
// by QML on the CPU, and the two MUST agree to the pixel or cars will float
// off the tarmac. So the curve model here is deliberately one that can be
// evaluated identically in GLSL: a piecewise quadratic.
//
// ---------------------------------------------------------------- the model
//
// The original Pole Position's road is FLAT -- it has curves but no hills.
// That is worth stating because it is what makes this tractable: with no
// elevation there is no occlusion, the horizon never moves, and the mapping
// from a screen row to a distance ahead is a closed form rather than a walk
// down a depth buffer.
//
// A course is a cyclic list of features, each a constant curvature held for a
// length. Curvature c is the second derivative of lateral offset with respect
// to distance, so integrating twice gives, within one feature:
//
//     heading(z) = theta0 + c * z
//     offset(z)  = x0 + theta0 * z + c * z^2 / 2
//
// A piecewise quadratic in z. `runs()` returns those pieces relative to the
// camera and `centerAt()` evaluates them; road.frag carries the same two
// functions in GLSL over the same numbers, passed as the seg0..seg7 uniforms.
//
// ------------------------------------------------------------- de-rotation
//
// runs() starts at x = 0, theta = 0 at the camera. That is not a
// simplification, it is the whole trick: it re-expresses the road relative to
// the car's own position and heading, so the road always leaves the bottom of
// the screen pointing straight at the camera and bends away from there.
// Integrate in absolute world coordinates instead and a long corner walks the
// road sideways off the screen.
//
// The same property makes the seam free. Distance is monotonic and only the
// feature index wraps, so heading and offset keep integrating through the end
// of the lap -- the course is geometrically an ever-widening spiral that
// nobody can see, rather than a loop with a kink where the ends fail to meet.
//

// ------------------------------------------------------------------- world

// World units. The road is 2000 units across; everything else is scaled to
// that, and speeds are units per second.
var ROAD_HALF   = 1000
// 1365, not a round number: the eye height sets how hard the road flares at
// the bottom of the frame (screen width per row goes as 1/CAM_HEIGHT). At
// 1500 the road reached 77% of the frame width on the bottom row; the arcade
// and the mood-board mockup both run it out to ~85%, and 1365 lands there.
var CAM_HEIGHT  = 1365
var CAM_DEPTH   = 1.6          // 1 / tan(fov/2); ~64 degree vertical field
var DRAW_DIST   = 90000        // beyond this the road is sub-pixel, so it fogs
var STRIPE_LEN  = 1800         // world length of one rumble/grass band pair
var MAX_RUNS    = 8            // curve pieces handed to the shader

// The unit that ties the abstract world to real distances, and the reason the
// arcade's numbers can be used as-is.
//
// Pole Position gives you 90 seconds of driving and demands a lap in 73 to make
// the race. That target only means something if a lap is the right length, so
// the course is authored in METRES and converted here. At 150 units per metre
// the 2000-unit road is 13.3m across -- a wide circuit -- 288 km/h comes out at
// 12000 units/s, and Fuji's 4.36km lap becomes ~654,000 units, which needs an
// average of about 215 km/h to lap in 73s. That is a real target rather than a
// formality: the first course here was 135,000 units, which flat out was an
// 11-second lap and made qualifying impossible to fail.
var UNITS_PER_METRE = 150

function metres(m) { return m * UNITS_PER_METRE }
function kmh(unitsPerSecond) { return unitsPerSecond / UNITS_PER_METRE * 3.6 }

// Curvature is quoted in friendly integers in COURSE and scaled by this.
//
// Calibrated against the picture, not guessed. What reads as a corner is how
// far the vanishing point moves, and the vanishing point sits around z = 20000
// where the screen scale is 8e-5: an offset of x units there lands 0.0128 * x
// pixels off centre. Curve 3 needs to move it about 60px to look like a corner
// rather than a drift, so x ~= 4700, and x = curve * UNIT * z^2 / 2 gives
// UNIT ~= 8e-6. At 1e-6 -- the value this started at -- curve 3 moved the
// vanishing point eight pixels and every corner rendered as a straight.
var CURVE_UNIT  = 8.0e-6

// Where the beach ends and the water starts, in road half-widths, on the
// courses that have a shore.
//
// The fourth thing written in two places -- shaders/road.frag paints the sand
// out to here and buildScenery() must not plant anything past it, or there are
// road signs standing in the sea. It is passed to the shader as a uniform
// rather than duplicated as a literal, so there is one number and no drift.
var SHORE_SAND_END = 1.95

// Puddle geometry, declared up here because selectCourse(0) at load time
// computes the first course's puddle list and `var` initialisers further down
// have not run yet. The reasoning lives with puddles(), below the courses.
var PUDDLE_HALF_LEN = 700       // 4.7m of standing water
var PUDDLE_HALF_W   = 340       // 2.3m wide -- half a lane
var PUDDLE_LANES    = [-320, 300, -140]
var PUDDLES = []

// -------------------------------------------------------------- the courses
//
// Pole Position (1982) has exactly one circuit, Fuji. Four courses is a Pole
// Position II thing, and this is it.
//
// Each course is authored in METRES (`m`) and converted to world units by
// selectCourse(), so a layout can be checked against a real lap length rather
// than against itself. `curve` is signed, positive bends right, and its
// magnitude is what moves the vanishing point (see CURVE_UNIT); the length
// only decides how long you are stuck in it. Features stay long -- the
// shortest is 150m, or 22,500 units -- because only MAX_RUNS pieces reach the
// shader, so a course made of short features would spend its whole budget
// inside the near distance.
//
// `scenery` names what lines this feature's verges; see SCENERY below.
//
// Each course also carries its own qualifying numbers, because a single
// 73s/90s pair only means anything for a 4360m lap. They are not guessed:
// each was set by lap-timing the course with dev/laptime.qml and leaving the
// cautious autopilot the same ~4.5s of margin it has at Fuji, which is the
// one circuit whose difficulty is already calibrated. The averages that
// falls out at are Fuji 215km/h, Seaside 228, City 195 (tight, and it shows)
// and Sunset 238.
//
// And its own palette and backdrop, which is the whole reason the renderer
// needed no changes for this: the colours were already shader uniforms and
// the scenery was already per-feature.

var COURSES = [
    {
        name: "FUJI",
        blurb: "THE ORIGINAL",
        target: 73, time: 90,
        backdrop: "backdrop",
        // A sky graded from deep blue overhead down to the fog colour it meets
        // the mountains in. Three of these were a single flat fill until the
        // Sunset work proved the gradient path; a flat sky above a hazed road
        // is the one place the frame admitted it was made of layers. The
        // horizon sits at 0.42 of the frame, so the last stop is where the
        // sky ends -- everything below it is covered by the road quad.
        skyStops: [
            { at: 0.00, colour: "#1b6ed6" },
            { at: 0.20, colour: "#2a84e4" },
            { at: 0.34, colour: "#4d9ee9" },
            { at: 0.42, colour: "#7fb8e8" }
        ],
        palette: {
            sky: "#2a84e4", fog: "#7fb8e8",
            road: "#3a3b3b", roadAlt: "#363737",
            grassA: "#349515", grassB: "#4aa316",
            rumbleA: "#bf220d", rumbleB: "#d7d5d2", lane: "#eeeeeb"
        },
        // A caricature of Fuji's 1982 layout -- the arcade's own was hardly
        // faithful either -- but the lengths are honest: 4360m against the
        // real 4359m, and the corner names are kept so the shape can be
        // argued with.
        features: [
            { m: 1075, curve:  0, scenery: "start" },   // main straight
            { m:  200, curve:  3, scenery: "plain" },   // Turn 1, fast right
            { m:  150, curve:  0, scenery: "signs" },
            { m:  180, curve:  4, scenery: "trees" },   // Coca-Cola corner
            { m:  200, curve:  0, scenery: "trees" },
            { m:  250, curve:  4, scenery: "trees" },   // 100R
            { m:  180, curve:  0, scenery: "plain" },
            { m:  160, curve: -6, scenery: "signs" },   // Hairpin
            { m:  220, curve:  0, scenery: "trees" },
            { m:  400, curve:  2, scenery: "trees" },   // 300R, long and fast
            { m:  150, curve:  0, scenery: "plain" },
            { m:  220, curve: -4, scenery: "trees" },   // Dunlop
            { m:  180, curve:  0, scenery: "signs" },
            { m:  170, curve:  6, scenery: "plain" },   // Panasonic, tight right
            { m:  250, curve:  0, scenery: "trees" },
            { m:  200, curve: -3, scenery: "plain" },   // final corner
            { m:  175, curve:  0, scenery: "signs" }    // run to the line
        ]
    },
    {
        name: "SEASIDE",
        blurb: "LONG AND FLOWING",
        target: 71, time: 88,
        backdrop: "backdrop_seaside",
        skyStops: [
            { at: 0.00, colour: "#1360cf" },
            { at: 0.20, colour: "#1f77e2" },
            { at: 0.34, colour: "#5a9ee4" },
            { at: 0.42, colour: "#8fc0e0" }
        ],
        // The sea is on the LEFT, which is what `shore: -1` tells the road
        // shader -- and it is why the scenery below plants everything on the
        // right. Before this the circuit was called Seaside and was a green
        // field with hills on it, indistinguishable from Fuji.
        shore: -1,
        waveAmt: 0.20,
        palette: {
            sky: "#1f77e2", fog: "#8fc0e0",
            road: "#3a3b3b", roadAlt: "#363737",
            // Drier than Fuji's lush green: this is the landward side of a
            // coast road, not a meadow.
            grassA: "#6d9c37", grassB: "#7cae42",
            // The water, banded like the grass, and the beach between it and
            // the kerb.
            shoreA: "#14608f", shoreB: "#1b74a8",
            sand:   "#d9c894",
            rumbleA: "#bf220d", rumbleB: "#d7d5d2", lane: "#eeeeeb"
        },
        // 4500m of long radius. Nothing here is tight; the lap is won by
        // carrying speed through corners you never fully lift for.
        features: [
            { m:  950, curve:  0, scenery: "start" },
            { m:  300, curve:  2, scenery: "coast" },
            { m:  260, curve:  0, scenery: "trees" },
            { m:  340, curve: -3, scenery: "coast" },
            { m:  200, curve:  0, scenery: "signs" },
            { m:  380, curve:  3, scenery: "coast" },   // around the bay
            { m:  220, curve:  0, scenery: "trees" },
            { m:  260, curve: -5, scenery: "signs" },   // the headland
            { m:  300, curve:  0, scenery: "coast" },
            { m:  340, curve:  4, scenery: "trees" },
            { m:  250, curve:  0, scenery: "coast" },
            { m:  300, curve: -2, scenery: "trees" },
            { m:  400, curve:  0, scenery: "signs" }
        ]
    },
    {
        name: "CITY",
        blurb: "TIGHT AND MEAN",
        target: 70, time: 86,
        backdrop: "backdrop_city",
        // City's grades into smog rather than haze -- its fog colour is the
        // grey-blue one, and the sky reaching it is what puts the skyline in
        // dirty air instead of pasting it on a clean one.
        skyStops: [
            { at: 0.00, colour: "#2472c9" },
            { at: 0.22, colour: "#2983e4" },
            { at: 0.36, colour: "#5c93cd" },
            { at: 0.42, colour: "#8aa8bd" }
        ],
        palette: {
            sky: "#2983e4", fog: "#8aa8bd",
            road: "#414243", roadAlt: "#3c3d3e",
            grassA: "#3a5566", grassB: "#44606d",
            rumbleA: "#bf220d", rumbleB: "#d7d5d2", lane: "#eeeeeb"
        },
        // 3800m and fifteen features, the busiest lap here. The straights are
        // too short to recover a bad exit, so this is the one where the
        // gearbox costs you rather than saves you.
        features: [
            { m:  900, curve:  0, scenery: "start" },
            { m:  180, curve:  5, scenery: "urban" },
            { m:  150, curve:  0, scenery: "urban" },
            { m:  170, curve: -6, scenery: "signs" },
            { m:  200, curve:  0, scenery: "urban" },
            { m:  160, curve:  6, scenery: "urban" },
            { m:  220, curve:  0, scenery: "signs" },
            { m:  180, curve: -5, scenery: "urban" },
            { m:  260, curve:  0, scenery: "urban" },
            { m:  200, curve:  4, scenery: "signs" },
            { m:  150, curve:  0, scenery: "urban" },
            { m:  190, curve: -7, scenery: "urban" },   // tightest here
            { m:  240, curve:  0, scenery: "signs" },
            { m:  200, curve:  3, scenery: "urban" },
            { m:  400, curve:  0, scenery: "urban" }
        ]
    },
    {
        name: "SUNSET",
        blurb: "FLAT OUT",
        target: 74, time: 91,
        backdrop: "backdrop_sunset",
        // The only course with these two. `sun` is a single sprite the
        // renderer hangs behind the horizon strip rather than tiling, and
        // `skyStops` replaces the flat sky with a gradient -- both because
        // the look this circuit is after is a low banded sun under a graded
        // sky, and a tiling strip can be neither.
        sun: "sun_sunset",
        skyStops: [
            { at: 0.00, colour: "#b93a7f" },
            { at: 0.35, colour: "#cc407d" },
            { at: 0.72, colour: "#ef706a" },
            { at: 1.00, colour: "#ee8a68" }
        ],
        palette: {
            sky: "#cc407d", fog: "#ee8a68",
            road: "#3f2c46", roadAlt: "#3a2842",
            grassA: "#7e2c63", grassB: "#8d3269",
            rumbleA: "#e2496f", rumbleB: "#f6dcc9", lane: "#f7e9d6"
        },
        // 4900m, the longest, and the one with the longest straight. Almost
        // all of it is flat out in HI -- except the -5, which arrives after
        // half a minute of not touching the wheel.
        features: [
            { m: 1250, curve:  0, scenery: "start" },   // longest straight here
            { m:  420, curve:  2, scenery: "plain" },
            { m:  300, curve:  0, scenery: "plain" },
            { m:  480, curve: -2, scenery: "signs" },
            { m:  260, curve:  0, scenery: "plain" },
            { m:  520, curve:  3, scenery: "plain" },
            { m:  300, curve:  0, scenery: "signs" },
            { m:  260, curve: -5, scenery: "plain" },   // catches you out
            { m:  340, curve:  0, scenery: "plain" },
            { m:  450, curve:  2, scenery: "signs" },
            { m:  320, curve:  0, scenery: "plain" }
        ]
    }
]

// Which course is loaded. Everything below reads COURSE, so selecting one is
// a matter of pointing COURSE at a different feature list and recomputing the
// two lengths derived from it.
var courseIndex = 0
var COURSE = null

// Which side of the loaded course is water, if any. Copied out of the course
// by selectCourse() so buildScenery() can enforce the one rule a coast adds:
// nothing stands in the sea.
var SHORE = 0
var LAP_LENGTH = 0
var LAP_METRES = 0

function courseCount() { return COURSES.length }
function course() { return COURSES[courseIndex] }

function selectCourse(i) {
    var n = COURSES.length
    courseIndex = ((i % n) + n) % n            // wraps, so the select screen can
    var c = COURSES[courseIndex]               // step past either end
    COURSE = c.features
    SHORE = c.shore || 0

    // Convert the authored metres once, here rather than at load, because
    // "load" no longer knows which course is wanted.
    LAP_LENGTH = 0
    for (var f = 0; f < COURSE.length; f++) {
        COURSE[f].len = metres(COURSE[f].m)
        LAP_LENGTH += COURSE[f].len
    }
    LAP_METRES = LAP_LENGTH / UNITS_PER_METRE
    PUDDLES = puddles()          // hoisted; defined with the gantries below
    return c
}

selectCourse(0)

// --------------------------------------------------------------- projection

// Screen scale of something `z` units ahead of the camera.
function scaleAt(z) {
    return CAM_DEPTH / Math.max(z, 1)
}


// How thoroughly the air has swallowed something z units away, 0 to 1.
//
// The third piece of maths written twice: shaders/road.frag hazes the tarmac
// with these two numbers and Game.qml fades sprites with this. They have to
// agree, or the cars stay fully saturated against a road that no longer is --
// which is exactly what a cardboard cut-out looks like.
//
// Squared rather than a plain smoothstep so the near field stays honest: the
// haze is barely there for the first half of the draw distance and then closes
// in quickly, which is how distance actually reads.
var FOG_START = 0.20

function fogAt(z) {
    var t = (z / DRAW_DIST - FOG_START) / (1 - FOG_START)
    t = Math.max(0, Math.min(1, t))
    t = t * t * (3 - 2 * t)            // smoothstep, the GLSL one
    return t * t
}

// Screen row for something `z` ahead, sitting on the road surface.
// Derived from scale * CAM_HEIGHT * (h / 2), measured down from the horizon.
function screenY(z, horizonY, h) {
    return horizonY + scaleAt(z) * CAM_HEIGHT * h * 0.5
}

// The inverse: how far ahead the road surface is at screen row `y`. This is
// the closed form the flat road buys us, and road.frag uses the same one.
function depthAt(y, horizonY, h) {
    var dy = y - horizonY
    if (dy <= 0) return Infinity
    return CAM_DEPTH * CAM_HEIGHT * h * 0.5 / dy
}

// Half the road's width in screen pixels at distance z.
function halfWidthAt(z, w) {
    return scaleAt(z) * ROAD_HALF * w * 0.5
}

// ------------------------------------------------------------------- curves

// Index of the feature covering `dist`, plus how much of it is left.
function featureAt(dist) {
    var d = dist % LAP_LENGTH
    if (d < 0) d += LAP_LENGTH
    for (var i = 0; i < COURSE.length; i++) {
        if (d < COURSE[i].len) return { index: i, remaining: COURSE[i].len - d }
        d -= COURSE[i].len
    }
    var last = COURSE.length - 1
    return { index: last, remaining: COURSE[last].len }
}

// The visible road ahead of `dist`, as up to MAX_RUNS quadratic pieces.
//
// Each run is { z0, curve, head, x }: at z0 units ahead the road centre is at
// lateral offset `x` with heading `head`, and holds curvature `curve` until
// the next run. x and head start at zero -- see the de-rotation note above.
function runs(dist) {
    var at = featureAt(dist)
    var i = at.index
    var remaining = at.remaining

    var out = []
    var z = 0, x = 0, head = 0

    while (out.length < MAX_RUNS && z < DRAW_DIST) {
        var c = COURSE[i % COURSE.length].curve * CURVE_UNIT
        out.push({ z0: z, curve: c, head: head, x: x })

        var len = Math.min(remaining, DRAW_DIST - z)
        x += head * len + 0.5 * c * len * len
        head += c * len
        z += len

        i++
        remaining = COURSE[i % COURSE.length].len
    }
    return out
}

// Lateral offset of the road centre `z` units ahead, from the same runs the
// shader was given. Every sprite is placed through this.
function centerAt(rs, z) {
    var r = rs[0]
    for (var i = 1; i < rs.length; i++) {
        if (z >= rs[i].z0) r = rs[i]; else break
    }
    var d = z - r.z0
    return r.x + r.head * d + 0.5 * r.curve * d * d
}

// Curvature under the car right now -- what pushes it out of a corner.
function curvatureAt(dist) {
    return COURSE[featureAt(dist).index].curve * CURVE_UNIT
}

// Pack runs for the shader as (z0, curve, head, x). Unused slots are parked
// past the draw distance so their comparisons never fire.
function packRuns(rs) {
    var out = []
    for (var i = 0; i < MAX_RUNS; i++) {
        if (i < rs.length) out.push([rs[i].z0, rs[i].curve, rs[i].head, rs[i].x])
        else out.push([DRAW_DIST * 10, 0, 0, 0])
    }
    return out
}

// --------------------------------------------------------------- scenery

// What lines the verges, per feature style. `x` is in road-half units, so
// 1.0 is the white line and 1.6 is comfortably clear of the rumble strip.
// `every` is METRES between repeats -- at the old 17m spacing the verges read
// as a picket fence once the course was scaled to a real lap length.
var SCENERY = {
    "start":  [ { sprite: "marshal",      x: -2.0,  every: 260 },
                { sprite: "sign_checker", x:  1.9,  every: 260 },
                { sprite: "cone_a",       x:  1.35, every: 22 },
                { sprite: "cone_b",       x: -1.35, every: 22 } ],
    "plain":  [ { sprite: "cone_a",       x:  1.35, every: 20 },
                { sprite: "cone_b",       x: -1.35, every: 20 },
                { sprite: "tree_small",   x: -3.0,  every: 65 } ],
    "trees":  [ { sprite: "tree_big",     x: -2.6,  every: 26 },
                { sprite: "tree_small",   x:  2.4,  every: 19 },
                { sprite: "tree_big",     x:  3.4,  every: 34 },
                { sprite: "cone_a",       x:  1.35, every: 30 } ],
    "signs":  [ { sprite: "sign_100",     x: -1.8,  every: 34 },
                { sprite: "sign_50",      x:  1.8,  every: 34 },
                { sprite: "sign_right",   x:  2.6,  every: 60 },
                { sprite: "cone_b",       x: -1.35, every: 24 } ],

    // No trees. The sprite set has no buildings in it, so a city verge is
    // made of what a city verge actually has more of -- signage and cones,
    // closer together than anywhere else, which also reads as "tight".
    "urban":  [ { sprite: "sign_100",     x: -1.8,  every: 30 },
                { sprite: "sign_50",      x:  1.8,  every: 30 },
                { sprite: "sign_left",    x: -2.7,  every: 72 },
                { sprite: "cone_a",       x:  1.35, every: 17 },
                { sprite: "cone_b",       x: -1.35, every: 17 } ],

    // Open on one side, planted on the other: the sea is on the left, so the
    // trees are all to the right of the road.
    // Planted inland and bare seaward. Everything on the water side has to stay
    // inside SHORE_SAND_END or it is standing in the sea -- which is exactly
    // what the sign at -2.8 was doing the moment the water arrived.
    "coast":  [ { sprite: "tree_small",   x:  2.5,  every: 28 },
                { sprite: "tree_big",     x:  3.3,  every: 44 },
                { sprite: "sign_right",   x:  2.0,  every: 85 },
                { sprite: "cone_a",       x:  1.35, every: 24 },
                { sprite: "cone_b",       x: -1.35, every: 24 },
                { sprite: "marshal",      x: -1.72, every: 150 } ]
}

// Where this lap's sponsor arches stand.
//
// Placed, not repeated. Everything else on the verge is laid down every N
// metres, which is right for cones and signs and would be a tunnel for these:
// an arch is an event, and three a lap is what makes the third one still feel
// like one.
//
// One is always over the start/finish line, which is where a real one is and
// which finally gives the lap line something to arrive AT -- it was painted by
// the shader and had nothing standing over it. The other two are spread around
// the lap, at the straight nearest a third and two thirds of the way round.
//
// Spread rather than "the two longest", which was the first rule and put both
// of Fuji's in the back half: an arch is only in view for the last ~370m of
// the approach, so where they are matters more than how grand the straight is.
//
// ------------------------------------------------------------------ puddles
//
// Standing water on the racing line, the arcade's own hazard. Written in ONE
// place and read by two: shaders/road.frag paints exactly these ellipses (as
// the pud0..2 uniforms) and Game.qml's slide trigger walks the same list, so
// the water you can see is precisely the water that takes your grip -- the
// same discipline as every other written-twice pair here, except this one
// never even forks.
//
// Placed like the gantries: on straights, because a puddle arriving edge-on
// out of a corner cannot be read in time to be fair -- Pole Position's own
// puddles sit where you can see them coming. Fractions 0.30/0.70 of a
// straight keep them clear of the gantry standing at 0.50. Lateral positions
// cycle so one is on the left line, one on the right, one near the middle:
// wherever you like to drive, some lap puts water on it. (The geometry
// constants sit up in the world section -- selectCourse(0) runs at load,
// before initialisers down here would have.)
function puddles() {
    var spots = []
    var base = 0
    for (var i = 0; i < COURSE.length; i++) {
        var f = COURSE[i]
        if (i > 0 && f.curve === 0 && f.len >= metres(170)) {
            spots.push(base + f.len * 0.30)
            spots.push(base + f.len * 0.70)
        }
        base += f.len
    }

    // Three, spread round the lap: nearest unused spot to each third.
    var used = {}
    var out = []
    for (var t = 0; t < 3; t++) {
        var target = LAP_LENGTH * (t + 0.5) / 3
        var best = -1
        for (var k = 0; k < spots.length; k++) {
            if (used[k]) continue
            if (best < 0 || Math.abs(spots[k] - target)
                          < Math.abs(spots[best] - target)) best = k
        }
        if (best < 0) continue
        used[best] = true
        out.push({ z: spots[best], x: PUDDLE_LANES[out.length % 3],
                   len: PUDDLE_HALF_LEN, w: PUDDLE_HALF_W })
    }
    return out
}

function puddleList() { return PUDDLES }

// Corners are skipped on purpose. The arch is placed at x = 0 and so follows
// centerAt() exactly like everything else, and would sit perfectly well in a
// bend; it just stops reading as an arch when it arrives edge-on out of a
// curve. A gantry wants to be seen square, from a long way out.
function gantries() {
    // The line's arch is the same structure with a different board on it:
    // FINISH between two rows of chequers, matching the chequers the shader
    // paints on the tarmac directly underneath. The other two a lap are the
    // sponsor board.
    var out = [{ z: 0, x: 0, sprite: "gantry_finish" }]

    var lap = 0
    var straights = []
    var base = 0
    for (var i = 0; i < COURSE.length; i++) {
        var f = COURSE[i]
        // i > 0 skips the start straight: it already has the line's arch.
        // The length floor keeps one off a 150m link between two corners,
        // where it would arrive already overhead.
        if (i > 0 && f.curve === 0 && f.len >= metres(170))
            straights.push(base + f.len * 0.5)
        base += f.len
        lap += f.len
    }

    var used = {}
    for (var t = 1; t <= 2; t++) {
        var target = lap * t / 3
        var best = -1
        for (var k = 0; k < straights.length; k++) {
            if (used[k]) continue
            if (best < 0 || Math.abs(straights[k] - target)
                          < Math.abs(straights[best] - target)) best = k
        }
        if (best < 0) continue
        used[best] = true
        out.push({ z: straights[best], x: 0, sprite: "gantry" })
    }

    return out
}


// Build the whole lap's roadside furniture once. Each entry is
// { z, x, sprite } with z an absolute distance along the lap.
function buildScenery() {
    var out = []
    var base = 0
    for (var i = 0; i < COURSE.length; i++) {
        var f = COURSE[i]
        var kinds = SCENERY[f.scenery] || []
        for (var k = 0; k < kinds.length; k++) {
            var s = kinds[k]
            var step = metres(s.every)
            // Offset each kind by a different phase so the two verges do not
            // line up into a picket fence.
            var atX = s.x * ROAD_HALF

            // Nothing stands in the sea.
            //
            // Enforced here rather than by rewriting every scenery set,
            // because the sets are shared: SEASIDE uses "trees" and "start"
            // like the inland circuits do, and both plant on BOTH verges --
            // so a coast put a marshal and a row of trees out on the water.
            // One rule at the point of placement cannot be forgotten by the
            // next scenery set someone writes.
            //
            // Dropped rather than mirrored to the landward side. A beach with
            // nothing on it is what a beach looks like; a beach with a double
            // row of trees on the other verge is what a bug looks like.
            if (SHORE !== 0 && atX * SHORE > 0
                    && Math.abs(atX) > SHORE_SAND_END * ROAD_HALF)
                continue

            for (var z = step * (0.3 + 0.4 * k); z < f.len; z += step)
                out.push({ z: base + z, x: atX, sprite: s.sprite })
        }
        base += f.len
    }
    out = out.concat(gantries())
    out.sort(function (a, b) { return a.z - b.z })
    return out
}
