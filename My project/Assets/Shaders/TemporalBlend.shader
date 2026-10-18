Shader "ARCar/TemporalBlend"
{
    Properties
    {
        _MainTex ("Current Neural Mask", 2D) = "black" {}
        _PrevTex ("History Mask", 2D) = "black" {}
        _Blend ("Temporal Blend Rate", Range(0, 1)) = 0.35
    }

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off
        ZTest Always
        Cull Off

        Pass
        {
            Name "TemporalFilter"
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            TEXTURE2D(_MainTex);
            SAMPLER(sampler_MainTex);
            TEXTURE2D(_PrevTex);
            SAMPLER(sampler_PrevTex);

            CBUFFER_START(UnityPerMaterial)
                float _Blend;
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

            Varyings vert(Attributes input)
            {
                Varyings output;
                output.positionHCS = TransformObjectToHClip(input.positionOS.xyz);
                output.uv = input.uv;
                return output;
            }

            half4 frag(Varyings input) : SV_Target
            {
                float4 current = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, input.uv);
                float4 prev = SAMPLE_TEXTURE2D(_PrevTex, sampler_PrevTex, input.uv);
                return lerp(prev, current, _Blend);
            }
            ENDHLSL
        }
    }

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off
        ZTest Always
        Cull Off

        Pass
        {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #include "UnityCG.cginc"

            sampler2D _MainTex;
            sampler2D _PrevTex;
            float _Blend;

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

            v2f vert(appdata input)
            {
                v2f output;
                output.vertex = UnityObjectToClipPos(input.vertex);
                output.uv = input.uv;
                return output;
            }

            fixed4 frag(v2f input) : SV_Target
            {
                fixed4 current = tex2D(_MainTex, input.uv);
                fixed4 prev = tex2D(_PrevTex, input.uv);
                return lerp(prev, current, _Blend);
            }
            ENDCG
        }
    }
}
