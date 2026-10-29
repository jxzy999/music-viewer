#include <metal_stdlib>
using namespace metal;
struct Vertex { float3 position; float2 uv; float4 color; };
struct Frame { float4x4 mvp; float4 options; };
struct PaperLight { float4 positionRadius; float4 color; };
struct Raster { float4 position [[position]]; float2 uv; float4 color; float2 worldXY; };
vertex Raster score_vertex(const device Vertex *vertices [[buffer(0)]], constant Frame &frame [[buffer(1)]], uint id [[vertex_id]]) {
    Raster out; out.position = frame.mvp * float4(vertices[id].position, 1); out.uv = vertices[id].uv; out.color = vertices[id].color; out.worldXY = vertices[id].position.xy; return out;
}
fragment float4 paper_fragment(Raster in [[stage_in]], texture2d<float> page [[texture(0)]], constant Frame &frame [[buffer(1)]], constant PaperLight *lights [[buffer(2)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 ink = page.sample(s, in.uv).rgb;
    float cinematic = frame.options.x;
    float grain = fract(sin(dot(in.uv * 4000, float2(12.9898,78.233))) * 43758.5453) * 0.012;
    float light = 0.91 + 0.08 * exp(-3 * dot(in.uv - float2(0.5, 0.4), in.uv - float2(0.5,0.4)));
    float3 illumination = float3(light * 0.64);
    if (cinematic > 0.5) {
        for (uint i = 0; i < uint(frame.options.y); ++i) {
            float2 d = (in.worldXY - lights[i].positionRadius.xy) / lights[i].positionRadius.z;
            float pool = exp(-3 * dot(d,d)) * lights[i].color.a;
            illumination += mix(float3(1), lights[i].color.rgb, 0.25) * pool * 0.42;
        }
    }
    float3 paper = mix(float3(0.985), float3(0.88,0.84,0.75) * min(illumination, float3(1.12)) + grain, cinematic);
    return float4(mix(float3(0.055,0.08,0.10), paper, saturate(dot(ink,float3(0.2126,0.7152,0.0722)))), 1);
}
fragment float4 glow_fragment(Raster in [[stage_in]]) {
    float r = length(in.uv * 2 - 1);
    float alpha = exp(-5 * r * r) * smoothstep(1.0,0.65,r);
    float core = exp(-32 * r * r);
    return float4(mix(in.color.rgb, float3(1), core * 0.65), alpha * in.color.a);
}
fragment float4 line_fragment(Raster in [[stage_in]]) {
    float d = abs(in.uv.x * 2 - 1);
    float alpha = exp(-5 * d * d) * smoothstep(1.0,0.72,d);
    return float4(mix(in.color.rgb, float3(1), exp(-24 * d * d) * 0.3), in.color.a * alpha);
}
