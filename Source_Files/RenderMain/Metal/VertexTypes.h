//
//  VertexTypes.h
//  AlephOne
//
//  Created by Aanand Prasad on 28/08/2026.
//

#ifndef VertexTypes_h
#define VertexTypes_h

#ifdef __METAL_VERSION__
typedef float2 VertexFloat2;
typedef float3 VertexFloat3;
typedef float4 VertexFloat4;
#else
#import <simd/simd.h>
typedef simd_float2 VertexFloat2;
typedef simd_float3 VertexFloat3;
typedef simd_float4 VertexFloat4;
#endif

typedef struct {
	VertexFloat3 v0, v1, v2, v3;
} QuadData;

#endif /* VertexTypes_h */
