//=============================================================================
// Common.fxh
// 共享顶点结构、通用计算与采样权重。
// 由 ShadowEffect.fx 统一声明参数并装配 Technique。
//=============================================================================

// 源纹理（SpriteBatch 自动绑定到 register s0）
sampler2D SourceTexture : register(s0);

struct VSInput
{
    float4 Position : POSITION0;
    float4 Color : COLOR0;
    float2 TexCoord : TEXCOORD0;
};

struct VSOutput
{
    float4 Position : SV_POSITION;
    float4 Color : COLOR0;
    float2 TexCoord : TEXCOORD0;
};

float CalculateNormalizedY(float texCoordY, float srcTop, float srcBottom)
{
    float range = srcBottom - srcTop;
    if (range > 0.001)
    {
        return saturate((texCoordY - srcTop) / range);
    }
    return 0.5;  // 默认值（范围无效时）
}

float CalculateShadowGradient(float normalizedPos)
{
    // 与旧 LUT 预烘焙曲线保持一致：lerp(GradientStart, GradientEnd, exp(-2.0 * x))
    return lerp(GradientStart, GradientEnd, exp(-2.0 * normalizedPos));
};

VSOutput SpriteVertexShader(VSInput input)
{
    VSOutput output;
    output.Position = mul(input.Position, MatrixTransform);
    output.Color = input.Color;
    output.TexCoord = input.TexCoord;
    return output;
}

static const float Weights[5] = { 0.227027, 0.1945946, 0.1216216, 0.054054, 0.016216 };
