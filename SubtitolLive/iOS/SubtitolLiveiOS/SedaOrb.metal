#include <metal_stdlib>
using namespace metal;

// Seda, the voice orb of the "Versió final" design (orbs/seda.glsl), ported to Metal.
// The shader is the study's own, line for line, with two changes: the cycle angle
// arrives already computed (`theta`), because the app speeds it up while someone speaks,
// and the size, deformation, turbulence, crest and balance arrive per frame, because the
// voice drives them. Colours stay on the project's ramp (#FF6400 to #FFC200).
//
// On top of the study, the inside moves like molten glass: `liquid` stirs the silk
// with two stacked currents on their own clock (`flow`), which never stops, and a voice
// churns deeper. Every term turns a whole number of times per turn of `flow`, so the
// phase wraps without a seam. The grain is finer, lighter and redrawn many times a
// second, so the material shimmers instead of sitting under a still screen.

struct SedaUniforms {
    float2 resolution;
    float theta;          // cycle angle, 0..1 of a turn
    float level;          // fast voice envelope, 0..1
    float motion;
    float react;
    float size;
    float square;
    float edge;
    float deform;
    float deformDetail;
    float fold;
    float foldAngle;
    float crest;
    float crestWidth;
    float turbulence;
    float turbulenceScale;
    float balance;
    float contrast;
    float grain;
    float grainSize;
    float scale;          // device pixels per point
    float flow;           // liquid phase, 0..1 of a turn
    float churn;          // how deeply the liquid folds
    float grainSeed;      // changes every grain frame
    float grainMode;      // 0 dithers the pigment; 1+ blends a grey grain layer (study)
    float grainMix;       // opacity of that layer
    float4 color1;
    float4 color2;
    float4 color3;
    float4 color4;
    float4 background;
};

struct SedaVertexOut {
    float4 position [[position]];
};

vertex SedaVertexOut sedaVertex(uint vertexID [[vertex_id]]) {
    // One triangle that covers the whole view.
    float2 positions[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    SedaVertexOut out;
    out.position = float4(positions[vertexID], 0, 1);
    return out;
}

constant float TAU = 6.28318531;
constant float DEEPEST = 0.0;
constant float ORANGE = 0.1167;
constant float EMBER = 0.1667;
constant float FLAME = 0.3333;
constant float APRICOT = 0.6667;
constant float AMBER = 1.0;

static float glslMod(float x, float y) { return x - y * floor(x / y); }

static float hash(float2 p) {
    float3 p3 = fract(float3(p.x, p.y, p.x) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}
static float gauss(float d, float s) { return exp(-d * d / (s * s)); }
static float spot(float2 p, float2 c, float2 s) { float2 d = (p - c) / s; return exp(-dot(d, d)); }
static float bounce(float x) { return 1. - abs(1. - glslMod(x, 2.)); }

static float3 palette(float x, constant SedaUniforms& u) {
    x = clamp(x, 0., 1.) * 3.;
    float3 c = mix(u.color1.rgb, u.color2.rgb, clamp(x, 0., 1.));
    c = mix(c, u.color3.rgb, clamp(x - 1., 0., 1.));
    return mix(c, u.color4.rgb, clamp(x - 2., 0., 1.));
}

static float2 outline(float a, float th, float m, constant SedaUniforms& u) {
    float k = u.deformDetail;
    float4 e = float4(0.50 * (0.75 + 0.25 * sin(th + 1.1)), 0.36 * (0.75 + 0.25 * sin(2. * th + 3.0)),
                      0.24 * k * (0.7 + 0.3 * sin(3. * th + 0.2)), 0.16 * k);
    float e7 = 0.10 * k * k;
    float4 ph = float4(2. * a + th + 0.4, 3. * a - 2. * th + 1.7, 4. * a + 3. * th + 4.1, 5. * a - 4. * th + 2.3);
    float ph7 = 7. * a + 5. * th + 0.9;
    float amp = u.deform * 0.16 * (1. + 0.5 * m);
    float w = dot(e, sin(ph)) + e7 * sin(ph7);
    float dw = dot(e * float4(2., 3., 4., 5.), cos(ph)) + 7. * e7 * cos(ph7);
    return float2(1. + amp * w, amp * dw);
}

static float2 flow(float2 p, float th) {
    float2 x = p;
    float f = 1.;
    float2x2 r = float2x2(float2(1., 0.), float2(0., 1.));
    float2x2 turn = float2x2(float2(0.8, 0.6), float2(-0.6, 0.8));
    for (int i = 0; i < 5; i++) {
        float k = float(i);
        float2 s = sin((r * x).yx * f + float2((1. + k) * th + 1.7 * k, -(1. + k) * th + 2.9 * k)) / f;
        x += 0.55 * (s * r);
        r = turn * r;
        f *= 1.7;
    }
    return x - p;
}

// Two currents, the second riding on the first, the way lava folds over itself.
static float2 liquid(float2 p, float ph, float churn) {
    float2 a = flow(p * 1.35 + float2(0.3, -0.2), ph);
    float2 b = flow((p + 0.55 * a) * 2.1 + float2(-1.7, 2.4), -2. * ph + 1.3);
    return churn * (0.30 * a + 0.16 * b);
}

static float2 silk(float2 p, float th, float m, constant SedaUniforms& u) {
    float ph = TAU * u.flow;
    float2 stirred = p + liquid(p, ph, u.churn);
    // Hot cores drift through the body and swell with the voice.
    float heat = spot(stirred, float2(0.32 * sin(ph + 0.8), 0.28 * cos(2. * ph + 0.3)), float2(0.42))
               + 0.8 * spot(stirred, float2(-0.36 * cos(ph + 2.1), -0.22 * sin(3. * ph)), float2(0.34));
    p = stirred;
    float c = cos(u.foldAngle * M_PI_F / 180.), s = sin(u.foldAngle * M_PI_F / 180.);
    p = float2x2(float2(c, s), float2(-s, c)) * p;
    p += u.turbulence * 0.45 * flow(p * u.turbulenceScale, th) / u.turbulenceScale;
    float fold = p.y + 0.30 * p.x + u.fold * 0.19 * sin(2.7 * p.x + 0.45 + th) * (0.7 + 0.45 * m);
    float t = mix(FLAME, APRICOT, smoothstep(-0.22, 1.3, p.y + 0.27 * p.x));
    t = mix(t, ORANGE, spot(p, float2(0.45, 0.22), float2(0.65, 0.8)) * 0.58);
    t = mix(t, EMBER, 1. - smoothstep(-0.58, -0.03, fold));
    t = mix(t, DEEPEST, (1. - smoothstep(-0.82, -0.30, fold)) * 0.84);
    t = mix(t, AMBER, gauss(fold + 0.075, 0.12 * u.crestWidth) * min(0.88 * u.crest, 1.));
    t = mix(t, APRICOT, gauss(fold - 0.13, 0.22 * u.crestWidth) * 0.43 * min(u.crest, 1.));
    t = mix(t, AMBER, clamp(heat, 0., 1.) * (0.12 + 0.2 * m));
    return float2(t, fold);
}

static float grade(float t, float fold, float z, float th, float light, constant SedaUniforms& u) {
    t = clamp((t - 0.5) * u.contrast + 0.5, 0., 1.);
    t = pow(t, exp2(-1.6 * u.balance));
    t = bounce(t);
    return t * light;
}

static float2 orb(float2 q, float th, float m, float light, float px, constant SedaUniforms& u) {
    float R = 0.73 * u.size;
    float2 p = q / R;
    float2 o = outline(atan2(p.y, p.x + 1e-6), th, m, u);
    float n = mix(2., 8., u.square);
    float2 ap = max(abs(p), float2(1e-4));
    float rn = pow(pow(ap.x, n) + pow(ap.y, n), 1. / n);
    float d = (rn - o.x) / sqrt(1. + o.y * o.y / max(rn * rn, 0.01));
    float soft = 0.9 * px / R + u.edge * u.edge * 0.55;
    float cover = 1. - smoothstep(-soft, soft, d);
    float z = sqrt(max(0., 1. - rn * rn / (o.x * o.x)));
    float2 s = silk(p / o.x, th, m, u);
    return float2(grade(s.x, s.y, z, th, light, u), cover);
}

static float2 grainCell(float2 q, float th, float m, constant SedaUniforms& u) {
    float R = 0.73 * u.size;
    float2 p = q / R;
    float2 o = outline(atan2(p.y, p.x + 1e-6), th, m, u);
    // One cell is half a point, the density the study shows at 2x, so the grain looks
    // the same on every screen scale.
    return floor(p / o.x * R * (u.resolution.y / u.scale) / u.grainSize);
}

static float3 grain(float3 col, float2 c, constant SedaUniforms& u) {
    c += float2(u.grainSeed * 71.3, u.grainSeed * 19.7);
    float redDark = hash(c + float2(0., 1031.)) < 0.5 ? hash(c + float2(0., 2063.)) * 10. : 0.;
    float greenDark = hash(c + float2(0., 3089.)) * 27.;
    float greenLight = hash(c + float2(0., 4111.)) * 16.;
    float blueLight = hash(c + float2(0., 5147.)) < 0.5 ? hash(c + float2(0., 6173.)) * 10. : 0.;
    col *= float3(1. - u.grain * redDark / 255., 1. - u.grain * greenDark / 255., 1.);
    col += u.grain * float3(0., greenLight, blueLight) / 255.;
    return clamp(col, 0., 1.);
}

// Grain as a grey layer over the pigment, in the blend modes of an image editor, so the
// modes can be compared side by side. 1 multiply, 2 screen, 3 overlay, 4 soft light,
// 5 linear light, 6 colour burn, 7 colour dodge.
static float3 blendGrain(float3 col, float2 c, constant SedaUniforms& u) {
    c += float2(u.grainSeed * 71.3, u.grainSeed * 19.7);
    float3 g = float3(hash(c + float2(0., 911.)));
    int mode = int(u.grainMode + 0.5);
    float3 b = col;
    if (mode == 1) b = col * g;
    else if (mode == 2) b = 1. - (1. - col) * (1. - g);
    else if (mode == 3) b = mix(2. * col * g, 1. - 2. * (1. - col) * (1. - g), step(0.5, col));
    else if (mode == 4) b = (1. - 2. * g) * col * col + 2. * g * col;
    else if (mode == 5) b = col + 2. * g - 1.;
    else if (mode == 6) b = 1. - (1. - col) / max(g, 1e-3);
    else if (mode == 7) b = col / max(1. - g, 1e-3);
    return clamp(mix(col, clamp(b, 0., 1.), u.grainMix), 0., 1.);
}

static float grainEdge(float a, float2 c, constant SedaUniforms& u) {
    c += float2(u.grainSeed * 71.3, u.grainSeed * 19.7);
    return clamp(a + (hash(c + float2(0., 7187.)) - 0.5) * u.grain * a * (1. - a), 0., 1.);
}

fragment float4 sedaFragment(SedaVertexOut in [[stage_in]], constant SedaUniforms& u [[buffer(0)]]) {
    // Metal counts rows from the top; the study counts them from the bottom.
    float2 frag = float2(in.position.x, u.resolution.y - in.position.y);
    float2 q = (frag - 0.5 * u.resolution) / (0.5 * u.resolution.y);
    float px = 2. / u.resolution.y;
    float th = TAU * u.theta;
    float v = u.level;
    float m = v * u.motion * u.react;
    float light = mix(0.78 + 0.22 * v, 1., u.motion);
    float2 o = orb(q, th, m, light, px, u);
    float3 pigment = palette(o.x, u);
    float3 col = u.background.rgb;
    float2 cell = grainCell(q, th, m, u);
    float3 grained = u.grainMode < 0.5 ? grain(pigment, cell, u) : blendGrain(pigment, cell, u);
    col = mix(col, grained, grainEdge(o.y, cell, u));
    return float4(col, 1.);
}
