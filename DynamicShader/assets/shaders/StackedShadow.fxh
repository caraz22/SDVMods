//=============================================================================
// StackedShadow.fxh
// 堆叠建筑阴影的 Mask 构建与模糊合成。
// 由 ShadowEffect.fx 统一声明参数并装配 Technique。
//=============================================================================

VSOutput StackedShadowVS(VSInput input)
{
    VSOutput output;
    output.TexCoord = input.TexCoord;

    float4 pos = input.Position;

    // 从 Color 获取参数（由C#端预计算）
    float srcTop = input.Color.r;
    float srcBottom = input.Color.g;
    float layerBaseGlobalY = input.Color.b;  // 已预计算：(layer * stepSize) / totalStackHeight
    float layerSpan = input.Color.a;         // 已预计算：spriteRenderHeight / totalStackHeight

    // 优化：简化 normalizedV 计算（移除函数调用，内联并优化）
    float range = srcBottom - srcTop;
    float normalizedV = (input.TexCoord.y - srcTop) / max(range, 0.001);  // max()避免除零，比if分支快
    normalizedV = saturate(normalizedV);  // 确保在0-1范围，替代条件判断

    // 斜切计算
    float shearFactor = 1.0 - normalizedV;

    // 斜切偏移 = 基础偏移 + 层间补偿
    //   layerSpan * 512: 本层渲染高度（归一化到512参考值）
    pos.x += NormalizedShearX * shearFactor * (layerSpan + layerBaseGlobalY * 0.3) * 512.0;

    // 阴影长度缩放：将远端顶点向近端收缩/扩张
    pos.y -= (1.0 - ShadowLengthScale) * layerSpan * 512.0 * shearFactor;

    output.Position = mul(pos, MatrixTransform);

    // 关键优化：在VS中直接计算 globalY，PS只需读取插值后的值
    // 使用预计算的参数，只需一次乘法和一次加法
    float globalY = normalizedV * layerSpan + layerBaseGlobalY;

    // 将 globalY 存储到 Color.r，PS直接读取（GPU自动插值）
    output.Color.r = globalY;
    // 其他通道置0（PS不需要）
    output.Color.gba = float3(0, 0, 0);

    return output;
}

float4 SquareBuildingShadowMaskPS(VSOutput input) : COLOR
{
    float4 texColor = tex2D(SourceTexture, input.TexCoord);

    // 优化：使用 clip() 代替 if+discard（某些GPU上更高效）
    // clip() 当参数 < 0 时丢弃像素（阈值 0.15 过滤半透明软阴影像素）
    clip(texColor.a - 0.15);

    // 关键优化：直接从 Color.r 读取 VS 插值后的 globalY（无需计算！）
    // VS已经完成了除法和globalY计算，GPU自动插值到每个像素
    float globalY = input.Color.r;

    // 直接输出插值后的 globalY，供渐变阶段使用
    return float4(globalY, 0, 0, 1.0);
}

float4 StackedShadowCachedMaskPS(VSOutput input) : COLOR
{
    float4 maskColor = tex2D(SourceTexture, input.TexCoord);
    clip(maskColor.a - 0.15);
    return maskColor;
}

float2 GetStackedShadowMaskMoment(float4 maskColor)
{
    // Mask 的透明区域由 RT clear 为 0；LinearClamp 在轮廓边缘采样时，
    // R 已自然成为 coverage 加权后的 globalY，A 则是连续 coverage。
    // 不在这里再次 alpha clip，否则会截断半分辨率上采样生成的软边并产生分层轮廓。
    return float2(maskColor.r, saturate(maskColor.a));
}

float2 SampleStackedShadowMaskMoment(float2 uv)
{
    return GetStackedShadowMaskMoment(tex2D(SourceTexture, uv));
}

float4 StackedShadowBlurCompositePS(VSOutput input) : COLOR
{
    float2 uv = input.TexCoord;
    float4 centerMask = tex2D(SourceTexture, uv);
    float2 centerMoment = GetStackedShadowMaskMoment(centerMask);
    float centerCoverage = centerMoment.y;
    float centerGlobalY = saturate(centerMoment.x / max(centerCoverage, 0.001));

    // globalY 越低代表越远端，模糊越强；中心无 mask 时按最大半径处理软边外扩。
    float blurY = centerGlobalY;
    float blurScale = lerp(StackedShadowBlurScaleMax, StackedShadowBlurScaleMin, blurY);
    float2 offset = TexelSize * ShadowEdgeBlurIntensity * blurScale;

    float2 blurredMoment = centerMoment * Weights[0];

    // 单 pass 十字形近似高斯：复用现有 9-tap 权重，每个半径同时采样水平和垂直方向。
    // 权重乘 0.5 后总和仍为 1：Weights[0] + 2 * sum(Weights[1..4])。
    blurredMoment += SampleStackedShadowMaskMoment(uv + float2( offset.x * 1.0, 0.0)) * Weights[1] * 0.5;
    blurredMoment += SampleStackedShadowMaskMoment(uv + float2(-offset.x * 1.0, 0.0)) * Weights[1] * 0.5;
    blurredMoment += SampleStackedShadowMaskMoment(uv + float2(0.0,  offset.y * 1.0)) * Weights[1] * 0.5;
    blurredMoment += SampleStackedShadowMaskMoment(uv + float2(0.0, -offset.y * 1.0)) * Weights[1] * 0.5;

    blurredMoment += SampleStackedShadowMaskMoment(uv + float2( offset.x * 2.0, 0.0)) * Weights[2] * 0.5;
    blurredMoment += SampleStackedShadowMaskMoment(uv + float2(-offset.x * 2.0, 0.0)) * Weights[2] * 0.5;
    blurredMoment += SampleStackedShadowMaskMoment(uv + float2(0.0,  offset.y * 2.0)) * Weights[2] * 0.5;
    blurredMoment += SampleStackedShadowMaskMoment(uv + float2(0.0, -offset.y * 2.0)) * Weights[2] * 0.5;

    blurredMoment += SampleStackedShadowMaskMoment(uv + float2( offset.x * 3.0, 0.0)) * Weights[3] * 0.5;
    blurredMoment += SampleStackedShadowMaskMoment(uv + float2(-offset.x * 3.0, 0.0)) * Weights[3] * 0.5;
    blurredMoment += SampleStackedShadowMaskMoment(uv + float2(0.0,  offset.y * 3.0)) * Weights[3] * 0.5;
    blurredMoment += SampleStackedShadowMaskMoment(uv + float2(0.0, -offset.y * 3.0)) * Weights[3] * 0.5;

    blurredMoment += SampleStackedShadowMaskMoment(uv + float2( offset.x * 4.0, 0.0)) * Weights[4] * 0.5;
    blurredMoment += SampleStackedShadowMaskMoment(uv + float2(-offset.x * 4.0, 0.0)) * Weights[4] * 0.5;
    blurredMoment += SampleStackedShadowMaskMoment(uv + float2(0.0,  offset.y * 4.0)) * Weights[4] * 0.5;
    blurredMoment += SampleStackedShadowMaskMoment(uv + float2(0.0, -offset.y * 4.0)) * Weights[4] * 0.5;

    float blurredCoverage = saturate(blurredMoment.y);
    float averageGlobalY = saturate(blurredMoment.x / max(blurredCoverage, 0.001));

    // 阴影内部保留当前切片自己的 globalY，避免模糊把相邻切片的渐变高度混在一起形成重影。
    // 只有中心位于 mask 外部时，才使用邻域 moment 把正确的渐变延伸到软边区域。
    float gradientY = lerp(averageGlobalY, centerGlobalY, step(0.001, centerCoverage));
    float gradientFactor = CalculateShadowGradient(gradientY);
    float alpha = ShadowColor.a * gradientFactor * blurredCoverage;

    clip(alpha - 0.001);

    float4 result = ShadowColor;
    result.a = alpha;
    result.b = ShadowColor.b;
    return result;
}
