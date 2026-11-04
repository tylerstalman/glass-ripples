#include <metal_stdlib>
using namespace metal;

struct Vertex { float4 position [[position]]; float2 uv; };
struct Wave { float4 originAge; float4 end; float4 curve; };
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
    bool lowStrength = u.style.y < 0.5f;
    float travel = lowStrength ? 0.55f : 1.0f;
    // Colored reflections read more strongly than clear refraction.
    float strength = (lowStrength ? 0.62f : u.style.y) * (u.style.z < 0.5f ? 1.08f : 0.65f);
    float2 point = v.uv * size;
    float2 displacement = 0;
    float coverage = 0;
    float lighting = 0;
    float sunsetCrest = 0;
    float sunsetTrough = 0;
    float wakeCoverage = 0;
    float2 wakeBend = 0;
    float wakeLight = 0;
    float wakeWeight = 0;
    for (uint i = 0; i < uint(u.header.z); ++i) {
        float4 r = u.ripples[i].originAge;
        bool wake = r.w > 0.5f;
        float age = r.z;
        float2 origin = r.xy;
        if (wake) {
            float2 tip = u.ripples[i].end.xy;
            float dragActivation = u.ripples[i].curve.z;
            if (dragActivation <= 0) continue;
            float2 start = u.ripples[i].curve.xy;
            float2 finish = (origin + tip) * 0.5f;
            // Integrate overlapping smooth kernels along the curve. A nearest
            // point solver can jump between roots on a bend, making hard seams.
            for (uint sample = 0; sample < 8; ++sample) {
            float t = (float(sample) + 0.5f) / 8.0f;
            float2 nearest = mix(mix(start, origin, t), mix(origin, finish, t), t);
            float2 derivative = 2 * mix(origin - start, finish - origin, t);
            float2 tangent = derivative / max(length(derivative), 0.001f);
            float2 side = float2(-tangent.y, tangent.x);
            float2 delta = point - nearest;
            float lateral = dot(delta, side);
            float axial = dot(delta, tangent);
            // Elliptical caps round both ends rather than multiplying two
            // rectangular masks. Older portions fan out into a broad wake.
            float distance = sqrt(lateral * lateral + axial * axial * 0.5f + 0.01f);
            float2 normal = (side * lateral + tangent * axial * 0.5f) / distance;
            float longitudinalFade = 1;
            float pixelFootprint = max(length(dfdx(point)), length(dfdy(point)));
            float width = sqrt(pow((16 + age * 32 * travel) * scale, 2.0f)
                             + pixelFootprint * pixelFootprint);
            float q = distance / width;
            float channel = exp(-q * q * 0.5f);
            float life = smoothstep(0.0f, 0.02f, age) * (1 - smoothstep(0.20f, 1.2f, age));
            float edgeRadius = (18 + age * 100 * travel) * scale;
            float edgeWidth = sqrt(pow((13 + age * 10) * scale, 2.0f)
                                 + pixelFootprint * pixelFootprint);
            float edgeX = (distance - edgeRadius) / edgeWidth;
            float edge = exp(-edgeX * edgeX * 0.5f);
            float influence = max(channel * 0.8f, edge) * life * longitudinalFade * dragActivation;
            float weight = influence * influence;
            float slope = (q * channel * 1.15f - edgeX * edge * 1.8f) * life * longitudinalFade;
            wakeCoverage = max(wakeCoverage, influence);
            wakeBend += normal * slope * weight;
            wakeLight += slope * dot(normal, normalize(float2(-0.6f, -0.8f))) * weight;
            wakeWeight += weight;
            }
            continue;
        }
        float2 delta = point - origin;
        float distance = length(delta);
        float2 direction = delta / max(distance, 0.001f);
        float radius = (18 + age * 290 * travel) * scale;
        float width = (13 + age * 8) * scale;
        float x = (distance - radius) / width;
        // A damped packet: a glassy crest followed by two softer waves.
        float envelope = exp(-x*x*0.22f);
        float life = smoothstep(0.0f, 0.07f, age) * (1 - smoothstep(0.8f, 1.65f, age));
        float slope = sin(x * (lowStrength ? 1.8f : 2.9f)) * envelope * life;
        displacement += direction * slope * 4 * u.header.w;
        coverage = max(coverage, envelope * life);
        float light = dot(direction, normalize(float2(-0.6f, -0.8f)));
        lighting += slope * light * 0.035f + pow(max(0.0f, slope * light), 5.0f) * 0.05f;
        sunsetCrest = max(sunsetCrest, max(slope * light, 0.0f));
        sunsetTrough = max(sunsetTrough, max(-slope * light, 0.0f));
    }
    wakeBend /= max(wakeWeight, 0.00001f);
    wakeLight /= max(wakeWeight, 0.00001f);
    displacement += wakeBend * 7 * u.header.w;
    coverage = max(coverage, wakeCoverage * 0.9f);
    lighting += wakeLight * 0.065f;
    sunsetCrest = max(sunsetCrest, max(wakeLight, 0.0f));
    sunsetTrough = max(sunsetTrough, max(-wakeLight, 0.0f));
    float alpha = smoothstep(0.005f, 0.22f, coverage)
                * (lowStrength ? 0.42f : min(0.9f, 0.65f * strength));
    if (alpha < 0.001f) return float4(0);
    displacement *= strength;
    float length = metal::length(displacement);
    displacement *= min(1.0f, 7.0f * strength / max(length, 0.001f));
    float2 offset = displacement / size;
    // Wavelength-dependent sampling produces actual color separation of the
    // captured background, rather than a rainbow painted over a white ring.
    bool prism = u.style.z > 0.5f && u.style.z < 1.5f;
    float dispersion = prism ? 1.15f : 0.28f;
    float3 centerColor = desktop.sample(s, v.uv + offset).rgb;
    float3 refracted = float3(desktop.sample(s, v.uv + offset * (1 + dispersion)).r,
                              centerColor.g,
                              desktop.sample(s, v.uv + offset * (1 - dispersion)).b);
    if (prism) {
        // Thin-film-style interference follows the bent surface, with a slow
        // spectral drift so the highlights flow through magenta, cyan and gold.
        float phase = dot(displacement, float2(0.045f, -0.035f))
                    + dot(v.uv, float2(0.8f, 0.65f)) + u.style.w * 0.06f;
        float3 film = 0.5f + 0.5f * cos(6.283185f * (phase + float3(0, 0.3333f, 0.6667f)));
        float crest = saturate(sunsetCrest + sunsetTrough);
        refracted = mix(centerColor, refracted, 0.8f);
        refracted = mix(refracted, film, saturate((crest * 0.48f + coverage * 0.12f) * strength));
        refracted += film * crest * 0.10f * strength;
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
        refracted = mix(refracted, reflection * 0.18f, saturate(sunsetTrough * 0.22f * strength));
        refracted = mix(refracted, reflection, saturate(sunsetCrest * 0.60f * strength));
        refracted += reflection * sunsetCrest * 0.045f * strength;
    } else if (u.style.z > 1.5f) {
        // Sunset reflections: amber/coral crests above deep teal troughs.
        // Preserve the refracted desktop between those moving highlights.
        refracted = mix(refracted, float3(0.025f, 0.18f, 0.23f), saturate(sunsetTrough * 0.20f * strength));
        refracted += float3(0.26f, 0.105f, -0.035f) * sunsetCrest * strength;
    }
    refracted = clamp(refracted + lighting * coverage * strength, 0.0f, 1.0f);
    return float4(refracted * alpha, alpha); // Premultiplied alpha.
}
