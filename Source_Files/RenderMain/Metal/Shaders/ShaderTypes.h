//
//  ShaderTypes.h
//  AlephOne
//
//  Created by Aanand Prasad on 28/08/2026.
//

#ifndef ShaderTypes_h
#define ShaderTypes_h

#include <simd/simd.h>

#define MAX_TEXTURES 1024

#define MASK_ALL  0xFF
#define MASK_NONE 0x00

// Copied from map.h
#define MAXIMUM_VERTICES_PER_POLYGON 8

enum {
	InitialRenderVertexShaderVertexDataIndex,
	InitialRenderVertexShaderUniformsIndex,
	InitialRenderVertexShader_NumBuffers,
};

enum {
	InitialRenderFragmentShaderUniformsIndex,
	InitialRenderFragmentShaderAlbedoTexturesIndex,
	InitialRenderFragmentShaderNormalMapsIndex,
	InitialRenderFragmentShaderEmissionMapsIndex,
	InitialRenderFragmentShader_NumBuffers,
};

enum {
	InitialRenderAttachmentDiffuseAlbedo,
	InitialRenderAttachmentSpecularAlbedo,
	InitialRenderAttachmentRoughness,
	InitialRenderAttachmentDepth,
	InitialRenderAttachmentNormal,
	InitialRenderAttachmentMotion,
};

enum {
	RayTracingKernelAccelerationStructureIndex,
	RayTracingKernelUniformsIndex,
	RayTracingKernelPerInstanceDataIndex,
	RayTracingKernelAlbedoTexturesIndex,
	RayTracingKernelNormalMapsIndex,
	RayTracingKernelEmissionMapsIndex,
	RayTracingKernelLightSourcesIndex,
	RayTracingKernelPreviousReservoirIndex,
	RayTracingKernelCurrentReservoirIndex,
	RayTracingKernel_NumBuffers,
};

enum {
	RayTracingKernelOutImageIndex,
	RayTracingKernel_NumTextures,
};

enum {
	DenoisePassUniformsIndex,
	DenoisePassConfigIndex,
	DenoisePass_NumBuffers,
};

enum {
	DenoisePassNormalTextureIndex,
	DenoisePassDepthTextureIndex,
	DenoisePassInputTextureIndex,
	DenoisePassOutputTextureIndex,
	DenoisePass_NumTextures,
};

enum {
	TAAKernelUniformsIndex,
	TAAKernel_NumBuffers,
};

enum {
	TAAKernelInputTextureIndex,
	TAAKernelMotionTextureIndex,
	TAAKernelPreviousOutputTextureIndex,
	TAAKernelOutputTextureIndex,
	TAAKernel_NumTextures,
};

enum {
	FinalRenderVertexShader_NumBuffers,
};

enum {
	FinalRenderFragmentShaderUniformsIndex,
	FinalRenderFragmentShader_NumBuffers,
};

enum {
	FinalRenderFragmentShaderAlbedoTextureIndex,
	FinalRenderFragmentShaderRayTracingTextureIndex,
	FinalRenderFragmentShader_NumTextures,
};

typedef struct {
	vector_float3 bottomEmission;
	vector_float3 topEmission;

	bool hasSun;
	vector_float3 sunEmission;
	vector_float3 sunPosition; // Unit vector towards sun

	// Half the angle subtended by the sun, in radians
	float sunRadius;

	// Axis and rate at which the sun rotates around its axis (radians per frame).
	// Applied on the CPU, but located here for convenience.
	float sunRotationSpeed;
	vector_float3 sunRotationAxis;
} Sky;

typedef struct {
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
} Camera;

typedef struct {
	// true = full path tracing: raytracer does everything
	// false = raytracer does a lighting-only pass, to be mixed with rasterized albedo
	bool fullPathTracing;

	vector_uint2 resolution;
	uint64_t frameNumber;
	
	// Global light parameters
	Sky sky;
	
	Camera camera;
	Camera previousCamera;
	
	float weaponFlare; // Intensity of the weapon flare (0 if it's inactive)
	float flashlight; // Intensity of the flashlight (0 if it's inactive)
	bool isInMedium; // True if player is underwater (i.e. over their head)
} Uniforms;

typedef struct {
	uint step;
} DenoiseConfig;

typedef struct {
	bool isLandscape;
	float f0;
	float roughness;
	float transparency;
	float refractiveIndex;
} Material;

// A vertex in Marathon world-space: X = east, Y = north, Z = up
typedef struct {
	vector_int3 position;
	uint32_t textureIndex;
	vector_float2 textureCoordinate;
	vector_float3 surfaceNormal;
	vector_float4 surfaceTangent;
	Material material;
} WorldVertex;

typedef struct {
	float intensity;
} LightSource;

// The fourth component of a tangent vector is the handedness (+1 or -1),
// which lets us calculate the bitangent from the normal and tangent.

typedef struct {
	vector_float3 surfaceNormal;
	vector_float4 surfaceTangent;

	Material material;

	// Per-primitive data only uses 3 of the floats in this array, because it's always a triangle.
	// Per-instance data can use more (up to MAXIMUM_VERTICES_PER_POLYGON).
	uint8_t numVertices;
	simd_float2 uv[MAXIMUM_VERTICES_PER_POLYGON];
	uint32_t textureIndex;

	int32_t lightSourceIndex;
} RayTracingData;

typedef struct {
	vector_float3 direction;
	float sampleWeight;
	float sumWeight;
} Reservoir;

#endif /* VertexTypes_h */
