#include <metal_stdlib>
using namespace metal;

// A two-voice metaball fluid for the voice orb. Cool droplets pulse and wave with
// the model's speech (biased top-left), warm droplets with yours (bottom-right).
// The droplets orbit, ripple with audio, merge like liquid, and glint. Driven by
// SwiftUI's `.colorEffect`, so the first two arguments are the pixel position and
// the (ignored) source color; the rest are supplied from the view.
[[ stitchable ]] half4 voiceOrb(float2 position, half4 currentColor,
                                float size, float time,
                                float userLevel, float modelLevel) {
    float2 uv = position / size;          // 0...1
    float2 p = uv * 2.0 - 1.0;            // -1...1, centered
    float dist = length(p);
    if (dist > 1.05) {
        return half4(0.0);
    }

    const int count = 14;
    const float idle = 0.14;
    const float3 cool = float3(0.20, 0.55, 1.0);
    const float3 warm = float3(1.0, 0.42, 0.28);

    float field = 0.0;
    float3 tint = float3(0.0);
    float weight = 0.0;

    for (int i = 0; i < count; i++) {
        float fi = float(i);
        bool isModel = (i % 2) == 0;
        float level = max(idle, isModel ? modelLevel : userLevel);
        float lobe = isModel ? 3.9269908 : 0.7853982;   // 5pi/4 (top-left) vs pi/4 (bottom-right)

        float angle = fi / float(count) * 6.2831853 + time * 0.22;
        float orbit = 0.28 + 0.16 * sin(time * 0.55 + fi * 1.7);
        float2 c = float2(cos(angle), sin(angle)) * orbit;
        c += float2(cos(lobe), sin(lobe)) * (0.12 + 0.42 * level);
        c += 0.10 * level * float2(sin(time * 2.7 + fi), cos(time * 2.3 + fi * 1.3));

        float r = 0.15 + 0.08 * level;
        float2 d = p - c;
        float contrib = (r * r) / (dot(d, d) + 0.0009);
        field += contrib;
        tint += (isModel ? cool : warm) * contrib;
        weight += contrib;
    }

    float mass = smoothstep(0.85, 1.25, field);
    if (mass <= 0.0) {
        return half4(0.0);
    }

    float3 color = tint / max(weight, 0.0001);

    // Gloss: whiten the dense cores and add a soft top-left specular glint.
    float core = clamp((field - 1.1) * 0.6, 0.0, 1.0);
    float2 lightDir = normalize(float2(-0.55, -0.7));
    float2 normal = normalize(p + float2(0.0001, 0.0001));
    float spec = pow(max(0.0, dot(normal, -lightDir)), 3.0);
    color = mix(color, float3(1.0), core * 0.55 + spec * 0.25);

    float edge = smoothstep(1.05, 0.85, dist);
    float alpha = mass * edge;
    return half4(half3(color) * half(alpha), half(alpha));   // premultiplied
}
