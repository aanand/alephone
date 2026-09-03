//
//  VertexTypes.h
//  AlephOne
//
//  Created by Aanand Prasad on 28/08/2026.
//

#ifndef VertexTypes_h
#define VertexTypes_h

#include <simd/simd.h>

enum {
	InitialRenderVertexShaderVertexDataIndex,
	InitialRenderVertexShaderCameraIndex,
	InitialRenderVertexShader_NumBuffers,
};

enum {
	InitialRenderFragmentShaderColorTextureIndex,
	InitialRenderFragmentShader_NumTextures,
};

enum {
	RayTracingKernelOutImageIndex,
	RayTracingKernel_NumTextures,
};

enum {
	FinalRenderFragmentShaderInputTextureIndex,
	FinalRenderFragmentShader_NumTextures,
};

typedef struct {
	matrix_float4x4 perspective;
	matrix_float4x4 rotation;
	matrix_float4x4 toWorldSpace;
} Camera;

typedef struct {
	vector_float3 position;
	vector_float2 textureCoordinate;
	vector_float3 surfaceNormal;
} Vertex;

#endif /* VertexTypes_h */
