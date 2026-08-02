//=============================================================================
// Shadow.fxh
// 普通阴影、小型物体阴影、缓存贴回与通用降采样。
// 由 ShadowEffect.fx 统一声明参数并装配 Technique。
//=============================================================================

VSOutput ShearVertexShader(VSInput input)
{
    VSOutput output;
    output.Color = input.Color;
    output.TexCoord = input.TexCoord;

    float4 pos = input.Position;

    // 从 Color.RG 获取源矩形的 Y 边界（归一化到 0-1）
    float srcTop = input.Color.r;
    float srcBottom = input.Color.g;
    float2 packedHeight = floor(input.Color.ba * 255.0 + 0.5);

    // 计算当前顶点在精灵内的相对位置（在VS中执行除法，仅4次）
    float normalizedV = CalculateNormalizedY(input.TexCoord.y, srcTop, srcBottom);

    // 恢复精灵的实际渲染高度（像素）
    // B/A 保存 16-bit 实际渲染高度，避免高于 512px 的精灵被截断后改变投影角度。
    float spriteHeight = packedHeight.x * 256.0 + packedHeight.y;

    // FlipVertically 后：normalizedV=1 是近端（固定），normalizedV=0 是远端（最大偏移）
    float shearFactor = 1.0 - normalizedV;

    // 计算像素偏移：使用预计算的归一化斜切因子
    float pixelOffset = NormalizedShearX * spriteHeight * shearFactor;

    pos.x += pixelOffset;

    // 阴影长度缩放：将远端顶点向近端收缩/扩张
    // shearFactor = 0 在近端（固定），= 1 在远端（最大缩放）
    pos.y -= (1.0 - ShadowLengthScale) * spriteHeight * shearFactor;

    // 应用 SpriteBatch 的变换矩阵
    output.Position = mul(pos, MatrixTransform);

    // 关键优化：将计算好的 normalizedV 写入 Color.b，供PS通过插值器获取
    // GPU会自动在顶点之间线性插值，PS直接读取插值后的值（零成本）
    output.Color.b = normalizedV;

    return output;
}

VSOutput CachedShearVertexShader(VSInput input)
{
    VSOutput output;
    output.Color = input.Color;
    output.TexCoord = input.TexCoord;

    float4 pos = input.Position;
    float4 packed = floor(input.Color * 255.0 + 0.5);
    float packedHighRemainder = floor(packed.a / 4.0);
    float quantizedSlopeHigh = packed.a - packedHighRemainder * 4.0;
    float packedAfterIntercept = floor(packedHighRemainder / 4.0);
    float quantizedInterceptHigh = packedHighRemainder - packedAfterIntercept * 4.0;
    float quantizedSlope = packed.r + quantizedSlopeHigh * 256.0;
    float quantizedIntercept = packed.g + quantizedInterceptHigh * 256.0;

    float mappingSlope = quantizedSlope * (2.0 / 1023.0);
    float mappingIntercept = -0.5 + quantizedIntercept * (1.5 / 1023.0);
    float normalizedV = input.TexCoord.y * mappingSlope + mappingIntercept;
    float spriteHeight = packed.b + packedAfterIntercept * 256.0;
    float shearFactor = 1.0 - normalizedV;
    float pixelOffset = NormalizedShearX * spriteHeight * shearFactor;

    pos.x += pixelOffset;
    pos.y -= (1.0 - ShadowLengthScale) * spriteHeight * shearFactor;

    output.Position = mul(pos, MatrixTransform);
    output.Color.b = normalizedV;

    return output;
}

float4 NormalShadowPS(VSOutput input) : COLOR
{
    float4 texColor = tex2D(SourceTexture, input.TexCoord);

    // clip() 当参数 < 0 时丢弃像素（阈值 0.55 过滤半透明软阴影像素）
    clip(texColor.a - 0.55);

    // 关键优化：直接从 Color.b 读取 VS 插值后的 normalizedY（无需计算！）
    // GPU已经自动在顶点之间线性插值，PS只需读取，零成本
    float normalizedV = input.Color.b;

    // 计算渐变因子
    float gradientFactor = CalculateShadowGradient(normalizedV);

    // 输出阴影颜色
    float4 result = ShadowColor;
    result.a *= gradientFactor * texColor.a;

    // NormalShadow 不再进入全屏模糊链路；B 通道恢复为真实阴影颜色，避免动态阴影发蓝。
    result.b = ShadowColor.b;

    return result;
}

float4 NormalShadowCacheBuildPS(VSOutput input) : COLOR
{
    float4 texColor = tex2D(SourceTexture, input.TexCoord);
    clip(texColor.a - 0.55);

    float normalizedV = CalculateNormalizedY(input.TexCoord.y, input.Color.r, input.Color.g);
    float gradientFactor = CalculateShadowGradient(normalizedV);

    // RGB 不参与缓存语义；A 保存未乘 ShadowColor 的 gradient mask，B 供局部 blur 判定软边区域。
    return float4(0.0, 0.0, normalizedV, gradientFactor * texColor.a);
}

float4 NormalShadowCachedShearPS(VSOutput input) : COLOR
{
    float4 cachedColor = tex2D(SourceTexture, input.TexCoord);
    clip(cachedColor.a - 0.001);

    float4 result = ShadowColor;
    result.a *= cachedColor.a;
    result.b = ShadowColor.b;
    return result;
}

float4 SmallObjectShadowPS(VSOutput input) : COLOR
{
    float4 texColor = tex2D(SourceTexture, input.TexCoord);

    clip(texColor.a - 0.15);

    float4 result = ShadowColor;
    result.a *= texColor.a;

    // SmallObjectShadow 也不进入全屏模糊链路；B 通道恢复为真实阴影颜色。
    result.b = ShadowColor.b;

    return result;
}

float4 HorizontalBlurPS(VSOutput input) : COLOR
{
    // 采样中心像素
    float4 centerColor = tex2D(SourceTexture, input.TexCoord);

    // 获取 normalizedV (存储在 B 通道)
    float normalizedV = centerColor.b;

    // 跳过非阴影像素
    if (centerColor.a <= 0.0)
    {
        return centerColor;
    }

    // 提前退出：跳过不需要模糊的区域（收益巨大：节省9次纹理采样）
    if (normalizedV > 0.4)
    {
        return centerColor;
    }

    // 执行高斯模糊
    float4 blurredColor = centerColor * Weights[0];

    float2 offset1 = float2(TexelSize.x * 1.0 * ShadowEdgeBlurIntensity, 0);
    float2 offset2 = float2(TexelSize.x * 2.0 * ShadowEdgeBlurIntensity, 0);
    float2 offset3 = float2(TexelSize.x * 3.0 * ShadowEdgeBlurIntensity, 0);
    float2 offset4 = float2(TexelSize.x * 4.0 * ShadowEdgeBlurIntensity, 0);

    blurredColor += tex2D(SourceTexture, input.TexCoord + offset1) * Weights[1];
    blurredColor += tex2D(SourceTexture, input.TexCoord - offset1) * Weights[1];
    blurredColor += tex2D(SourceTexture, input.TexCoord + offset2) * Weights[2];
    blurredColor += tex2D(SourceTexture, input.TexCoord - offset2) * Weights[2];
    blurredColor += tex2D(SourceTexture, input.TexCoord + offset3) * Weights[3];
    blurredColor += tex2D(SourceTexture, input.TexCoord - offset3) * Weights[3];
    blurredColor += tex2D(SourceTexture, input.TexCoord + offset4) * Weights[4];
    blurredColor += tex2D(SourceTexture, input.TexCoord - offset4) * Weights[4];

    // 完全模糊区域(normalizedV < 0.3)：直接返回模糊结果，跳过lerp
    if (normalizedV < 0.2)
    {
        blurredColor.b = normalizedV;
        return blurredColor;
    }

    // 过渡区域(0.3-0.4)：计算权重并混合
    // Branchless权重计算：smoothstep自动处理边界
    float blurWeight = 1.0 - smoothstep(0.2, 0.4, normalizedV);
    float4 result = lerp(centerColor, blurredColor, blurWeight);

    // 保留 B 通道位置信息供 Vertical Pass 使用
    result.b = normalizedV;

    return result;
}

float4 VerticalBlurPS(VSOutput input) : COLOR
{
    // 采样中心像素
    float4 centerColor = tex2D(SourceTexture, input.TexCoord);

    // 获取 normalizedV (存储在 B 通道)
    float normalizedV = centerColor.b;

    // 合并提前退出条件：非阴影像素或不需要模糊的区域
    if (centerColor.a <= 0.0 || normalizedV > 0.4)
    {
        centerColor.b = ShadowColor.b;
        return centerColor;
    }

    // 执行高斯模糊
    float4 blurredColor = centerColor * Weights[0];

    float2 offset1 = float2(0, TexelSize.y * 1.0 * ShadowEdgeBlurIntensity);
    float2 offset2 = float2(0, TexelSize.y * 2.0 * ShadowEdgeBlurIntensity);
    float2 offset3 = float2(0, TexelSize.y * 3.0 * ShadowEdgeBlurIntensity);
    float2 offset4 = float2(0, TexelSize.y * 4.0 * ShadowEdgeBlurIntensity);

    blurredColor += tex2D(SourceTexture, input.TexCoord + offset1) * Weights[1];
    blurredColor += tex2D(SourceTexture, input.TexCoord - offset1) * Weights[1];
    blurredColor += tex2D(SourceTexture, input.TexCoord + offset2) * Weights[2];
    blurredColor += tex2D(SourceTexture, input.TexCoord - offset2) * Weights[2];
    blurredColor += tex2D(SourceTexture, input.TexCoord + offset3) * Weights[3];
    blurredColor += tex2D(SourceTexture, input.TexCoord - offset3) * Weights[3];
    blurredColor += tex2D(SourceTexture, input.TexCoord + offset4) * Weights[4];
    blurredColor += tex2D(SourceTexture, input.TexCoord - offset4) * Weights[4];

    // 完全模糊区域(normalizedV < 0.3)：直接返回模糊结果，跳过lerp
    if (normalizedV < 0.2)
    {
        blurredColor.b = ShadowColor.b;
        return blurredColor;
    }

    // 过渡区域(0.2-0.4)：计算权重并混合
    // Branchless权重计算（逻辑同 HorizontalBlurPS）
    float blurWeight = 1.0 - smoothstep(0.2, 0.4, normalizedV);
    float4 result = lerp(centerColor, blurredColor, blurWeight);

    // 恢复 B 通道为原始阴影颜色
    result.b = ShadowColor.b;

    return result;
}

float4 DownsamplePS(VSOutput input) : COLOR
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
