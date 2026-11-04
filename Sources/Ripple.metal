#include <metal_stdlib>
using namespace metal;

struct Vertex { float4 position [[position]]; float2 uv; };
struct Wave { float4 originAge; float4 end; };
struct Uniforms { float4 header; Wave ripples[24]; };

vertex Vertex fullscreen(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2, id & 2);
    return {float4(p.x * 2 - 1, 1 - p.y * 2, 0, 1), p};
}

fragment float4 liquid(Vertex v [[stage_in]],
                       texture2d<float> desktop [[texture(0)]],
                       constant Uniforms& u [[buffer(0)]]) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 size = u.header.xy;
    float2 point = v.uv * size;
    float2 displacement = 0;
    float coverage = 0;
    float lighting = 0;
    for (uint i = 0; i < uint(u.header.z); ++i) {
        float4 r = u.ripples[i].originAge;
        bool wake = r.w > 0.5f;
        float age = r.z;
        float2 origin = r.xy;
        if (wake) {
            float2 segment = u.ripples[i].end.xy - origin;
            float along = saturate(dot(point - origin, segment) / max(dot(segment, segment), 0.001f));
            origin += along * segment;
        }
        float2 delta = point - origin;
        float distance = length(delta);
        float2 direction = delta / max(distance, 0.001f);
        float radius = wake ? 3 + age * 65 : 18 + age * 290;
        float width = wake ? 10 + age * 10 : 13 + age * 8;
        float x = (distance - radius) / width;
        // A damped packet: a glassy crest followed by two softer waves.
        float envelope = exp(-x*x*0.22f);
        float life = wake
            ? smoothstep(0.0f, 0.015f, age) * (1 - smoothstep(0.12f, 0.75f, age)) * 0.45f
            : smoothstep(0.0f, 0.07f, age) * (1 - smoothstep(0.8f, 1.65f, age));
        float slope = sin(x * 2.9f) * envelope * life;
        displacement += direction * slope * 4 * u.header.w;
        coverage = max(coverage, envelope * life);
        float light = dot(direction, normalize(float2(-0.6f, -0.8f)));
        lighting += slope * light * 0.035f + pow(max(0.0f, slope * light), 5.0f) * 0.05f;
    }
    float alpha = smoothstep(0.005f, 0.22f, coverage) * 0.65f;
    if (alpha < 0.001f) return float4(0);
    float length = metal::length(displacement);
    displacement *= min(1.0f, 7.0f / max(length, 0.001f));
    float2 offset = displacement / size;
    // Wavelength-dependent sampling produces actual color separation of the
    // captured background, rather than a rainbow painted over a white ring.
    float3 refracted = float3(desktop.sample(s, v.uv + offset * 1.28f).r,
                              desktop.sample(s, v.uv + offset).g,
                              desktop.sample(s, v.uv + offset * 0.72f).b);
    refracted = clamp(refracted + lighting * coverage, 0.0f, 1.0f);
    return float4(refracted * alpha, alpha); // Premultiplied alpha.
}
