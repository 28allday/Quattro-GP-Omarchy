#version 440

// Quattro GP -- flat-colour tint for the bitmap font.
//
// art/font.png is white-on-transparent so one atlas can serve every colour the
// HUD uses. Plain QtQuick has no way to tint an Image, and the alternatives all
// cost more than this: QtQuick.Effects pulls in another module, and colouring
// inside a Canvas means compositing every glyph by hand. This takes the glyph's
// alpha as a mask and paints the tint through it, premultiplied.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;
    vec4  tint;
};

layout(binding = 1) uniform sampler2D src;

void main()
{
    float a = texture(src, qt_TexCoord0).a * tint.a * qt_Opacity;
    fragColor = vec4(tint.rgb * a, a);
}
