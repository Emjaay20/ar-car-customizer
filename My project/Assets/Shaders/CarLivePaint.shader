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

                // 1. Live camera crease / shutline Ambient Occlusion (AO)
                // Preserves deep door seams, hood gaps, badges without cartoon outlines
                float luma = dot(scene, float3(0.2126, 0.7152, 0.0722));
                float lumaDx = ddx(luma);
                float lumaDy = ddy(luma);
                float crease = saturate(sqrt(lumaDx * lumaDx + lumaDy * lumaDy) * 4.5);
                float ao = clamp(1.0 - crease * 0.75, 0.30, 1.0);

                // 2. Car-normalized 3D shading
                bool hasIntrinsic = abs(maskSample.r - maskSample.g) > 0.015 || abs(maskSample.g - maskSample.b) > 0.015;
                float normShade = hasIntrinsic ? intrinsicShade : smoothstep(0.08, 0.88, luma);

                // 3. 3D Surface normal & geometric grazing sheen
                float2 gradient = float2(ddx(mask), ddy(mask));
                float edgeGrad = length(gradient) * 3.5;
                float grazing = saturate(edgeGrad);

                // 4. PBR Finish-dependent parameters
                float paintLuma = dot(_Tint.rgb, float3(0.2126, 0.7152, 0.0722));
                
                float ambientFloor = lerp(0.68, 0.55, _Smoothness);
                float directScale = lerp(0.36, 0.54, _Smoothness);
                float clearcoatF0 = 0.03;
                float clearcoatGrazing = lerp(0.10, 0.38, _Smoothness);
                float specPower = lerp(12.0, 64.0, _Smoothness);

                if (paintLuma < 0.12)
                {
                    // Showroom Obsidian / Gloss Black: deep base + glass-like clearcoat
                    ambientFloor = 0.14;
                    directScale = 0.26;
                    clearcoatF0 = 0.05;
                    clearcoatGrazing = 0.45;
                }
                else if (paintLuma > 0.72)
                {
                    // Metallic Silver / Pure White
                    ambientFloor = 0.72;
                    directScale = 0.38;
                }

                half3 effectiveTint = (paintLuma < 0.12) ? max(_Tint.rgb, half3(0.08, 0.08, 0.08)) : _Tint.rgb;

                // Diffuse basecoat: 100% solid pigment, modulated by normalized lighting & AO
                float baseIllum = ambientFloor + directScale * pow(saturate(normShade), 0.88);
                half3 diffuse = effectiveTint * (baseIllum * ao);

                // Clearcoat dielectric specular reflection (Schlick Fresnel approximation)
                float directGlint = pow(saturate((normShade - 0.66) / 0.34), specPower / 14.0);
                float fresnelSheen = clearcoatF0 + (clearcoatGrazing - clearcoatF0) * grazing;
                
                half3 clearcoatColor = half3(1.0, 0.98, 0.96);
                half3 specular = clearcoatColor * (directGlint * 0.38 + fresnelSheen * 0.40);

                if (_Metallic > 0.25)
                {
                    // Metallic flake micro-sparkle in midtones
                    float flake = saturate(abs(lumaDx) + abs(lumaDy)) * _Metallic * 0.40;
                    diffuse *= (1.0 + flake);
                }

                return saturate(diffuse + specular);
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

                // Solid paint: 100% solid core across all sheet metal (zero see-through)
                // Sub-pixel anti-aliasing strictly at the mask perimeter
                float edgeAA = smoothstep(0.02, 0.14, mask);
                float solidCore = smoothstep(0.16, 0.30, mask);
                float effectiveStrength = (_Strength > 0.01) ? 1.0 : 0.0;
                float alpha = saturate(lerp(edgeAA, 1.0, solidCore) * effectiveStrength);
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

                float paintLuma = dot(_Tint.rgb, float3(0.2126, 0.7152, 0.0722));
                float ambientFloor = (paintLuma < 0.12) ? 0.14 : lerp(0.68, 0.55, _Smoothness);
                float directScale = (paintLuma < 0.12) ? 0.26 : lerp(0.36, 0.54, _Smoothness);
                fixed3 baseTint = (paintLuma < 0.12) ? max(_Tint.rgb, fixed3(0.08, 0.08, 0.08)) : _Tint.rgb;
                
                float baseIllum = ambientFloor + directScale * pow(saturate(normShade), 0.88);
                fixed3 diffuse = baseTint * baseIllum;

                float directGlint = pow(saturate((normShade - 0.66) / 0.34), lerp(1.2, 4.0, _Smoothness));
                fixed3 specColor = fixed3(1.0, 0.98, 0.96) * directGlint * _Smoothness * 0.35;

                float edgeAA = smoothstep(0.02, 0.14, mask);
                float solidCore = smoothstep(0.16, 0.30, mask);
                float alpha = saturate(lerp(edgeAA, 1.0, solidCore) * ((_Strength > 0.01) ? 1.0 : 0.0));
                if (alpha < 0.004) discard;
                return fixed4(saturate(diffuse + specColor), alpha);
            }
            ENDCG
        }
    }
}
