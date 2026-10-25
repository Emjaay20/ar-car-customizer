Shader "ARCar/LivePaint"
{
    Properties
    {
        _MaskTex ("Segmentation mask", 2D) = "black" {}
        _SceneTex ("Live camera scene", 2D) = "black" {}
        _Tint ("Tint", Color) = (0.61, 0.11, 0.19, 1)
        _Strength ("Strength", Range(0, 1)) = 1.0
        _Metallic ("Metallic", Range(0, 1)) = 0.08
        _Smoothness ("Smoothness", Range(0, 1)) = 0.92
        _Panel ("Panel", Float) = 0
        _Finish ("Finish Mode", Float) = 0
        _MaskUVOffset ("Mask UV Offset", Vector) = (0, 0, 0, 0)
        _LetterboxAspect ("Letterbox Aspect", Float) = 1.0
        _DebugMaskMode ("Debug Mask Mode", Float) = 0
    }

    SubShader
    {
        PackageRequirements
        {
            "com.unity.render-pipelines.universal"
        }

        Tags
        {
            "RenderPipeline" = "UniversalPipeline"
            "Queue" = "Overlay"
            "RenderType" = "Transparent"
        }

        Blend SrcAlpha OneMinusSrcAlpha
        ZWrite Off
        ZTest Always
        Cull Off

        Pass
        {
            Name "LivePaint"
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareOpaqueTexture.hlsl"

            TEXTURE2D(_MaskTex);
            SAMPLER(sampler_MaskTex);
            TEXTURE2D(_SceneTex);
            SAMPLER(sampler_SceneTex);

            CBUFFER_START(UnityPerMaterial)
                float4 _Tint;
                float _Strength;
                float _Metallic;
                float _Smoothness;
                float _Panel;
                float _Finish;
                float4 _MaskUVOffset;
                float _LetterboxAspect;
                float _DebugMaskMode;
            CBUFFER_END

            struct Attributes
            {
                float4 positionOS : POSITION;
                float2 uv : TEXCOORD0;
            };

            struct Varyings
            {
                float4 positionHCS : SV_POSITION;
                float2 uv : TEXCOORD0;
            };

            float PanelGate(float2 uv, float panel)
            {
                // Body (panel 0): 100% full vehicle wrap
                if (panel < 0.5) return 1.0;
                // Hood (panel 1): center mid-lower sheet metal (hood / bonnet)
                if (panel < 1.5)
                {
                    return smoothstep(0.44, 0.54, uv.y) * smoothstep(0.78, 0.68, uv.y)
                         * smoothstep(0.20, 0.30, uv.x) * smoothstep(0.80, 0.70, uv.x);
                }
                // Two-Tone Floating Roof (panel 2): upper cabin sheet metal (roof & pillars)
                if (panel < 2.5)
                {
                    return smoothstep(0.16, 0.26, uv.y) * smoothstep(0.48, 0.38, uv.y)
                         * smoothstep(0.22, 0.32, uv.x) * smoothstep(0.78, 0.68, uv.x);
                }
                // Doors (panel 3): left and right sides
                if (panel < 3.5)
                {
                    float side = max(smoothstep(0.42, 0.28, uv.x), smoothstep(0.58, 0.72, uv.x));
                    return side * smoothstep(0.25, 0.35, uv.y) * smoothstep(0.75, 0.65, uv.y);
                }
                // Mirrors & Accents (panel 4): outer mid sides
                float mirrorSide = max(smoothstep(0.25, 0.12, uv.x), smoothstep(0.75, 0.88, uv.x));
                return mirrorSide * smoothstep(0.32, 0.42, uv.y) * smoothstep(0.62, 0.52, uv.y);
            }

            half3 SampleBlurredPlate(float2 screenUV, float2 uv)
            {
                half3 acc = half3(0, 0, 0);
                float2 stepScreen = float2(0.0085, 0.0065);
                [unroll]
                for (int y = -2; y <= 2; y++)
                {
                    [unroll]
                    for (int x = -2; x <= 2; x++)
                    {
                        float2 offset = float2(x, y) * stepScreen;
                        float3 s1 = SampleSceneColor(saturate(screenUV + offset));
                        float3 s2 = SAMPLE_TEXTURE2D(_SceneTex, sampler_SceneTex, saturate(uv + offset)).rgb;
                        acc += max(s1, s2);
                    }
                }
                return acc / 25.0;
            }

            // Meta AI RGB <-> HSV conversion with Value preservation (keeps shadows/reflections, stops see-through pink)
            float3 rgb2hsv(float3 c)
            {
                float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
                float4 p = lerp(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
                float4 q = lerp(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
                float d = q.x - min(q.w, q.y);
                float e = 1.0e-10;
                return float3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
            }

            float3 hsv2rgb(float3 c)
            {
                float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
                float3 p = abs(frac(c.xxx + K.xyz) * 6.0 - K.www);
                return c.z * lerp(K.xxx, saturate(p - K.xxx), c.y);
            }

            float2 GetSmoothedUV(float2 uv, float2 texSize)
            {
                float2 pixel = uv * texSize - 0.5;
                float2 f = frac(pixel);
                // C2 continuous quintic Hermite polynomial: 6f^5 - 15f^4 + 10f^3
                float2 s = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
                return (floor(pixel) + 0.5 + s) / texSize;
            }

            float2 GetMaskUV(float2 screenUV)
            {
                if (_LetterboxAspect < 0.95 && _LetterboxAspect > 0.1)
                {
                    float offsetY = (1.0 - _LetterboxAspect) * 0.5;
                    float maskY = (screenUV.y - offsetY) / _LetterboxAspect;
                    return float2(screenUV.x, maskY);
                }
                return screenUV;
            }

            float SampleAntiAliasedMask(float2 maskUV, float2 screenUV, float3 centerScene)
            {
                if (maskUV.y < 0.0 || maskUV.y > 1.0 || maskUV.x < 0.0 || maskUV.x > 1.0)
                    return 0.0;
                float2 texSize = float2(384.0, 384.0);
                float2 smUV = GetSmoothedUV(maskUV, texSize);
                float centerMask = SAMPLE_TEXTURE2D(_MaskTex, sampler_MaskTex, smUV).r;

                // Fast path inside deep interior or completely outside mask
                if (centerMask > 0.92 || centerMask < 0.03)
                    return centerMask;

                // 3x3 Edge-Guided Joint Bilateral Filter: snaps 384px neural mask to 1080p camera edges
                float2 maskStep = 1.0 / texSize;
                float2 sceneStep = float2(0.0022, 0.0022);
                float sumMask = 0.0;
                float sumWeight = 0.0;

                [unroll]
                for (int dy = -1; dy <= 1; dy++)
                {
                    [unroll]
                    for (int dx = -1; dx <= 1; dx++)
                    {
                        float2 mOff = float2(dx, dy) * maskStep;
                        float2 sOff = float2(dx, dy) * sceneStep;
                        float mVal = SAMPLE_TEXTURE2D(_MaskTex, sampler_MaskTex, saturate(smUV + mOff)).r;
                        float3 sCol = SampleSceneColor(saturate(screenUV + sOff));
                        float3 diff = sCol - centerScene;
                        float dist2 = dot(diff, diff);
                        float spatialW = (dx == 0 && dy == 0) ? 1.5 : ((dx == 0 || dy == 0) ? 1.0 : 0.7);
                        float rangeW = exp(-dist2 / 0.018);
                        float w = spatialW * rangeW;
                        sumMask += mVal * w;
                        sumWeight += w;
                    }
                }
                return sumMask / max(sumWeight, 1e-4);
            }

            half3 ShadePaint(float mask, float3 sceneLinear, float2 uv, float2 screenUV)
            {
                // Convert Linear inputs to perceptual sRGB for lighting calculations
                float3 tintSrgb = pow(max(_Tint.rgb, 0.0), 1.0 / 2.2);
                float targetLuma = dot(tintSrgb, float3(0.299, 0.587, 0.114));

                float3 sceneSrgb = pow(max(sceneLinear, 0.0), 1.0 / 2.2);
                float rawLuma = dot(sceneSrgb, float3(0.299, 0.587, 0.114));
                float normShade = saturate((rawLuma - 0.05) / 0.85);

                // Intrinsic detail ratio (preserves door seams, fuel cap lines, and body creases)
                float2 dStep = float2(0.003, 0.003);
                float3 n1 = pow(max(SampleSceneColor(saturate(screenUV + float2(dStep.x, 0))), 0.0), 1.0 / 2.2);
                float3 n2 = pow(max(SampleSceneColor(saturate(screenUV - float2(dStep.x, 0))), 0.0), 1.0 / 2.2);
                float3 n3 = pow(max(SampleSceneColor(saturate(screenUV + float2(0, dStep.y))), 0.0), 1.0 / 2.2);
                float3 n4 = pow(max(SampleSceneColor(saturate(screenUV - float2(0, dStep.y))), 0.0), 1.0 / 2.2);
                float l1 = dot(n1, float3(0.299, 0.587, 0.114));
                float l2 = dot(n2, float3(0.299, 0.587, 0.114));
                float l3 = dot(n3, float3(0.299, 0.587, 0.114));
                float l4 = dot(n4, float3(0.299, 0.587, 0.114));
                float broadLuma = (l1 + l2 + l3 + l4) * 0.25;
                float minNeighborLuma = min(min(l1, l2), min(l3, l4));

                // Wide 4-tap macro illumination (~30px radius) to separate 3D body curvature from wide HDR sky reflections
                float2 mStep = float2(0.028, 0.028);
                float3 m1 = pow(max(SampleSceneColor(saturate(screenUV + float2(mStep.x, mStep.y))), 0.0), 1.0 / 2.2);
                float3 m2 = pow(max(SampleSceneColor(saturate(screenUV + float2(-mStep.x, mStep.y))), 0.0), 1.0 / 2.2);
                float3 m3 = pow(max(SampleSceneColor(saturate(screenUV + float2(mStep.x, -mStep.y))), 0.0), 1.0 / 2.2);
                float3 m4 = pow(max(SampleSceneColor(saturate(screenUV + float2(-mStep.x, -mStep.y))), 0.0), 1.0 / 2.2);
                float macroLuma = dot((m1 + m2 + m3 + m4) * 0.25, float3(0.299, 0.587, 0.114));
                normShade = saturate((macroLuma - 0.08) / 0.80);

                // Crevice-only detail ratio: darkens panel gaps & door handles (<1.0), never boosts bright edges next to dark seams
                float detailRatio = clamp((rawLuma + 0.03) / (broadLuma + 0.03), 0.60, 1.01);
                // Seam-free HDR clearcoat reflection: captures sky/palm-tree reflections on hood & roof without white-paint wash
                float seamFree = smoothstep(0.48, 0.66, minNeighborLuma);
                float envReflect = smoothstep(0.006, 0.085, broadLuma - macroLuma * 1.003) * seamFree;

                // Crisp shutlines / panel gaps (DDX/DDY on perceptual luma)
                float lumaDx = ddx(rawLuma);
                float lumaDy = ddy(rawLuma);
                float grad = sqrt(lumaDx * lumaDx + lumaDy * lumaDy);
                float seam = saturate((grad - 0.10) * 6.0);
                float ao = clamp(1.0 - seam * 0.35, 0.62, 1.0) * detailRatio;

                float3 diffuse = float3(0, 0, 0);
                float3 specular = float3(0, 0, 0);

                // Finish Modes: 0=gloss, 1=matte, 2=satin, 3=metallic, 4=candy, 5=carbon
                if (_Finish > 0.5 && _Finish < 1.5)
                {
                    // === 1. 3M 2080 MATTE STEALTH FINISH (0% clearcoat glint, deep solid diffuse) ===
                    if (targetLuma < 0.15)
                    {
                        float bodyLuma = 0.032 + 0.050 * normShade;
                        float velvetSheen = pow(normShade, 2.0) * 0.012;
                        diffuse = (float3(bodyLuma, bodyLuma, bodyLuma + 0.002) + velvetSheen) * ao;
                    }
                    else
                    {
                        diffuse = tintSrgb * clamp(0.68 + 0.32 * normShade, 0.62, 1.04) * ao;
                    }
                    specular = float3(0, 0, 0);
                }
                else if (_Finish > 1.5 && _Finish < 2.5)
                {
                    // === 2. SATIN OEM+ FINISH (silky eggshell horizon glow, no sharp mirror) ===
                    float satinGlow = pow(normShade, 2.2) * 0.12 + envReflect * 0.14;
                    if (targetLuma < 0.15)
                    {
                        float bodyLuma = 0.024 + 0.056 * normShade;
                        diffuse = float3(bodyLuma, bodyLuma, bodyLuma + 0.003) * ao;
                    }
                    else
                    {
                        diffuse = tintSrgb * clamp(0.56 + 0.44 * normShade, 0.50, 1.10) * ao;
                    }
                    float directGlint = pow(saturate((rawLuma - 0.75) / 0.25), 16.0);
                    specular = float3(0.96, 0.98, 1.0) * (satinGlow + directGlint * 0.22);
                }
                else if (_Finish > 2.5 && _Finish < 3.5)
                {
                    // === 3. METALLIC FINISH (anisotropic metallic micro-flake + clearcoat) ===
                    float flake = saturate(abs(lumaDx) + abs(lumaDy)) * 0.32;
                    diffuse = tintSrgb * clamp(0.48 + 0.54 * normShade, 0.44, 1.16) * (1.0 + flake) * ao;
                    float directGlint = pow(saturate((rawLuma - 0.70) / 0.30), 28.0);
                    specular = float3(0.98, 0.99, 1.0) * (envReflect * 0.35 + directGlint * 0.58);
                }
                else if (_Finish > 3.5 && _Finish < 4.5)
                {
                    // === 4. HOUSE OF KOLOR LIQUID CANDY FINISH (deep ruby shadows -> vivid midtones + wet clearcoat) ===
                    float normCandy = pow(normShade, 1.20);
                    float3 deepBase = pow(max(tintSrgb, 0.001), 1.55) * 0.38;
                    float3 brightMid = saturate(tintSrgb * 1.28);
                    diffuse = lerp(deepBase, brightMid, normCandy) * ao;
                    float directGlint = pow(saturate((rawLuma - 0.68) / 0.32), 32.0);
                    specular = float3(1.0, 0.98, 0.96) * (envReflect * 0.44 + directGlint * 0.70) + tintSrgb * envReflect * 0.18;
                }
                else if (_Finish >= 4.5)
                {
                    // === 5. CARBON FIBER ===
                    float2 carbonUV = frac(uv * 140.0);
                    float carbonWeave = ((carbonUV.x > 0.5) ^ (carbonUV.y > 0.5)) ? 0.80 : 1.20;
                    diffuse = float3(0.036, 0.036, 0.040) * carbonWeave * lerp(0.58, 1.22, normShade) * ao;
                    float directGlint = pow(saturate((rawLuma - 0.72) / 0.28), 24.0);
                    specular = float3(0.98, 0.99, 1.0) * (envReflect * 0.25 + directGlint * 0.38);
                }
                else
                {
                    // === 0. INOZETEK SUPER GLOSS SHOWROOM FINISH (Liquid Piano Base + Crisp Clearcoat Reflection) ===
                    if (targetLuma < 0.15)
                    {
                        diffuse = float3(0.015, 0.015, 0.019) * lerp(0.45, 1.25, normShade) * ao;
                        float directGlint = pow(saturate((rawLuma - 0.72) / 0.28), 26.0);
                        specular = float3(0.96, 0.98, 1.0) * (envReflect * 0.42 + directGlint * 0.65);
                    }
                    else
                    {
                        diffuse = tintSrgb * clamp(0.46 + 0.56 * normShade, 0.40, 1.15) * ao;
                        float directGlint = pow(saturate((rawLuma - 0.74) / 0.26), 24.0);
                        specular = float3(0.98, 0.99, 1.0) * (envReflect * 0.36 + directGlint * 0.50);
                    }
                }

                // Combine diffuse and HDR specular with filmic highlight roll-off, then convert back to Linear for URP
                float3 rawHdr = diffuse + specular * seamFree;
                float3 paintSrgb = saturate(rawHdr / (1.0 + 0.18 * max(0.0, rawHdr - 0.82)));
                return pow(paintSrgb, 2.2);
            }

            Varyings vert(Attributes input)
            {
                Varyings output;
                output.positionHCS = TransformObjectToHClip(input.positionOS.xyz);
                output.uv = input.uv;
                return output;
            }

            half4 frag(Varyings input) : SV_Target
            {
                // ARCore 6DoF continuous tracking offset between inferences
                float2 maskUV = GetMaskUV(input.uv - _MaskUVOffset.xy);
                float3 rawSample = (maskUV.y < 0.0 || maskUV.y > 1.0 || maskUV.x < 0.0 || maskUV.x > 1.0)
                    ? float3(0, 0, 0)
                    : SAMPLE_TEXTURE2D(_MaskTex, sampler_MaskTex, maskUV).rgb;
                float2 screenUV = GetNormalizedScreenSpaceUV(input.positionHCS);

                // Live License Plate Privacy Blur: worker encodes plate region as R=0, B=1
                if (rawSample.r < 0.04 && rawSample.b > 0.82)
                {
                    half3 blurredPlate = SampleBlurredPlate(screenUV, input.uv);
                    return half4(blurredPlate, 0.98);
                }

                // Sample fresh camera scene directly from URP camera buffer
                float3 scene = SampleSceneColor(screenUV);
                float3 sceneSrgb = pow(max(scene, 0.0), 1.0 / 2.2);
                float rawLuma = dot(sceneSrgb, float3(0.299, 0.587, 0.114));

                float smoothMask = SampleAntiAliasedMask(maskUV, screenUV, scene);
                // Protect dark rubber window seals, mirror glass, and tire edges near mask boundaries
                if (smoothMask < 0.82 && rawLuma < 0.14)
                    smoothMask *= smoothstep(0.05, 0.14, rawLuma);

                float mask = smoothMask * PanelGate(input.uv, _Panel);

                // Diagnostic Mask View Mode (emerald overlay + bright contour border)
                if (_DebugMaskMode > 0.5)
                {
                    float maskAlpha = smoothstep(0.18, 0.32, mask) * ((_Strength > 0.01) ? 0.74 : 0.0);
                    if (maskAlpha < 0.01) discard;
                    float isBorder = (mask > 0.20 && mask < 0.42) ? 1.0 : 0.0;
                    float3 debugSrgb = lerp(float3(0.04, 0.92, 0.38), float3(0.95, 1.0, 0.20), isBorder);
                    return half4(pow(debugSrgb, 2.2), maskAlpha);
                }

                half3 paintRgb = ShadePaint(mask, scene, input.uv, screenUV);

                float lumaDx = ddx(rawLuma);
                float lumaDy = ddy(rawLuma);
                float grad = sqrt(lumaDx * lumaDx + lumaDy * lumaDy);
                float seam = saturate((grad - 0.10) * 6.0);

                // Solid 100% opaque basecoat inside sheet metal (0% transparency on white car)
                // Controlled edge-snap anti-aliasing in [0.18, 0.32] prevents spill onto pavers
                float edgeSnap = saturate(1.0 - seam * 0.40);
                float edgeAlpha = smoothstep(0.18, 0.32, mask) * edgeSnap;
                float alpha = (mask > 0.32) ? 1.0 : edgeAlpha;
                alpha *= ((_Strength > 0.01) ? 1.0 : 0.0);
                if (alpha < 0.01) discard;

                return half4(paintRgb, alpha);
            }
            ENDHLSL
        }
    }

    SubShader
    {
        Tags { "Queue" = "Overlay" "RenderType" = "Transparent" }
        Blend SrcAlpha OneMinusSrcAlpha
        ZWrite Off
        ZTest Always
        Cull Off

        Pass
        {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #include "UnityCG.cginc"

            sampler2D _MaskTex;
            sampler2D _SceneTex;
            fixed4 _Tint;
            float _Strength;
            float _Metallic;
            float _Smoothness;
            float _Panel;
            float _Finish;
            float4 _MaskUVOffset;
            float _LetterboxAspect;
            float _DebugMaskMode;

            struct appdata
            {
                float4 vertex : POSITION;
                float2 uv : TEXCOORD0;
            };

            struct v2f
            {
                float4 vertex : SV_POSITION;
                float2 uv : TEXCOORD0;
            };

            float PanelGate(float2 uv, float panel)
            {
                if (panel < 0.5) return 1.0;
                if (panel < 1.5)
                {
                    return smoothstep(0.44, 0.54, uv.y) * smoothstep(0.78, 0.68, uv.y)
                         * smoothstep(0.20, 0.30, uv.x) * smoothstep(0.80, 0.70, uv.x);
                }
                if (panel < 2.5)
                {
                    return smoothstep(0.16, 0.26, uv.y) * smoothstep(0.48, 0.38, uv.y)
                         * smoothstep(0.22, 0.32, uv.x) * smoothstep(0.78, 0.68, uv.x);
                }
                if (panel < 3.5)
                {
                    float side = max(smoothstep(0.42, 0.28, uv.x), smoothstep(0.58, 0.72, uv.x));
                    return side * smoothstep(0.25, 0.35, uv.y) * smoothstep(0.75, 0.65, uv.y);
                }
                float mirrorSide = max(smoothstep(0.25, 0.12, uv.x), smoothstep(0.75, 0.88, uv.x));
                return mirrorSide * smoothstep(0.32, 0.42, uv.y) * smoothstep(0.62, 0.52, uv.y);
            }

            v2f vert(appdata input)
            {
                v2f output;
                output.vertex = UnityObjectToClipPos(input.vertex);
                output.uv = input.uv;
                return output;
            }

            float3 rgb2hsv(float3 c)
            {
                float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
                float4 p = lerp(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
                float4 q = lerp(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
                float d = q.x - min(q.w, q.y);
                float e = 1.0e-10;
                return float3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
            }

            float3 hsv2rgb(float3 c)
            {
                float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
                float3 p = abs(frac(c.xxx + K.xyz) * 6.0 - K.www);
                return c.z * lerp(K.xxx, saturate(p - K.xxx), c.y);
            }

            float2 GetSmoothedUVCG(float2 uv, float2 texSize)
            {
                float2 pixel = uv * texSize - 0.5;
                float2 f = frac(pixel);
                float2 s = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
                return (floor(pixel) + 0.5 + s) / texSize;
            }

            float2 GetMaskUVCG(float2 screenUV)
            {
                if (_LetterboxAspect < 0.95 && _LetterboxAspect > 0.1)
                {
                    float offsetY = (1.0 - _LetterboxAspect) * 0.5;
                    float maskY = (screenUV.y - offsetY) / _LetterboxAspect;
                    return float2(screenUV.x, maskY);
                }
                return screenUV;
            }

            float SampleAntiAliasedMaskCG(float2 maskUV)
            {
                if (maskUV.y < 0.0 || maskUV.y > 1.0 || maskUV.x < 0.0 || maskUV.x > 1.0)
                    return 0.0;
                float2 texSize = float2(384.0, 384.0);
                float2 smUV = GetSmoothedUVCG(maskUV, texSize);
                return tex2D(_MaskTex, smUV).r;
            }

            fixed4 frag(v2f input) : SV_Target
            {
                float2 maskUV = GetMaskUVCG(input.uv - _MaskUVOffset.xy);
                float3 rawSample = (maskUV.y < 0.0 || maskUV.y > 1.0 || maskUV.x < 0.0 || maskUV.x > 1.0)
                    ? float3(0, 0, 0)
                    : tex2D(_MaskTex, maskUV).rgb;
                if (rawSample.r < 0.04 && rawSample.b > 0.82)
                {
                    float3 blurAcc = 0;
                    float2 stepUV = float2(0.008, 0.006);
                    for (int y = -1; y <= 1; y++)
                    {
                        for (int x = -1; x <= 1; x++)
                        {
                            blurAcc += tex2D(_SceneTex, saturate(input.uv + float2(x, y) * stepUV)).rgb;
                        }
                    }
                    return fixed4(blurAcc / 9.0, 0.98);
                }

                float3 sceneLinear = tex2D(_SceneTex, input.uv).rgb;
                float3 tintSrgb = pow(max(_Tint.rgb, 0.0), 1.0 / 2.2);
                float targetLuma = dot(tintSrgb, float3(0.299, 0.587, 0.114));

                float3 sceneSrgb = pow(max(sceneLinear, 0.0), 1.0 / 2.2);
                float rawLuma = dot(sceneSrgb, float3(0.299, 0.587, 0.114));
                float normShade = saturate((rawLuma - 0.05) / 0.85);

                float smoothMask = SampleAntiAliasedMaskCG(maskUV);
                if (smoothMask < 0.82 && rawLuma < 0.14)
                    smoothMask *= smoothstep(0.05, 0.14, rawLuma);
                float mask = smoothMask * PanelGate(input.uv, _Panel);

                if (_DebugMaskMode > 0.5)
                {
                    float maskAlpha = smoothstep(0.18, 0.32, mask) * ((_Strength > 0.01) ? 0.74 : 0.0);
                    if (maskAlpha < 0.01) discard;
                    float isBorder = (mask > 0.20 && mask < 0.42) ? 1.0 : 0.0;
                    float3 debugSrgb = lerp(float3(0.04, 0.92, 0.38), float3(0.95, 1.0, 0.20), isBorder);
                    return fixed4(pow(debugSrgb, 2.2), maskAlpha);
                }

                float lumaDx = ddx(rawLuma);
                float lumaDy = ddy(rawLuma);
                float grad = sqrt(lumaDx * lumaDx + lumaDy * lumaDy);
                float seam = saturate((grad - 0.10) * 6.0);
                float ao = clamp(1.0 - seam * 0.35, 0.65, 1.0);

                float3 diffuse = float3(0, 0, 0);
                float3 specular = float3(0, 0, 0);

                if (_Finish > 0.5 && _Finish < 1.5)
                {
                    // Matte
                    if (targetLuma < 0.15)
                    {
                        float bodyLuma = 0.030 + 0.048 * normShade;
                        float velvetSheen = pow(normShade, 2.0) * 0.012;
                        diffuse = (float3(bodyLuma, bodyLuma, bodyLuma + 0.002) + velvetSheen) * ao;
                    }
                    else
                    {
                        diffuse = tintSrgb * clamp(0.70 + 0.30 * normShade, 0.65, 1.05) * ao;
                    }
                    specular = float3(0, 0, 0);
                }
                else if (_Finish > 1.5 && _Finish < 2.5)
                {
                    // Satin
                    if (targetLuma < 0.15)
                    {
                        float bodyLuma = 0.022 + 0.052 * normShade;
                        diffuse = float3(bodyLuma, bodyLuma, bodyLuma + 0.003) * ao;
                    }
                    else
                    {
                        diffuse = tintSrgb * clamp(0.58 + 0.42 * normShade, 0.52, 1.10) * ao;
                    }
                    float directGlint = pow(saturate((rawLuma - 0.75) / 0.25), 18.0);
                    specular = float3(1.0, 0.99, 0.97) * directGlint * 0.25;
                }
                else if (_Finish > 2.5 && _Finish < 3.5)
                {
                    // Metallic
                    float flake = saturate(abs(lumaDx) + abs(lumaDy)) * 0.28;
                    diffuse = tintSrgb * clamp(0.50 + 0.52 * normShade, 0.45, 1.15) * (1.0 + flake) * ao;
                    float directGlint = pow(saturate((rawLuma - 0.70) / 0.30), 32.0);
                    specular = float3(1.0, 0.99, 0.97) * directGlint * 0.60;
                }
                else if (_Finish > 3.5 && _Finish < 4.5)
                {
                    // Candy
                    float normCandy = pow(normShade, 1.15);
                    float3 deepBase = tintSrgb * 0.62;
                    float3 brightMid = tintSrgb * 1.28;
                    diffuse = lerp(deepBase, brightMid, normCandy) * ao;
                    float directGlint = pow(saturate((rawLuma - 0.68) / 0.32), 36.0);
                    specular = float3(1.0, 0.98, 0.95) * directGlint * 0.70;
                }
                else if (_Finish >= 4.5)
                {
                    // Carbon
                    float2 carbonUV = frac(input.uv * 140.0);
                    float carbonWeave = ((carbonUV.x > 0.5) ^ (carbonUV.y > 0.5)) ? 0.82 : 1.18;
                    diffuse = float3(0.038, 0.038, 0.042) * carbonWeave * lerp(0.6, 1.2, normShade) * ao;
                    float directGlint = pow(saturate((rawLuma - 0.72) / 0.28), 24.0);
                    specular = float3(1.0, 0.99, 0.97) * directGlint * 0.40;
                }
                else
                {
                    // Gloss
                    if (targetLuma < 0.15)
                    {
                        diffuse = float3(0.016, 0.016, 0.020) * lerp(0.5, 1.25, normShade) * ao;
                        float directGlint = pow(saturate((rawLuma - 0.72) / 0.28), 28.0);
                        specular = float3(1.0, 0.99, 0.97) * directGlint * 0.65;
                    }
                    else
                    {
                        diffuse = tintSrgb * clamp(0.48 + 0.54 * normShade, 0.42, 1.15) * ao;
                        float directGlint = pow(saturate((rawLuma - 0.74) / 0.26), 24.0);
                        specular = float3(1.0, 0.99, 0.97) * directGlint * 0.48;
                    }
                }

                float3 paintSrgb = saturate(diffuse + specular);
                fixed3 paintLinear = pow(paintSrgb, 2.2);

                float edgeSnap = saturate(1.0 - seam * 0.40);
                float edgeAlpha = smoothstep(0.18, 0.32, mask) * edgeSnap;
                float alpha = (mask > 0.32) ? 1.0 : edgeAlpha;
                alpha *= ((_Strength > 0.01) ? 1.0 : 0.0);
                if (alpha < 0.01) discard;
                return fixed4(paintLinear, alpha);
            }
            ENDCG
        }
    }
}
