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
typedef float4 VertexFloat4;
#else
#import <simd/simd.h>
typedef simd_float2 VertexFloat2;
typedef simd_float4 VertexFloat4;
#endif

struct VertexData {
	VertexFloat2 position;
	VertexFloat4 color;
};

struct TriangleData {
	VertexData vertex0, vertex1, vertex2;
};

#endif /* VertexTypes_h */
