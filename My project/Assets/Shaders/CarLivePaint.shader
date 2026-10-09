Shader "ARCar/LivePaint"
{
    Properties
    {
        _MaskTex ("Segmentation mask", 2D) = "black" {}
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
                if (panel < 0.5) return 1.0;
                if (panel < 1.5)
                {
                    return smoothstep(0.32, 0.40, uv.y) * smoothstep(0.70, 0.60, uv.y)
                        * smoothstep(0.22, 0.32, uv.x) * smoothstep(0.78, 0.68, uv.x);
                }
                if (panel < 2.5)
                {
                    return smoothstep(0.58, 0.68, uv.y)
                        * smoothstep(0.20, 0.32, uv.x) * smoothstep(0.80, 0.68, uv.x);
                }
                float side = max(smoothstep(0.40, 0.28, uv.x), smoothstep(0.60, 0.72, uv.x));
                return side * smoothstep(0.22, 0.32, uv.y) * smoothstep(0.68, 0.56, uv.y);
            }

            half3 ShadePaint(float mask, float3 scene)
            {
                float2 gradient = float2(ddx(mask), ddy(mask));
                float3 normal = normalize(float3(-gradient * 6.0, 1.0));
                float3 lightDir = normalize(float3(0.35, 0.72, 0.6));
                float ndotl = saturate(dot(normal, lightDir));
                float3 halfDir = normalize(lightDir + float3(0, 0, 1));
                float specPower = lerp(6.0, 84.0, _Smoothness);
                float spec = pow(saturate(dot(normal, halfDir)), specPower) * _Smoothness * _Smoothness;

                float luma = dot(scene, float3(0.2126, 0.7152, 0.0722));
                float energy = max(luma, max(scene.r, max(scene.g, scene.b)));
                float shade = energy > 0.03 ? lerp(0.32, 1.2, luma) : lerp(0.5, 1.0, ndotl);
                half3 specColor = lerp(half3(1, 1, 1), _Tint.rgb, _Metallic);
                half3 diffuse = _Tint.rgb * shade * (1.0 - _Metallic * 0.55);
                return diffuse + specColor * spec * 0.9;
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
                float alpha = saturate(mask * _Strength);
                if (alpha < 0.004) discard;

                float2 screenUV = GetNormalizedScreenSpaceUV(input.positionHCS);
                float3 scene = SampleSceneColor(screenUV);
                return half4(ShadePaint(mask, scene), alpha);
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
                    return smoothstep(0.32, 0.40, uv.y) * smoothstep(0.70, 0.60, uv.y)
                        * smoothstep(0.22, 0.32, uv.x) * smoothstep(0.78, 0.68, uv.x);
                }
                if (panel < 2.5)
                {
                    return smoothstep(0.58, 0.68, uv.y)
                        * smoothstep(0.20, 0.32, uv.x) * smoothstep(0.80, 0.68, uv.x);
                }
                float side = max(smoothstep(0.40, 0.28, uv.x), smoothstep(0.60, 0.72, uv.x));
                return side * smoothstep(0.22, 0.32, uv.y) * smoothstep(0.68, 0.56, uv.y);
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
                float alpha = saturate(mask * _Strength);
                if (alpha < 0.004) discard;

                float2 gradient = float2(ddx(mask), ddy(mask));
                float3 normal = normalize(float3(-gradient * 6.0, 1.0));
                float3 lightDir = normalize(float3(0.35, 0.72, 0.6));
                float ndotl = saturate(dot(normal, lightDir));
                float3 halfDir = normalize(lightDir + float3(0, 0, 1));
                float spec = pow(saturate(dot(normal, halfDir)), lerp(6.0, 84.0, _Smoothness));
                spec *= _Smoothness * _Smoothness;
                fixed3 specColor = lerp(fixed3(1, 1, 1), _Tint.rgb, _Metallic);
                fixed3 diffuse = _Tint.rgb * lerp(0.5, 1.0, ndotl) * (1.0 - _Metallic * 0.55);
                return fixed4(diffuse + specColor * spec * 0.9, alpha);
            }
            ENDCG
        }
    }
}
