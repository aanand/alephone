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
	InitialRenderVertexShaderUniformsIndex,
	InitialRenderVertexShader_NumBuffers,
};

enum {
	InitialRenderFragmentShaderColorTextureIndex,
	InitialRenderFragmentShader_NumTextures,
};

enum {
	RayTracingKernelAccelerationStructureIndex,
	RayTracingKernelCameraIndex,
	RayTracingKernel_NumBuffers,
};

enum {
	RayTracingKernelOutImageIndex,
	RayTracingKernel_NumTextures,
};

enum {
	FinalRenderVertexShader_NumBuffers,
};

enum {
	FinalRenderFragmentShaderUniformsIndex,
	FinalRenderFragmentShader_NumBuffers,
};

enum {
	FinalRenderFragmentShaderInitialPassTextureIndex,
	FinalRenderFragmentShaderRayTracingPassTextureIndex,
	FinalRenderFragmentShader_NumTextures,
};

typedef struct {
	vector_uint2 resolution;
	uint64_t frameNumber;
	
	// Horizontal FOV
	float fov;

	// World-space camera position
	vector_int3 origin;

	// In view-space, rotates the world up or down to match player look
	matrix_float4x4 pitchMat;
	
	// In view-space, rotates the world left or right to match player look
	matrix_float4x4 yawMat;

	// In view-space, rotates a direction vector to match player look
	matrix_float4x4 rotateDirectionMat;
	
	// Transforms a view-space vector to clip-space
	matrix_float4x4 perspectiveMat;
} Uniforms;

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

typedef struct {
	vector_float3 surfaceNormal;
} TriangleRayTracingData;

#endif /* VertexTypes_h */
