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

            half3 ShadePaint(float3 maskSample, float3 scene, float2 uv)
            {
                float mask = maskSample.r;

                // 1. Scene luminance and lighting gradient
                float rawLuma = dot(scene, float3(0.299, 0.587, 0.114));
                
                // Top-to-bottom macro 3D lighting gradient (sky illumination -> ground)
                float macroLight = lerp(0.88, 1.08, saturate(1.0 - uv.y * 0.75));
                
                // Gentle macro scene lighting modulation (smooth ambient adaptation, +/- 12%)
                // Clamped so dark dirt, water stains, and scratches on the underlying car NEVER bleed through!
                float sceneLight = lerp(0.88, 1.12, smoothstep(0.22, 0.78, rawLuma));

                // 2. Crisp mechanical panel seams (door shutlines, hood gaps)
                // Filtered with a threshold so surface blemishes/dirt (gradient < 0.14) do NOT trigger shadow
                float lumaDx = ddx(rawLuma);
                float lumaDy = ddy(rawLuma);
                float grad = sqrt(lumaDx * lumaDx + lumaDy * lumaDy);
                float seam = saturate((grad - 0.13) * 4.5);
                float ao = clamp(1.0 - seam * 0.32, 0.68, 1.0);

                // 3. PBR Finish-dependent parameters
                float paintLuma = dot(_Tint.rgb, float3(0.299, 0.587, 0.114));
                
                float clearcoatF0 = 0.04;
                float clearcoatGrazing = lerp(0.18, 0.48, _Smoothness);
                float specPower = lerp(16.0, 72.0, _Smoothness);

                if (paintLuma < 0.12)
                {
                    // Showroom Obsidian / Gloss Black:
                    // Rich deep black pigment + glass-like specular & environment reflections
                    clearcoatF0 = 0.06;
                    clearcoatGrazing = 0.60;
                }
                else if (paintLuma > 0.72)
                {
                    // Metallic Silver / Pure White
                    clearcoatF0 = 0.03;
                    clearcoatGrazing = 0.32;
                }

                half3 effectiveTint = (paintLuma < 0.12) ? max(_Tint.rgb, half3(0.07, 0.07, 0.07)) : _Tint.rgb;

                // 4. 100% Opaque Pigment Vinyl Basecoat: completely covers blemishes, scratches, and old paint!
                float totalIllum = macroLight * sceneLight;
                half3 diffuse = effectiveTint * (0.45 * _AmbientLightColor.rgb + 0.55 * totalIllum) * ao;

                // 5. Dielectric Clearcoat Specular Highlight & Sky Fresnel Reflection (Additive)
                float2 maskGrad = float2(ddx(mask), ddy(mask));
                float edgeCurvature = saturate(length(maskGrad) * 4.5);
                float fresnel = clearcoatF0 + (clearcoatGrazing - clearcoatF0) * pow(edgeCurvature, 1.25);

                // Sun / overhead light specular glint
                float directGlint = pow(saturate((rawLuma - 0.62) / 0.38), specPower / 6.0);
                half3 glintColor = half3(1.0, 0.99, 0.97) * directGlint * 0.65;

                // Environment sky reflection along vehicle curvature
                half3 envReflect = scene * fresnel * 0.90;
                half3 specular = (glintColor + envReflect) * _Smoothness;

                // Metallic flake micro-sparkle in midtones
                if (_Metallic > 0.25)
                {
                    float flake = saturate(abs(lumaDx) + abs(lumaDy)) * _Metallic * 0.35;
                    diffuse *= (1.0 + flake);
                }

                // Procedural Carbon Fiber weave if finish is carbon
                if (_Metallic > 0.80 && _Smoothness > 0.85 && _Metallic < 0.90)
                {
                    float2 carbonUV = frac(uv * 140.0);
                    float carbonWeave = ((carbonUV.x > 0.5) ^ (carbonUV.y > 0.5)) ? 0.84 : 1.16;
                    diffuse *= carbonWeave;
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
                // Cutoff uncertain noise while ensuring full sheet metal coverage
                if (mask < 0.10) discard;

                float3 opaqueScene = SampleSceneColor(screenUV);
                float3 camScene = SAMPLE_TEXTURE2D(_SceneTex, sampler_SceneTex, input.uv).rgb;
                float3 scene = max(opaqueScene, camScene);

                half3 paintRgb = ShadePaint(maskSample, scene, input.uv);

                // Full sheet metal coverage up to rubber gaskets with smooth anti-aliased edge
                float alpha = smoothstep(0.12, 0.35, mask) * ((_Strength > 0.01) ? 1.0 : 0.0);
                if (alpha < 0.005) discard;

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
                if (mask < 0.10) discard;

                float3 scene = tex2D(_SceneTex, input.uv).rgb;
                float rawLuma = dot(scene, float3(0.299, 0.587, 0.114));

                float macroLight = lerp(0.85, 1.15, saturate(1.0 - input.uv.y * 0.75));
                float sceneLight = lerp(0.85, 1.15, smoothstep(0.22, 0.78, rawLuma));

                float paintLuma = dot(_Tint.rgb, float3(0.299, 0.587, 0.114));
                fixed3 baseTint = (paintLuma < 0.12) ? max(_Tint.rgb, fixed3(0.07, 0.07, 0.07)) : _Tint.rgb;

                // 100% Opaque Pigment Vinyl Basecoat
                fixed3 diffuse = baseTint * (macroLight * sceneLight * 0.90);

                // Dielectric Specular Glint & Environmental Sheen (Additive)
                float directGlint = pow(saturate((rawLuma - 0.62) / 0.38), lerp(2.0, 16.0, _Smoothness));
                fixed3 specColor = fixed3(1.0, 0.99, 0.97) * directGlint * _Smoothness * 0.60;
                fixed3 envSheen = scene * (0.28 * _Smoothness);

                float alpha = smoothstep(0.12, 0.35, mask) * ((_Strength > 0.01) ? 1.0 : 0.0);
                if (alpha < 0.005) discard;
                return fixed4(saturate(diffuse + specColor + envSheen), alpha);
            }
            ENDCG
        }
    }
}
