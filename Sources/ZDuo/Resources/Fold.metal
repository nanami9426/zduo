#include <metal_stdlib>
using namespace metal;

struct VertexOut { float4 position [[position]]; float2 uv; };
struct FoldUniforms { float rotation; float blur; float width; float height; };

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
    // 固定观察点的逆投影：参考平面绕底部铰链旋转，求显示屏上的射线对应原图的位置。
    const float distance = 2.4;
    const float eyeHeight = 0.55;
    float y = 1 - in.uv.y;
    float s = sin(u.rotation);
    float denominator = max(0.2, distance * cos(u.rotation) + (eyeHeight - y) * s);
    float sourceY = y * distance / denominator;
    float sourceX = 0.5 + (in.uv.x - 0.5) * (distance + sourceY * s) / distance;
    float2 sourceUV = float2(sourceX, 1 - sourceY);

    float amount = u.blur * (0.12 + 0.88 * y);
    float3 foreground = blurredColor(sourceUV, amount, sharp, soft, medium, deep);
    // 超出参考画面的区域延续边缘色，再融入模糊背景；避免黑色三角和硬裁切。
    float edge = min(min(sourceUV.x, 1 - sourceUV.x), min(sourceUV.y, 1 - sourceUV.y));
    float feather = max(0.0001, u.blur * 0.075);
    float boundary = smoothstep(-feather, feather, edge);
    float3 background = blurredColor(clamp(sourceUV, float2(0), float2(1)),
                                    min(1.0, amount + u.blur * 0.7), sharp, soft, medium, deep);
    float3 color = mix(background, foreground, mix(1.0, boundary, saturate(u.rotation * 8)));
    color = mix(color, float3(0.52), u.blur * 0.10);
    color *= 1 - u.blur * 0.045;
    // 仅压暗虚拟屏幕外侧；边缘柔和衔接，合盖越多越暗，内部画面亮度保持不变。
    float outside = 1 - smoothstep(-feather, 0.0, edge);
    float dimming = 0.55 * smoothstep(0.0, 0.75, u.rotation);
    color *= 1 - outside * dimming;
    return float4(color, 1);
}
