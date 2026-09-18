#include <metal_stdlib>
using namespace metal;

struct VertexOut { float4 position [[position]]; float2 uv; };
struct FoldUniforms {
    float closure; float blur; float projectionDepth; float sourceHeight;
    float width; float height;
};

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
    // 只读取相邻两档 MPS 纹理，散射半径以 point 为单位，不额外叠一层模糊。
    float sigma = 28 * saturate(amount);
    if (sigma < 4) return mix(sharp.sample(linearSampler, uv).rgb,
                              soft.sample(linearSampler, uv).rgb, sigma / 4);
    if (sigma < 12) return mix(soft.sample(linearSampler, uv).rgb,
                              medium.sample(linearSampler, uv).rgb, (sigma - 4) / 8);
    return mix(medium.sample(linearSampler, uv).rgb,
               deep.sample(linearSampler, uv).rgb, (sigma - 12) / 16);
}

fragment float4 foldProjectionFragment(VertexOut in [[stage_in]],
                                       constant FoldUniforms &u [[buffer(0)]],
                                       texture2d<float> desktop [[texture(0)]],
                                       texture2d<float> backdrop [[texture(1)]]) {
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    // 参数统一由 FoldCore 计算，CPU 检查和 GPU 使用同一组转角与视距。
    // Hinge 原始的轻微收窄和顶部裁剪，底部锚定，避免再次放大物理屏幕的转动。
    float y = 1 - in.uv.y;
    float q = 1 / (1 - u.projectionDepth * y);
    float sourceY = u.sourceHeight * y * (1 - u.projectionDepth) * q;
    float sourceX = 0.5 + (in.uv.x - 0.5) * q;
    float2 sourceUV = float2(sourceX, 1 - sourceY);
    float3 color = desktop.sample(linearSampler, sourceUV).rgb;
    // 图外采样独立的宽模糊背景，使用屏幕坐标，不能 clamp sourceUV 后重复边缘文字。
    // 背景模糊不随合盖进度减到零，刚开始合盖时也不会露出横向拖尾。
    float edge = min(sourceX, 1 - sourceX);
    float feather = max(1.0 / max(u.width, 1.0), u.closure * 0.012);
    float outside = 1 - smoothstep(-feather, 0.0, edge);
    float3 background = backdrop.sample(linearSampler, in.uv).rgb;
    background *= 1 - 0.55 * smoothstep(0.0, 0.75, u.closure);
    color = mix(color, background, outside);
    return float4(color, 1);
}

fragment float4 foldFragment(VertexOut in [[stage_in]],
                             constant FoldUniforms &u [[buffer(0)]],
                             texture2d<float> sharp [[texture(0)]],
                             texture2d<float> soft [[texture(1)]],
                             texture2d<float> medium [[texture(2)]],
                             texture2d<float> deep [[texture(3)]]) {
    // 恢复 2919cde（22:44，最接近用户提到的 22:46）的磨砂渐变与冷灰色调。
    // 材质仍附着在物理屏幕上，用 y 而不是逆投影后的坐标，底部轻、顶部浓。
    float y = 1 - in.uv.y;
    float fold = pow(saturate(u.blur), 0.65);
    float surfaceGradient = pow(smoothstep(0.0, 1.0, y), 1.2);
    float frostOpacity = 0.44 * fold * surfaceGradient;
    float depthBlur = u.blur * (0.12 + 0.88 * y);
    float amount = 1 - (1 - depthBlur) * (1 - frostOpacity * 0.85);
    float2 surfaceSize = max(float2(u.width, u.height), float2(1));
    float sourceX = 0.5 + (in.uv.x - 0.5) / (1 - u.projectionDepth * y);
    float edge = min(sourceX, 1 - sourceX);
    float feather = max(1.0 / surfaceSize.x, u.closure * 0.012);
    float outside = 1 - smoothstep(-feather, 0.0, edge);
    amount = saturate(amount + outside * u.blur * 0.7);
    float3 color = blurredColor(in.uv, amount, sharp, soft, medium, deep);
    color *= 1 - u.blur * 0.045;

    // 旧版细颗粒固定在屏幕上，恢复宽而柔和的顶部反光，不加入新的折射位移。
    float2 surfacePixel = floor(in.uv * surfaceSize);
    float grain = fract(sin(dot(surfacePixel, float2(12.9898, 78.233))) * 43758.5453) - 0.5;
    float reflection = exp(-pow((y - 0.92) / 0.30, 2.0));
    float3 frostTint = float3(0.64, 0.68, 0.73) + reflection * 0.055 + grain * 0.018;
    color = mix(color, frostTint, frostOpacity);
    return float4(saturate(color), 1);
}
