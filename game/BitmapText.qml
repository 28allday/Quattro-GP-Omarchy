import QtQuick

// A line of text in the 5x7 arcade font, in any colour.
//
// Each glyph is one Image clipped out of art/font.png; the row is rendered to a
// layer and run through shaders/tint.frag, because the atlas is white and plain
// QtQuick cannot tint an Image. That is one small extra pass per line of text,
// which the HUD's handful of lines will never notice.
//
// The font has no lowercase, so text is upper-cased rather than dropped -- an
// arcade HUD is all caps anyway. Anything outside the sheet renders as a blank.
Item {
    id: root

    property string text: ""
    property color color: "#ffffff"
    property int px: 1              // integer pixel scale

    readonly property int cellW: 6
    readonly property int cellH: 8
    readonly property string shown: text.toUpperCase()

    implicitWidth: shown.length * cellW * px
    implicitHeight: cellH * px

    Item {
        id: glyphs
        width: Math.max(1, root.implicitWidth)
        height: Math.max(1, root.implicitHeight)

        Repeater {
            model: root.shown.length

            Image {
                required property int index

                x: index * root.cellW * root.px
                width: root.cellW * root.px
                height: root.cellH * root.px
                source: Qt.resolvedUrl("../art/font.png")
                smooth: false
                mipmap: false
                fillMode: Image.Stretch

                sourceClipRect: {
                    var c = root.shown.charCodeAt(index)
                    if (isNaN(c) || c < 32 || c > 95) c = 32
                    var i = c - 32
                    return Qt.rect((i % 16) * root.cellW,
                                   Math.floor(i / 16) * root.cellH,
                                   root.cellW, root.cellH)
                }
            }
        }
    }

    ShaderEffectSource {
        id: glyphSource
        sourceItem: glyphs
        hideSource: true
        visible: false
        smooth: false
        live: true
    }

    ShaderEffect {
        anchors.fill: parent
        fragmentShader: Qt.resolvedUrl("../shaders/tint.frag.qsb")
        blending: true
        property variant src: glyphSource
        property color tint: root.color
    }
}
