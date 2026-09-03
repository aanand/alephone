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
	FinalRenderVertexShader_NumBuffers,
};

enum {
	FinalRenderFragmentShaderInitialPassTextureIndex,
	FinalRenderFragmentShaderRayTracingPassTextureIndex,
	FinalRenderFragmentShader_NumTextures,
};

typedef struct {
	// World-space camera position
	vector_int3 origin;

	// Rotates positions up or down to match player look
	matrix_float4x4 pitchMat;
	
	// Rotates positions left or right to match player look
	matrix_float4x4 yawMat;
	
	// Transforms a view-space vector to clip-space
	matrix_float4x4 perspectiveMat;
} Camera;

// A vertex in Marathon world-space: X = east, Y = north, Z = up
typedef struct {
	vector_int3 position;
	vector_float2 textureCoordinate;
	vector_float3 surfaceNormal;
} WorldVertex;

// A vertex in view- or clip-space: X = right, Y = up, Z = far
typedef struct {
	vector_float3 position;
	vector_float2 textureCoordinate;
	vector_float3 surfaceNormal;
} Vertex;

#endif /* VertexTypes_h */
