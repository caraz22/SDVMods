//=============================================================================
// GodRay.fxh
// 程序化 God Ray 生成。
// 由 ShadowEffect.fx 统一声明参数并装配 Technique。
//=============================================================================

float Hash11(float n)
{
    return frac(sin(n) * 43758.5453123);
}

float EaseInOutQuad01(float x)
{
    x = saturate(x);
    return x < 0.5
        ? 2.0 * x * x
        : 1.0 - pow(-2.0 * x + 2.0, 2.0) * 0.5;
}

float CalculateGodRayBeamMask(
    float rayCoord,
    float centerCoord,
    float halfWidthPixels,
    float featherPixels)
{
    float distPixels = abs(rayCoord - centerCoord);
    return 1.0 - smoothstep(
        max(0.0, halfWidthPixels - featherPixels),
        halfWidthPixels + featherPixels,
        distPixels);
}

float CalculateSingleGodRay(
    float rayCoord,
    float alongCoord,
    float screenProgress,
    float cellWidth,
    float cellIndex)
{
    // 以固定 cell 作为稳定种子，但每条光柱中心强烈抖动，实际间距不再等距。
    float jitter = lerp(-0.44, 0.44, Hash11(cellIndex * 17.137 + 3.11));
    float centerCoord = (cellIndex + 0.5 + jitter) * cellWidth;

    // 每条光柱的进入位置与长度不同：不是贯穿屏幕，而是在随机距离内渐隐。
    float startOffset = lerp(-0.08, 0.10, Hash11(cellIndex * 13.73 + 4.81));
    float rayLength = lerp(0.38, 0.92, Hash11(cellIndex * 19.91 + 7.17));
    float rayProgress = saturate((screenProgress - startOffset) / max(rayLength, 0.05));
    float lengthMask = smoothstep(0.0, 0.12, rayProgress)
        * (1.0 - smoothstep(0.62, 1.0, rayProgress));

    // 一个 cell 不是一根光柱，而是一簇方向接近的子光束 + 宽而淡的 haze。
    // 这比孤立硬条更接近 Global God Rays 的贴图观感。
    float taper = lerp(1.18, 0.18, rayProgress);
    float widthScale = max(GodRayBaseWidth, 0.05);
    float softness = saturate(GodRaySoftness);

    float clusterHalfWidth = max(4.0, cellWidth * lerp(0.12, 0.22, Hash11(cellIndex * 23.731 + 9.27)) * widthScale * taper);
    float clusterFeather = max(5.0, clusterHalfWidth * lerp(1.10, 2.45, softness));
    float hazeMask = CalculateGodRayBeamMask(
        rayCoord,
        centerCoord,
        clusterHalfWidth,
        clusterFeather);

    float subBaseWidth = max(1.0, clusterHalfWidth * lerp(0.18, 0.34, Hash11(cellIndex * 37.91 + 1.77)));
    float subFeather = max(2.0, subBaseWidth * lerp(1.0, 2.2, softness));

    float sub0 = CalculateGodRayBeamMask(
        rayCoord,
        centerCoord - clusterHalfWidth * lerp(0.52, 0.86, Hash11(cellIndex * 5.13 + 1.0)),
        subBaseWidth * 0.78,
        subFeather);

    float sub1 = CalculateGodRayBeamMask(
        rayCoord,
        centerCoord - clusterHalfWidth * lerp(0.06, 0.28, Hash11(cellIndex * 7.71 + 2.0)),
        subBaseWidth * 1.08,
        subFeather * 1.15);

    float sub2 = CalculateGodRayBeamMask(
        rayCoord,
        centerCoord + clusterHalfWidth * lerp(0.08, 0.34, Hash11(cellIndex * 17.3 + 5.0)),
        subBaseWidth * 0.92,
        subFeather);

    float sub3 = CalculateGodRayBeamMask(
        rayCoord,
        centerCoord + clusterHalfWidth * lerp(0.48, 0.82, Hash11(cellIndex * 23.2 + 7.0)),
        subBaseWidth * 0.70,
        subFeather * 1.25);

    float subBeamMask = max(max(sub0 * 0.78, sub1), max(sub2 * 0.92, sub3 * 0.70));
    float rayMask = (hazeMask * 0.38 + subBeamMask * 0.82) * lengthMask;

    float phase = Hash11(cellIndex * 31.79 + 1.91) * 6.2831853;
    float flickerSpeed = max(GodRayFlickerSpeed, 0.0);
    float speed = lerp(0.8, 2.8, Hash11(cellIndex * 43.19 + 5.17)) * (0.35 + flickerSpeed * 2.65);
    float wave = sin(GodRayTime * speed + phase) * 0.5 + 0.5;
    float animatedFlicker = lerp(0.34, 1.18, EaseInOutQuad01(wave));
    float flicker = lerp(1.0, animatedFlicker, step(0.001, flickerSpeed));

    // 连续纵向呼吸，避免 floor 分段造成“突然瞬移/跳亮”。
    float shimmerWave = sin(alongCoord * 0.006 + phase * 1.73) * 0.5 + 0.5;
    float shimmer = lerp(0.92, 1.05, shimmerWave);
    float baseStrength = lerp(0.34, 0.68, Hash11(cellIndex * 61.13 + 8.43));

    // 约 30% cell 会成为重点光柱；在默认密度 7 左右时，屏幕上通常有 2~3 条明显更亮。
    float prominent = step(0.70, Hash11(cellIndex * 71.57 + 2.37));
    float prominentBoost = lerp(1.0, lerp(1.35, 1.75, Hash11(cellIndex * 83.29 + 6.13)), prominent);

    return rayMask * flicker * shimmer * baseStrength * prominentBoost;
}

float4 GodRayPS(VSOutput input) : COLOR
{
    float2 uv = input.TexCoord;
    float2 viewport = max(ViewportSize, float2(1.0, 1.0));
    float2 worldPos = uv * viewport + GodRayCameraOffset;

    float2 direction = normalize(GodRayDirection);
    float2 perpendicular = float2(-direction.y, direction.x);

    float2 screenPos = uv * viewport;
    float screenAlong = dot(screenPos, direction);
    float along0 = 0.0;
    float along1 = dot(float2(viewport.x, 0.0), direction);
    float along2 = dot(float2(0.0, viewport.y), direction);
    float along3 = dot(viewport, direction);
    float minAlong = min(min(along0, along1), min(along2, along3));
    float maxAlong = max(max(along0, along1), max(along2, along3));
    float screenProgress = saturate((screenAlong - minAlong) / max(maxAlong - minAlong, 1.0));

    // 不做全局平移，避免 ray cell 集体换种子导致“瞬移”。位置主要随世界/相机视差稳定移动。
    float rayCoord = dot(worldPos, perpendicular);
    float alongCoord = dot(worldPos, direction);

    float cellWidth = max(viewport.x / max(GodRayDensity, 1.0), 32.0);
    float baseCell = floor(rayCoord / cellWidth);

    // 手动采样相邻 3 个 cell，避免光柱中心靠近边界时被截断。
    float ray = CalculateSingleGodRay(rayCoord, alongCoord, screenProgress, cellWidth, baseCell - 1.0);
    ray = max(ray, CalculateSingleGodRay(rayCoord, alongCoord, screenProgress, cellWidth, baseCell));
    ray = max(ray, CalculateSingleGodRay(rayCoord, alongCoord, screenProgress, cellWidth, baseCell + 1.0));

    // 整体上仍然保持“从上方洒入”的感觉，底部自然变弱。
    float verticalFade = 1.0 - smoothstep(0.72, 1.08, uv.y);
    ray *= verticalFade;

    // 太阳角落的径向 haze，替代矩形边缘泛白块。
    float sourceX = step(0.0, -direction.x); // 早晨 direction.x < 0 => 右上角；傍晚 => 左上角。
    float2 aspect = float2(viewport.x / max(viewport.y, 1.0), 1.0);
    float cornerDist = length((uv - float2(sourceX, 0.0)) * aspect);
    float cornerGlow = 1.0 - smoothstep(0.0, 0.72, cornerDist);
    cornerGlow *= cornerGlow;
    float topHaze = (1.0 - smoothstep(0.0, 0.26, uv.y)) * 0.18;
    float edgeGlow = (cornerGlow * 0.42 + topHaze) * GodRayEdgeGlowIntensity;

    float rawIntensity = (ray * 0.95 + edgeGlow * 0.22) * GodRayIntensity * GodRayCloudFadeFactor;
    float intensity = 1.0 - exp(-rawIntensity);
    intensity = min(intensity, 0.18);
    clip(intensity - 0.0005);

    // 使用 Additive 混合，但用 alpha 上限控制最大加光量；同时压低蓝通道以保留暖色而非爆成纯白。
    float3 additiveColor = saturate(GodRayColor.rgb * float3(1.0, 0.88, 0.62));
    return float4(additiveColor, intensity);
}
