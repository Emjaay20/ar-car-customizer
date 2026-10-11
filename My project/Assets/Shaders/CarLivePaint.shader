Shader "ARCar/LivePaint"
{
    Properties
    {
        _MaskTex ("Segmentation mask", 2D) = "black" {}
        _SceneTex ("Live camera scene", 2D) = "black" {}
        _Tint ("Tint", Color) = (0.61, 0.11, 0.19, 1)
        _Strength ("Strength", Range(0, 1)) = 0
        _Metallic ("Metallic", Range(0, 1)) = 0.08
        _Smoothness ("Smoothness", Range(0, 1)) = 0.92
        _Panel ("Panel", Float) = 0
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
                // Body (panel 0): paint 100% of the segmented sheet-metal mask
                if (panel < 0.5) return 1.0;
                // Approximate region gates until part-level segmentation is active
                if (panel < 1.5)
                {
                    return smoothstep(0.28, 0.38, uv.y) * smoothstep(0.66, 0.56, uv.y)
                        * smoothstep(0.18, 0.28, uv.x) * smoothstep(0.82, 0.72, uv.x);
                }
                if (panel < 2.5)
                {
                    return smoothstep(0.55, 0.65, uv.y)
                        * smoothstep(0.20, 0.30, uv.x) * smoothstep(0.80, 0.70, uv.x);
                }
                float side = max(smoothstep(0.42, 0.28, uv.x), smoothstep(0.58, 0.72, uv.x));
                return side * smoothstep(0.20, 0.30, uv.y) * smoothstep(0.68, 0.56, uv.y);
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

            half3 ShadePaint(float3 maskSample, float3 scene)
            {
                float mask = maskSample.r;
                float intrinsicShade = maskSample.g;
                float intrinsicSpec = maskSample.b;

                float2 gradient = float2(ddx(mask), ddy(mask));
                float3 normal = normalize(float3(-gradient * 4.5, 1.0));
                float3 lightDir = normalize(float3(0.35, 0.75, 0.60));
                float ndotl = saturate(dot(normal, lightDir));
                float3 halfDir = normalize(lightDir + float3(0, 0, 1));
                float specPower = lerp(10.0, 96.0, _Smoothness);
                float geomSpec = pow(saturate(dot(normal, halfDir)), specPower) * _Smoothness * _Smoothness;

                float luma = dot(scene, float3(0.2126, 0.7152, 0.0722));
                // High-frequency live camera crease/seam detail (ddx/ddy local contrast)
                float lumaDx = ddx(luma);
                float lumaDy = ddy(luma);
                float microEdge = saturate(sqrt(lumaDx * lumaDx + lumaDy * lumaDy) * 3.5);

                // Combine car-normalized 3D shading from worker (maskSample.g) with live camera shading
                // If an older monochrome mask is used (where R == G == B), fall back to normalized luma curve
                bool hasIntrinsic = abs(maskSample.r - maskSample.g) > 0.015 || abs(maskSample.g - maskSample.b) > 0.015;
                float normShade = hasIntrinsic ? intrinsicShade : smoothstep(0.08, 0.88, luma);

                // Finish-aware base-coat shading curve matching studio_polish_car_paint:
                // Deep, saturated midtones and dark creases so even bright white cars turn rich Candy Red / Gloss Black
                float shadeMin = lerp(0.36, 0.22, _Smoothness);
                float shadeSpan = lerp(0.54, 0.86, _Smoothness);
                float paintLuma = dot(_Tint.rgb, float3(0.2126, 0.7152, 0.0722));
                if (paintLuma > 0.70)
                {
                    shadeMin = 0.54;
                    shadeSpan = 0.46;
                }
                else if (paintLuma < 0.12)
                {
                    shadeMin = 0.04;
                    shadeSpan = 0.22;
                }

                float bodyShade = (shadeMin + shadeSpan * pow(saturate(normShade), 0.98)) * (1.0 - microEdge * 0.28);
                bodyShade = lerp(bodyShade, bodyShade * lerp(0.88, 1.08, ndotl), 0.22);

                // Clear-coat specular highlight only on the top 35% of car-normalized reflections (never across the whole white body)
                float specLayer = hasIntrinsic
                    ? saturate(intrinsicSpec / 0.92)
                    : pow(smoothstep(0.68, 0.96, normShade), 1.8);
                float specStrength = _Smoothness * _Smoothness * lerp(0.38, 0.62, _Metallic);
                if (paintLuma < 0.12)
                {
                    specStrength *= 0.68;
                }

                half3 baseTint = (paintLuma < 0.12) ? max(_Tint.rgb, half3(0.08, 0.08, 0.08)) : _Tint.rgb;
                half3 specColor = lerp(half3(1, 1, 1), _Tint.rgb * 0.55 + 0.45, saturate(_Metallic + (_Smoothness > 0.88 ? 0.35 : 0.0)));
                half3 diffuse = baseTint * bodyShade * (1.0 - _Metallic * 0.18);
                half3 totalSpec = specColor * (specLayer * specStrength + geomSpec * 0.22);
                half3 envReflect = scene * (specLayer * _Smoothness * ((paintLuma < 0.12) ? 0.14 : 0.20));
                return saturate(diffuse + totalSpec + envReflect);
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
                float3 maskSample = SAMPLE_TEXTURE2D(_MaskTex, sampler_MaskTex, input.uv).rgb;
                float2 screenUV = GetNormalizedScreenSpaceUV(input.positionHCS);

                // Live License Plate Privacy Blur: worker encodes plate region as R=0, B=1
                if (maskSample.r < 0.04 && maskSample.b > 0.82)
                {
                    half3 blurredPlate = SampleBlurredPlate(screenUV, input.uv);
                    return half4(blurredPlate, 0.98);
                }

                float mask = maskSample.r * PanelGate(input.uv, _Panel);
                if (mask < 0.02) discard;

                float3 opaqueScene = SampleSceneColor(screenUV);
                float3 camScene = SAMPLE_TEXTURE2D(_SceneTex, sampler_SceneTex, input.uv).rgb;
                float3 scene = max(opaqueScene, camScene);

                half3 paintRgb = ShadePaint(maskSample, scene);

                // Tolerant automotive edge feathering with 100% solid base-coat replacement on interior sheet metal
                float smoothMask = smoothstep(0.03, 0.30, mask);
                float effectiveStrength = saturate(max(_Strength, 0.96));
                float alpha = saturate(smoothMask * effectiveStrength);
                if (alpha < 0.004) discard;

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
                    return smoothstep(0.28, 0.38, uv.y) * smoothstep(0.66, 0.56, uv.y)
                        * smoothstep(0.18, 0.28, uv.x) * smoothstep(0.82, 0.72, uv.x);
                }
                if (panel < 2.5)
                {
                    return smoothstep(0.55, 0.65, uv.y)
                        * smoothstep(0.20, 0.30, uv.x) * smoothstep(0.80, 0.70, uv.x);
                }
                float side = max(smoothstep(0.42, 0.28, uv.x), smoothstep(0.58, 0.72, uv.x));
                return side * smoothstep(0.20, 0.30, uv.y) * smoothstep(0.68, 0.56, uv.y);
            }

            v2f vert(appdata input)
            {
                v2f output;
                output.vertex = UnityObjectToClipPos(input.vertex);
                output.uv = input.uv;
                return output;
            }

            fixed4 frag(v2f input) : SV_Target
            {
                float3 maskSample = tex2D(_MaskTex, input.uv).rgb;
                if (maskSample.r < 0.04 && maskSample.b > 0.82)
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

                float mask = maskSample.r * PanelGate(input.uv, _Panel);
                if (mask < 0.02) discard;

                float3 scene = tex2D(_SceneTex, input.uv).rgb;
                float luma = dot(scene, float3(0.2126, 0.7152, 0.0722));
                bool hasIntrinsic = abs(maskSample.r - maskSample.g) > 0.015 || abs(maskSample.g - maskSample.b) > 0.015;
                float normShade = hasIntrinsic ? maskSample.g : smoothstep(0.08, 0.88, luma);
                float specLayer = hasIntrinsic ? saturate(maskSample.b / 0.92) : pow(smoothstep(0.68, 0.96, normShade), 1.8);

                float paintLuma = dot(_Tint.rgb, float3(0.2126, 0.7152, 0.0722));
                float shadeMin = (paintLuma < 0.12) ? 0.04 : lerp(0.36, 0.24, _Smoothness);
                float shadeSpan = (paintLuma < 0.12) ? 0.22 : lerp(0.54, 0.84, _Smoothness);
                float bodyShade = shadeMin + shadeSpan * normShade;
                fixed3 baseTint = (paintLuma < 0.12) ? max(_Tint.rgb, fixed3(0.08, 0.08, 0.08)) : _Tint.rgb;
                fixed3 specColor = lerp(fixed3(1, 1, 1), _Tint.rgb * 0.55 + 0.45, _Metallic);
                fixed3 diffuse = baseTint * bodyShade * (1.0 - _Metallic * 0.18);
                float smoothMask = smoothstep(0.03, 0.30, mask);
                float alpha = saturate(smoothMask * max(_Strength, 0.96));
                if (alpha < 0.004) discard;
                return fixed4(saturate(diffuse + specColor * specLayer * _Smoothness * ((paintLuma < 0.12) ? 0.34 : 0.48)), alpha);
            }
            ENDCG
        }
    }
}
