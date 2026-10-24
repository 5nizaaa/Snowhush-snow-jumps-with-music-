let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 viewSize;
    float scale;
    float time;
    float columnWidth;
    int columnCount;
    float pileTop;
    int occluderCount;
    float2 origin;
    float pileBottom;
    float padding;
};

struct Sprite {
    float2 position;
    float size;
    float alpha;
    float soft;
    float tintAmount;
    float tintRed;
    float tintGreen;
    float tintBlue;
    float padding;
};

struct SpriteOut {
    float4 position [[position]];
    float pointSize [[point_size]];
    float alpha;
    float soft;
    float4 tint;
};

vertex SpriteOut spriteVertex(uint vid [[vertex_id]],
                              const device Sprite *sprites [[buffer(0)]],
                              constant Uniforms &u [[buffer(1)]]) {
    Sprite s = sprites[vid];
    float pixels = s.size * u.scale;
    SpriteOut out;
    out.position = float4(s.position / u.viewSize * 2.0 - 1.0, 0.0, 1.0);
    out.pointSize = max(pixels, 2.0);
    out.alpha = s.alpha * min(pixels / 2.0, 1.0);
    out.soft = s.soft;
    out.tint = float4(s.tintRed, s.tintGreen, s.tintBlue, s.tintAmount);
    return out;
}

fragment float4 spriteFragment(SpriteOut in [[stage_in]], float2 coord [[point_coord]]) {
    float r = length(coord - 0.5) * 2.0;
    float a = (1.0 - smoothstep(mix(0.6, 0.0, in.soft), 1.0, r)) * in.alpha;
    if (a < 0.002) discard_fragment();
    float3 core = float3(0.965, 0.975, 0.995);
    float3 rim = float3(0.62, 0.67, 0.77);
    float3 color = mix(core, rim, smoothstep(0.35, 1.0, r) * 0.65);
    color = mix(color, in.tint.rgb, in.tint.a);
    return float4(color * a, a);
}

struct PileOut {
    float4 position [[position]];
    float2 point;
};

vertex PileOut pileVertex(uint vid [[vertex_id]], constant Uniforms &u [[buffer(0)]]) {
    float2 corner = float2(float(vid & 1), float(vid >> 1));
    float2 p = float2(corner.x * float(u.columnCount) * u.columnWidth, mix(u.pileBottom, u.pileTop, corner.y));
    PileOut out;
    out.position = float4((p + u.origin) / u.viewSize * 2.0 - 1.0, 0.0, 1.0);
    out.point = p;
    return out;
}

static float heightAt(const device float *h, constant Uniforms &u, float x) {
    float f = x / u.columnWidth - 0.5;
    float base = floor(f);
    int i = clamp(int(base), 0, u.columnCount - 1);
    int j = min(i + 1, u.columnCount - 1);
    return mix(h[i], h[j], saturate(f - base));
}

static float hash(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

fragment float4 pileFragment(PileOut in [[stage_in]],
                             const device float *heights [[buffer(0)]],
                             constant Uniforms &u [[buffer(1)]],
                             constant float4 *occluders [[buffer(2)]]) {
    float2 world = in.point + u.origin;
    for (int k = 0; k < u.occluderCount; k++) {
        float4 o = occluders[k];
        if (world.x >= o.x && world.x < o.z && world.y >= o.y && world.y < o.w) discard_fragment();
    }

    float x = in.point.x;
    float level = heightAt(heights, u, x);
    float bed = heightAt(heights + u.columnCount, u, x);
    float depth = level - in.point.y;
    float coverage = saturate(depth * u.scale + 0.5)
        * saturate((in.point.y - bed) * u.scale + 0.5)
        * saturate((level - bed) / 0.75);
    if (coverage <= 0.0) discard_fragment();

    float slope = (heightAt(heights, u, x + 2.0) - heightAt(heights, u, x - 2.0)) * 0.25;
    float light = dot(normalize(float2(-slope, 1.0)), normalize(float2(-0.5, 1.0)));

    float3 surface = float3(0.925, 0.94, 0.965);
    float3 shadow = float3(0.72, 0.78, 0.88);
    float shade = (1.0 - exp(-depth / 30.0)) * 0.32 + (1.0 - light) * 0.6 * exp(-depth / 5.0);
    float3 color = mix(surface, shadow, saturate(shade));
    color = mix(color, float3(0.975, 0.982, 0.995), exp(-depth * 0.9) * 0.6);
    color += (hash(floor(in.position.xy)) - 0.5) * 0.02;

    float seed = hash(floor(in.position.xy * 0.5) + 31.7);
    if (seed > 0.992) {
        float twinkle = pow(saturate(sin(u.time * (0.6 + seed * 1.8) + seed * 90.0)), 28.0);
        color = mix(color, float3(1.0), twinkle * exp(-depth / 7.0));
    }

    return float4(color * coverage, coverage);
}
"""
