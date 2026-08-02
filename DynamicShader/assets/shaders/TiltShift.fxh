//=============================================================================
// TiltShift.fxh
// 移轴降采样、水平/垂直模糊与最终 Alpha 输出。
// 由 ShadowEffect.fx 统一声明参数并装配 Technique。
//=============================================================================

float CalculateTiltShiftWeight(float screenY)
{
    // 计算距离焦点中心的距离
    float distFromCenter = abs(screenY - FocusCenter);

    // 根据上下位置选择对应的模糊范围比例
    float blurRangeRatio = (screenY < FocusCenter) ? TopBlurRangeRatio : BottomBlurRangeRatio;

    // 计算清晰带半宽
    float focusBandSize = (1.0 - blurRangeRatio) * 0.5;

    // 在清晰带内，权重为0（不模糊）
    if (distFromCenter <= focusBandSize)
    {
        return 0.0;
    }

    // 计算过渡范围
    float transitionRange = 0.5 - focusBandSize;

    // 避免除零
    if (transitionRange < 0.001)
    {
        return 1.0;
    }

    // 计算归一化的距离（0 = 清晰带边缘, 1 = 屏幕边缘）
    float normalizedDist = (distFromCenter - focusBandSize) / transitionRange;

    // 使用平方根函数让过渡更自然
    return sqrt(saturate(normalizedDist));
}

float4 TiltShiftDownsamplePS(VSOutput input) : COLOR
{
    float2 uv = input.TexCoord;
    float2 offset = TexelSize * 0.5;

    // 2×2 区域采样（box filter）
    float4 color = tex2D(SourceTexture, uv + float2(-offset.x, -offset.y));
    color += tex2D(SourceTexture, uv + float2(+offset.x, -offset.y));
    color += tex2D(SourceTexture, uv + float2(-offset.x, +offset.y));
    color += tex2D(SourceTexture, uv + float2(+offset.x, +offset.y));

    // 简单平均
    return color * 0.25;
}

float4 SampleTiltShiftHorizontalBlur(float2 uv)
{
    float4 color = tex2D(SourceTexture, uv) * Weights[0];

    // 使用 TiltShiftBlur 参数控制模糊强度
    float2 offset1 = float2(TexelSize.x * 1.0 * TiltShiftBlur, 0);
    float2 offset2 = float2(TexelSize.x * 2.0 * TiltShiftBlur, 0);
    float2 offset3 = float2(TexelSize.x * 3.0 * TiltShiftBlur, 0);
    float2 offset4 = float2(TexelSize.x * 4.0 * TiltShiftBlur, 0);

    color += tex2D(SourceTexture, uv + offset1) * Weights[1];
    color += tex2D(SourceTexture, uv - offset1) * Weights[1];
    color += tex2D(SourceTexture, uv + offset2) * Weights[2];
    color += tex2D(SourceTexture, uv - offset2) * Weights[2];
    color += tex2D(SourceTexture, uv + offset3) * Weights[3];
    color += tex2D(SourceTexture, uv - offset3) * Weights[3];
    color += tex2D(SourceTexture, uv + offset4) * Weights[4];
    color += tex2D(SourceTexture, uv - offset4) * Weights[4];

    return color;
}

float4 TiltShiftDownsampleHorizontalBlurPS(VSOutput input) : COLOR
{
    // 直接绘制到 1/2 RT；LinearClamp 在缩放时完成双线性降采样。
    // C# 传入目标 RT 的 TexelSize，使采样间距与旧的半分辨率水平模糊一致。
    return SampleTiltShiftHorizontalBlur(input.TexCoord);
}

float4 PureHorizontalBlurPS(VSOutput input) : COLOR
{
    return SampleTiltShiftHorizontalBlur(input.TexCoord);
}

float4 PureVerticalBlurPS(VSOutput input) : COLOR
{
    float4 color = tex2D(SourceTexture, input.TexCoord) * Weights[0];

    // 使用 TiltShiftBlur 参数控制模糊强度
    float2 offset1 = float2(0, TexelSize.y * 1.0 * TiltShiftBlur);
    float2 offset2 = float2(0, TexelSize.y * 2.0 * TiltShiftBlur);
    float2 offset3 = float2(0, TexelSize.y * 3.0 * TiltShiftBlur);
    float2 offset4 = float2(0, TexelSize.y * 4.0 * TiltShiftBlur);

    color += tex2D(SourceTexture, input.TexCoord + offset1) * Weights[1];
    color += tex2D(SourceTexture, input.TexCoord - offset1) * Weights[1];
    color += tex2D(SourceTexture, input.TexCoord + offset2) * Weights[2];
    color += tex2D(SourceTexture, input.TexCoord - offset2) * Weights[2];
    color += tex2D(SourceTexture, input.TexCoord + offset3) * Weights[3];
    color += tex2D(SourceTexture, input.TexCoord - offset3) * Weights[3];
    color += tex2D(SourceTexture, input.TexCoord + offset4) * Weights[4];
    color += tex2D(SourceTexture, input.TexCoord - offset4) * Weights[4];

    return color;
}

float4 TiltShiftAlphaOutputPS(VSOutput input) : COLOR
{
    // 计算移轴权重
    float blurWeight = CalculateTiltShiftWeight(input.TexCoord.y);

    // 如果权重接近0（清晰区域），输出完全透明，不影响原图
    if (blurWeight < 0.001)
    {
        return float4(0, 0, 0, 0);
    }

    // 采样模糊图（降采样后的，LinearClamp 自动上采样）
    float4 blurredColor = tex2D(SourceTexture, input.TexCoord);

    // 将权重作为 Alpha 输出（不预乘，让混合器处理）
    blurredColor.a = blurWeight;

    return blurredColor;
}
