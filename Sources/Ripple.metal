#include <metal_stdlib>
using namespace metal;

struct Vertex { float4 position [[position]]; float2 uv; };
struct Wave { float4 originAge; float4 end; };
struct Uniforms { float4 header; float4 style; Wave ripples[24]; };

vertex Vertex fullscreen(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2, id & 2);
    return {float4(p.x * 2 - 1, 1 - p.y * 2, 0, 1), p};
}

fragment float4 liquid(Vertex v [[stage_in]],
                       texture2d<float> desktop [[texture(0)]],
                       constant Uniforms& u [[buffer(0)]]) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 size = u.header.xy;
    float scale = u.style.x;
    float2 point = v.uv * size;
    float2 displacement = 0;
    float coverage = 0;
    float lighting = 0;
    float sunsetCrest = 0;
    float sunsetTrough = 0;
    float wakeCoverage = 0;
    float2 wakeBend = 0;
    float wakeLight = 0;
    for (uint i = 0; i < uint(u.header.z); ++i) {
        float4 r = u.ripples[i].originAge;
        bool wake = r.w > 0.5f;
        float age = r.z;
        float2 origin = r.xy;
        if (wake) {
            float2 segment = u.ripples[i].end.xy - origin;
            float along = saturate(dot(point - origin, segment) / max(dot(segment, segment), 0.001f));
            origin += along * segment;
            float2 delta = point - origin;
            float distance = length(delta);
            float2 normal = delta / max(distance, 0.001f);
            float width = (22 + age * 14) * scale;
            float q = distance / width;
            float envelope = exp(-q * q * 0.5f);
            float life = smoothstep(0.0f, 0.02f, age) * (1 - smoothstep(0.12f, 0.75f, age));
            float waveRadius = (14 + age * 120) * scale;
            float waveWidth = (12 + age * 8) * scale;
            float waveX = (distance - waveRadius) / waveWidth;
            float waveEnvelope = exp(-waveX * waveX * 0.5f);
            float influence = max(envelope * 0.6f, waveEnvelope) * life;
            // A shared distance field joins the finger's path into a channel.
            // Selecting its strongest influence avoids stacked rings at joints.
            if (influence > wakeCoverage) {
                wakeCoverage = influence;
                float slope = (q * envelope * 0.8f
                               + sin(waveX * 2.3f) * waveEnvelope * 1.1f) * life;
                wakeBend = normal * slope;
                wakeLight = slope * dot(normal, normalize(float2(-0.6f, -0.8f)));
            }
            continue;
        }
        float2 delta = point - origin;
        float distance = length(delta);
        float2 direction = delta / max(distance, 0.001f);
        float radius = (18 + age * 290) * scale;
        float width = (13 + age * 8) * scale;
        float x = (distance - radius) / width;
        // A damped packet: a glassy crest followed by two softer waves.
        float envelope = exp(-x*x*0.22f);
        float life = smoothstep(0.0f, 0.07f, age) * (1 - smoothstep(0.8f, 1.65f, age));
        float slope = sin(x * 2.9f) * envelope * life;
        displacement += direction * slope * 4 * u.header.w;
        coverage = max(coverage, envelope * life);
        float light = dot(direction, normalize(float2(-0.6f, -0.8f)));
        lighting += slope * light * 0.035f + pow(max(0.0f, slope * light), 5.0f) * 0.05f;
        sunsetCrest = max(sunsetCrest, max(slope * light, 0.0f));
        sunsetTrough = max(sunsetTrough, max(-slope * light, 0.0f));
    }
    displacement += wakeBend * 7 * u.header.w;
    coverage = max(coverage, wakeCoverage * 0.9f);
    lighting += wakeLight * 0.065f;
    sunsetCrest = max(sunsetCrest, max(wakeLight, 0.0f));
    sunsetTrough = max(sunsetTrough, max(-wakeLight, 0.0f));
    float alpha = smoothstep(0.005f, 0.22f, coverage) * 0.65f;
    if (alpha < 0.001f) return float4(0);
    float length = metal::length(displacement);
    displacement *= min(1.0f, 7.0f / max(length, 0.001f));
    float2 offset = displacement / size;
    // Wavelength-dependent sampling produces actual color separation of the
    // captured background, rather than a rainbow painted over a white ring.
    bool prism = u.style.z > 0.5f && u.style.z < 1.5f;
    float dispersion = prism ? 0.5f : 0.28f;
    float3 centerColor = desktop.sample(s, v.uv + offset).rgb;
    float3 refracted = float3(desktop.sample(s, v.uv + offset * (1 + dispersion)).r,
                              centerColor.g,
                              desktop.sample(s, v.uv + offset * (1 - dispersion)).b);
    if (prism) {
        // Limit the introduced fringe, retaining the desktop's own palette.
        float3 fringe = clamp((refracted - centerColor) * 0.65f, -0.10f, 0.10f);
        refracted = centerColor + fringe;
    }
    if (u.style.z > 2.5f) {
        constexpr float3 colors[6] = {
            float3(98, 187, 71) / 255.0f,
            float3(252, 184, 39) / 255.0f,
            float3(246, 130, 31) / 255.0f,
            float3(224, 58, 62) / 255.0f,
            float3(150, 61, 151) / 255.0f,
            float3(0, 157, 220) / 255.0f
        };
        // Smooth reflections use the six reference colors without hard bands.
        float phase = fract(v.uv.y * 0.65f + v.uv.x * 0.35f + u.style.w * 0.02f) * 6;
        uint index = uint(phase);
        float3 reflection = mix(colors[index], colors[(index + 1) % 6],
                                smoothstep(0.0f, 1.0f, fract(phase)));
        refracted = mix(refracted, reflection * 0.18f, sunsetTrough * 0.22f);
        refracted = mix(refracted, reflection, sunsetCrest * 0.60f);
        refracted += reflection * sunsetCrest * 0.045f;
    } else if (u.style.z > 1.5f) {
        // Sunset reflections: amber/coral crests above deep teal troughs.
        // Preserve the refracted desktop between those moving highlights.
        refracted = mix(refracted, float3(0.025f, 0.18f, 0.23f), sunsetTrough * 0.20f);
        refracted += float3(0.26f, 0.105f, -0.035f) * sunsetCrest;
    }
    refracted = clamp(refracted + lighting * coverage, 0.0f, 1.0f);
    return float4(refracted * alpha, alpha); // Premultiplied alpha.
}
