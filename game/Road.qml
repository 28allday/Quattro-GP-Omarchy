import QtQuick
import "Track.js" as Track

// The road surface, plus the sky and mountains behind it.
//
// This item is the 320x240 game frame's ground layer. Everything in it is
// positioned in game pixels; the caller scales the whole thing up.
//
// It also owns `runs` -- the visible road expressed as quadratic pieces. The
// shader gets them as uniforms and SpriteLayer reads the same array to place
// cars and scenery, so there is exactly one description of where the road is
// per frame and no way for the two to disagree.
Item {
    id: root

    // Set by the engine each frame.
    property real dist: 0           // distance travelled, world units
    property real playerX: 0        // driver's offset from the centreline

    // Screen row the road converges to. Everything above is sky.
    property real horizonY: Math.round(height * 0.42)

    // Recomputed once per frame, when dist changes. Read by SpriteLayer.
    readonly property var runs: Track.runs(dist)
    readonly property var packed: Track.packRuns(runs)

    function seg(i) {
        var p = packed[i]
        return Qt.vector4d(p[0], p[1], p[2], p[3])
    }

    // Colours sampled off the mood board (art/palette.json).
    // The course being driven, from Track.COURSES. Everything below reads its
    // palette and its backdrop, which is why adding three more circuits needed
    // no renderer changes: the colours were already uniforms.
    //
    // The fallbacks are Fuji's, so this still renders if it is instantiated
    // bare -- dev/shot.qml and dev/play.qml both do that.
    property var course: null
    readonly property var pal: course ? course.palette : null

    // Lap length is passed in rather than read from Track, because Track is a
    // plain JS library: reassigning LAP_LENGTH there cannot notify a QML
    // binding. Game.qml sets this when the course changes.
    property real lapLength: Track.LAP_LENGTH

    readonly property url backdropUrl: Qt.resolvedUrl(
        "../art/" + (course ? course.backdrop : "backdrop") + ".png")

    // Optional per-course extras. `skyStops` turns the sky into a gradient;
    // `sun` hangs a single sprite behind the horizon strip.
    readonly property var skyStops: course && course.skyStops ? course.skyStops : null

    function skyStop(i) {
        var ss = root.skyStops
        if (!ss || !ss.length) return { at: 0, colour: root.cSky }
        return ss[Math.min(i, ss.length - 1)]
    }
    readonly property url sunUrl: (course && course.sun)
        ? Qt.resolvedUrl("../art/" + course.sun + ".png") : ""

    property color cSky:     pal ? pal.sky     : "#2a84e4"
    property color cFog:     pal ? pal.fog     : "#7fb8e8"
    property color cRoad:    pal ? pal.road    : "#3a3b3b"
    property color cRoadAlt: pal ? pal.roadAlt : "#363737"
    property color cGrassA:  pal ? pal.grassA  : "#349515"
    property color cGrassB:  pal ? pal.grassB  : "#4aa316"
    property color cRumbleA: pal ? pal.rumbleA : "#bf220d"
    property color cRumbleB: pal ? pal.rumbleB : "#d7d5d2"
    property color cLane:    pal ? pal.lane    : "#eeeeeb"

    // The coast, on the courses that have one. `shore` is -1 for water on the
    // left, +1 for the right, absent for the three circuits that are inland --
    // and the fallbacks below are only ever used to keep the shader's uniforms
    // supplied, since shoreSide 0 stops it looking at any of them.
    readonly property real shoreSide: (course && course.shore) ? course.shore : 0
    readonly property real waveAmt:   (course && course.waveAmt !== undefined)
                                      ? course.waveAmt : 0.18
    property color cShoreA:  pal && pal.shoreA ? pal.shoreA : root.cGrassA
    property color cShoreB:  pal && pal.shoreB ? pal.shoreB : root.cGrassB
    property color cSand:    pal && pal.sand   ? pal.sand   : root.cGrassA

    // ----------------------------------------------------------------- sky

    // Sky. A flat colour for three of the four courses; Sunset supplies
    // `skyStops` and gets a vertical gradient instead, because the whole look
    // of that circuit is the graded sky behind the sun and a single uniform
    // cannot be one.
    Rectangle {
        anchors.fill: parent
        color: root.cSky
        gradient: root.skyStops ? skyGradient : null

        // Four explicit stops rather than a Repeater: Gradient.stops is a
        // list of GradientStop objects and will not take an Instantiator's
        // output. skyStop() clamps, so a course declaring fewer than four
        // simply repeats its last one instead of breaking.
        Gradient {
            id: skyGradient
            GradientStop { position: root.skyStop(0).at; color: root.skyStop(0).colour }
            GradientStop { position: root.skyStop(1).at; color: root.skyStop(1).colour }
            GradientStop { position: root.skyStop(2).at; color: root.skyStop(2).colour }
            GradientStop { position: root.skyStop(3).at; color: root.skyStop(3).colour }
        }
    }

    // Mountains, parked with their base on the horizon. The strip is drawn
    // twice side by side and slid by the accumulated curve so the distance
    // swings the opposite way through a corner -- the cheapest parallax there
    // is, and the only one Pole Position ever had.
    Item {
        width: parent.width
        // Tall enough for whichever is deeper, the horizon strip or the sun,
        // both of which sit with their base on the horizon.
        height: Math.max(backdrop.height,
                         sun.visible ? sun.height + backdrop.height * 0.28 : 0)
        y: root.horizonY - height + 1
        clip: true

        readonly property real shift: {
            var rs = root.runs
            if (!rs || !rs.length) return 0
            // Offset by where the road is heading a long way out, so the
            // panorama leans into the corner ahead.
            return -Track.centerAt(rs, 26000) * 0.0016 - root.playerX * 0.0018
        }

        // ONE sun, never tiled -- which is the whole reason it is not part of
        // the strip. It parallaxes at less than the ridges do, because it is
        // further away, and it is drawn BEFORE the Row so the ridges occlude
        // its base and it reads as setting behind them rather than in front.
        Image {
            id: sun
            visible: root.sunUrl != ""
            source: root.sunUrl
            smooth: false
            mipmap: false
            // Sunk into the ridge line rather than floating over it: the
            // bottom margin is less than the height of the ridges in the
            // strip, so the crest cuts across the disc.
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Math.round(backdrop.height * 0.28)
            x: Math.round((parent.width - width) / 2 + parent.shift * 0.35)
        }

        Row {
            id: backdropRow
            anchors.bottom: parent.bottom
            x: {
                var w = backdrop.width
                var s = parent.shift % w
                return s > 0 ? s - w : s
            }
            Image {
                id: backdrop
                source: root.backdropUrl
                smooth: false
                mipmap: false
            }
            Image { source: root.backdropUrl; smooth: false; mipmap: false }
            Image { source: root.backdropUrl; smooth: false; mipmap: false }
        }
    }

    // Haze, drawn over the bottom of the panorama and under the road.
    //
    // The tarmac fades into cFog as it recedes; the mountains behind it did
    // not, so the two met at a hard seam with distance on one side of the line
    // and none on the other. This is the same fog leaking a few rows up into
    // the base of the backdrop, which is what stands the ridges in air rather
    // than pasting them on. Sixteen rows at 240 is a real gradient here.
    Rectangle {
        width: parent.width
        height: 16
        y: root.horizonY - height
        gradient: Gradient {
            GradientStop {
                position: 0.0
                color: Qt.rgba(root.cFog.r, root.cFog.g, root.cFog.b, 0.0)
            }
            GradientStop {
                position: 1.0
                color: Qt.rgba(root.cFog.r, root.cFog.g, root.cFog.b, 0.9)
            }
        }
    }

    // ---------------------------------------------------------------- road

    ShaderEffect {
        anchors.fill: parent
        fragmentShader: Qt.resolvedUrl("../shaders/road.frag.qsb")
        blending: true

        property real resX: root.width
        property real resY: root.height
        property real horizonY: root.horizonY
        property real camDepth: Track.CAM_DEPTH
        property real camHeight: Track.CAM_HEIGHT
        property real camX: root.playerX
        property real roadHalf: Track.ROAD_HALF
        property real zCam: root.dist
        property real maxZ: Track.DRAW_DIST
        property real stripeLen: Track.STRIPE_LEN
        property real shoreSide: root.shoreSide
        property real waveAmt: root.waveAmt
        property real pad0: 0
        property real pad1: 0

        property vector4d seg0: root.seg(0)
        property vector4d seg1: root.seg(1)
        property vector4d seg2: root.seg(2)
        property vector4d seg3: root.seg(3)
        property vector4d seg4: root.seg(4)
        property vector4d seg5: root.seg(5)
        property vector4d seg6: root.seg(6)
        property vector4d seg7: root.seg(7)

        property color cRoad: root.cRoad
        property color cRoadAlt: root.cRoadAlt
        property color cGrassA: root.cGrassA
        property color cGrassB: root.cGrassB
        property color cRumbleA: root.cRumbleA
        property color cRumbleB: root.cRumbleB
        property color cLane: root.cLane
        property color cFog: root.cFog
        property color cShoreA: root.cShoreA
        property color cShoreB: root.cShoreB
        property color cSand: root.cSand

        // The course's puddles, straight off Track.puddleList(). The binding
        // leans on lapLength so a course change re-reads the list -- the list
        // itself is recomputed by Track.selectCourse().
        function pud(i) {
            var l = root.lapLength   // re-evaluate on course change
            var p = Track.puddleList()
            return i < p.length ? Qt.vector4d(p[i].z, p[i].x, p[i].len, p[i].w)
                                : Qt.vector4d(0, 0, 0, 0)
        }
        property vector4d pud0: pud(0)
        property vector4d pud1: pud(1)
        property vector4d pud2: pud(2)

        // (lap length, start/finish band width, beach outer edge, wet fraction)
        property vector4d lapSpec: Qt.vector4d(root.lapLength,
                                               Track.metres(4),
                                               Track.SHORE_SAND_END, 0.20)
    }
}
