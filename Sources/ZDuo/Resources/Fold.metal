#include <metal_stdlib>
using namespace metal;

struct VertexOut { float4 position [[position]]; float2 uv; };
struct FoldUniforms { float closure; float blur; float width; float height; };

vertex VertexOut foldVertex(uint index [[vertex_id]]) {
    const float2 positions[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    VertexOut result;
    result.position = float4(positions[index], 0, 1);
    result.uv = float2((positions[index].x + 1) * 0.5, (1 - positions[index].y) * 0.5);
    return result;
}

float3 blurredColor(float2 uv, float amount, texture2d<float> sharp,
                    texture2d<float> soft, texture2d<float> medium, texture2d<float> deep) {
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float3 a = sharp.sample(linearSampler, uv).rgb;
    float3 b = soft.sample(linearSampler, uv).rgb;
    float3 c = medium.sample(linearSampler, uv).rgb;
    float3 d = deep.sample(linearSampler, uv).rgb;
    if (amount < 0.143) return mix(a, b, amount / 0.143);
    if (amount < 0.429) return mix(b, c, (amount - 0.143) / 0.286);
    return mix(c, d, saturate((amount - 0.429) / 0.571));
}

fragment float4 foldFragment(VertexOut in [[stage_in]],
                             constant FoldUniforms &u [[buffer(0)]],
                             texture2d<float> sharp [[texture(0)]],
                             texture2d<float> soft [[texture(1)]],
                             texture2d<float> medium [[texture(2)]],
                             texture2d<float> deep [[texture(3)]]) {
    // 满高度投影参考 Noveum/hinge（MIT，见 THIRD_PARTY_NOTICES.md）。
    // 屏幕自身已经旋转，软件只轻微收窄侧边、裁去顶部；不再压低整张画面的顶边。
    float y = 1 - in.uv.y;
    float taper = 0.30 * u.closure;
    float q = (1 + taper) / (1 + taper * in.uv.y);
    float sourceY = cos(u.closure * M_PI_F * 0.5 * 0.65) * (1 - in.uv.y * q);
    float sourceX = 0.5 + (in.uv.x - 0.5) * q;
    float2 sourceUV = float2(sourceX, 1 - sourceY);

    // 磨砂附着在物理屏幕上：用显示坐标 y，而非透视变换后的 sourceY。
    // 从铰链处的透明过渡到顶部的磨砂；开合与反向打开共用同一角度曲线。
    float fold = pow(saturate(u.blur), 0.65);
    float surfaceGradient = pow(smoothstep(0.0, 1.0, y), 1.2);
    float frostOpacity = 0.44 * fold * surfaceGradient;
    float depthBlur = u.blur * (0.12 + 0.88 * y);
    float amount = 1 - (1 - depthBlur) * (1 - frostOpacity * 0.85);
    float3 foreground = blurredColor(sourceUV, amount, sharp, soft, medium, deep);
    // 超出参考画面的区域延续边缘色，再融入模糊背景；避免黑色三角和硬裁切。
    float edge = min(sourceUV.x, 1 - sourceUV.x);
    float feather = max(0.0001, u.blur * 0.075);
    float boundary = smoothstep(-feather, feather, edge);
    float3 background = blurredColor(clamp(sourceUV, float2(0), float2(1)),
                                    min(1.0, amount + u.blur * 0.7), sharp, soft, medium, deep);
    float3 color = mix(background, foreground, mix(1.0, boundary, saturate(u.closure * 8)));
    color *= 1 - u.blur * 0.045;
    // 仅压暗虚拟屏幕外侧；边缘柔和衔接，合盖越多越暗，内部画面亮度保持不变。
    float outside = 1 - smoothstep(-feather, 0.0, edge);
    float dimming = 0.55 * smoothstep(0.0, 0.75, u.closure);
    color *= 1 - outside * dimming;

    // 最后覆盖半透明冷灰磨砂层，保留后方内容；静态细颗粒固定在屏幕上，不随内容移动或闪烁。
    float2 surfacePixel = floor(in.uv * float2(u.width, u.height));
    float grain = fract(sin(dot(surfacePixel, float2(12.9898, 78.233))) * 43758.5453) - 0.5;
    float reflection = exp(-pow((y - 0.92) / 0.30, 2.0));
    float3 frostTint = float3(0.64, 0.68, 0.73) + reflection * 0.055 + grain * 0.018;
    color = mix(color, frostTint, frostOpacity);
    return float4(color, 1);
}
