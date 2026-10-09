Shader "ARCar/PhotoPaint"
{
    Properties
    {
        _BaseMap ("Albedo", 2D) = "white" {}
        _BaseColor ("Color", Color) = (1, 1, 1, 1)
        _BumpMap ("Normal", 2D) = "bump" {}
        _HasNormal ("Has Normal", Float) = 0
        _MetallicRoughnessMap ("Metallic Roughness", 2D) = "white" {}
        _HasMetallicRoughness ("Has Metallic Roughness", Float) = 0
        _OcclusionMap ("Occlusion", 2D) = "white" {}
        _HasOcclusion ("Has Occlusion", Float) = 0
        _EmissionMap ("Emission", 2D) = "black" {}
        _EmissionColor ("Emission", Color) = (0, 0, 0, 1)
        _HasEmission ("Has Emission", Float) = 0
        _Metallic ("Metallic", Range(0, 1)) = 0
        _Smoothness ("Smoothness", Range(0, 1)) = 0.45
        _Clearcoat ("Clearcoat", Range(0, 1)) = 0.2
        _Painted ("Painted", Float) = 0
        _OcclusionStrength ("Occlusion Strength", Range(0, 1)) = 1
    }

    SubShader
    {
        Tags
        {
            "RenderPipeline" = "UniversalPipeline"
            "RenderType" = "Opaque"
            "Queue" = "Geometry"
        }

        Pass
        {
            Name "Photo"
            Tags { "LightMode" = "UniversalForward" }

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

            TEXTURE2D(_BaseMap);
            SAMPLER(sampler_BaseMap);
            TEXTURE2D(_BumpMap);
            SAMPLER(sampler_BumpMap);
            TEXTURE2D(_MetallicRoughnessMap);
            SAMPLER(sampler_MetallicRoughnessMap);
            TEXTURE2D(_OcclusionMap);
            SAMPLER(sampler_OcclusionMap);
            TEXTURE2D(_EmissionMap);
            SAMPLER(sampler_EmissionMap);

            CBUFFER_START(UnityPerMaterial)
                float4 _BaseMap_ST;
                float4 _BaseColor;
                float4 _EmissionColor;
                float _HasNormal;
                float _HasMetallicRoughness;
                float _HasOcclusion;
                float _HasEmission;
                float _Metallic;
                float _Smoothness;
                float _Clearcoat;
                float _Painted;
                float _OcclusionStrength;
            CBUFFER_END

            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS : NORMAL;
                float4 tangentOS : TANGENT;
                float2 uv : TEXCOORD0;
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float2 uv : TEXCOORD0;
                float3 positionWS : TEXCOORD1;
                float3 normalWS : TEXCOORD2;
                float3 tangentWS : TEXCOORD3;
                float3 bitangentWS : TEXCOORD4;
            };

            Varyings vert(Attributes input)
            {
                Varyings output;
                VertexNormalInputs normals = GetVertexNormalInputs(input.normalOS, input.tangentOS);
                output.positionWS = TransformObjectToWorld(input.positionOS.xyz);
                output.positionCS = TransformWorldToHClip(output.positionWS);
                output.uv = TRANSFORM_TEX(input.uv, _BaseMap);
                output.normalWS = normals.normalWS;
                output.tangentWS = normals.tangentWS;
                output.bitangentWS = normals.bitangentWS;
                return output;
            }

            half3 SkyFill(half3 reflectDir)
            {
                half up = saturate(reflectDir.y * 0.5 + 0.5);
                half3 horizon = half3(0.78, 0.80, 0.82);
                half3 zenith = half3(0.32, 0.46, 0.70);
                return lerp(horizon, zenith, up);
            }

            half4 frag(Varyings input) : SV_Target
            {
                half4 albedoSample = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, input.uv);
                half3 albedo = albedoSample.rgb * _BaseColor.rgb;

                half3 normalWS = normalize(input.normalWS);
                if (_HasNormal > 0.5)
                {
                    half3 tangentNormal = UnpackNormal(SAMPLE_TEXTURE2D(_BumpMap, sampler_BumpMap, input.uv));
                    half3x3 tangentToWorld = half3x3(
                        normalize(input.tangentWS),
                        normalize(input.bitangentWS),
                        normalWS);
                    normalWS = normalize(mul(tangentNormal, tangentToWorld));
                }

                half mapMetal = 0;
                half mapRough = 1.0 - _Smoothness;
                if (_HasMetallicRoughness > 0.5)
                {
                    half4 mr = SAMPLE_TEXTURE2D(_MetallicRoughnessMap, sampler_MetallicRoughnessMap, input.uv);
                    mapMetal = mr.b;
                    mapRough = mr.g;
                }

                half metallic = _Painted > 0.5 ? _Metallic : saturate(mapMetal * max(_Metallic, 0.001));
                half smoothness = _Painted > 0.5
                    ? saturate(_Smoothness * lerp(0.82, 1.05, 1.0 - mapRough))
                    : saturate(1.0 - mapRough);
                half roughness = max(1.0 - smoothness, 0.045);

                half occlusion = 1;
                if (_HasOcclusion > 0.5)
                {
                    half occ = SAMPLE_TEXTURE2D(_OcclusionMap, sampler_OcclusionMap, input.uv).r;
                    occlusion = lerp(1, occ, _OcclusionStrength);
                }

                Light mainLight = GetMainLight();
                half3 viewDir = normalize(GetWorldSpaceViewDir(input.positionWS));
                half ndotl = saturate(dot(normalWS, mainLight.direction));
                half ndotv = saturate(dot(normalWS, viewDir));
                half3 halfDir = normalize(mainLight.direction + viewDir);
                half ndoth = saturate(dot(normalWS, halfDir));

                half3 dielectric = half3(0.04, 0.04, 0.04);
                half3 f0 = lerp(dielectric, albedo, metallic);
                half3 diffuseColor = albedo * (1.0 - metallic);

                half alpha = roughness * roughness;
                half alpha2 = alpha * alpha;
                half denom = ndoth * ndoth * (alpha2 - 1.0) + 1.0;
                half distribution = alpha2 / (3.14159 * denom * denom + 0.0001);
                half3 specular = distribution * f0 * mainLight.color * ndotl;

                half3 ambient = SampleSH(normalWS) * diffuseColor * occlusion;
                half3 diffuse = diffuseColor * mainLight.color * ndotl * occlusion;

                half3 reflectDir = reflect(-viewDir, normalWS);
                half3 probe = GlossyEnvironmentReflection(reflectDir, input.positionWS, roughness, occlusion);
                half3 sky = SkyFill(reflectDir);
                half probeLum = dot(probe, half3(0.3, 0.59, 0.11));
                half3 environment = lerp(sky * 0.42, probe, saturate(probeLum * 5.0));
                half fresnel = pow(1.0 - ndotv, 5.0);
                half3 reflection = environment * lerp(f0, half3(1, 1, 1), fresnel) * lerp(0.35, 1.0, smoothness);

                half3 coat = _Clearcoat * pow(ndoth, lerp(12.0, 180.0, smoothness)) * mainLight.color * ndotl;
                coat += _Clearcoat * fresnel * sky * 0.35;

                half3 emission = 0;
                if (_HasEmission > 0.5)
                    emission = SAMPLE_TEXTURE2D(_EmissionMap, sampler_EmissionMap, input.uv).rgb * _EmissionColor.rgb;

                half3 color = ambient + diffuse + specular + reflection + coat + emission;
                return half4(color, 1);
            }
            ENDHLSL
        }
    }
}
