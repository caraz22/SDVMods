//=============================================================================
// ShadowEffect.fx
// 阴影渲染 Shader - 支持渐变透明度、高斯模糊和动态斜切
// 目标: MonoGame OpenGL (Shader Model 3.0)
//=============================================================================

//-----------------------------------------------------------------------------
// 参数
//-----------------------------------------------------------------------------

//-----------------------------------------------------------------------------
// [静态参数] 从 ModConfig 读取（游戏启动时同步一次）
//-----------------------------------------------------------------------------

// 阴影渐变参数
float GradientStart;              // 阴影渐变初始透明度 (0-1, 靠近物体处)
float GradientEnd;                // 阴影渐变结束透明度 (0-1, 远离物体处)
float ShadowEdgeBlurIntensity;   // 阴影边缘模糊强度
float StackedShadowBlurScaleMax; // StackedShadow 远端最大模糊倍率
float StackedShadowBlurScaleMin; // StackedShadow 近端最小模糊倍率

// 移轴效果参数
float FocusCenter;                // 移轴焦点中心位置 (0-1, 屏幕Y坐标, 0.5 = 中央)
float TiltShiftBlur;              // 移轴模糊强度
float TopBlurRangeRatio;          // 顶部模糊带宽比例 (0-1)
float BottomBlurRangeRatio;       // 底部模糊带宽比例 (0-1)

//-----------------------------------------------------------------------------
// [动态参数] 从 ShadowState 读取（每帧/每日更新）
//-----------------------------------------------------------------------------

// 阴影颜色（每日更新：根据天气调整）
float4 ShadowColor;               // 阴影颜色 (RGBA)

// 动态阴影参数（每帧更新：根据时间计算）
float NormalizedShearX;           // 归一化水平斜切因子（预计算 = ShearX / 100.0）
                                   // 表示阴影倾斜程度：正值向右，负值向左
                                   // 实际像素偏移 = NormalizedShearX * spriteHeight * shearFactor
float ShadowLengthScale;          // 阴影长度缩放 (1.0 = 原始长度，用于时间变化)

//-----------------------------------------------------------------------------
// [渲染上下文参数] 每帧由 C# 设置
//-----------------------------------------------------------------------------

float2 TexelSize;                 // 纹理像素尺寸 (用于模糊采样偏移计算)
float2 ViewportSize;              // 当前绘制目标尺寸（用于全屏后处理）
float4x4 MatrixTransform;         // SpriteBatch 变换矩阵

//-----------------------------------------------------------------------------
// [God Ray 参数]
//-----------------------------------------------------------------------------
float GodRayTime;                 // 当前游戏运行秒数（用于程序化闪烁）
float2 GodRayCameraOffset;        // 视口世界坐标偏移（已由 C# 预乘视差系数）
float2 GodRayDirection;           // 光传播方向（屏幕空间单位向量）
float4 GodRayColor;               // 当前时间段的光柱颜色
float GodRayIntensity;            // 用户配置整体强度
float GodRayDensity;              // 光柱密度
float GodRayBaseWidth;            // 光柱基础宽度倍率
float GodRaySoftness;             // 光柱边缘柔和度
float GodRayFlickerSpeed;         // 光柱闪烁速度倍率
float GodRayEdgeGlowIntensity;    // 屏幕边缘 glow 强度
float GodRayCloudFadeFactor;      // 云影/天气之外的轻量云下淡出

//-----------------------------------------------------------------------------
// [树冠主体光照参数] 仅用于成熟 Oak Tree 测试版
//-----------------------------------------------------------------------------
float2 TreeCanopyLightSunDirection; // 树冠局部伪法线空间来光方向
float4 TreeCanopyLightColor;        // 迎光面颜色倍率，默认 (1.05, 1.00, 0.90)
float4 TreeCanopyShadowColor;       // 背光面颜色倍率，默认 (0.78, 0.84, 0.92)
float TreeCanopyLightStrength;      // 迎光面提亮强度
float TreeCanopyShadowStrength;     // 背光面压暗强度

float4 TextureGuidedPineLightColor;  // Pine 迎光中间调颜色倍率
float4 TextureGuidedPineShadowColor; // Pine 背光暗部颜色倍率
float4 TextureGuidedPineRimColor;    // Pine 受光边缘颜色倍率
float TextureGuidedPineLightStrength;
float TextureGuidedPineShadowStrength;
float TextureGuidedPineRimStrength;

//-----------------------------------------------------------------------------
// 功能模块
//-----------------------------------------------------------------------------

#include "Common.fxh"
#include "Shadow.fxh"
#include "StackedShadow.fxh"
#include "TiltShift.fxh"
#include "GodRay.fxh"
#include "CanopyLight.fxh"

//=============================================================================
// Technique 装配
//=============================================================================

//-----------------------------------------------------------------------------
// 阴影
//-----------------------------------------------------------------------------

technique NormalShadow
{
    pass P0
    {
        VertexShader = compile vs_3_0 ShearVertexShader();
        PixelShader = compile ps_3_0 NormalShadowPS();
    }
}

technique NormalShadowCacheBuild
{
    pass P0
    {
        VertexShader = compile vs_3_0 SpriteVertexShader();
        PixelShader = compile ps_3_0 NormalShadowCacheBuildPS();
    }
}

technique NormalShadowCachedShear
{
    pass P0
    {
        VertexShader = compile vs_3_0 CachedShearVertexShader();
        PixelShader = compile ps_3_0 NormalShadowCachedShearPS();
    }
}

technique SmallObjectShadow
{
    pass P0
    {
        VertexShader = compile vs_3_0 SpriteVertexShader();  // 无斜切
        PixelShader = compile ps_3_0 SmallObjectShadowPS();  // 无渐变
    }
}

technique HorizontalBlur
{
    pass P0
    {
        PixelShader = compile ps_3_0 HorizontalBlurPS();
    }
}

technique VerticalBlur
{
    pass P0
    {
        PixelShader = compile ps_3_0 VerticalBlurPS();
    }
}

technique Downsample
{
    pass P0
    {
        VertexShader = compile vs_3_0 SpriteVertexShader();
        PixelShader = compile ps_3_0 DownsamplePS();
    }
}

//-----------------------------------------------------------------------------
// 堆叠阴影
//-----------------------------------------------------------------------------

technique SquareBuildingShadowMask
{
    pass P0
    {
        VertexShader = compile vs_3_0 StackedShadowVS();
        PixelShader = compile ps_3_0 SquareBuildingShadowMaskPS();
    }
}

technique StackedShadowCachedMask
{
    pass P0
    {
        VertexShader = compile vs_3_0 SpriteVertexShader();
        PixelShader = compile ps_3_0 StackedShadowCachedMaskPS();
    }
}

technique StackedShadowBlurComposite
{
    pass P0
    {
        VertexShader = compile vs_3_0 SpriteVertexShader();
        PixelShader = compile ps_3_0 StackedShadowBlurCompositePS();
    }
}

//-----------------------------------------------------------------------------
// 移轴
//-----------------------------------------------------------------------------

technique TiltShiftDownsample
{
    pass P0
    {
        VertexShader = compile vs_3_0 SpriteVertexShader();
        PixelShader = compile ps_3_0 TiltShiftDownsamplePS();
    }
}

technique TiltShiftDownsampleHorizontalBlur
{
    pass P0
    {
        VertexShader = compile vs_3_0 SpriteVertexShader();
        PixelShader = compile ps_3_0 TiltShiftDownsampleHorizontalBlurPS();
    }
}

technique PureHorizontalBlur
{
    pass P0
    {
        VertexShader = compile vs_3_0 SpriteVertexShader();
        PixelShader = compile ps_3_0 PureHorizontalBlurPS();
    }
}

technique PureVerticalBlur
{
    pass P0
    {
        VertexShader = compile vs_3_0 SpriteVertexShader();
        PixelShader = compile ps_3_0 PureVerticalBlurPS();
    }
}

technique TiltShiftAlphaOutput
{
    pass P0
    {
        VertexShader = compile vs_3_0 SpriteVertexShader();
        PixelShader = compile ps_3_0 TiltShiftAlphaOutputPS();
    }
}

//-----------------------------------------------------------------------------
// God Ray
//-----------------------------------------------------------------------------

technique GodRay
{
    pass P0
    {
        VertexShader = compile vs_3_0 SpriteVertexShader();
        PixelShader = compile ps_3_0 GodRayPS();
    }
}

//-----------------------------------------------------------------------------
// 树冠光照
//-----------------------------------------------------------------------------

technique TreeCanopyLight
{
    pass P0
    {
        VertexShader = compile vs_3_0 SpriteVertexShader();
        PixelShader = compile ps_3_0 TreeCanopyLightPS();
    }
}

technique TextureGuidedPineCanopyLight
{
    pass P0
    {
        VertexShader = compile vs_3_0 SpriteVertexShader();
        PixelShader = compile ps_3_0 TextureGuidedPineCanopyLightPS();
    }
}
