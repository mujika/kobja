#include <metal_stdlib>
using namespace metal;

struct VisualUniforms {
    float2 resolution;
    float time;
    float seed;
    float level;
    float low;
    float mid;
    float high;
    float centroid;
    float flux;
    float beat;
    float3 baseColor;
    float3 accentColor;
};

struct VSOut { float4 pos [[position]]; float2 uv; };

vertex VSOut fullScreenVertex(uint vid [[vertex_id]], constant VisualUniforms& u [[buffer(0)]]) {
    float2 pos;
    if (vid == 0) pos = float2(-1.0, -1.0);
    else if (vid == 1) pos = float2( 3.0, -1.0);
    else pos = float2(-1.0, 3.0);
    VSOut o; o.pos = float4(pos, 0, 1);
    // uv in 0..1
    o.uv = (pos * 0.5 + 0.5);
    return o;
}

float hash11(float n) {
    return fract(sin(n) * 43758.5453123);
}

float2 rot(float2 p, float a) {
    float s = sin(a), c = cos(a);
    return float2(c*p.x - s*p.y, s*p.x + c*p.y);
}

float linstep(float a, float b, float x){ return clamp((x - a)/(b - a), 0.0, 1.0); }

// Neon kaleidoscope + rings + noise glow
fragment float4 kaleidoFragment(VSOut in [[stage_in]], constant VisualUniforms& u [[buffer(0)]]) {
    float2 R = u.resolution;
    float2 uv = (in.uv * 2.0 - 1.0);
    uv.x *= R.x / max(R.x, R.y);
    uv.y *= R.y / max(R.x, R.y);

    float t = u.time;
    float amp = clamp(u.level*1.2 + u.mid*0.6 + u.flux*0.6, 0.0, 1.8);
    float beatKick = smoothstep(0.0, 1.0, u.beat) * 0.7;

    // Kaleidoscope segments driven by high band
    int seg = 6 + int(floor(clamp(u.high * 8.0 + 2.0, 0.0, 12.0)));
    float a = atan2(uv.y, uv.x);
    float r = length(uv);
    float segAngle = 6.2831853 / float(seg);
    a = fmod(abs(a), segAngle);
    a = abs(a - 0.5*segAngle);
    float2 p = float2(cos(a), sin(a)) * r;
    p = rot(p, 0.05 * t + 0.2 * (u.low - u.high));

    // Radial rings with dispersion
    float ringFreq = 18.0 + 24.0*(u.high + 0.1) + 8.0*hash11(u.seed);
    float ring = 0.5 + 0.5*cos(r * ringFreq - t*3.0*(0.6+u.mid) + 6.2831*hash11(u.seed+7.0));
    float ring2 = 0.5 + 0.5*cos(r * (ringFreq*0.5) - t*1.6 + 4.0*u.low);
    float rings = pow(smoothstep(0.4, 1.0, ring) * (0.8 + 0.2*ring2), 1.3);

    // Flow distort from centroid & flux
    float wob = 0.02 + 0.12*amp;
    float2 q = p;
    q += wob * float2(sin(3.0*q.y + t*1.2), cos(3.0*q.x - t*1.0));
    q += wob * 0.5 * float2(sin(6.0*q.y - t*1.7), cos(6.0*q.x + t*1.3));

    // Neon burst by angle
    float glow = exp(-2.5*length(q)) * (0.6 + 0.6*amp) + rings * (0.8 + 1.2*amp);
    glow += beatKick * 0.6;

    float3 base = mix(u.baseColor, u.accentColor, 0.4 + 0.6*smoothstep(0.0, 1.0, u.centroid/4000.0));
    float3 col = base * (0.3 + 0.7 * rings) + u.accentColor * glow;

    // Fake bloom by soft threshold and power curve
    float luma = dot(col, float3(0.299,0.587,0.114));
    float bloom = smoothstep(0.6, 1.2, luma) * (0.8 + 0.4*amp);
    col += bloom * (0.6 * u.accentColor + 0.2);
    col = pow(col, float3(1.0/1.8));

    return float4(col, 1.0);
}

// Mirror wall uniforms must match MirrorUniforms in Swift
struct MirrorUniforms {
    float2 resolution;
    float time;
    float seed;
    float level;
    float low;
    float mid;
    float high;
    float flux;
    float beat;
    float cols;
    float rows;
    float seamWidth;
    float seamBright;
    float curveAmt;
    float noiseAmp;
    float noiseSpeed;
};

float hash21(float2 p) {
    p = fract(p*float2(123.34, 456.21));
    p += dot(p, p+45.32);
    return fract(p.x*p.y);
}

// Simple analytic noise from sines (cheap)
float noise2(float2 p) {
    return 0.5 + 0.5 * (sin(p.x) * sin(p.y));
}

fragment float4 mirrorFragment(VSOut in [[stage_in]],
                               constant MirrorUniforms& u [[buffer(0)]],
                               texture2d<float> camTex [[texture(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 uv = in.uv;
    float2 grid = float2(max(1.0,u.cols), max(1.0,u.rows));
    float2 suv = uv * grid;
    float2 cell = floor(suv);
    float2 fuv = fract(suv); // 0..1 inside tile

    // Tile center-based warp (mild barrel/ pincushion)
    float2 p = fuv - 0.5;
    float r = length(p);
    float k = u.curveAmt;
    float2 warp = p * (k * r*r);
    float n = noise2(p*18.0 + u.time*u.noiseSpeed*2.0);
    warp += (n-0.5) * u.noiseAmp;

    float2 srcUV = (cell + (fuv + warp)) / grid;
    float4 col = float4(0.0,0.0,0.0,1.0);
    if (camTex.get_width() > 0) {
        col = camTex.sample(s, clamp(srcUV, 0.0, 1.0));
    }

    // Vertical & optional horizontal seams
    float seamX = min(fuv.x, 1.0 - fuv.x);
    float seamY = min(fuv.y, 1.0 - fuv.y);
    float w = max(0.0005, u.seamWidth);
    float ax = smoothstep(w, 0.0, seamX);
    float ay = smoothstep(w, 0.0, seamY);
    // combine seams: keep vertical dominant, but use a fraction of horizontal
    float seam = max(ax, ay * 0.6);
    float seamHL = pow(seam, 2.0) * u.seamBright;
    col.rgb += seamHL;

    // Subtle gamma and exposure
    col.rgb = pow(col.rgb, float3(1.0/1.2));
    return float4(col.rgb, 1.0);
}
