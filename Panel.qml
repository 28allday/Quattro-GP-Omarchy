import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Window
import qs.Commons
import qs.Ui
import "game"

// Quattro GP for omarchy-shell. Summoned/toggled through the shell host:
//   omarchy-shell shell toggle nosignal.quattro-gp
//
// This file is the cabinet, not the game. Everything that has to know about
// the shell lives here -- the window, keyboard focus, the high score on disk --
// and game/Game.qml stays pure QtQuick so the whole thing can be run and tuned
// under `qml6 dev/play.qml` without restarting the shell. That split is the
// only reason the handling could be iterated on at all.
//
// `keepLoaded: true` in manifest.json matters: without it the host's Loader
// destroys this instance on hide, and closing the panel mid-race would drop
// the game rather than pause it.
Item {
    id: root

    property bool opened: false

    readonly property string selfId: "nosignal.quattro-gp"

    // Injected by the shell host after the Loader resolves. Used to keep the
    // host's open-flag honest on close(), and to self-restore if the host's
    // panel Instantiator rebuild destroys a visibly-open instance.
    property var shell: null
    onShellChanged: {
        if (!root.opened && root.shell && root.shell.openPanelIds
                && root.shell.openPanelIds[root.selfId] === true)
            root.open("{}")
    }

    // ---------------------------------------------------------------- theme

    // Only the surround is themed. The game itself is fixed artwork at a fixed
    // palette -- recolouring a 1982 arcade cabinet to match the desktop would
    // be the one change guaranteed to stop it looking like one.
    property color background: Color.menu.background
    property color border: Color.menu.border
    property var borderSpec: Border.surfaceSpec("menu", "border", border,
                                                Math.max(1, Style.space(2)))
    readonly property int cornerRadius: Style.cornerRadius

    // ------------------------------------------------------- self-registration

    // `omarchy plugin enable` only writes the bar.layout entry for a
    // panel+bar-widget plugin, so the keybinding dies with the bar icon unless
    // the plugin claims its own plugins[] entry. Upstream fix is PR #6510;
    // until it lands, self-register on first open. Idempotent, jq-guarded.
    //
    // Harness: sh -c <script> plugin-selfref <id> -- $0 is the label, $1 the id.
    property bool selfRefEnsured: false
    readonly property string ensureSelfRefScript: [
        'id="$1"',
        'f="$HOME/.config/omarchy/shell.json"',
        '[ -f "$f" ] || exit 0',
        'jq -e --arg id "$id" \'any(.plugins[]?; (.id // empty) == $id)\' "$f" >/dev/null && exit 0',
        'tmp="$f.selfref.$$"',
        'jq --arg id "$id" \'.plugins = ((.plugins // []) + [{id: $id}])\' "$f" > "$tmp" || {',
        '  rm -f "$tmp"; exit 1;',
        '}',
        '[ -s "$tmp" ] || { rm -f "$tmp"; exit 1; }',
        'mv "$tmp" "$f"'
    ].join("\n")

    function ensureSelfReference() {
        if (root.selfRefEnsured) return
        root.selfRefEnsured = true
        Quickshell.execDetached(["sh", "-c", root.ensureSelfRefScript,
                                 "plugin-selfref", root.selfId])
    }

    // ---------------------------------------------------------- persistence

    readonly property string stateDir:
        (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state"))
        + "/quattro-gp"
    readonly property string statePath: root.stateDir + "/state.json"

    // One ranking table per circuit, keyed by course name: up to five
    // {n, s} rows, best first. Per circuit because a single list stopped
    // meaning anything once there were four courses of different lengths
    // and targets -- a Sunset score is not comparable to a City one.
    property var tables: ({})
    // The last name entered on the initials screen, so the next session's
    // entry arrives prefilled.
    property string driver: ""
    property bool stateLoaded: false

    function tableFor(name) {
        var t = name ? root.tables[name] : null
        return Array.isArray(t) ? t : []
    }

    function topScoreFor(name) {
        var t = root.tableFor(name)
        return t.length ? t[0].s : 0
    }

    function applyState(text) {
        try {
            var o = JSON.parse(text)
            var out = {}

            if (o && typeof o.tables === "object" && o.tables) {
                for (var k in o.tables) {
                    if (!Array.isArray(o.tables[k])) continue
                    var rows = []
                    for (var i = 0; i < o.tables[k].length && rows.length < 5; i++) {
                        var r = o.tables[k][i]
                        if (r && typeof r.n === "string" && typeof r.s === "number")
                            rows.push({ n: r.n.slice(0, 3).toUpperCase(),
                                        s: Math.max(0, Math.floor(r.s)) })
                    }
                    if (rows.length) out[k] = rows
                }
            }

            // Migrate the two older shapes: `topScores` held one number per
            // course, and the pre-course file one bare `topScore`, which was
            // necessarily set on Fuji because Fuji was the only circuit. A
            // migrated score has no name on record, so it wears "---".
            if (o && typeof o.topScores === "object" && o.topScores) {
                for (var c in o.topScores)
                    if (typeof o.topScores[c] === "number" && out[c] === undefined)
                        out[c] = [{ n: "---", s: Math.max(0, Math.floor(o.topScores[c])) }]
            }
            if (o && typeof o.topScore === "number" && out["FUJI"] === undefined)
                out["FUJI"] = [{ n: "---", s: Math.max(0, Math.floor(o.topScore)) }]

            if (o && typeof o.driver === "string")
                root.driver = o.driver.slice(0, 3).toUpperCase()

            root.tables = out
        } catch (e) {
            // A missing or corrupt file just means no high scores yet.
        }
        root.stateLoaded = true
    }

    function saveState() {
        if (!root.stateLoaded) return
        stateFile.setText(JSON.stringify({ tables: root.tables,
                                           driver: root.driver }))
    }

    FileView {
        id: stateFile
        path: root.statePath
        atomicWrites: true
        printErrors: false
        onLoaded: root.applyState(text())
        onLoadFailed: function (err) { root.applyState("") }
    }

    Process {
        id: mkStateDir
        command: ["mkdir", "-p", root.stateDir]
        onExited: stateFile.reload()
    }

    Component.onCompleted: mkStateDir.running = true

    // ----------------------------------------------------------- open/close

    function open(payloadJson) {
        root.opened = true
        root.ensureSelfReference()
        Qt.callLater(function () { cabinet.focusGame() })
    }

    function close() {
        if (!root.opened) return
        root.opened = false
        if (root.shell && typeof root.shell.hide === "function")
            root.shell.hide(root.selfId)
    }

    function toggle() {
        if (root.opened) root.close(); else root.open("{}")
    }

    // -------------------------------------------------------------- window

    PanelWindow {
        id: panel
        visible: root.opened
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        WlrLayershell.namespace: "omarchy-quattro-gp"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive
                                                 : WlrKeyboardFocus.None
        exclusionMode: ExclusionMode.Ignore

        MouseArea {
            anchors.fill: parent
            onClicked: root.close()
        }

        BorderSurface {
            id: surface
            anchors.centerIn: parent
            width: cabinet.width + root.cornerRadius
            height: cabinet.height + root.cornerRadius
            radius: root.cornerRadius
            color: "#000000"
            borderSpec: root.borderSpec
            clip: true

            // Swallow clicks so they don't fall through to the close-on-click
            // backdrop behind.
            MouseArea { anchors.fill: parent; onClicked: {} }

            Item {
                id: cabinet
                anchors.centerIn: parent

                // ---- integer scaling, as far as it can be taken
                //
                // The game is 320x240 of deliberate pixel art, so it wants to be
                // magnified by a whole number: at 2.5x some source pixels become
                // two screen pixels and their neighbours three, and straight
                // edges come out ragged.
                //
                // The whole number is picked against devicePixelRatio rather
                // than in QML's logical pixels, which is exact whenever the
                // ratio is a whole number.
                //
                // It is NOT exact under Wayland fractional scaling, and that is
                // worth knowing rather than believing otherwise. On this desktop
                // Hyprland runs the output at 1.667 but Qt reports a ratio of 2
                // and a 2304x1296 logical screen: Qt renders into a 2x buffer
                // and the compositor resamples *that* down to 1.667. So the
                // whole number here is an integer number of buffer pixels, and
                // the compositor's final non-integer downscale of the finished
                // surface cannot be avoided from inside the process -- the true
                // output scale is not visible to Qt at all. Measured result on
                // this machine: 320px of game lands on 1333 physical pixels.
                readonly property real dpr: Math.max(1, Screen.devicePixelRatio)
                readonly property real availW: panel.width - Style.gapsOut * 4
                readonly property real availH: panel.height - Style.bar.sizeHorizontal
                                               - Style.gapsOut * 4

                // The bezel's native geometry, from art/make_art.py (BEZEL_*):
                // 16px pillars each side, a 28px marquee, a 26px control card.
                // The game's 320x240 sits in the transparent hole at (16, 28).
                readonly property int bezelW: 344
                readonly property int bezelH: 294
                readonly property int bezelX: 12
                readonly property int bezelY: 28

                // How much of the screen the cabinet is allowed to take.
                //
                // Filling the available area is the wrong default: it picked 8x
                // on a 3840x2160 display, which is 2560x1920 device pixels and
                // near enough the whole desktop. Aiming a little over half
                // lands on 4x there and 2x on a 1080p screen, both of which sit
                // on the desktop rather than swallowing it.
                //
                // It only ever moves in whole steps, so nudging this does
                // nothing until it crosses an integer boundary -- that is the
                // point, not a rounding bug.
                //
                // 0.62, up from 0.55 when the game stood alone: the fraction
                // now covers the bezel too, and 0.62 is what keeps the GAME at
                // the same integer step as before on both a 2160 and a 1080
                // display -- the window grew by the bezel, the game did not
                // shrink to pay for it.
                readonly property real screenFraction: 0.62

                readonly property int deviceScale:
                    Math.max(1, Math.floor(Math.min(
                        availW * dpr * screenFraction / bezelW,
                        availH * dpr * screenFraction / bezelH)))
                readonly property real zoom: deviceScale / dpr

                width: Math.round(bezelW * zoom)
                height: Math.round(bezelH * zoom)

                function focusGame() { game.forceActiveFocus() }

                Game {
                    id: game
                    width: 320
                    height: 240
                    x: Math.round(cabinet.bezelX * cabinet.zoom)
                    y: Math.round(cabinet.bezelY * cabinet.zoom)
                    transformOrigin: Item.TopLeft
                    scale: cabinet.zoom

                    // The simulation runs only while the cabinet is open.
                    // FrameAnimation is a process-wide animation job: it keeps
                    // firing as long as ANY shell window renders (the bar
                    // always does), so without this gate the game stepped at
                    // frame rate forever after the first open -- attract miles
                    // accruing, slot churn every frame, a closed mid-race game
                    // silently draining its clock to a game over. Closing the
                    // cabinet now PAUSES it, which is what keepLoaded was for.
                    selfDriven: root.opened

                    // Render the frame to a texture at its native size and
                    // magnify that, rather than letting each child scale
                    // itself. One nearest-neighbour upscale of the finished
                    // frame is what puts the road, the sprites and the HUD on
                    // the same pixel grid.
                    layer.enabled: true
                    layer.smooth: false
                    layer.textureSize: Qt.size(320, 240)

                    topScore: root.topScoreFor(course ? course.name : "")
                    highScores: root.tableFor(course ? course.name : "")
                    defaultDriver: root.driver
                    onDriverNamed: function (name) {
                        root.driver = name
                        root.saveState()
                    }
                    onHighScoreEntered: function (name, value) {
                        if (!course) return
                        // Replace the object rather than mutating it: QML will
                        // not re-evaluate the table bindings for an in-place
                        // change to a var property's contents.
                        var next = {}
                        for (var k in root.tables) next[k] = root.tables[k]
                        next[course.name] = game.mergeScore(
                            root.tableFor(course.name), name, value)
                        root.tables = next
                        root.saveState()
                    }
                    onQuitRequested: root.close()
                }

                // The cabinet surround, over the game: its screen area is
                // transparent, so it frames rather than covers. Same integer
                // magnification as the frame, same nearest-neighbour scaling,
                // so bezel pixels and road pixels are the same size.
                Image {
                    anchors.fill: parent
                    source: Qt.resolvedUrl("art/bezel.png")
                    smooth: false
                    mipmap: false
                    z: 1
                }
            }
        }
    }
}
