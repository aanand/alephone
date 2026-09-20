//
//  ShaderTypes.h
//  AlephOne
//
//  Created by Aanand Prasad on 28/08/2026.
//

#ifndef ShaderTypes_h
#define ShaderTypes_h

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
	InitialRenderAttachmentAlbedo,
	InitialRenderAttachmentDepth,
};

enum {
	RayTracingKernelAccelerationStructureIndex,
	RayTracingKernelUniformsIndex,
	RayTracingKernelPerInstanceDataIndex,
	RayTracingKernelSpriteTexturesIndex,
	RayTracingKernelLightSourcesIndex,
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
	
	// Global light parameters
	vector_float3 sunDirection; // Unit vector pointing away from the sun
	float sunIntensity;
	float sunRadius; // Half the angle subtended by the sun, in radians
	
	float weaponFlare; // Intensity of the weapon flare (0 if it's inactive)
} Uniforms;

// A vertex in Marathon world-space: X = east, Y = north, Z = up
typedef struct {
	vector_int3 position;
	vector_float2 textureCoordinate;
} WorldVertex;

typedef struct {
	float intensity;
} LightSource;

typedef struct {
	vector_float3 surfaceNormal;
	vector_float3 emission;
	int32_t lightSourceIndex;
} PrimitiveRayTracingData;

typedef struct {
	vector_float3 surfaceNormal;
	vector_float3 emission;
	matrix_float4x2 uv;
	uint32_t textureIndex;
} InstanceRayTracingData;

#endif /* VertexTypes_h */
