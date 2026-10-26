//
//  AlphaTest.metal
//  AlephOne
//
//  Created by Aanand Prasad on 25/10/2026.
//


#include <metal_stdlib>
using namespace metal;

#include "ShaderTypes.h"
#include "Utils.h"

[[intersection(triangle, raytracing::triangle_data, raytracing::instancing)]]
bool alphaTestIntersection(             float2          coordinates     [[ barycentric_coord ]],
						                unsigned int    instanceIndex   [[ user_instance_id ]],
						                unsigned int    primitiveIndex  [[ primitive_id ]],
						   const device RayTracingData *primitiveData   [[ primitive_data ]],
						   device       RayTracingData *perInstanceData [[ buffer(AlphaTestPerInstanceDataIndex) ]],
						   device       TextureArgs    *albedoTextures  [[ buffer(AlphaTestAlbedoTexturesIndex) ]])
{
	RayTracingData data = (instanceIndex > 0) ? perInstanceData[instanceIndex] : *primitiveData;
	if (data.textureIndex == 0) return true;

	float2 uv = getUV(coordinates, primitiveIndex, instanceIndex, data);
	texture2d<float> texture = albedoTextures->textures[data.textureIndex];
	constexpr sampler sam(mag_filter::linear, min_filter::linear, address::repeat);
	float4 albedo = texture.sample(sam, uv);

	return albedo.a >= 0.5;
}

