//
//  VertexTypes.h
//  AlephOne
//
//  Created by Aanand Prasad on 28/08/2026.
//

#ifndef VertexTypes_h
#define VertexTypes_h

#include <simd/simd.h>

typedef struct {
	matrix_float4x4 perspective;
	matrix_float4x4 rotation;
} Camera;

typedef struct {
	vector_float3 position;
	vector_float2 textureCoordinate;
} Vertex;

#endif /* VertexTypes_h */
