//
//  语音球 —— GPU 着色器（iOS 17+ 的 SwiftUI ShaderLibrary 用）
//
//  2026-10-13 用户要求「语音球我要 Siri 质感的」，这一版整个重写：
//    以前的是一颗**玻璃球**（有硬边、有折射、有高光、球心是暗的）—— 那是"玻璃"的质感。
//    Siri 那颗球完全相反：**没有轮廓、没有高光点**，是一团**会呼吸的虹彩光雾**，
//    颜色在里面慢慢流、边缘化到背景里，说话时整团涨大、变亮、边缘扭动。
//
//  所以这里做四件事：
//    ① 形状：半径按**噪声 + 时间**轻微起伏（边一直在游，永远不是正圆）；
//    ② 流动：两层域扭曲的 fBm 噪声做流场（丝滑、没有"格子味"，不是三角函数叠出来的）；
//    ③ 颜色：四个品牌锚色按流场 + 时间**环状插值**（Siri 那种蓝→紫→粉→橙的虹彩），
//       再叠一层错开相位的，让颜色互相咬合；边缘加一点点色散（RGB 轻微错开）；
//    ④ 发光：中心 exp 亮核 + 主体 smoothstep 化开的边 + 外圈泛光，
//       透明度在 d>1.35 处**精确归零**（这样叠在深色底上永远不会露出方框）。
//
//  接口和上一版完全一致（time, w, h, c1…c4, amp, glass, radius），Swift 那边不用改。
//
#include <metal_stdlib>
using namespace metal;

static float sat(float x) { return clamp(x, 0.0, 1.0); }

/* 值噪声：Siri 那种丝滑流动必须用它（正弦叠出来的会看出规律，像"格子布料"） */
static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}
static float vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);          // 平滑插值
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}
static float fbm(float2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 4; i++) {
        v += a * vnoise(p);
        p = p * 2.03 + float2(17.1, 9.7);
        a *= 0.5;
    }
    return v;
}

/* 四个锚色环状插值：x 绕一圈颜色走一圈（Siri 的虹彩就是这么变的） */
static float3 anchors(float x, float3 a, float3 b, float3 c, float3 d) {
    float s = fract(x) * 4.0;
    if (s < 1.0) return mix(a, b, s);
    if (s < 2.0) return mix(b, c, s - 1.0);
    if (s < 3.0) return mix(c, d, s - 2.0);
    return mix(d, a, s - 3.0);
}

[[ stitchable ]] half4 voiceOrb(float2 pos, half4 inColor,
                                float time, float w, float h,
                                half4 c1, half4 c2, half4 c3, half4 c4,
                                float amp, float glass, float radius)
{
    float2 size = float2(w, h);
    float2 uv = (pos - size * 0.5) / (size.x * 0.5);      // -1 … 1
    float t = time;
    float a = sat(amp);

    /* ① 形状：半径按角度上的噪声 + 时间轻轻起伏（边一直在游，不是正圆） */
    float ang = atan2(uv.y, uv.x);
    float wob = fbm(float2(cos(ang) * 1.35, sin(ang) * 1.35) + float2(0.0, t * 0.10));
    float R = radius * (1.0 + (wob - 0.5) * (0.15 + a * 0.22));
    float d = length(uv) / max(R, 0.001);

    /* ② 流场：两层域扭曲（丝滑流动的来源） */
    float2 q = uv * 1.5;
    float2 warp = float2(fbm(q + float2(0.0, t * 0.11)),
                         fbm(q + float2(3.7, -t * 0.09)));
    float flow = fbm(q * 1.2 + (warp - 0.5) * 0.95 + float2(t * 0.05, -t * 0.04));

    /* ③ 虹彩：颜色沿流场 + 时间绕圈；再叠一层错开相位的，两种颜色互相咬合 */
    float hue = flow * 1.15 + t * 0.055 + d * 0.20;
    float3 colA = anchors(hue, float3(c1.rgb), float3(c2.rgb), float3(c3.rgb), float3(c4.rgb));
    float3 colB = anchors(hue + 0.35, float3(c4.rgb), float3(c1.rgb), float3(c2.rgb), float3(c3.rgb));
    float3 col = mix(colA, colB, 0.5 + 0.25 * sin(t * 0.7));

    /* ④ 发光体：中心亮核 + 化开的主体 + 外圈泛光（没有高光点、没有硬边） */
    float core = exp(-d * d * 2.6);
    float body = smoothstep(1.45, 0.05, d);
    float glow = exp(-max(0.0, d - 0.82) * 2.3);
    float lum = 0.30 + a * 0.55;

    float3 out3 = col * (core * 0.95 + body * 0.50) * (0.72 + lum)
                + col * glow * (0.28 + a * 0.38);
    /* 球心掺一点中性白（Siri 球心是发白的，不是纯彩色） */
    out3 += float3(1.0, 0.99, 1.0) * core * (0.20 + a * 0.26);

    /* 色散：越靠边 RGB 错得越多（边缘那一圈细彩边） */
    float disp = (d - 1.0) * 0.055 * clamp(glass, 0.0, 1.4);
    out3.r *= 1.0 + disp;
    out3.b *= 1.0 - disp;

    /* 透明度：主体 + 泛光，d>1.35 精确为 0（叠在深色底上永远不会露出方框） */
    float alpha = sat(body * 0.92 + glow * 0.52) * smoothstep(1.35, 0.55, d);
    return half4(half3(max(out3, 0.0)), half(alpha));
}
