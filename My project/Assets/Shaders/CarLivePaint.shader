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

            half3 ShadePaint(float mask, float3 scene, out float alphaScale)
            {
                float2 gradient = float2(ddx(mask), ddy(mask));
                float3 normal = normalize(float3(-gradient * 5.0, 1.0));
                float3 lightDir = normalize(float3(0.35, 0.75, 0.60));
                float ndotl = saturate(dot(normal, lightDir));
                float3 halfDir = normalize(lightDir + float3(0, 0, 1));
                float specPower = lerp(8.0, 88.0, _Smoothness);
                float geomSpec = pow(saturate(dot(normal, halfDir)), specPower) * _Smoothness * _Smoothness;

                float luma = dot(scene, float3(0.2126, 0.7152, 0.0722));
                float energy = max(luma, max(scene.r, max(scene.g, scene.b)));

                // Intrinsic-style shading curve so even dark/black cars take light colors (Super White, Silver, Candy Red)
                // while preserving 3D hood creases and real clear-coat reflections
                float bodyShade = energy > 0.015
                    ? lerp(0.78, 1.14, smoothstep(0.02, 0.58, luma))
                    : lerp(0.74, 1.06, ndotl);

                float realHighlight = energy > 0.015
                    ? smoothstep(0.48, 0.86, luma) * _Smoothness
                    : 0.0;

                // Protect intense white glare / headlights from heavy tinting
                float cmax = max(scene.r, max(scene.g, scene.b));
                float cmin = min(scene.r, min(scene.g, scene.b));
                float sat = (cmax - cmin) / (cmax + 0.001);
                float glareSuppress = smoothstep(0.76, 0.92, luma) * (1.0 - smoothstep(0.10, 0.32, sat));
                alphaScale = 1.0 - 0.75 * glareSuppress;

                half3 specColor = lerp(half3(1, 1, 1), _Tint.rgb * 0.7 + 0.3, _Metallic);
                half3 diffuse = _Tint.rgb * bodyShade * (1.0 - _Metallic * 0.28);
                half3 totalSpec = specColor * (geomSpec * 0.45 + realHighlight * 0.55);
                return saturate(diffuse + totalSpec);
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
                float mask = SAMPLE_TEXTURE2D(_MaskTex, sampler_MaskTex, input.uv).r;
                mask *= PanelGate(input.uv, _Panel);
                if (mask < 0.02) discard;

                float2 screenUV = GetNormalizedScreenSpaceUV(input.positionHCS);
                float3 opaqueScene = SampleSceneColor(screenUV);
                float3 camScene = SAMPLE_TEXTURE2D(_SceneTex, sampler_SceneTex, input.uv).rgb;
                float3 scene = max(opaqueScene, camScene);

                float alphaScale = 1.0;
                half3 paintRgb = ShadePaint(mask, scene, alphaScale);

                // Smooth feather on mask boundaries, strong coverage on sheet metal interior
                float smoothMask = smoothstep(0.08, 0.55, mask);
                float paintLuma = dot(_Tint.rgb, float3(0.2126, 0.7152, 0.0722));
                // Boost coverage slightly for bright paints (e.g., Super White on a black car)
                float effectiveStrength = saturate(_Strength + paintLuma * 0.22);
                float alpha = saturate(smoothMask * effectiveStrength * alphaScale);
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
                float mask = tex2D(_MaskTex, input.uv).r;
                mask *= PanelGate(input.uv, _Panel);
                if (mask < 0.02) discard;

                float3 scene = tex2D(_SceneTex, input.uv).rgb;
                float luma = dot(scene, float3(0.2126, 0.7152, 0.0722));
                float2 gradient = float2(ddx(mask), ddy(mask));
                float3 normal = normalize(float3(-gradient * 5.0, 1.0));
                float3 lightDir = normalize(float3(0.35, 0.75, 0.60));
                float ndotl = saturate(dot(normal, lightDir));
                float3 halfDir = normalize(lightDir + float3(0, 0, 1));
                float spec = pow(saturate(dot(normal, halfDir)), lerp(8.0, 88.0, _Smoothness));
                spec *= _Smoothness * _Smoothness;

                float bodyShade = luma > 0.015 ? lerp(0.78, 1.14, smoothstep(0.02, 0.58, luma)) : lerp(0.74, 1.06, ndotl);
                fixed3 specColor = lerp(fixed3(1, 1, 1), _Tint.rgb, _Metallic);
                fixed3 diffuse = _Tint.rgb * bodyShade * (1.0 - _Metallic * 0.28);
                float smoothMask = smoothstep(0.08, 0.55, mask);
                float alpha = saturate(smoothMask * _Strength);
                if (alpha < 0.004) discard;
                return fixed4(saturate(diffuse + specColor * spec * 0.55), alpha);
            }
            ENDCG
        }
    }
}
