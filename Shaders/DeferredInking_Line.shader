﻿Shader "DeferredInking/Line"
{
    Properties
    {
        _Color("Color", Color) = (0, 0, 0, 1)
        _OutlineWidth("Outline Width", FLOAT) = 0.003
        [KeywordEnum(Off, Front, Back)] _Cull("Culling", Float) = 0
        [Space]
        [Toggle] _Use_Object_ID("Use Object ID", Float) = 1
        [Space]
        [Toggle] _Use_Depth("Use Depth", Float) = 0
        _DepthThreshold("Threshold_Depth", FLOAT) = 2.0
        [Space]
        [Toggle] _Use_Normal("Use Normal", Float) = 0
        _NormalThreshold("Threshold_Normal", Range(-1, 1)) = 0.5
        _DepthRange("Depth_Range", FLOAT) = 0.2
    }
    SubShader
    {
        Tags { "RenderType"="Opaque" }
        LOD 100

        Pass
        {
            CGPROGRAM
            #pragma vertex vert
            #pragma geometry geom
            #pragma fragment frag

            #include "UnityCG.cginc"

            #pragma multi_compile _CULL_OFF _CULL_FRONT _CULL_BACK
            #pragma multi_compile _ _USE_OBJECT_ID_ON
            #pragma multi_compile _ _USE_DEPTH_ON
            #pragma multi_compile _ _USE_NORMAL_ON

            struct appdata
            {
                float4 vertex : POSITION;
                #ifdef _USE_NORMAL_ON
                float3 normal : NORMAL;
                #endif
            };

            struct v2g
            {
                float4 vertex : SV_POSITION;
                float2 projXY : POSITION1;
                #ifdef _USE_NORMAL_ON
                float3 normal : TEXCOORD0;
                #endif
            };

            struct g2f
            {
                float4 vertex : SV_POSITION;
                float4 center : POSITION1;
                #ifdef _USE_NORMAL_ON
                float3 normal : TEXCOORD0;
                #endif
            };

            fixed4 _Color;
            float _OutlineWidth;
            float _DepthThreshold;
            float _NormalThreshold;
            float _DepthRange;

            Texture2D _GBuffer;
            float4 _GBuffer_TexelSize;
            Texture2D _GBufferDepth;
            SamplerState my_point_clamp_sampler;

            float modelID;
            float meshID;

            v2g vert (appdata v)
            {
                v2g o;
                o.vertex = UnityObjectToClipPos(v.vertex);
                o.projXY = o.vertex.xy / o.vertex.w;

                #ifdef _USE_NORMAL_ON
                    o.normal = COMPUTE_VIEW_NORMAL;
                #endif

                return o;
            }

            bool culling(v2g input[3])
            {
                float3 v01 = float3(input[1].projXY - input[0].projXY, 0);
                float3 v02 = float3(input[2].projXY - input[0].projXY, 0);
                float c = cross(v01, v02).z;

                bool isFrontFace;
                #ifdef UNITY_REVERSED_Z
                    isFrontFace = c >= 0;
                #else
                    isFrontFace = c <= 0;
                #endif

                #ifdef _CULL_FRONT
                    return isFrontFace;
                #elif _CULL_BACK
                    return !isFrontFace;
                #endif
            }

            void appendPoint(v2g p, float2 translate, inout g2f o, inout TriangleStream<g2f> ts)
            {
                float2 xy = (p.projXY + translate) * p.vertex.w;
                o.vertex = float4(xy, p.vertex.zw);
                o.center = p.vertex;

                #ifdef _USE_NORMAL_ON
                    o.normal = p.normal;
                #endif

                ts.Append(o);
            }

            void generateLine(v2g p1, v2g p2, float aspect, inout TriangleStream<g2f> ts)
            {
                float2 v12 = p2.projXY - p1.projXY;
                v12.x *= aspect;
                v12 = normalize(v12);
                float2 right = float2(-v12.y, v12.x);
                float2 translate = _OutlineWidth * right;
                translate.x /= aspect;

                g2f o;

                appendPoint(p1, -translate, o, ts);
                appendPoint(p2, -translate, o, ts);
                appendPoint(p1, translate, o, ts);
                appendPoint(p2, translate, o, ts);
                ts.RestartStrip();
            }

            [maxvertexcount(12)]
            void geom(triangle v2g input[3], uint pid : SV_PrimitiveID, inout TriangleStream<g2f> ts)
            {
                #if !defined(_CULL_OFF)
                    if (culling(input) == true) return;
                #endif

                float aspect = (-UNITY_MATRIX_P[1][1]) / UNITY_MATRIX_P[0][0];

                generateLine(input[0], input[1], aspect, ts);
                generateLine(input[1], input[2], aspect, ts);
                generateLine(input[2], input[0], aspect, ts);
            }

            bool depthSobel(float3x3 depths)
            {
                float2 sumsX = float2(1, -1) * depths[0].xz + float2(2, -2) * depths[1].xz + float2(1, -1) * depths[2].xz;
                float lx = sumsX.x + sumsX.y;

                float3 sumsY = float3(1, 2, 1) * depths[0] + float3(-1, -2, -1) * depths[2];
                float ly = sumsY.x + sumsY.y + sumsY.z;

                return sqrt(lx * lx + ly * ly) >= _DepthThreshold;
            }

        #ifdef _USE_NORMAL_ON
            void sampleGBuffers(float2 uv, out bool3x3 isSameIDs, out float2 normals[3][3])
        #else
            void sampleGBuffers(float2 uv, out bool3x3 isSameIDs)
        #endif
            {
                float2 selfID = float2(modelID, meshID);

                for (int y = -1; y <= 1; y++)
                {
                    for (int x = -1; x <= 1; x++)
                    {
                        float2 _uv = uv + float2(x, y) * _GBuffer_TexelSize;
                        float4 g = _GBuffer.Sample(my_point_clamp_sampler, _uv);

                        #ifdef _USE_NORMAL_ON
                            normals[y + 1][x + 1] = g.xy;
                        #endif

                        float2 sub = abs(g.zw * 255.0f - selfID);
                        isSameIDs[y + 1][x + 1] = sub.x + sub.y < 0.1f;
                    }
                }
            }

            float3x3 sampleDepths(float2 uv)
            {
                float3x3 dst;

                for (int y = -1; y <= 1; y++)
                {
                    for (int x = -1; x <= 1; x++)
                    {
                        float2 _uv = uv + float2(x, y) * _GBuffer_TexelSize;
                        dst[y + 1][x + 1] = DECODE_EYEDEPTH(_GBufferDepth.Sample(my_point_clamp_sampler, _uv)).x;
                    }
                }

                return dst;
            }

            bool detectDifferentID(bool3x3 isSameIDs, float3x3 depths, float centerDepth)
            {
                bool isDraw = false;

                for (int y = 0; y <= 2; y++)
                {
                    for (int x = 0; x <= 2; x++)
                    {
                        bool _isDraw = !isSameIDs[y][x] && (centerDepth < depths[y][x]);
                        isDraw = isDraw || _isDraw;
                    }
                }

                return isDraw;
            }

            bool detectNormal(float3 centerNormal, float centerDepth, float2 normals[3][3], float3x3 depths)
            {
                bool isDraw = false;
                float d = centerDepth - _DepthRange;

                for (int y = 0; y < 3; y++)
                {
                    for (int x = 0; x < 3; x++)
                    {
                        float3 n = DecodeViewNormalStereo(float4(normals[y][x], 0, 0));
                        isDraw = isDraw ||
                            (
                                (dot(centerNormal, n) < _NormalThreshold) &&
                                (d < depths[y][x])
                            );
                    }
                }

                return isDraw;
            }

            fixed4 frag (g2f i) : SV_Target
            {
                float2 uv = (i.center.xy / i.center.w + 1.0f) * 0.5f;
                #if UNITY_UV_STARTS_AT_TOP == 1
                    uv.y = 1 - uv.y;
                #endif

                bool3x3 isSameIDs;
                #ifdef _USE_NORMAL_ON
                    float2 normals[3][3];
                    sampleGBuffers(uv, isSameIDs, normals);
                #else
                    sampleGBuffers(uv, isSameIDs);
                #endif

                clip(any(isSameIDs) - 0.1f);

                bool isDraw = false;
                float3x3 depths = sampleDepths(uv);

                #ifdef _USE_OBJECT_ID_ON
                    isDraw = isDraw || detectDifferentID(isSameIDs, depths, i.center.w);
                #endif

                #ifdef _USE_DEPTH_ON
                    isDraw = isDraw || depthSobel(depths);
                #endif

                #ifdef _USE_NORMAL_ON
                    isDraw = isDraw || detectNormal(i.normal, i.center.w, normals, depths);
                #endif

                clip(isDraw - 0.1f);

                return _Color;
            }
            ENDCG
        }
    }

    FallBack "Diffuse"
}
