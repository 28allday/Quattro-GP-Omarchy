import QtQuick
import "Track.js" as Track

// Quattro GP -- the cabinet.
//
// Everything here is drawn at 320x240 and integer-scaled by the caller, so all
// geometry below is in game pixels. That single decision is what keeps the look
// honest: the shaded road, the extracted sprites and the bitmap HUD all land on
// the same pixel grid, and none of them can end up looking hand-drawn over the
// others.
//
// Deliberately free of Quickshell imports. The whole game runs under a plain
// `qml6 dev/play.qml`, which is the only reason it was possible to tune the
// handling without restarting the shell for every change. Panel.qml adds the
// things that genuinely need the shell: a window, keyboard focus, and saving
// the high score.
Item {
    id: game

    focus: true

    // ------------------------------------------------------------ interface

    property int topScore: 0            // seeded from disk by Panel.qml
    // The ranking table for the current course: up to five {n, s} rows,
    // best first, owned and persisted by the host. The game only reads it --
    // to decide whether a finished run has earned the initials screen -- and
    // reports an entry back through the signal. Same emit-don't-assign rule
    // as topScore, for the same binding reason.
    property var highScores: []
    signal highScoreEntered(string name, int value)
    // The last name entered on the initials screen, stored by the host so
    // the next session starts prefilled. The game's own copy for the running
    // session is driverName below.
    property string defaultDriver: ""
    signal driverNamed(string name)
    signal quitRequested()

    // Insert an entry into a table, best first, five rows kept. A function on
    // the game rather than in each host so Panel.qml, dev/play.qml and the
    // bugcheck can never disagree about what the table is.
    function mergeScore(table, name, value) {
        var out = []
        for (var i = 0; i < table.length; i++)
            out.push({ n: table[i].n, s: table[i].s })
        out.push({ n: name, s: value })
        out.sort(function (a, b) { return b.s - a.s })
        if (out.length > 5) out.length = 5
        return out
    }

    // Would this score make the table? Ties lose: arriving level with the
    // fifth-best is not beating it.
    function scoreQualifies(value) {
        if (value <= 0) return false
        if (game.highScores.length < 5) return true
        return value > game.highScores[game.highScores.length - 1].s
    }

    // ------------------------------------------------------------ constants

    // ---- gearbox
    //
    // The signature mechanic, and the reason the cabinet has a lever. Two
    // positions, LOW and HI. LOW pulls hard off the line and runs out of legs
    // at ~168km/h; HI has almost nothing at low speed and everything at the
    // top. The crossover is deliberately just above LOW's ceiling, so the
    // arcade's own advice -- shift up before about 105mph -- is the right
    // advice here too.
    readonly property real lowMax:       7000    // ~168 km/h, ~104 mph
    readonly property real highMax:     12000    // ~288 km/h, ~179 mph
    readonly property real lowTorque:   11000
    readonly property real highTorque:   6200
    readonly property real revLimit:     6000    // holds LOW to its ceiling

    readonly property real maxSpeed:    highMax
    readonly property real brakeRate:   14000
    readonly property real dragRate:      900
    readonly property real offRoadMax:   4200
    readonly property real offRoadDrag: 11000
    readonly property real steerRate:    4200

    // Cornering push, scaled by speed squared.
    //
    // The number that decides whether the circuit is a circuit. Each corner
    // lets go at sqrt(steerRate / (curvature * centrifugal)), and at 0.9 that
    // sorts them into a gradient worth driving:
    //   curve 2 (300R)        -- no limit, flat all day
    //   curve 3 (Turn 1)      -- 335 km/h, above the car's top speed
    //   curve 4 (Coca-Cola)   -- 290 km/h, flat but with nothing to spare
    //   curve 6 (the hairpin) -- 237 km/h, needs a genuine lift
    //
    // It began at 1.2e-4, which came to roughly one unit per second against a
    // 1000-unit road half-width: three orders of magnitude short, and corners
    // had no effect on the car whatsoever.
    readonly property real centrifugal: 0.9

    // ---- letting go
    //
    // Above a full wheel's worth of cornering load the car slides: no steering
    // for slideLength, the push running unopposed, and speed scrubbing off the
    // whole time. The arcade does the same -- taking a curve too quickly
    // briefly costs you control -- and it is also the hook a puddle would use.
    readonly property real slideLength: 0.85     // seconds

    // How far ahead of the camera the player car is drawn: the z whose screen
    // row the sprite's wheels sit on, CAM_DEPTH * CAM_HEIGHT * (h/2) / dy
    // with dy = (240 - 8) - horizonY(101) = 131 rows below the horizon.
    // Anything that tests the CAR against a painted road feature (puddles)
    // uses this, or the effect fires while the water is still visibly ahead.
    readonly property real puddleCarZ: 2000
    readonly property real slideDrag:   7000

    // World units per sprite pixel: a 56px rival ends up ~730 units wide
    // against a 2000-unit road, so three cars fill it.
    readonly property real worldPerPx: 13

    // How far ahead roadside furniture is drawn, and how many sprites the pool
    // holds. 30000 units was only 200m -- two and a half seconds of road at
    // racing speed, so the verges kept arriving out of nowhere. 55000 is ~370m.
    readonly property real spriteDist: 55000
    readonly property int  slotCount:  64   // ~56 scenery + 7 rivals, plus slack

    // ---- the start signal
    //
    // Three lamps fill red, one per beat, and the phase changes on the beat
    // after the last one -- so the green light *is* the start rather than a
    // cue that something else is about to happen. Both starts run through the
    // "ready" phase, so qualifying and the race get the same signal.
    //
    // readyTime must be lightBeat * 4: three beats to fill the lamps and one
    // more holding them full red, which is the beat you launch off.
    readonly property real lightBeat:  0.8       // seconds between lamps
    readonly property real readyTime:  3.2
    readonly property real greenHold:  0.9       // green stays lit after GO

    // ---- jumping the start
    //
    // The offence is being on the throttle before the green. The car cannot
    // move during "ready" -- the driving code is gated -- so "moved early"
    // is not a thing that can be detected; the throttle is.
    //
    // The grace matters more than it looks. You reach the grid by crossing the
    // line flat out, so the throttle is ALREADY held the instant the countdown
    // starts, and without a beat to lift in every qualifier would jump their
    // own race start. It is judged on the held state rather than a key press:
    // auto-repeat fires onPressed over and over for a held key, so an edge test
    // would be at the mercy of the keyboard's repeat rate.
    readonly property real jumpGrace:   0.5      // seconds to lift off in
    readonly property real jumpPenalty: 2.0      // engine held this long at GO

    // ---- the arcade's numbers
    //
    // Laps were DIP-selectable 3/4/5/6; four is the setting this ships with.
    readonly property int  raceLaps:      4

    // ---------------------------------------------------------------- course
    //
    // Which of Track.COURSES is loaded. Changing it re-points Track.COURSE,
    // rebuilds the roadside furniture and republishes the two lengths derived
    // from the layout -- Track is a plain JS library, so nothing there can
    // notify a QML binding and the values have to be copied out to properties.
    property int courseIndex: 0
    property var course: Track.course()
    property real lapLength: Track.LAP_LENGTH
    readonly property int courseCount: Track.courseCount()

    onCourseIndexChanged: game.loadCourse()

    function loadCourse() {
        game.course = Track.selectCourse(game.courseIndex)
        game.lapLength = Track.LAP_LENGTH
        game.scenery = Track.buildScenery()
    }

    // The qualifying pair started as the machine's own -- 90 seconds of
    // driving and a lap in 73 or you do not start -- and that is still what
    // Fuji uses. It is per course now, because 73s/90s only means anything
    // for a 4360m lap: City is 3800m and tighter, Sunset 4900m and faster.
    // Each is set so the average speed it demands suits the circuit.
    readonly property real qualifyTime:   game.course ? game.course.time   : 90
    readonly property real qualifyTarget: game.course ? game.course.target : 73
    readonly property real raceTime:      85     // on the clock at the start
    readonly property real extendTime:    75     // added at each lap line

    // ---- scoring
    //
    // 50 a car passed and 200 a second left on the clock are the arcade's.
    // Distance is not: the strategy guides say 50 points per 5 metres, which
    // over a four-lap race comes to more than 170,000 and cannot be squared
    // with a tracked world record of 67,310. Calibrated against the record
    // instead -- 50 points per 20 metres puts a strong game in the sixties.
    readonly property real pointsPerCar:    50
    readonly property real pointsPerSecond: 200
    readonly property real distanceStep:    3000   // world units, = 20m
    readonly property real pointsPerStep:   50

    readonly property real carLength: 900        // collision box, world units

    // Centre-to-centre gap at which two cars are touching, so also the
    // lateral collision threshold.
    //
    // This was 620, which is 4.13m, and it was the "you crashed but you were
    // nowhere near it" bug reported from play on 2026-08-18. The cars stop
    // overlapping on screen at 3.07m, so there was a **1.07m band of clear
    // air** in which the game still killed you -- and since a pass only has
    // about 2m of room to begin with, it made overtaking feel arbitrary.
    // Measured, not guessed: dev/passcheck.qml sweeps the separation and asks
    // the collider and the renderer the same question independently.
    //
    // Re-measured 2026-08-20 after the scale pass (player 88->72px, rival
    // draw width 56->44): the sprites now part at 2.40m, so 460 had grown a
    // 0.67m phantom band of its own. Same harness, same method: this number
    // is whatever dev/passcheck.qml says the renderer says, and must be
    // re-measured whenever a car's drawn size changes.
    readonly property real carWidth:  360

    // The size updateSlots() hands place() for a rival, in art pixels. 44,
    // not the art file's 56: chosen so a rival at the player's own row
    // renders the same width as the 72px player sprite. THE one copy -- the
    // dev harnesses read rivalHalfWidth off the game rather than restating
    // the number, so certifying and drawing can never disagree.
    readonly property int rivalDrawW: 44
    readonly property int rivalDrawH: 31

    // Half the width a rival is actually DRAWN at, world units. Anything that
    // positions a rival laterally has to know this or it will place the car's
    // centre legally and hang its bodywork over the kerb.
    readonly property real rivalHalfWidth: game.rivalDrawW * game.worldPerPx * 0.5

    // The furthest a rival's centre can sit and still keep all four wheels on
    // the tarmac.
    readonly property real rivalXLimit: Track.ROAD_HALF - game.rivalHalfWidth

    readonly property real rivalDodge: 2600      // lateral units/s when passing

    // The two files of the starting grid, either side of the centreline.
    //
    // This was briefly pulled in to 0.38 while fixing the grid, on the theory
    // that 0.55 put the cars too near the kerb. Filming it showed the
    // opposite: 0.55 leaves 0.58m of tarmac outside the bodywork, which is
    // fine, while 0.38 left only 0.21m *between the two files* and the grid
    // read as one cramped huddle. The offset was never the bug -- the file
    // assignment was. So it stays where it was.
    readonly property real gridColumn: Track.ROAD_HALF * 0.55

    // ---------------------------------------------------------------- state

    // "attract" | "select" | "ready" | "qualify" | "race" | "crash"
    //           | "initials" | "over"
    property string phase: "attract"
    property real   phaseTime: 0

    // ---- the initials screen
    //
    // Sits between course select and the qualifying lap: you say who is
    // driving BEFORE you drive, and a score that makes the table afterwards
    // files itself under that name with no ceremony at the end. Steered the
    // arcade way: left/right cycle the letter, ENTER locks it, three locks
    // start the game. ESC backs out to course select. The letters arrive
    // prefilled with the last name entered -- this session's, or the one the
    // host remembered from disk -- so a returning driver is three ENTERs
    // from the grid.
    readonly property string entryAlphabet: "ABCDEFGHIJKLMNOPQRSTUVWXYZ "
    property var entryLetters: [0, 0, 0]
    property int entrySlot: 0
    property string driverName: ""
    readonly property string entryName:
        entryAlphabet[entryLetters[0]] + entryAlphabet[entryLetters[1]]
        + entryAlphabet[entryLetters[2]]

    function openEntry() {
        var seed = game.driverName || game.defaultDriver || ""
        var ls = [0, 0, 0]
        for (var i = 0; i < 3; i++) {
            var at = i < seed.length ? game.entryAlphabet.indexOf(seed[i]) : 0
            ls[i] = at >= 0 ? at : 0
        }
        game.entryLetters = ls
        game.entrySlot = 0
        game.setPhase("initials")
    }

    // What the last submitted entry was, so the ranking tables can point at
    // your row rather than leaving you to find yourself in the list.
    property string lastEntryName: ""
    property int    lastEntryScore: -1

    function cycleEntry(step) {
        var ls = game.entryLetters.slice()
        var n = game.entryAlphabet.length
        ls[game.entrySlot] = (ls[game.entrySlot] + step + n) % n
        game.entryLetters = ls
    }

    function lockEntry() {
        if (game.entrySlot < 2) { game.entrySlot++; return }
        game.submitInitials()
    }

    function submitInitials() {
        var name = game.entryName.replace(/ +$/, "")
        if (name.length === 0) name = "AAA"
        game.driverName = name
        game.driverNamed(name)
        game.startGame()
        // Some drivers do not qualify. They arrive.
        if (name === "DHH") {
            game.qualified = true
            game.gridPos = 1
            game.lap = 1
            game.timeLeft = game.raceTime
            game.speed = 0
            game.gear = 0
            game.spawnRivals()
            game.setPhase("ready")
        }
    }

    property real dist: 0                // absolute distance travelled
    property real playerX: 0             // lateral offset from the centreline
    property real speed: 0
    property real lapStart: 0            // dist at which the current lap began
    property real lapClock: 0
    property real bestLap: 0

    property int  score: 0
    property int  lap: 0
    property real timeLeft: 0
    property bool qualified: false

    property int  gear: 0                // 0 = LOW, 1 = HI
    property int  gridPos: 0             // 1..8, set by the qualifying lap

    // Where the player actually is in the race, 1..8, recomputed every frame
    // from where the field is.
    //
    // Distinct from gridPos, which is the slot the qualifying lap earned and
    // never changes. The HUD used to show gridPos for POS, so it read the
    // grid slot for the whole race however many cars had been passed -- the
    // "I was 6th, passed all the cars, and there were more cars in front"
    // report, of which this was half.
    property int  racePos: 0
    property real distScored: 0          // distance not yet turned into points
    property real slideTime: 0           // seconds of lost control remaining
    property int  slideDirection: 0      // which way the tail stepped out

    // Seconds since the lights went green. Starts expired, so nothing but a
    // real start can show the green -- a crash rejoin re-enters the driving
    // phase with phaseTime at zero and would otherwise flash GO at you.
    property real greenClock: greenHold

    property bool jumped: false          // latched during "ready", judged at GO
    property real stallTime: 0           // engine held, seconds remaining

    // What the signal is showing: -1 nothing, 0..3 that many red lamps, 4 green.
    readonly property int startLights: {
        if (game.phase === "ready")
            return Math.min(3, Math.floor(game.phaseTime / game.lightBeat))
        if ((game.phase === "qualify" || game.phase === "race")
            && game.greenClock < game.greenHold)
            return 4
        return -1
    }

    // The seven cars you are qualifying against. Beat a time and you start
    // ahead of that car; the spread is what turns one lap into a grid slot
    // rather than a pass/fail.
    //
    // The spread is anchored to the CURRENT course's target, not written as
    // absolute times: the original array was calibrated for Fuji's 73s, and
    // on City (target 70s) its two slowest cars could never be out-qualified
    // by anyone who qualified at all -- grid slots 7 and 8 were unreachable
    // there and the qualifying bonus had a hidden floor. Same offsets, every
    // circuit: the slowest rival is always one second under the target, so
    // barely scraping in always means starting P8.
    readonly property var rivalQualifyingOffsets: [-14.5, -11.5, -9.0, -6.5, -4.5, -2.5, -1.0]
    readonly property var rivalQualifying: {
        var t = game.course ? game.course.target : 73
        return game.rivalQualifyingOffsets.map(function (o) { return t + o })
    }

    property var rivals: []
    property var scenery: Track.buildScenery()   // rebuilt by loadCourse()

    property int  steerInput: 0          // -1, 0, +1
    property bool throttle: false
    property bool braking: false

    // Filled each frame with what to draw, sorted far to near. Reassigning the
    // array re-evaluates the delegates' bindings without rebuilding them --
    // making this a Repeater model instead would destroy and recreate forty
    // items every frame.
    property var slots: []

    readonly property real horizonY: road.horizonY
    readonly property int  kmh: Math.round(Track.kmh(speed))
    readonly property int  mph: Math.round(Track.kmh(speed) * 0.621371)

    // Engine pull at the current speed, for the gear you are in. LOW is a flat
    // torque curve that simply runs out; HI is deliberately gutless until the
    // revs are up, which is what makes shifting a decision rather than a
    // formality you do once at the lights.
    function accelAt(v) {
        if (game.gear === 0)
            return game.lowTorque * Math.max(0, 1 - v / game.lowMax)
        var band = 0.20 + 0.80 * Math.min(1, v / 5200)
        return game.highTorque * Math.max(0, 1 - v / game.highMax) * band
    }

    // Grid slot for a qualifying lap time: one place for every rival you beat.
    function gridFor(lapTime) {
        var place = 1
        for (var i = 0; i < game.rivalQualifying.length; i++)
            if (game.rivalQualifying[i] < lapTime) place++
        return place
    }

    // ---------------------------------------------------------------- input

    Keys.onPressed: function (e) {
        // The initials screen owns the keyboard outright while it is up --
        // the same keys mean different things there, and a lingering throttle
        // press must not leak into the next attract loop.
        if (game.phase === "initials") {
            switch (e.key) {
            case Qt.Key_Left:  case Qt.Key_A: game.cycleEntry(-1); break
            case Qt.Key_Right: case Qt.Key_D: game.cycleEntry(1); break
            case Qt.Key_Up:    case Qt.Key_W: game.cycleEntry(-1); break
            case Qt.Key_Down:  case Qt.Key_S: game.cycleEntry(1); break
            case Qt.Key_Return: case Qt.Key_Enter: case Qt.Key_Space:
                if (e.isAutoRepeat) return
                game.lockEntry()
                break
            case Qt.Key_Escape: case Qt.Key_Q: game.setPhase("select"); break
            default: return
            }
            e.accepted = true
            return
        }
        switch (e.key) {
        case Qt.Key_Left:  case Qt.Key_A:
            if (game.phase === "select") game.pickCourse(-1)
            else game.steerInput = -1
            break
        case Qt.Key_Right: case Qt.Key_D:
            if (game.phase === "select") game.pickCourse(1)
            else game.steerInput = 1
            break
        case Qt.Key_Up:    case Qt.Key_W: case Qt.Key_Z: game.throttle = true; break
        case Qt.Key_Down:  case Qt.Key_S: case Qt.Key_X: game.braking = true; break
        case Qt.Key_Return: case Qt.Key_Enter:
            if (game.phase === "select") game.openEntry()
            else if (game.phase === "attract" || game.phase === "over") game.openSelect()
            break
        case Qt.Key_Space: case Qt.Key_Shift:
            // The shifter. Guarded against auto-repeat, or holding it down
            // flaps the gearbox between LOW and HI many times a second.
            if (e.isAutoRepeat) return
            if (game.phase === "select") game.openEntry()
            else if (game.phase === "attract" || game.phase === "over") game.openSelect()
            else game.gear = game.gear === 0 ? 1 : 0
            break
        case Qt.Key_Escape: case Qt.Key_Q:
            // The menus step back toward the title; anywhere else ESC closes
            // the cabinet AND resets it. The host keeps this instance loaded
            // across open/close (keepLoaded), so without the reset the next
            // open would land mid-race in a game abandoned days ago.
            if (game.phase === "select") { game.setPhase("attract"); break }
            if (game.phase !== "attract") game.abortRun()
            game.quitRequested()
            break
        default: return
        }
        e.accepted = true
    }

    Keys.onReleased: function (e) {
        if (e.isAutoRepeat) return
        switch (e.key) {
        case Qt.Key_Left:  case Qt.Key_A: if (game.steerInput === -1) game.steerInput = 0; break
        case Qt.Key_Right: case Qt.Key_D: if (game.steerInput ===  1) game.steerInput = 0; break
        case Qt.Key_Up:    case Qt.Key_W: case Qt.Key_Z: game.throttle = false; break
        case Qt.Key_Down:  case Qt.Key_S: case Qt.Key_X: game.braking = false; break
        default: return
        }
        e.accepted = true
    }

    // ------------------------------------------------------------ game flow

    // Open the course menu. Entered from the attract screen and from GAME
    // OVER, so a second go can be on a different circuit without waiting for
    // the attract loop to come round.
    function openSelect() {
        game.dist = 0
        game.speed = 0
        game.playerX = 0
        game.rivals = []
        // Clear the last race's start-line state as well as its car. These
        // drive HUD messages, and a penalty carried into the menu prints
        // itself over the course name.
        game.jumped = false
        game.stallTime = 0
        game.slideTime = 0
        game.greenClock = game.greenHold
        game.clearInputs()
        game.setPhase("select")
    }

    // The inputs are only ever cleared by key RELEASES, and a release is not
    // delivered to a window that hid between press and release -- ESC quits
    // the cabinet with the throttle key still down, keepLoaded preserves the
    // latch, and the next session opens with a phantom throttle that jump-
    // starts the grid by itself. Every fresh start clears them instead.
    function clearInputs() {
        game.throttle = false
        game.braking = false
        game.steerInput = 0
    }

    // Step through the circuits. Track.selectCourse() wraps, so this does too.
    function pickCourse(delta) {
        game.courseIndex = (game.courseIndex + delta + Track.courseCount())
                           % Track.courseCount()
        game.dist = 0
        game.phaseTime = 0
    }

    function startGame() {
        game.score = 0
        game.dist = 0
        game.playerX = 0
        game.speed = 0
        game.lap = 1
        game.lapStart = 0
        game.lapClock = 0
        game.bestLap = 0
        game.qualified = false
        game.rivals = []
        game.gear = 0
        game.gridPos = 0
        game.distScored = 0
        game.slideTime = 0
        game.greenClock = game.greenHold
        game.jumped = false
        game.stallTime = 0
        game.timeLeft = game.qualifyTime
        game.clearInputs()
        game.setPhase("ready")
    }

    // ESC mid-run: abandon the race and put the cabinet back on its title.
    function abortRun() {
        game.startGame()             // clears the whole run state...
        game.setPhase("attract")     // ...but lands on the title, not the grid
    }

    function setPhase(p) {
        game.phase = p
        game.phaseTime = 0
        // Every route into the countdown clears the offence, so the flag can
        // never be carried from one start to the next.
        if (p === "ready") game.jumped = false
    }

    // Line the seven rivals up on the grid around the player.
    //
    // Seven, not eight -- the arcade fields seven CPU cars and the player makes
    // the eighth. Where the player sits among them is `gridPos`, so a pole lap
    // means an empty road ahead and a scrappy one means six cars to pass.
    function spawnRivals() {
        var colours = ["rival_red", "rival_blue", "rival_yellow",
                       "rival_green", "rival_white"]
        var gap = Track.metres(14)
        // Defensive: a caller that jumps straight into a race without
        // qualifying leaves gridPos at 0, which would put every car behind the
        // player and empty the road ahead.
        var pos = Math.max(1, Math.min(8, game.gridPos || 4))
        var ahead = pos - 1
        var out = []

        for (var i = 0; i < 7; i++) {
            // Slots run positive in front of the player and negative behind,
            // skipping zero, which is the player's own place on the grid.
            var slot = i < ahead ? (ahead - i) : (ahead - i - 1)
            out.push({
                z: game.dist + slot * gap,
                // Which file this car lines up in, from its ABSOLUTE grid
                // position rather than its offset from the player. That is
                // the fix for "on the grid they are not lined up very well":
                // the column used to alternate by slot, which is relative, so
                // whichever file the player belonged in, they were never
                // actually in it -- the two files formed either side and the
                // player sat in the gap down the middle.
                x: game.gridColumnFor(pos - slot),
                speed: game.maxSpeed * (0.52 + Math.random() * 0.26),
                sprite: colours[i % colours.length],
                passed: slot < 0,
                // Still racing. A car only stops racing when the player has
                // put it a long way behind -- see updateRivals().
                backmarker: false
            })
        }
        game.rivals = out
        game.racePos = pos

        // The player is on the grid too, so line them up in their own file.
        // Without this the field forms two columns and the player is left
        // straddling the centreline between them. It has to happen here
        // rather than at the call site because this function is the one
        // thing that knows the grid's shape.
        game.playerX = game.gridColumnFor(pos)
    }

    // Odd grid positions take the left file, even the right, so pole sits on
    // the left and the field alternates back from there.
    function gridColumnFor(position) {
        return (position % 2 === 1 ? -1 : 1) * game.gridColumn
    }

    function crash() {
        if (game.phase === "crash") return
        game.setPhase("crash")
        game.speed = 0
    }

    // Push anything sitting on top of the player far enough up the road to
    // rejoin into.
    //
    // Needed because a crash freezes the world for 2.6s -- updateRivals() does
    // not run -- and then drops the car back at the same distance. The car that
    // hit you is still exactly where it was, a car's length ahead, so the very
    // next frame collides again and the game locks into a crash loop. Found by
    // dev/bugcheck.qml, not by playing.
    function clearRoadAhead() {
        var rs = game.rivals.slice()
        var safe = Track.metres(90)
        for (var i = 0; i < rs.length; i++) {
            var dz = rs[i].z - game.dist
            if (dz > -Track.metres(25) && dz < safe) {
                rs[i].z = game.dist + safe + Math.random() * Track.metres(140)
                // `passed` stays as it was: it is the SCORING latch, not a
                // position. Resetting it here paid +50 a second time for
                // re-passing a car the crash teleported back ahead, so two
                // identical drives scored differently by crash timing.
            }
        }
        game.rivals = rs
    }

    function endGame() {
        // The driver named themselves before the run, so a score that makes
        // the table files itself here with no ceremony -- the host owns
        // writing it to disk. "---" covers harness paths that start a game
        // without passing the entry screen. Never assign topScore or
        // highScores here: both are bound to the host's stored values in
        // Panel.qml, and writing to them from this side would break the
        // bindings for the rest of the session.
        if (game.scoreQualifies(game.score)) {
            var name = game.driverName || "---"
            game.lastEntryName = name
            game.lastEntryScore = game.score
            game.highScoreEntered(name, game.score)
        }
        game.setPhase("over")
    }

    // Crossing the lap line: bank the lap, extend the clock, and in qualifying
    // decide whether there is a race at all.
    function crossLine() {
        var t = game.lapClock
        if (game.bestLap === 0 || t < game.bestLap) game.bestLap = t
        // Advance by exactly one lap rather than snapping to the current
        // distance. The crossing is detected a frame late, so assigning `dist`
        // banks that overshoot and the lap line walks a few metres further from
        // the painted chequers every lap.
        game.lapStart += game.lapLength
        game.lapClock = 0

        if (game.phase === "qualify") {
            if (t <= game.qualifyTarget) {
                game.qualified = true
                game.gridPos = game.gridFor(t)
                game.lap = 1
                game.timeLeft = game.raceTime
                // Qualifying bonus rewards the slot, not just the pass: pole
                // is worth 4000, eighth 500.
                game.score += (9 - game.gridPos) * 500

                // Line up for a STANDING start, and go through "ready" so
                // there is a pause to line up in. Handing straight over to the
                // race kept the flying lap's speed, so the reward for
                // qualifying was arriving at the back of a stationary grid at
                // 290km/h and being killed before you could react.
                game.speed = 0
                game.gear = 0
                game.slideTime = 0
                game.spawnRivals()      // also puts the player in their file
                game.setPhase("ready")
            } else {
                game.endGame()
            }
            return
        }

        game.lap++
        if (game.lap > game.raceLaps) {
            // The arcade's finish bonus: 200 a second still on the clock.
            game.score += Math.round(game.timeLeft) * game.pointsPerSecond
            game.endGame()
        } else {
            game.timeLeft += game.extendTime
        }
    }

    // ------------------------------------------------------------ the frame

    // Set false to drive step() yourself at a fixed timestep. dev/laptime.qml
    // uses it to run whole laps as fast as the CPU allows, against the real
    // physics rather than a second copy of it in another language.
    property bool selfDriven: true

    FrameAnimation {
        running: game.selfDriven
        onTriggered: game.step(Math.min(frameTime, 0.05))
    }

    function step(dt) {
        game.phaseTime += dt

        if (game.phase === "attract") {
            game.dist += game.maxSpeed * 0.42 * dt      // road rolls behind the title
            // The course is lap-periodic, so wrapping is invisible -- and
            // necessary: the shader receives dist as an fp32 uniform, and an
            // attract loop left running long enough pushes it past 2^24,
            // where the tarmac grain and the painted lines start to shimmer
            // at single-float precision. Races never get there (startGame
            // zeroes dist); only the menus idle forever.
            if (game.dist > game.lapLength) game.dist -= game.lapLength
            game.playerX = Math.sin(game.phaseTime * 0.6) * 420
            game.updateSlots()
            return
        }

        // Choosing a circuit. The road is already being drawn in the selected
        // course's colours behind the menu, so the preview costs nothing --
        // it is the same renderer, just rolling.
        if (game.phase === "select") {
            game.dist += game.maxSpeed * 0.38 * dt
            if (game.dist > game.lapLength) game.dist -= game.lapLength  // see attract
            game.playerX = Math.sin(game.phaseTime * 0.5) * 300
            game.updateSlots()
            return
        }

        if (game.phase === "initials") {
            // The selected course idles behind the entry, exactly as it does
            // behind select. No timeout: nobody reaches this screen except by
            // asking to race, and submitting would START one unattended.
            game.updateSlots()
            return
        }

        if (game.phase === "over") {
            game.speed = Math.max(0, game.speed - game.dragRate * dt * 3)
            game.dist += game.speed * dt
            if (game.phaseTime > 6) game.setPhase("attract")
            game.updateSlots()
            return
        }

        if (game.phase === "ready") {
            // Latched, not sampled at the green: lifting off again once the
            // lamps have seen you does not undo it.
            if (!game.jumped && game.throttle && game.phaseTime > game.jumpGrace)
                game.jumped = true

            if (game.phaseTime > game.readyTime) {
                game.greenClock = 0                 // lights go green: GO
                game.stallTime = game.jumped ? game.jumpPenalty : 0
                game.setPhase(game.qualified ? "race" : "qualify")
            }
            game.updateSlots()
            return
        }

        if (game.phase === "crash") {
            if (game.phaseTime > 2.6) {
                game.playerX = 0
                game.speed = 0
                game.gear = 0          // rejoin in LOW; HI from a standstill is hopeless
                game.slideTime = 0
                game.stallTime = 0                  // a crash is punishment enough
                game.greenClock = game.greenHold    // rejoining is not a start
                game.clearRoadAhead()
                game.setPhase(game.qualified ? "race" : "qualify")
            }
            game.updateSlots()
            return
        }

        // ---- driving

        if (game.greenClock < game.greenHold) game.greenClock += dt

        // The jump-start penalty: the engine is dead for jumpPenalty seconds
        // while the field leaves. Held rather than time-docked because the
        // clock is already the currency here -- standing still costs you the
        // seconds AND the places, and you can see both happening.
        var stalled = game.stallTime > 0
        if (stalled) game.stallTime = Math.max(0, game.stallTime - dt)

        var onRoad = Math.abs(game.playerX) < Track.ROAD_HALF

        if (game.braking)                   game.speed -= game.brakeRate * dt
        else if (game.throttle && !stalled) game.speed += game.accelAt(game.speed) * dt
        else                                game.speed -= game.dragRate * dt

        // Left in LOW past its ceiling the engine simply holds you there, so
        // forgetting to shift costs speed rather than being silently ignored.
        if (game.gear === 0 && game.speed > game.lowMax)
            game.speed -= game.revLimit * dt

        if (!onRoad && game.speed > game.offRoadMax)
            game.speed -= game.offRoadDrag * dt

        game.speed = Math.max(0, Math.min(game.speed, game.highMax))

        var frac = game.speed / game.highMax
        game.dist += game.speed * dt
        game.lapClock += dt

        // ---- grip
        //
        // How much of the wheel the corner is eating. Above 1.0 the push has
        // more authority than the driver does, and the car lets go.
        //
        // This is what makes corners matter. Without it an autopilot that
        // never lifted lapped in 57.6s against 57.2s for one that drove
        // properly -- the corners were decoration, because full opposite lock
        // held the car through anything and running wide cost almost nothing.
        // The arcade's own answer is the same: take a curve too quickly and
        // you briefly lose control.
        var curve = Track.curvatureAt(game.dist)
        var load = Math.abs(curve) * game.speed * game.speed
                   * game.centrifugal / game.steerRate

        if (load > 1.0 && game.slideTime <= 0) {
            game.slideTime = game.slideLength
            game.slideDirection = curve > 0 ? -1 : 1
        }

        // Points for ground covered, banked a step at a time so the score
        // ticks up rather than jumping at the line.
        game.distScored += game.speed * dt
        while (game.distScored >= game.distanceStep) {
            game.distScored -= game.distanceStep
            game.score += game.pointsPerStep
        }

        if (game.slideTime > 0) {
            // Passenger for a moment: no steering, the push runs unopposed and
            // then some, and the car scrubs speed the whole way.
            game.slideTime -= dt
            game.playerX -= curve * game.speed * game.speed
                            * game.centrifugal * dt * 1.35
            game.speed = Math.max(0, game.speed - game.slideDrag * dt)
        } else {
            // Steering authority scales with speed -- stationary, the wheel
            // does nothing, which is also what stops a crashed car sliding
            // sideways.
            game.playerX += game.steerInput * game.steerRate * frac * dt
            game.playerX -= curve * game.speed * game.speed
                            * game.centrifugal * dt
        }

        // The verge is a wall, not a cliff: you can run wide, but not forever.
        var limit = Track.ROAD_HALF * 3.2
        if (game.playerX < -limit) game.playerX = -limit
        if (game.playerX >  limit) game.playerX =  limit

        // ---- puddles
        //
        // Standing water on the racing line: hit one at speed and it is the
        // same loss of grip as overcooking a corner -- the existing slide,
        // through exactly the hook the backlog note predicted. Below the
        // speed floor (~100km/h) the car just wets its tyres: a slide that
        // can catch a crawling car punishes the wrong thing.
        //
        // puddleCarZ: the car sprite sits that far AHEAD of the camera (the
        // z of its own screen row), so the trigger tests where the car is
        // DRAWN, not where the camera is -- the slide starts on the frame
        // the wheels visibly touch the water the shader painted from the
        // same list.
        if (game.slideTime <= 0 && game.speed > game.highMax * 0.35) {
            var pls = Track.puddleList()
            var carLap = (game.dist + game.puddleCarZ) % game.lapLength
            for (var pi = 0; pi < pls.length; pi++) {
                var pdz = carLap - pls[pi].z
                pdz -= game.lapLength * Math.round(pdz / game.lapLength)
                if (Math.abs(pdz) < pls[pi].len
                        && Math.abs(game.playerX - pls[pi].x) < pls[pi].w) {
                    game.slideTime = game.slideLength
                    game.slideDirection = game.playerX >= pls[pi].x ? 1 : -1
                    break
                }
            }
        }

        // The crossing is tested BEFORE the clock, and both before the
        // rivals. A car that physically reaches the line in the tick the
        // clock empties has earned its extension -- dist was already advanced
        // this frame, so the old order discarded a crossing the screen showed.
        // And crossLine() can leave the driving phases entirely (game over at
        // the flag, or qualifying handing over to the grid): one more frame
        // of rivals-and-collisions inside "over" could crash a finished race
        // back to life and file its score twice.
        if (game.dist - game.lapStart >= game.lapLength) {
            game.crossLine()
            if (game.phase !== "race" && game.phase !== "qualify") return
        }

        game.timeLeft -= dt
        if (game.timeLeft <= 0) {
            game.timeLeft = 0
            game.endGame()
            return
        }

        game.updateRivals(dt)
        game.checkCollisions()
        game.updateSlots()
    }

    function updateRivals(dt) {
        if (!game.rivals.length) return
        var rs = game.rivals
        for (var i = 0; i < rs.length; i++) {
            var r = rs[i]
            r.z += r.speed * dt

            // A car coming up behind moves aside rather than driving through.
            //
            // The collision test only looks ahead, so an overtaking rival has
            // to cross the window between "behind" and "ahead" -- and in the
            // player's lane that kills them from a direction the game gives
            // them no way to see. It dodges toward the roomier side of the
            // road, which is by definition the side the player is not on.
            var gap = r.z - game.dist
            if (gap < 0 && gap > -Track.metres(70) && r.speed > game.speed
                    && Math.abs(r.x - game.playerX) < game.carWidth * 1.15) {
                var away = game.playerX >= 0 ? -1 : 1
                r.x += away * game.rivalDodge * dt
                // Clamp the car's BODYWORK to the tarmac, not its centre.
                // This was ROAD_HALF * 0.94, which is a limit on the centre
                // and let 2.02m of car hang over the kerb -- the "opponents
                // drive off the road" report. It only showed when the player
                // was slow enough to be overtaken (a crash, LOW gear, or
                // sitting out a jump-start penalty), which is why no harness
                // had caught it: at racing speed you outrun the field and the
                // dodge never fires.
                var edge = game.rivalXLimit
                if (r.x >  edge) r.x =  edge
                if (r.x < -edge) r.x = -edge
            }

            // Score the overtake once, as the nose goes by.
            if (!r.passed && game.dist > r.z) {
                r.passed = true
                game.score += game.pointsPerCar
            }

            // ---- dropping out of the race
            //
            // Every car used to be recycled 60m after the player passed it,
            // teleported 250-600m up the road and un-passed. That is the
            // arcade's endless-traffic model, and it makes beating the field
            // impossible by construction: pass all seven and all seven come
            // back, one every few seconds, for ever.
            //
            // A car the player has left this far behind stops being a rival
            // and becomes traffic. 300m rather than 60m for two reasons: it is
            // past the draw distance, so a car is genuinely out of sight
            // before it changes into something else; and anything nearer is
            // still close enough to take the place back if the player crashes,
            // which is the racecraft the old threshold threw away.
            if (!r.backmarker && game.dist - r.z > Track.metres(300))
                r.backmarker = true

            // ---- backmarkers
            //
            // Recycled for ever, which is what keeps the road busy once the
            // field is beaten -- but they no longer count toward position, so
            // passing one cannot make the leader sixth again. Slower than the
            // race pace on purpose: a backmarker the player cannot catch is
            // just a car in the distance.
            if (r.backmarker && r.z < game.dist - Track.metres(60)) {
                r.z = game.dist + Track.metres(250 + Math.random() * 350)
                // Spread across the road the car can legally occupy, so fresh
                // traffic never arrives already half on the grass.
                r.x = (Math.random() * 2 - 1) * game.rivalXLimit * 0.92
                r.speed = game.maxSpeed * (0.42 + Math.random() * 0.22)
                r.passed = false
            }
        }

        // Position: one more than the number of cars still racing and still
        // ahead. Computed here rather than bound to `rivals`, because
        // updateRivals mutates that array in place and never reassigns it --
        // a QML binding on it would fire once and then never again.
        var ahead = 0
        for (i = 0; i < rs.length; i++)
            if (!rs[i].backmarker && rs[i].z > game.dist) ahead++
        game.racePos = ahead + 1
    }

    function checkCollisions() {
        var rs = game.rivals
        for (var i = 0; i < rs.length; i++) {
            var dz = rs[i].z - game.dist
            if (dz > 0 && dz < game.carLength
                    && Math.abs(rs[i].x - game.playerX) < game.carWidth) {
                game.crash()
                return
            }
        }

        // Off the road, the furniture is solid. On it, nothing is.
        if (Math.abs(game.playerX) < Track.ROAD_HALF * 1.15) return
        var lapPos = game.dist % game.lapLength
        for (var s = 0; s < game.scenery.length; s++) {
            var item = game.scenery[s]
            // Wrap exactly as updateSlots() does. Without this, furniture in
            // the first few metres of the next lap is drawn but cannot be hit
            // -- a narrow window, but the renderer and the collider disagreeing
            // is the class of bug that is impossible to diagnose from play.
            var d = item.z - lapPos
            if (d < 0) d += game.lapLength
            if (d > 0 && d < game.carLength * 0.7
                    && Math.abs(item.x - game.playerX) < 320) {
                game.crash()
                return
            }
        }
    }

    // ------------------------------------------------------- sprite placing

    // Project one world object into the frame. `runs` comes from Road, which
    // is the same array the shader was handed, so a car placed here sits on
    // the tarmac the GPU drew rather than near it.
    function place(runs, z, worldX, sprite, w, h) {
        if (z < 200 || z > game.spriteDist) return null
        var scale = Track.scaleAt(z)
        var sy = Track.screenY(z, game.horizonY, game.height)
        var sx = game.width * 0.5
               + scale * (Track.centerAt(runs, z) + worldX - game.playerX)
                 * game.width * 0.5
        var sw = Math.max(1, Math.round(scale * w * game.worldPerPx * game.width * 0.5))
        var sh = Math.max(1, Math.round(sw * h / w))
        if (sx + sw < -40 || sx - sw > game.width + 40) return null
        return {
            src: sprite,
            x: Math.round(sx - sw * 0.5),
            y: Math.round(sy - sh),
            w: sw,
            h: sh,
            z: z,
            // How much air is between this and the camera. The delegate fades
            // the sprite by it and shrinks its shadow with it.
            dim: Track.fogAt(z),
            // Width of the shadow as a fraction of the sprite's own. A car
            // puts nearly all of itself on the ground; a sign is a pole.
            shadow: game.shadowSpan(sprite)
        }
    }

    function updateSlots() {
        var runs = road.runs
        if (!runs || !runs.length) return

        var out = []
        var lapPos = game.dist % game.lapLength
        var i, p

        // Roadside furniture, this lap and the start of the next so the
        // horizon does not empty out as the lap line approaches.
        for (i = 0; i < game.scenery.length; i++) {
            var it = game.scenery[i]
            var dz = it.z - lapPos
            if (dz < 0) dz += game.lapLength
            if (dz > game.spriteDist) continue
            p = place(runs, dz, it.x, it.sprite, spriteW(it.sprite), spriteH(it.sprite))
            if (p) out.push(p)
        }

        for (i = 0; i < game.rivals.length; i++) {
            var r = game.rivals[i]
            p = place(runs, r.z - game.dist, r.x, r.sprite,
                      game.rivalDrawW, game.rivalDrawH)
            if (p) out.push(p)
        }

        // Cull first, then order for painting -- and in that order.
        //
        // Sorting far-to-near and truncating the tail throws away the NEAREST
        // sprites, which are the large ones filling the screen, while keeping
        // sub-pixel specks on the horizon. So: nearest first, drop everything
        // past the pool size, then reverse so the painter's algorithm still
        // draws far before near.
        out.sort(function (a, b) { return a.z - b.z })
        if (out.length > game.slotCount) out.length = game.slotCount
        out.reverse()
        game.slots = out
    }

    readonly property var spriteSizes: ({
        "tree_big":     [30, 30], "tree_small":   [18, 20],
        "sign_left":    [28, 32], "sign_right":   [28, 32],
        "sign_100":     [26, 26], "sign_50":      [26, 26],
        "sign_checker": [26, 28], "cone_a":       [10, 26],
        "cone_b":       [10, 26], "marshal":      [40, 48],

        // The sponsor arch. 208 art pixels is 2704 world units, so it spans
        // the 2000-unit road and stands its legs out in the verge; 120 is
        // 1560 units, which is just over the camera's own eye height and is
        // what makes it pass overhead rather than read as a hoarding. Both
        // numbers are derived in art/make_art.py -- change them there.
        "gantry":       [208, 120], "gantry_finish": [208, 120]
    })
    function spriteW(n) { var s = spriteSizes[n]; return s ? s[0] : 32 }
    function spriteH(n) { var s = spriteSizes[n]; return s ? s[1] : 32 }

    // ---- what each thing puts on the ground
    //
    // Nothing in the frame cast a shadow, and everything in it therefore
    // floated: cars hovered a pixel over tarmac they were supposed to be
    // standing on, and trees sat in front of the grass rather than in it. A
    // shadow is the cheapest depth cue there is and the only one that says
    // *which* ground a sprite is on.
    //
    // The span is the width of the blob against the sprite's own width, so it
    // scales with perspective for free. A car is nearly all contact patch; a
    // sign and a cone are a pole and a base; a tree is a canopy over a trunk,
    // so it lands between the two.
    readonly property var shadowSpans: ({
        "sign_left": 0.34, "sign_right": 0.34, "sign_100": 0.34,
        "sign_50":   0.34, "sign_checker": 0.34,
        "cone_a":    0.55, "cone_b": 0.55,
        "tree_big":  0.62, "tree_small": 0.62,
        "marshal":   0.40,

        // None. A gantry's shadow is two thin bars and a band across the
        // road, and the blob this pool draws -- an ellipse a fifth of the
        // sprite's own height -- would be a black bar the width of the
        // circuit. Zero means "draw nothing"; the legs meet the ground on
        // their own base plates instead.
        "gantry":    0, "gantry_finish": 0
    })
    function shadowSpan(n) {
        var s = game.shadowSpans[n]
        return s === undefined ? 0.86 : s          // cars, and anything new
    }

    // Black at this much, over whatever the road happens to be. Kept low
    // enough to read as a shadow rather than a hole -- at 320x240 a shadow
    // that reads as a separate object is worse than none.
    readonly property real shadowAlpha: 0.38

    // ---- the rattle off the tarmac
    //
    // Going off used to be a number quietly leaving the speedometer. One pixel
    // of judder makes the grass FEEL like grass, which is the only reason the
    // arcade's verges ever scared anyone.
    //
    // Phased on distance travelled rather than a clock, so it beats faster the
    // faster you are going and stops dead when you do -- and so it is a pure
    // function of game state, which is what lets dev/shot.qml pose a frame and
    // get the same picture every time.
    readonly property real rumbleShake: {
        if (game.phase === "crash") return 0
        if (game.speed < 1500) return 0
        if (Math.abs(game.playerX) < Track.ROAD_HALF) return 0
        return Math.floor(game.dist / 260) % 2 === 0 ? 1 : 0
    }

    // -------------------------------------------------------------- drawing

    Road {
        id: road
        anchors.fill: parent
        dist: game.dist
        playerX: game.playerX
        course: game.course
        lapLength: game.lapLength
    }

    // Fixed pool of sprite items. Index is depth order: slot 0 is furthest.
    //
    // Each slot is a shadow and a sprite together rather than two pools, and
    // that is deliberate: a single shadow pool drawn under everything would
    // let a far car paint over a near car's shadow. Pairing them keeps each
    // shadow immediately beneath its own sprite in the painter's order.
    Repeater {
        model: game.slotCount

        Item {
            required property int index
            readonly property var slot: index < game.slots.length ? game.slots[index] : null

            visible: !!slot

            // Shadow. An ellipse centred on the contact line, so its top half
            // is hidden behind the sprite and only the ground-side crescent
            // shows -- which is what you actually see under a car.
            Rectangle {
                readonly property var s: parent.slot
                visible: !!s && s.shadow > 0
                color: "black"
                opacity: s ? game.shadowAlpha * (1 - s.dim) : 0
                width:  s ? Math.max(1, Math.round(s.w * s.shadow)) : 1
                height: s ? Math.max(1, Math.round(s.h * 0.22)) : 1
                x: s ? Math.round(s.x + (s.w - width) / 2) : 0
                // Sunk by a third rather than a half, so a little more of the
                // blob clears the bodywork. Centred exactly on the contact
                // line, a car this size shows two pixels of shadow and reads
                // as having none.
                y: s ? Math.round(s.y + s.h - height * 0.34) : 0
                radius: height / 2
                antialiasing: false        // stays on the pixel grid
            }

            Image {
                readonly property var s: parent.slot
                x: s ? s.x : 0
                y: s ? s.y : 0
                width: s ? s.w : 1
                height: s ? s.h : 1
                source: s ? Qt.resolvedUrl("../art/sprites/" + s.src + ".png") : ""
                smooth: false
                mipmap: false
                fillMode: Image.Stretch

                // Aerial perspective, done by fading rather than tinting.
                //
                // What is behind a distant sprite is the road at the same
                // depth, which the shader has already hazed by the same
                // amount -- so letting that show through IS the fog colour,
                // to within a few percent, and costs neither a shader nor a
                // texture per sprite. Capped well short of invisible: a car
                // you cannot see is a crash you could not avoid.
                opacity: s ? 1 - s.dim * 0.6 : 1
            }
        }
    }

    // The player's own shadow. Not part of the pool -- the car is not in it,
    // because it never scales -- so it is placed by hand under the car and
    // follows every nudge, lean and rattle the car has.
    Rectangle {
        visible: playerCar.visible && game.phase !== "crash"
        color: "black"
        opacity: game.shadowAlpha
        width: 60
        height: 8
        radius: height / 2
        antialiasing: false
        x: Math.round(playerCar.x + (playerCar.width - width) / 2)
        y: Math.round(playerCar.y + playerCar.height - height / 2 - 1)
    }

    // The player's car. It does not scale -- it is always the same distance
    // from the camera -- so it is the one sprite drawn at its native size.
    Image {
        id: playerCar
        visible: game.phase !== "attract"
        width: 72
        height: 40
        smooth: false
        mipmap: false
        source: {
            if (game.steerInput < 0) return Qt.resolvedUrl("../art/sprites/car_left.png")
            if (game.steerInput > 0) return Qt.resolvedUrl("../art/sprites/car_right.png")
            return Qt.resolvedUrl("../art/sprites/car_straight.png")
        }

        // Lean into the steering by a couple of pixels. The three extracted
        // poses are nearly identical, so without this nudge the car reads as
        // static however hard it is being thrown about.
        x: Math.round((game.width - width) / 2 + game.steerInput * 3)
        y: Math.round(game.height - height - 8 + game.rumbleShake
                      + (game.phase === "crash" ? Math.sin(game.phaseTime * 26) * 3 : 0))

        // A crash spins the car; a slide just kicks the tail out, so losing
        // grip reads on the car itself rather than only in the handling.
        rotation: {
            if (game.phase === "crash") return game.phaseTime * 520
            if (game.slideTime > 0)
                return (game.slideDirection > 0 ? 9 : -9)
                       * Math.min(1, game.slideTime / (game.slideLength * 0.5))
            return 0
        }
        transformOrigin: Item.Center
    }

    Hud {
        id: hud
        anchors.fill: parent
        game: game
    }
}
