#version 440

// Quattro GP -- the road.
//
// The whole road surface is this one fragment shader over a single quad. It
// works because Pole Position's road is flat: with no elevation, the distance
// ahead at a given screen row is a closed form, so every pixel can ask "how far
// away am I, and where is the road centre there" without anything having walked
// down the screen first. No per-frame geometry, no row table, no CPU raster.
//
// centre() below is the GLSL half of a pair -- game/Track.js carries the same
// piecewise quadratic in JavaScript and places every sprite through it. They
// must stay identical or the cars will drift off the tarmac. Change one, change
// the other.
//
// Rebuild after editing:  shaders/bake.sh

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

// Members are grouped scalars-first under std140: mat4, then fifteen floats
// (qt_Opacity, twelve named uniforms, two explicit pads -- 124 bytes, so
// the compiler still inserts 4 before the first vec4 reaches its 16-byte
// boundary). Qt 6 binds ShaderEffect uniforms by NAME through qsb reflection,
// so the grouping is for legibility, not layout correctness -- but keep
// scalars together anyway; interleaving them with vec4s scatters padding.
layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;

    float resX;
    float resY;
    float horizonY;     // screen row the road converges to
    float camDepth;     // 1 / tan(fov/2)
    float camHeight;    // eye height above the tarmac, world units
    float camX;         // driver's lateral offset from the centreline
    float roadHalf;     // half the road's width, world units
    float zCam;         // distance travelled, for the band phase
    float maxZ;         // draw distance; past this is fog
    float stripeLen;    // world length of one band pair

    // Which side of the road is shore: 0 none, -1 left, +1 right. The only
    // thing in here that is not symmetric about the centreline -- everything
    // else works on abs(x - cx), and a coast cannot.
    float shoreSide;
    float waveAmt;      // how hard the wavelets are cut into the water
    float pad0;
    float pad1;

    // Road ahead as up to eight quadratic pieces: (z0, curvature, heading, x).
    // Unused slots arrive parked far past maxZ so their tests never fire.
    vec4  seg0; vec4 seg1; vec4 seg2; vec4 seg3;
    vec4  seg4; vec4 seg5; vec4 seg6; vec4 seg7;

    vec4  cRoad;  vec4 cRoadAlt;
    vec4  cGrassA; vec4 cGrassB;
    vec4  cRumbleA; vec4 cRumbleB;
    vec4  cLane;  vec4 cFog;

    // The shore side's ground: two water tones banded like the grass is, and
    // the sand between the kerb and the water.
    vec4  cShoreA; vec4 cShoreB;
    vec4  cSand;

    // (lap length, start/finish band width, beach outer edge in road
    // half-widths, how much of the beach is wet).
    // Up to three puddles a lap: (lap distance, lateral x, half length,
    // half width), world units. A zeroed entry (half length 0) is skipped.
    // Positions come from Track.puddles() -- the fifth thing written in one
    // place and read by two: the shader paints these and Game.qml's slide
    // trigger reads the same list, so the water you see is exactly the water
    // that takes your grip.
    vec4  pud0; vec4 pud1; vec4 pud2;

    // Packed into a vec4 rather than added as more floats so the block stays
    // 16-byte aligned without hand-inserted padding.
    vec4  lapSpec;
};

// A hash in [0,1) for a pair of integer cell coordinates. Used only for the
// ground texturing below, where the cells are world coordinates rather than
// screen ones -- a screen-space hash would boil as the camera moved.
float hash(vec2 c)
{
    return fract(sin(dot(c, vec2(41.7, 289.3))) * 43758.5453);
}

// Lateral offset of the road centre z units ahead. The mirror of
// Track.centerAt(): pick the last piece that has started, then evaluate
// x + heading*d + curve*d*d/2.
// Normalised squared distance from a puddle's centre: < 1 is inside its
// ellipse. The z difference is wrapped to the shortest way round the lap so a
// puddle near the line still paints whole.
float puddleAt(vec4 p, float lapPos, float wx)
{
    if (p.z < 1.0) return 9.0;
    float dz = lapPos - p.x;
    dz -= lapSpec.x * floor(dz / lapSpec.x + 0.5);
    float nx = (wx - p.y) / p.w;
    float nz = dz / p.z;
    return nx * nx + nz * nz;
}

float centre(float z)
{
    vec4 s = seg0;
    if (z >= seg1.x) s = seg1;
    if (z >= seg2.x) s = seg2;
    if (z >= seg3.x) s = seg3;
    if (z >= seg4.x) s = seg4;
    if (z >= seg5.x) s = seg5;
    if (z >= seg6.x) s = seg6;
    if (z >= seg7.x) s = seg7;
    float d = z - s.x;
    return s.w + s.z * d + 0.5 * s.y * d * d;
}

void main()
{
    // Snap to the 320x240 grid before doing anything else. The game is drawn
    // at that size and integer-scaled up, and sampling at pixel centres is what
    // keeps the edges hard rather than letting the upscale smear them.
    vec2 p = qt_TexCoord0 * vec2(resX, resY);
    float x = floor(p.x) + 0.5;
    float y = floor(p.y) + 0.5;

    float dy = y - horizonY;
    if (dy <= 0.0) {            // sky and backdrop are drawn behind this quad
        fragColor = vec4(0.0);
        return;
    }

    // Invert the projection: scale = dy / (camHeight * h/2), z = camDepth/scale.
    float scale = dy / (camHeight * resY * 0.5);
    float z = camDepth / scale;

    if (z > maxZ) {             // the last row or two before the horizon
        fragColor = vec4(cFog.rgb, 1.0);
        return;
    }

    float halfW = scale * roadHalf * resX * 0.5;
    float cx = resX * 0.5 + scale * (centre(z) - camX) * resX * 0.5;
    float sx = x - cx;              // signed: which side of the road
    float d = abs(sx);

    // Is this pixel on the shore side? Everything else in here is symmetric
    // about the centreline and works on d alone; a coast is the one thing
    // that cannot be, so it is the one thing that asks about the sign.
    bool shore = shoreSide != 0.0 && sx * shoreSide > 0.0;

    // Where this pixel is in the world, laterally -- the inverse of the cx
    // line above. The ground texturing needs it: patches and grain are
    // anchored to the world so they stream toward the driver with everything
    // else, rather than sitting still on the screen while the road moves.
    float worldX = camX + (x - resX * 0.5) / max(scale * resX * 0.5, 1e-6);

    // Bands are phased on world distance so they stream toward the driver.
    float worldZ = zCam + z;
    float band = mod(floor(worldZ / stripeLen), 2.0);

    // Near the horizon a band is far narrower than a pixel and aliases into a
    // shimmering mess, so fade the alternation out over the top few rows: at
    // band = 0.5 both colours average and the distance goes quiet.
    band = mix(0.5, band, smoothstep(0.0, 7.0, dy));

    vec3 grass  = mix(cGrassA.rgb,  cGrassB.rgb,  band);
    vec3 road   = mix(cRoad.rgb,    cRoadAlt.rgb, band);
    vec3 rumble = mix(cRumbleA.rgb, cRumbleB.rgb, band);

    // ------------------------------------------------------ ground texture
    //
    // Two flat greens alternating in bands is what the machine had, and on a
    // frame this size it reads as billiard felt: the verges are the largest
    // area on screen and the only one with nothing happening in it. What
    // follows adds variation without adding a texture -- every cell is hashed
    // off world coordinates, so it streams with the bands instead of swimming.
    //
    // Both fade out with distance for the same reason the band alternation
    // does: a cell smaller than a pixel is not detail, it is noise. The grain
    // is the finer of the two and so fades over a much shorter run of rows.
    float nearGrass = smoothstep(0.0, 26.0, dy);
    float nearRoad  = smoothstep(0.0, 60.0, dy);

    float clump = hash(vec2(floor(worldX / 2900.0), floor(worldZ / 2900.0)));
    grass *= 1.0 + (step(0.55, clump) - 0.5) * 0.11 * nearGrass;

    // Water. Banded like the grass so it streams toward the driver, then cut
    // with wavelets: cells far wider than they are long, which is the shape a
    // swell actually makes and is what stops the sea reading as blue grass.
    vec3 water = mix(cShoreA.rgb, cShoreB.rgb, band);
    float swell = hash(vec2(floor(worldX / 2100.0), floor(worldZ / 340.0)));
    water *= 1.0 + (step(0.62, swell) - 0.35) * waveAmt * nearGrass;

    // Sand, with a damp strip at the water's edge. One band of variation, so
    // it is not the only flat fill left on the screen.
    float sandy = hash(vec2(floor(worldX / 1700.0), floor(worldZ / 1700.0)));
    vec3 sand = cSand.rgb * (1.0 + (step(0.5, sandy) - 0.5) * 0.06 * nearGrass);

    float grain = hash(vec2(floor(worldX / 90.0), floor(worldZ / 90.0)));
    road *= 1.0 + (step(0.5, grain) - 0.5) * 0.05 * nearRoad;

    // Two strips of polished tarmac where the racing line has worn it, one in
    // each half of the road. Subtle on purpose -- enough to stop the surface
    // reading as one flat fill, not enough to be mistaken for a marking.
    float t = d / max(halfW, 1e-6);
    float wear = smoothstep(0.26, 0.34, t) - smoothstep(0.60, 0.70, t);
    road *= 1.0 - 0.055 * wear * nearRoad;

    // Marking widths are a fraction of the road's width, and the road's width
    // vanishes with distance -- so both need a floor in pixels. Without one the
    // centre line drops under a pixel about eight rows short of the horizon and
    // simply stops, while the kerb carries on to the tip: the road runs out of
    // markings before it runs out of road.
    float edgeHalf = max(halfW * 0.07,  0.60);
    float laneHalf = max(halfW * 0.022, 0.55);

    // Dashes shorter than a pixel would strobe as they crawl up the screen, so
    // close them into a solid line over the last few rows. That is what the far
    // end of a dashed line looks like from a car anyway.
    float dashOn = mod(floor(worldZ / (stripeLen * 0.5)), 2.0) < 0.5 ? 1.0 : 0.0;
    dashOn = max(dashOn, smoothstep(16.0, 5.0, dy));

    // The start/finish line.
    //
    // Painted by the shader rather than hung on the road as a sprite, so it
    // takes the road's own perspective for free and cannot drift off the
    // tarmac. It needs no per-frame uniform either: the line is wherever
    // absolute distance is a multiple of a lap, so one mod() puts one on every
    // lap for ever.
    float toLine = mod(worldZ, lapSpec.x);
    bool onLine = toLine < lapSpec.y;

    // The beach runs from the kerb out to the water. Quoted in road
    // half-widths like every other band here, so it narrows with distance
    // along with everything else rather than needing its own perspective --
    // and it arrives as a uniform rather than a literal because
    // buildScenery() has to respect the same edge to keep signs out of the
    // sea (Track.SHORE_SAND_END).
    float SAND_END = lapSpec.z;
    float WET      = lapSpec.w;

    vec3 col;
    if (shore && d > halfW * SAND_END) {
        col = water;
    } else if (shore && d > halfW * (SAND_END - WET)) {
        col = sand * 0.84;                              // wet sand
    } else if (shore && d > halfW * 1.16) {
        col = sand;
    } else if (d > halfW * 1.34) {
        col = grass;
    } else if (d > halfW * 1.16) {
        // Verge: the strip of ground the kerb sits in, scuffed and in the
        // road's own shadow. Derived from the grass rather than given a
        // uniform of its own, so it costs no palette entry and comes out
        // right on all four courses -- including Sunset, whose "grass" is
        // purple.
        col = grass * 0.76;
    } else if (d > halfW) {
        col = rumble;                                   // red/white kerb
    } else if (d > halfW - edgeHalf) {
        col = cLane.rgb;                                // solid edge line
    } else if (d < laneHalf && dashOn > 0.5) {
        col = cLane.rgb;                                // dashed centre line
    } else {
        col = road;
    }

    // Puddles: standing water on the tarmac, over the markings the way water
    // lies over paint. Tinted with cFog -- the course's own haze colour is
    // what its sky looks like reflected, so Fuji's puddles read blue and
    // Sunset's pink without costing a palette entry. Two bands, not a
    // gradient: a soft edge would be the only one in the frame.
    if (d < halfW) {
        float pr = min(puddleAt(pud0, toLine, worldX),
                   min(puddleAt(pud1, toLine, worldX),
                       puddleAt(pud2, toLine, worldX)));
        if (pr < 1.0)
            col = mix(col, cFog.rgb, pr < 0.58 ? 0.55 : 0.28);
    }

    // Chequers, two rows deep, laid over the tarmac and the edge lines but not
    // over the kerb, which carries on past it.
    if (onLine && d < halfW) {
        float cell = max(halfW * 0.17, 1.0);
        float row  = floor(toLine / (lapSpec.y * 0.5));
        float sq   = mod(floor((x - cx) / cell) + row, 2.0);
        col = sq < 0.5 ? cLane.rgb : vec3(0.06, 0.06, 0.07);
    }

    // Aerial perspective.
    //
    // This was a single smoothstep over the last 45% of the draw distance,
    // which cleaned up the seam against the mountains but left everything
    // nearer than that perfectly flat -- so the middle distance had no depth
    // and the sprites standing in it sat on top of the picture rather than in
    // it. Starting far earlier and squaring the result gives the same clean
    // horizon with a middle distance that recedes.
    //
    // game/Track.js carries the same curve as fogAt(): sprites fade on it too,
    // or the cars would stay fully saturated against a road that no longer is.
    float fog = smoothstep(0.20, 1.0, z / maxZ);
    col = mix(col, cFog.rgb, fog * fog);

    fragColor = vec4(col, 1.0);
}
