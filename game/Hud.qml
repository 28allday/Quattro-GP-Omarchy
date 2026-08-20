import QtQuick
import "Track.js" as Track

// The overlay: score box, speed bar and the centre messages.
//
// Laid out in game pixels against the 320x240 frame, in the same 5x7 bitmap
// font as everything else, so it sits on the pixel grid the road and sprites
// are already on.
Item {
    id: hud

    property var game: null

    readonly property color labelWhite:  "#eeeeeb"
    readonly property color labelRed:    "#e2382a"
    readonly property color labelYellow: "#f2c31c"
    readonly property color labelGreen:  "#5ad13a"
    readonly property color boxBorder:   "#2a6ee5"
    readonly property color boxFill:     "#05070b"

    function pad(n, width) {
        var s = String(Math.max(0, Math.floor(n)))
        while (s.length < width) s = " " + s
        return s
    }

    // A label/value pair, value flush to the right edge of the box.
    // Named StatRow, not Row: an inline component shadows the type of the same
    // name for the whole file, and calling this one Row would quietly replace
    // QtQuick's positioner everywhere below.
    component StatRow: Item {
        id: row
        property string label: ""
        property string value: ""
        property color labelColor: hud.labelWhite
        property color valueColor: hud.labelWhite
        height: 8

        BitmapText {
            x: 0
            text: row.label
            color: row.labelColor
        }
        BitmapText {
            id: val
            x: row.width - implicitWidth
            text: row.value
            color: row.valueColor
        }
    }

    // ------------------------------------------------------------- score box

    readonly property bool playing:
        hud.game && hud.game.phase !== "attract" && hud.game.phase !== "select"

    // Width is the widest row plus a readable gap, not a round number.
    //
    // The rows are label + value in a 6px-cell font, so the longest is SPEED:
    // five characters and "221KM/H"'s seven, twelve cells, 72px. 78px of inner
    // width leaves six between the two halves, which is the narrowest the pair
    // can be without reading as one word. 116 wide with 5px padding was a
    // third of the frame for the sake of a gap nothing needed.
    readonly property int boxPad: 4
    readonly property int boxInner: 78

    Rectangle {
        id: box
        visible: hud.playing
        x: 5
        y: 5
        width: hud.boxInner + hud.boxPad * 2
        height: column.height + hud.boxPad * 2
        color: hud.boxFill
        border.color: hud.boxBorder
        border.width: 1
        opacity: 0.94

        Column {
            id: column
            x: hud.boxPad
            y: hud.boxPad
            width: parent.width - hud.boxPad * 2
            // One pixel between rows, not two. At a 7px glyph the rows are
            // already separated by the font's own descender space.
            spacing: 1

            StatRow {
                width: parent.width
                label: "TOP"
                labelColor: hud.labelRed
                value: hud.pad(hud.game ? hud.game.topScore : 0, 6)
            }
            StatRow {
                width: parent.width
                label: "SCORE"
                value: hud.pad(hud.game ? hud.game.score : 0, 6)
            }
            StatRow {
                width: parent.width
                label: "SPEED"
                value: (hud.game ? hud.pad(hud.game.kmh, 3) : "  0") + "KM/H"
            }
            // The shifter's position, and the only HUD line that is a control
            // rather than a readout -- HI is highlighted so a glance tells you
            // whether you have forgotten to change up.
            StatRow {
                width: parent.width
                label: "GEAR"
                valueColor: (hud.game && hud.game.gear === 1)
                            ? hud.labelGreen : hud.labelYellow
                value: (hud.game && hud.game.gear === 1) ? "HI" : "LOW"
            }
            StatRow {
                width: parent.width
                visible: hud.game && hud.game.phase !== "qualify"
                         && hud.game.gridPos > 0
                label: "POS"
                // racePos, not gridPos: the live position, not the grid slot.
                value: (hud.game ? hud.game.racePos : 0) + "/8"
            }
            StatRow {
                width: parent.width
                label: "TIME"
                labelColor: hud.labelYellow
                // The clock going red under ten is the only warning you get.
                valueColor: (hud.game && hud.game.timeLeft < 10)
                            ? hud.labelRed : hud.labelYellow
                value: hud.pad(hud.game ? Math.ceil(hud.game.timeLeft) : 0, 3)
            }
            StatRow {
                width: parent.width
                label: hud.game && hud.game.phase === "qualify" ? "QUAL" : "LAP"
                value: {
                    if (!hud.game) return ""
                    if (hud.game.phase === "qualify") return hud.game.lapClock.toFixed(1)
                    // Clamped: crossing the last line increments lap before
                    // ending the game, which otherwise reads "5/4".
                    return Math.min(hud.game.lap, hud.game.raceLaps)
                           + "/" + hud.game.raceLaps
                }
            }
        }
    }

    // -------------------------------------------------------------- speedbar

    // Sixteen segments running red through green, lit up to the current speed.
    // The mood board's bar runs hot-to-cold left to right, so a full bar is
    // green at the far end rather than red.
    Item {
        id: bar
        visible: hud.playing
        x: box.x
        y: box.y + box.height + 3
        width: box.width
        height: 4

        readonly property real frac:
            hud.game ? hud.game.speed / hud.game.maxSpeed : 0

        // Sixteen is the mood board's count and is kept; the segments shrink
        // with the box rather than the bar running past its edge.
        readonly property int seg: Math.floor(box.width / 16)

        Repeater {
            model: 16

            Rectangle {
                required property int index
                x: index * bar.seg
                width: bar.seg - 1
                height: 4
                color: Qt.rgba(1.0 - (index / 15) * 0.85,
                               0.15 + (index / 15) * 0.75, 0.08, 1)
                opacity: (index / 16) < bar.frac ? 1.0 : 0.16
            }
        }
    }

    // --------------------------------------------------------- start signal

    // The lights, hanging over the road for the whole "ready" phase and held
    // green for a beat after the car is released. Both starts run through
    // that phase, so this is the signal for qualifying and for the race.
    //
    // Drawn in the overlay rather than out in the world: a signal standing on
    // the verge at the start line would be four pixels across by the time it
    // was near enough to read, and you would be looking at the road anyway.
    Item {
        id: startSignal

        // -1 nothing, 0..3 that many red lamps, 4 green. See Game.startLights.
        readonly property int lit: hud.game ? hud.game.startLights : -1

        visible: lit >= 0
        // Three 14px lamps and two 6px gaps, plus 6px of housing either side.
        // Wider than this and the housing closes on the score box, which ends
        // at x=122, and the one-pixel gap reads as an accident.
        width: 66
        height: 22
        x: Math.round((hud.width - width) / 2)
        y: 46                          // sky, above both the horizon and the banner

        // The mast it hangs from, running off the top of the frame.
        Rectangle {
            x: Math.round((startSignal.width - 3) / 2)
            y: -startSignal.y
            width: 3
            height: startSignal.y + 2
            color: "#2c3038"
        }

        Rectangle {
            anchors.fill: parent
            color: "#0b0d12"
            border.color: "#3a3f4a"
            border.width: 1
        }

        Row {
            anchors.centerIn: parent
            spacing: 6

            Repeater {
                model: 3

                Rectangle {
                    required property int index
                    width: 14
                    height: 14
                    radius: 7
                    // Off, or the pixel grid the rest of the frame sits on
                    // gets a soft edge here and nowhere else.
                    antialiasing: false
                    color: startSignal.lit === 4
                           ? hud.labelGreen
                           : (index < startSignal.lit ? hud.labelRed : "#2a1210")
                }
            }
        }
    }

    // ------------------------------------------------------------- messages

    // Centre-screen text. One item, retitled per phase, so only one thing can
    // ever be shouting at you.
    // Called at the moment of the offence and again while the engine is held,
    // so the reason and the consequence are the same words in the same place.
    readonly property bool jumpShown:
        hud.game !== null
        && ((hud.game.phase === "ready" && hud.game.jumped)
            || hud.game.stallTime > 0)

    BitmapText {
        id: banner
        px: 2
        // Green only while the lights are, so GO! reads as the signal rather
        // than as one more white message. Red beats it: a jumped start is not
        // a start.
        color: hud.jumpShown
               ? hud.labelRed
               : ((hud.game && hud.game.startLights === 4)
                  ? hud.labelGreen : hud.labelWhite)
        x: Math.round((hud.width - implicitWidth) / 2)
        // Below the score box, which is seven rows tall and reaches y=84.
        y: 92
        visible: text.length > 0
        text: {
            if (!hud.game) return ""
            switch (hud.game.phase) {
            case "attract": return ""
            case "ready":
                if (hud.game.jumped) return "JUMP START"
                return hud.game.qualified ? "GET READY" : "QUALIFY"
            case "crash":   return "CRASH"
            case "qualify":
            case "race":
                if (hud.game.stallTime > 0) return "JUMP START"
                if (hud.game.startLights === 4) return "GO!"
                return hud.game.slideTime > 0 ? "SLIDE" : ""
            case "over":    return "GAME OVER"
            default:        return ""
            }
        }
    }

    BitmapText {
        px: 1
        color: hud.labelYellow
        x: Math.round((hud.width - implicitWidth) / 2)
        y: 112
        visible: text.length > 0
        text: {
            if (!hud.game) return ""
            // The menu screens own the middle of the display. Without this the
            // stallTime test below fires in any phase, so a penalty left over
            // from the last race printed itself across the course select --
            // caught by dev/shot.qml's 12-select frame.
            if (hud.game.phase === "attract" || hud.game.phase === "select"
                    || hud.game.phase === "initials")
                return ""
            // The sentence, once the offence is committed. Says what is about
            // to happen rather than what you did, because the penalty lands
            // seconds later and would otherwise arrive unexplained.
            if (hud.game.phase === "ready" && hud.game.jumped)
                return "HELD " + hud.game.jumpPenalty + "S AT THE GREEN"
            if (hud.game.stallTime > 0)
                return "OFF THE THROTTLE BEFORE GREEN"
            if (hud.game.phase === "ready" && hud.game.qualified)
                return "P" + hud.game.gridPos + " ON THE GRID"
            if (hud.game.phase === "ready" && !hud.game.qualified)
                return "LAP UNDER " + hud.game.qualifyTarget + "S TO START"
            if (hud.game.phase === "over" && hud.game.bestLap > 0)
                return "BEST LAP " + hud.game.bestLap.toFixed(2) + "S"
            return ""
        }
    }

    // ------------------------------------------------------ ranking tables

    // One row of a table: rank, name padded to three, score right-aligned.
    // Hand-padded because the 5x7 font is monospaced and the columns should
    // land on the same cells in every row.
    function rankRow(i, e) {
        var name = (e.n + "   ").slice(0, 3)
        var score = ("      " + e.s).slice(-6)
        return (i + 1) + " " + name + " " + score
    }

    // ---------------------------------------------------- the initials screen

    Item {
        anchors.fill: parent
        visible: hud.game && hud.game.phase === "initials"

        Rectangle {
            x: 0
            y: 44
            width: parent.width
            height: 120
            color: "#05070b"
            opacity: 0.7
        }

        BitmapText {
            px: 2
            color: hud.labelWhite
            x: Math.round((hud.width - implicitWidth) / 2)
            y: 52
            text: "DRIVER"
        }
        BitmapText {
            px: 1
            color: hud.labelYellow
            x: Math.round((hud.width - implicitWidth) / 2)
            y: 74
            text: "ENTER YOUR INITIALS"
        }

        // The three letters, the live one blinking, a bar under each slot so
        // a blank (space) slot still shows where it is.
        Row {
            id: entryRow
            x: Math.round((hud.width - width) / 2)
            y: 88
            spacing: 8

            Repeater {
                model: 3

                Item {
                    required property int index
                    width: 20
                    height: 34

                    BitmapText {
                        px: 4
                        color: hud.labelWhite
                        x: Math.round((20 - implicitWidth) / 2)
                        visible: !hud.game
                                 || hud.game.entrySlot !== index
                                 || Math.floor(hud.game.phaseTime * 3) % 2 === 0
                        text: hud.game
                              ? hud.game.entryAlphabet[hud.game.entryLetters[index]]
                              : ""
                    }
                    Rectangle {
                        y: 30
                        width: 20
                        height: 2
                        color: hud.game && hud.game.entrySlot === index
                               ? hud.labelYellow : "#3a3f4a"
                    }
                }
            }
        }

        BitmapText {
            px: 1
            color: hud.labelWhite
            opacity: 0.7
            x: Math.round((hud.width - implicitWidth) / 2)
            y: 132
            text: "ARROWS CHANGE  ENTER LOCK  ESC BACK"
        }
    }

    // ------------------------------------------------- table on the game over

    Item {
        anchors.fill: parent
        visible: hud.game && hud.game.phase === "over"
                 && hud.game.highScores.length > 0

        Rectangle {
            x: 0
            y: 124
            width: parent.width
            height: 14 + (hud.game ? hud.game.highScores.length : 0) * 10
            color: "#05070b"
            opacity: 0.7
        }

        BitmapText {
            px: 1
            color: hud.labelRed
            x: Math.round((hud.width - implicitWidth) / 2)
            y: 128
            text: "BEST DRIVERS " + (hud.game && hud.game.course
                                     ? hud.game.course.name : "")
        }

        Column {
            x: Math.round((hud.width - width) / 2)
            y: 138
            spacing: 2

            Repeater {
                model: hud.game ? hud.game.highScores.length : 0

                BitmapText {
                    required property int index
                    px: 1
                    // Your fresh entry blinks; everyone else holds steady.
                    readonly property bool mine:
                        hud.game
                        && hud.game.highScores[index].n === hud.game.lastEntryName
                        && hud.game.highScores[index].s === hud.game.lastEntryScore
                    color: mine ? hud.labelYellow : hud.labelWhite
                    visible: !mine || Math.floor(hud.game.phaseTime * 2) % 2 === 0
                    text: hud.rankRow(index, hud.game.highScores[index])
                }
            }
        }
    }

    // ---------------------------------------------------------------- title

    Item {
        anchors.fill: parent
        visible: hud.game && hud.game.phase === "attract"

        // Backing for the whole attract block, not just the title. Red on
        // sky over a mountain range is unreadable, and the instruction lines
        // sit lower still, on bright tarmac. Kept translucent so the road
        // keeps rolling behind it.
        Rectangle {
            x: 0
            y: 44
            width: parent.width
            height: 150
            color: "#05070b"
            opacity: 0.7
        }

        BitmapText {
            px: 4
            color: hud.labelRed
            x: Math.round((hud.width - implicitWidth) / 2)
            y: 56
            text: "QUATTRO"
        }
        BitmapText {
            px: 4
            color: hud.labelWhite
            x: Math.round((hud.width - implicitWidth) / 2)
            y: 92
            text: "GP"
        }
        // Below the title the screen alternates, the way a cabinet's attract
        // loop does: five seconds of how-to-play, five of the ranking table.
        // An empty table skips its turn rather than showing five blank rows.
        readonly property bool showTable:
            hud.game && hud.game.highScores.length > 0
            && Math.floor(hud.game.phaseTime / 5) % 2 === 1

        Item {
            anchors.fill: parent
            visible: !parent.showTable

            BitmapText {
                px: 1
                color: hud.labelYellow
                x: Math.round((hud.width - implicitWidth) / 2)
                y: 140
                // Blinks, because an arcade attract screen always does.
                visible: Math.floor(hud.game.phaseTime * 1.6) % 2 === 0
                text: "PRESS ENTER TO START"
            }
            BitmapText {
                px: 1
                color: hud.labelWhite
                opacity: 0.7
                x: Math.round((hud.width - implicitWidth) / 2)
                y: 160
                text: "ARROWS STEER  UP GAS  DOWN BRAKE  SPACE SHIFT"
            }
            // The one rule the game will penalise you for without ever having
            // stated it. Cheaper to say here than to be mystified by on the
            // grid.
            BitmapText {
                px: 1
                color: hud.labelRed
                x: Math.round((hud.width - implicitWidth) / 2)
                y: 172
                text: "NO THROTTLE UNTIL THE LIGHTS GO GREEN"
            }
            BitmapText {
                px: 1
                color: hud.labelWhite
                opacity: 0.7
                x: Math.round((hud.width - implicitWidth) / 2)
                y: 184
                text: "TOP " + (hud.game ? hud.game.topScore : 0)
            }
        }

        Item {
            anchors.fill: parent
            visible: parent.showTable

            BitmapText {
                px: 1
                color: hud.labelRed
                x: Math.round((hud.width - implicitWidth) / 2)
                y: 134
                text: "BEST DRIVERS " + (hud.game && hud.game.course
                                         ? hud.game.course.name : "")
            }

            Column {
                x: Math.round((hud.width - width) / 2)
                y: 146
                spacing: 2

                Repeater {
                    model: hud.game ? hud.game.highScores.length : 0

                    BitmapText {
                        required property int index
                        px: 1
                        color: hud.labelWhite
                        text: hud.rankRow(index, hud.game.highScores[index])
                    }
                }
            }
        }
    }

    // ------------------------------------------------------- course select

    // Four circuits, chosen before the qualifying lap. The road behind this
    // is already the selected course -- same renderer, its own palette and
    // backdrop -- so the menu is a preview rather than a description of one.
    Item {
        anchors.fill: parent
        visible: hud.game && hud.game.phase === "select"

        readonly property var course: hud.game ? hud.game.course : null

        Rectangle {
            x: 0
            y: 40
            width: parent.width
            height: 128
            color: "#05070b"
            opacity: 0.72
        }

        BitmapText {
            px: 1
            color: hud.labelYellow
            x: Math.round((hud.width - implicitWidth) / 2)
            y: 50
            text: "SELECT COURSE"
        }

        // The name, with arrows either side to say the list moves. They dim
        // at the ends of nothing -- the list wraps -- so they always read as
        // live.
        BitmapText {
            px: 1
            color: hud.labelWhite
            x: 30
            y: 76
            text: "<"
        }
        BitmapText {
            px: 1
            color: hud.labelWhite
            x: hud.width - 30 - implicitWidth
            y: 76
            text: ">"
        }
        BitmapText {
            px: 3
            color: hud.labelWhite
            x: Math.round((hud.width - implicitWidth) / 2)
            y: 68
            text: parent.course ? parent.course.name : ""
        }
        BitmapText {
            px: 1
            color: hud.labelYellow
            x: Math.round((hud.width - implicitWidth) / 2)
            y: 96
            text: parent.course ? parent.course.blurb : ""
        }

        // What actually differs between them, in the terms the game judges
        // you by: how long the lap is and what it wants it driven in.
        BitmapText {
            px: 1
            color: hud.labelWhite
            x: Math.round((hud.width - implicitWidth) / 2)
            y: 112
            text: hud.game
                  ? Math.round(hud.game.lapLength / Track.UNITS_PER_METRE)
                    + "M   QUALIFY IN " + hud.game.qualifyTarget + "S"
                  : ""
        }
        BitmapText {
            px: 1
            color: hud.labelWhite
            opacity: 0.7
            x: Math.round((hud.width - implicitWidth) / 2)
            y: 124
            text: hud.game ? "BEST " + hud.game.topScore : ""
        }

        // Which of the four, as pips rather than a number: it is a short list
        // and the shape of it is the useful part.
        Row {
            spacing: 6
            y: 142
            x: Math.round((hud.width - width) / 2)
            Repeater {
                model: hud.game ? hud.game.courseCount : 0
                Rectangle {
                    required property int index
                    width: 6; height: 6
                    color: hud.game && index === hud.game.courseIndex
                           ? hud.labelYellow : hud.labelWhite
                    opacity: hud.game && index === hud.game.courseIndex ? 1 : 0.35
                }
            }
        }

        BitmapText {
            px: 1
            color: hud.labelGreen
            x: Math.round((hud.width - implicitWidth) / 2)
            y: 156
            visible: Math.floor(hud.game.phaseTime * 1.6) % 2 === 0
            text: "ENTER TO RACE"
        }
    }
}
