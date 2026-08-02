//=============================================================================
// CanopyLight.fxh
// Oak 与 Pine 树冠主体光照。
// 由 ShadowEffect.fx 统一声明参数并装配 Technique。
//=============================================================================

float4 TreeCanopyLightPS(VSOutput input) : COLOR
{
    float4 baseColor = tex2D(SourceTexture, input.TexCoord);
    clip(baseColor.a - 0.01);

    // Color.rgba 编码 sourceRect 的 UV 边界；R/B 的顺序额外表示水平翻转。
    // 翻转树仍使用 SpriteEffects 反向采样纹理，但光照局部坐标需要还原到屏幕方向，
    // 否则同一太阳方向下会有的树亮右上、有的树亮左上。
    float flipX = step(input.Color.b, input.Color.r);
    float2 rectMin = float2(min(input.Color.r, input.Color.b), input.Color.g);
    float2 rectMax = float2(max(input.Color.r, input.Color.b), input.Color.a);
    float2 rectSize = max(rectMax - rectMin, float2(0.0001, 0.0001));

    float2 localUV = saturate((input.TexCoord - rectMin) / rectSize);
    float2 lightUV = localUV;
    lightUV.x = lerp(lightUV.x, 1.0 - lightUV.x, flipX);
    float2 p = lightUV * 2.0 - 1.0;

    // 树冠主体椭圆遮罩：中心参与度高，边缘/四角渐弱，避免整块矩形贴片感。
    float2 q = p / float2(0.95, 0.8);
    float dist = length(q);
    float shapeMask = 1.0 - smoothstep(0.7, 1.05, dist);

    // 将局部位置近似为树冠表面方向；中心点用极小长度保护，避免 normalize(0)。
    float2 surfaceDir = p / max(length(p), 0.0001);
    float2 sunDir = TreeCanopyLightSunDirection / max(length(TreeCanopyLightSunDirection), 0.0001);

    float dir01 = dot(surfaceDir, sunDir) * 0.5 + 0.5;
    float sunFacing = dot(q, sunDir);

    // 顶部更容易吃到亮部。下半部分明显衰减，避免整片树冠均匀发亮。
    float topMask = 1.0 - lightUV.y;
    float topLightBoost = lerp(0.28, 1.0, topMask);

    float alpha = baseColor.a;

    // 迎光面改为“上方外缘弧形区域”，而不是一个圆形小光斑。
    // 使用较宽的高光遮罩，保留迎光侧外缘的弧形曝光区域。
    float upperArcMask = smoothstep(0.18, 0.88, topMask);
    float faceMask = smoothstep(0.02, 0.72, sunFacing);
    float radialOuter = smoothstep(0.22, 0.82, dist);
    float radialFade = 1.0 - smoothstep(1.10, 1.34, dist);
    float arcBand = radialOuter * radialFade;
    float innerFill = (1.0 - radialOuter) * 0.22;

    float highlight = saturate((arcBand * 1.18 + innerFill) * faceMask * upperArcMask);
    highlight *= alpha;
    highlight *= topLightBoost;

    float shadow = smoothstep(0.45, 0.95, 1.0 - dir01);
    shadow *= shapeMask;
    shadow *= alpha;

    // 原树冠已经由游戏绘制过；这层只负责覆盖“确实发生光照/背光变化”的像素。
    // 对几乎无变化的区域提前丢弃，减少后续曝光/暖色计算与 back buffer AlphaBlend 写入。
    clip(max(highlight, shadow) - 0.002);

    float shadowBlend = min(TreeCanopyShadowStrength * shadow, 3.0);

    // 先压暗背光面，再提亮迎光面；全部使用颜色倍率 lerp，不做 additive。
    float3 shadowed = lerp(
        baseColor.rgb,
        baseColor.rgb * TreeCanopyShadowColor.rgb,
        shadowBlend);

    // 曝光式提亮：只基于当前像素颜色做乘法曝光，不混入固定亮色贴片。
    // EV = 强度 * 受光遮罩 * 贴图明度保护；最终 brightness = 2^EV。
    // 这样调高强度更接近“提高相机曝光值”，暗纹理仍暗、亮纹理更亮，树叶细节会随原图保留。
    float luminance = dot(shadowed, float3(0.299, 0.587, 0.114));
    float detailKeep = lerp(0.62, 1.0, smoothstep(0.08, 0.52, luminance));

    float exposureEv = min(TreeCanopyLightStrength * highlight * detailKeep * 0.42, 5.0);
    float exposureScale = exp2(exposureEv);

    float3 exposed = shadowed * exposureScale;

    // 回到更自然的曝光乘法合成：RGB 只作为轻微色温倾向，不再按亮度重建一份黄色图。
    // 这样叶片仍保持原贴图的绿色层次，只是在受光处更亮/略暖，避免看起来像整体枯黄。
    float3 lightColor = max(TreeCanopyLightColor.rgb, float3(0.001, 0.001, 0.001));
    float lightColorLuma = max(dot(lightColor, float3(0.299, 0.587, 0.114)), 0.001);
    float3 normalizedLightTint = lightColor / lightColorLuma;
    float tintWeight = saturate(exposureEv * 0.32 + highlight * 0.08);
    float3 lightTint = lerp(float3(1.0, 1.0, 1.0), normalizedLightTint, tintWeight);

    float3 lit = exposed * lightTint;

    // 缓存贴图在 Tree.draw 的原世界层级中替换树冠像素，因此输出完整 lit 颜色和原始 alpha。
    return float4(saturate(lit), baseColor.a);
}

float SampleAlphaInsideRect(float2 uv, float2 rectMin, float2 rectMax)
{
    if (uv.x < rectMin.x || uv.x > rectMax.x || uv.y < rectMin.y || uv.y > rectMax.y)
        return 0.0;

    return tex2D(SourceTexture, uv).a;
}

float4 TextureGuidedPineCanopyLightPS(VSOutput input) : COLOR
{
    float4 baseColor = tex2D(SourceTexture, input.TexCoord);
    clip(baseColor.a - 0.01);

    // 与 Oak 共用同一套 sourceRect/flip 编码；只替换光影遮罩 Profile。
    float flipX = step(input.Color.b, input.Color.r);
    float2 rectMin = float2(min(input.Color.r, input.Color.b), input.Color.g);
    float2 rectMax = float2(max(input.Color.r, input.Color.b), input.Color.a);
    float2 rectSize = max(rectMax - rectMin, float2(0.0001, 0.0001));

    float2 localUV = saturate((input.TexCoord - rectMin) / rectSize);
    float2 lightUV = localUV;
    lightUV.x = lerp(lightUV.x, 1.0 - lightUV.x, flipX);
    float2 p = lightUV * 2.0 - 1.0;
    float2 sunDir = TreeCanopyLightSunDirection / max(length(TreeCanopyLightSunDirection), 0.0001);

    float alpha = baseColor.a;
    float luma = dot(baseColor.rgb, float3(0.299, 0.587, 0.114));
    float greenMask = saturate((baseColor.g - max(baseColor.r, baseColor.b)) * 2.0 + 0.35);
    float leafMask = alpha * lerp(0.52, 1.0, greenMask);

    float midtoneMask = smoothstep(0.12, 0.42, luma) * (1.0 - smoothstep(0.78, 0.96, luma));
    float darkMask = 1.0 - smoothstep(0.20, 0.50, luma);
    float brightSuppress = 1.0 - smoothstep(0.70, 0.96, luma);

    // Pine 使用 Oak-like 的空间光照：顶部局部受光 + 太阳侧边缘受光。
    // 不再让整棵树由纹理场统一提亮；贴图亮度/颜色只负责裁剪叶片和保留细节。
    float y = lightUV.y;
    float topMask = 1.0 - y;
    float bottomMask = smoothstep(0.36, 1.0, y);

    // 粗略 Pine 轮廓：顶部窄、底部宽。真实边界仍由 alpha 裁剪，这里只用于限制受光区域。
    float canopyWidth = lerp(0.18, 0.96, smoothstep(0.02, 0.84, y));
    float lateral = abs(p.x) / max(canopyWidth, 0.05);
    float canopyShape = 1.0 - smoothstep(0.86, 1.18, lateral);

    // 1) 顶部受光块：主要集中在树冠上部，并显式向太阳侧水平偏移。
    // 上午 sunDir.x > 0 时高光中心右移；下午自动左移。
    float upperBand = 1.0 - smoothstep(0.12, 0.46, y);
    float topShift = clamp(sunDir.x * 0.30, -0.30, 0.30);
    float2 topSpotCoord = float2((p.x - topShift) / 0.62, (y - 0.18) / 0.38);
    float topSpot = 1.0 - smoothstep(0.56, 1.08, length(topSpotCoord));
    float2 topNormal = float2(p.x * 0.55, -1.0) / max(length(float2(p.x * 0.55, -1.0)), 0.0001);
    float topFacing = dot(topNormal, sunDir) * 0.5 + 0.5;
    float topCanopy = 1.0 - smoothstep(0.96, 1.28, lateral);
    float topHighlight = upperBand * topSpot * topCanopy;
    topHighlight *= smoothstep(0.34, 0.90, topFacing);

    // 2) 太阳侧边缘：上午 sunDir.x 指向右侧时只让右侧外缘增强；下午自然换到左侧。
    float horizontalSun = saturate(abs(sunDir.x) * 1.45);
    float sunSide = smoothstep(0.12, 0.78, p.x * sunDir.x);
    float sideEdgeBand = smoothstep(0.70, 0.94, lateral) * (1.0 - smoothstep(1.00, 1.18, lateral));
    float sideHeightMask = 1.0 - smoothstep(0.62, 0.90, y);
    float sideHighlight = sideEdgeBand * sunSide * sideHeightMask * horizontalSun;

    // Alpha-guided sun-facing rim: 只作为太阳侧真实轮廓的额外增强，不再让整棵树变亮。
    float2 texel = rectSize / float2(48.0, 96.0);
    float2 textureSunDir = float2(lerp(sunDir.x, -sunDir.x, flipX), sunDir.y);
    float2 edgeTexel = texel * 1.35;
    float outsideAlpha = SampleAlphaInsideRect(input.TexCoord - textureSunDir * edgeTexel, rectMin, rectMax);

    float alphaL = SampleAlphaInsideRect(input.TexCoord - float2(edgeTexel.x, 0.0), rectMin, rectMax);
    float alphaR = SampleAlphaInsideRect(input.TexCoord + float2(edgeTexel.x, 0.0), rectMin, rectMax);
    float alphaU = SampleAlphaInsideRect(input.TexCoord - float2(0.0, edgeTexel.y), rectMin, rectMax);
    float alphaD = SampleAlphaInsideRect(input.TexCoord + float2(0.0, edgeTexel.y), rectMin, rectMax);
    float edgeGradX = alphaR - alphaL;
    float edgeGradY = alphaD - alphaU;
    edgeGradX *= 1.0 - 2.0 * flipX;
    float edgeGradLen = length(float2(edgeGradX, edgeGradY));
    float2 edgeNormal = float2(edgeGradX, edgeGradY) / max(edgeGradLen, 0.0001);
    float edgeFacing = saturate(dot(edgeNormal, sunDir) * 0.5 + 0.5);

    float rim = alpha * (1.0 - outsideAlpha);
    rim *= saturate(edgeGradLen * 1.8);
    rim *= smoothstep(0.42, 0.92, edgeFacing);
    rim *= lerp(0.45, 1.0, greenMask);
    rim *= sideHeightMask;

    float toneLightMask = lerp(0.32, 1.0, midtoneMask) * lerp(1.0, 0.58, 1.0 - brightSuppress);
    float lightSpatial = saturate(topHighlight * 0.78 + sideHighlight * 0.92 + rim * 0.30);
    float highlight = leafMask * toneLightMask * lightSpatial;

    // 背光区域与受光区域分离：太阳反侧 + 下半部 + 原图暗部形成体积，而不是全树一起提亮。
    float backSide = smoothstep(0.04, 0.72, -p.x * sunDir.x);
    float lowerOcclusion = bottomMask * lerp(0.55, 1.0, darkMask);
    float shadowSpatial = saturate(backSide * sideHeightMask * 0.72 + lowerOcclusion * 0.55);
    float toneShadowMask = lerp(0.62, 1.18, darkMask);
    float shadow = leafMask * toneShadowMask * shadowSpatial;
    shadow *= 1.0 - saturate(lightSpatial * 0.72);

    // 强度参数是 0..3 的用户标尺；这里先结合 texture-guided mask 得到实际受影响量。
    float lightAmount = saturate(highlight * TextureGuidedPineLightStrength);
    float shadowAmount = saturate(shadow * TextureGuidedPineShadowStrength);
    float rimAmount = saturate(rim * TextureGuidedPineRimStrength);

    float lightEv = min(lightAmount * 0.48, 1.40);
    float shadowEv = min(shadowAmount * 0.66, 1.90);
    float rimEv = min(rimAmount * 0.56, 1.35);

    clip(max(max(lightEv, shadowEv), rimEv) - 0.001);

    float3 shadowed = baseColor.rgb * exp2(-shadowEv);
    shadowed = lerp(
        shadowed,
        shadowed * TextureGuidedPineShadowColor.rgb,
        saturate(shadowEv * 0.65));

    float3 lightColor = max(TextureGuidedPineLightColor.rgb, float3(0.001, 0.001, 0.001));
    float lightColorLuma = max(dot(lightColor, float3(0.299, 0.587, 0.114)), 0.001);
    float3 normalizedLightTint = lightColor / lightColorLuma;
    float lightTintWeight = saturate(lightEv * 0.45 + lightAmount * 0.10);

    float3 lit = shadowed * exp2(lightEv);
    lit *= lerp(float3(1.0, 1.0, 1.0), normalizedLightTint, lightTintWeight);

    float3 rimColor = max(TextureGuidedPineRimColor.rgb, float3(0.001, 0.001, 0.001));
    float rimColorLuma = max(dot(rimColor, float3(0.299, 0.587, 0.114)), 0.001);
    float3 normalizedRimTint = rimColor / rimColorLuma;
    float rimTintWeight = saturate(rimEv * 0.55 + rimAmount * 0.12);

    float3 finalColor = lit * exp2(rimEv);
    finalColor *= lerp(float3(1.0, 1.0, 1.0), normalizedRimTint, rimTintWeight);

    return float4(saturate(finalColor), baseColor.a);
}
