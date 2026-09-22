#include <metal_stdlib>
using namespace metal;

struct VertexOutput {
    float4 position [[position]];
};

struct Uniforms {
    float2 viewportSize;
    float phase;
    float padding;
};

vertex VertexOutput noiseVertex(uint vertexID [[vertex_id]]) {
    const float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };
    VertexOutput output;
    output.position = float4(positions[vertexID], 0.0, 1.0);
    return output;
}

float hashValue(int2 point, uint seed) {
    uint value = uint(point.x) * 0x1F123BB5u;
    value ^= uint(point.y) * 0x5F356495u;
    value ^= seed * 0x9E3779B9u;
    value ^= value >> 16;
    value *= 0x7FEB352Du;
    value ^= value >> 15;
    value *= 0x846CA68Bu;
    value ^= value >> 16;
    return float(value) / 4294967295.0;
}

float valueNoise(float2 point, uint seed) {
    int2 cell = int2(floor(point));
    float2 fraction = fract(point);
    fraction = fraction * fraction * (3.0 - 2.0 * fraction);

    float top = mix(
        hashValue(cell, seed),
        hashValue(cell + int2(1, 0), seed),
        fraction.x
    );
    float bottom = mix(
        hashValue(cell + int2(0, 1), seed),
        hashValue(cell + int2(1, 1), seed),
        fraction.x
    );
    return mix(top, bottom, fraction.y);
}

float srgbToLinear(float value) {
    return value <= 0.04045
        ? value / 12.92
        : pow((value + 0.055) / 1.055, 2.4);
}

float3 srgbToLinear(float3 value) {
    return float3(
        srgbToLinear(value.r),
        srgbToLinear(value.g),
        srgbToLinear(value.b)
    );
}

fragment float4 noiseFragment(
    VertexOutput input [[stage_in]],
    constant Uniforms &uniforms [[buffer(0)]]
) {
    constexpr uint broadSeed = 0x1F123BB5u;
    constexpr uint detailSeed = 0xA53A9E31u;
    const float cellSize = max(1.0, uniforms.viewportSize.x * (70.0 / 410.0));
    const float2 cell = floor(input.position.xy / cellSize);
    const float phase = uniforms.phase;

    const float broad = valueNoise(
        cell * 0.19 + float2(17.3, -8.1) + phase * float2(0.90, 0.35),
        broadSeed
    );
    const float detail = valueNoise(
        cell * 0.43 + float2(-5.2, 11.7) + phase * float2(-1.40, 0.60),
        detailSeed
    );
    const float tone = broad * 0.74 + detail * 0.26;
    const float greenByte = clamp(128.655 + (tone - 0.5) * 195.0, 48.0, 194.0);

    const int2 grainCell = int2(input.position.xy) & 63;
    const float redDark = hashValue(grainCell, 0xD17E3A91u) < 0.5
        ? hashValue(grainCell, 0x4C6B2F05u) * 10.0
        : 0.0;
    const float greenDark = hashValue(grainCell, 0x91D17E3Au) * 27.0;
    const float greenLight = hashValue(grainCell, 0x2F054C6Bu) * 16.0;
    const float blueLight = hashValue(grainCell, 0x3A9191D1u) < 0.5
        ? hashValue(grainCell, 0x6B2F054Cu) * 10.0
        : 0.0;

    float3 color = float3(1.0, greenByte / 255.0, 0.0);
    color *= float3(
        1.0 - redDark / 255.0,
        1.0 - greenDark / 255.0,
        1.0
    );
    color += float3(0.0, greenLight / 255.0, blueLight / 255.0);
    color = clamp(color, 0.0, 1.0);
    return float4(srgbToLinear(color), 1.0);
}
