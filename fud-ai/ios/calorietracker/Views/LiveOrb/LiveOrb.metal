#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// The live Coach orb: a holographic sphere of rings, glowing filaments and sparks
// around a bright core, which swells with the voice. Drawn per pixel through
// SwiftUI's colorEffect; coordinates below are in units of the orb's radius.

namespace liveorb {

float hash13(float3 p) {
    p = fract(p * 0.1031);
    p += dot(p, p.zyx + 31.32);
    return fract((p.x + p.y) * p.z);
}

float noise(float3 x) {
    float3 i = floor(x);
    float3 f = fract(x);
    float3 u = f * f * (3.0 - 2.0 * f);
    float a = hash13(i);
    float b = hash13(i + float3(1, 0, 0));
    float c = hash13(i + float3(0, 1, 0));
    float d = hash13(i + float3(1, 1, 0));
    float e = hash13(i + float3(0, 0, 1));
    float g = hash13(i + float3(1, 0, 1));
    float h = hash13(i + float3(0, 1, 1));
    float k = hash13(i + float3(1, 1, 1));
    return mix(mix(mix(a, b, u.x), mix(c, d, u.x), u.y),
               mix(mix(e, g, u.x), mix(h, k, u.x), u.y), u.z);
}

float3 rotateX(float3 p, float a) {
    float c = cos(a), s = sin(a);
    return float3(p.x, c * p.y - s * p.z, s * p.y + c * p.z);
}

float3 rotateY(float3 p, float a) {
    float c = cos(a), s = sin(a);
    return float3(c * p.x + s * p.z, p.y, -s * p.x + c * p.z);
}

/// Glow of a circle of `radius` around the centre, lying in the plane with unit
/// normal `n`. The far half is dimmer; `dashes` > 0 breaks it into segments.
float ring(float2 p, float radius, float3 n, float width, float dashes, float dashShift) {
    float rr = radius * radius - dot(p, p);
    if (rr <= 0.0) return 0.0;
    float h = sqrt(rr);
    float3 u = normalize(abs(n.y) < 0.95 ? cross(n, float3(0, 1, 0)) : cross(n, float3(1, 0, 0)));
    float3 v = cross(n, u);
    float total = 0.0;
    for (int side = 0; side < 2; side++) {
        float z = side == 0 ? h : -h;
        float3 s = float3(p, z);
        // Distance to the circle on screen: the plane's equation over its slope.
        float2 slope = n.xy - n.z * p / z;
        float d = abs(dot(s, n)) / max(length(slope), 0.05);
        float line = exp(-(d * d) / (width * width)) + 0.22 * exp(-d / (width * 5.0));
        if (dashes > 0.0) {
            float angle = atan2(dot(s, v), dot(s, u)) / (2.0 * M_PI_F) + 0.5;
            float dash = fract(angle * dashes + dashShift);
            line *= smoothstep(0.0, 0.06, dash) * smoothstep(0.78, 0.66, dash);
        }
        total += line * (side == 0 ? 1.0 : 0.3);
    }
    return total * smoothstep(0.0, 0.003, rr);
}

/// Thin glowing veins on the sphere's surface (`s` is a point on the unit sphere).
float filaments(float3 s, float flow, float energy) {
    float3 q = s * 3.0 + float3(0.0, flow * 0.35, flow * 0.2);
    float n = noise(q) * 0.62 + noise(q * 2.1 + 7.3) * 0.28 + noise(q * 4.4 - 3.1) * 0.1;
    float m = noise(q * 1.3 - 11.0 + flow * 0.15);
    float veins = pow(1.0 - abs(n * 2.0 - 1.0), mix(34.0, 24.0, energy));
    float second = pow(1.0 - abs(m * 2.0 - 1.0), mix(48.0, 32.0, energy)) * 0.45;
    return veins + second;
}

/// Sparse twinkling points on the sphere's surface.
float sparks(float3 s, float time) {
    float3 cell = floor(s * 8.0);
    float rnd = hash13(cell);
    if (rnd < 0.7) return 0.0;
    float3 local = fract(s * 8.0) - 0.5;
    float twinkle = 0.5 + 0.5 * sin(time * (1.5 + rnd * 5.0) + rnd * 40.0);
    return exp(-dot(local, local) * 90.0) * twinkle * twinkle;
}

/// A flat dashed circle around the core, like the iris of a lens.
float iris(float2 p, float radius, float width, float dashes, float shift) {
    float d = abs(length(p) - radius);
    float angle = atan2(p.y, p.x) / (2.0 * M_PI_F) + 0.5;
    float dash = fract(angle * dashes + shift);
    float gate = smoothstep(0.0, 0.05, dash) * smoothstep(0.7, 0.6, dash);
    return (exp(-(d * d) / (width * width)) + 0.2 * exp(-d / (width * 4.0))) * gate;
}

} // namespace liveorb

using namespace liveorb;

/// - size: the view's size in points.
/// - time: seconds since the orb appeared (twinkle, breathing).
/// - spin, flow: phases that advance faster while thinking or talking.
/// - level: smoothed loudness of whoever is talking, 0...1.
/// - active, thinking, speaking: how much of each mood shows, 0...1.
[[ stitchable ]] half4 liveOrb(float2 position, half4 color, float2 size, float time,
                               float spin, float flow, float level, float active,
                               float thinking, float speaking, half4 tint, float clearBackground) {
    float scale = min(size.x, size.y) * 0.5;
    float2 raw = (position - size * 0.5) / scale;

    float energy = clamp(0.22 * active + 0.9 * level + 0.3 * speaking + 0.25 * thinking, 0.0, 1.3);
    float breathe = 1.0 + 0.015 * sin(time * 1.7) * (1.0 - active * 0.5);
    float radius = 0.56 * breathe * (1.0 + 0.07 * level);
    float2 p = raw / radius;
    float r = length(p);

    float glow = 0.0;

    if (r < 1.6) {
        // Great circles on the sphere, each precessing at its own pace.
        float3 n1 = rotateY(rotateX(float3(0, 1, 0), 1.15), spin * 0.9);
        float3 n2 = rotateY(rotateX(float3(0, 0, 1), 0.85 + 0.25 * sin(spin * 0.6)), -spin * 0.55);
        float3 n3 = rotateY(rotateX(float3(0, 1, 0), 0.32), -spin * 0.7 + 1.0);
        float3 n4 = normalize(float3(cos(spin * 0.45 + 2.0), 0.45 * sin(spin * 0.45 + 2.0), 0.75));
        float w = 0.011;
        float rings = ring(p, 1.0, n1, w, 0.0, 0.0)
                    + ring(p, 1.0, n2, w, 5.0, spin * 0.2)
                    + ring(p, 1.0, n3, w * 0.8, 0.0, 0.0)
                    + ring(p, 1.0, n4, w * 0.8, 9.0, -spin * 0.3);
        glow += rings * (0.38 + 0.4 * energy);

        // Wider orbits around the sphere.
        float3 o1 = rotateY(rotateX(float3(0, 1, 0), 1.28), spin * 0.25);
        float3 o2 = rotateY(rotateX(float3(0, 1, 0), -1.05), -spin * 0.18 + 0.7);
        float orbits = ring(p, 1.22, o1, 0.009, 3.0, spin * 0.1)
                     + ring(p, 1.4, o2, 0.007, 11.0, -spin * 0.15) * 0.7;
        glow += orbits * (0.3 + 0.3 * energy);
    }

    if (r < 1.0) {
        float h = sqrt(1.0 - r * r);
        float energyLines = 0.2 + 0.5 * energy;
        for (int side = 0; side < 2; side++) {
            float3 s = float3(p, side == 0 ? h : -h);
            float3 turned = rotateY(rotateX(s, 0.45), flow * 0.4);
            float weight = side == 0 ? 1.0 : 0.32;
            glow += filaments(turned, flow, energy) * energyLines * weight;
            glow += sparks(turned, time) * (0.5 + 0.7 * energy) * weight;
        }
        // Brighter towards the rim, like the edge of a glass shell.
        glow += pow(1.0 - h, 3.0) * (0.35 + 0.15 * energy);
    }

    // The core, its lens rings, and the halo around the shell.
    float pulse = 1.0 + 0.35 * thinking * sin(time * 7.0);
    float core = exp(-r * r / (0.015 + 0.025 * energy)) * (0.65 + 0.75 * energy) * pulse;
    float lens = iris(p, 0.15 * (1.0 + 0.3 * level), 0.012, 6.0, spin * 0.5)
               + iris(p, 0.26 * (1.0 + 0.2 * level), 0.008, 14.0, -spin * 0.35) * 0.7;
    float halo = exp(-abs(r - 1.0) * 8.0) * (0.18 + 0.35 * energy)
               + exp(-max(r - 1.0, 0.0) * 2.2) * 0.08 * (0.5 + energy);
    glow += core + lens * (0.5 + 0.6 * energy) + halo;

    glow *= 0.62 + 0.38 * active;

    float3 base = float3(tint.rgb);
    float3 hot = mix(base, float3(1.0, 0.96, 0.88), 0.75);
    float3 light = base * glow + hot * glow * glow * 0.35;
    light = 1.0 - exp(-light * 1.25);

    if (clearBackground > 0.5) {
        // colorEffect uses premultiplied RGB: light already contributes its full
        // intensity. Multiplying it by alpha again would dim the filaments.
        float alpha = clamp(max(light.r, max(light.g, light.b)), 0.0, 1.0);
        return half4(half3(light), half(alpha));
    }
    float3 background = float3(0.006, 0.008, 0.014) + base * 0.035 * exp(-dot(raw, raw) * 1.4);
    return half4(half3(background + light), 1.0);
}
