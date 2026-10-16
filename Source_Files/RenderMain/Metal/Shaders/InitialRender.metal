//
//  InitialRender.metal
//  AlephOne
//
//  Created by Aanand Prasad on 16/09/2026.
//

#include <metal_stdlib>
using namespace metal;

#include "ShaderTypes.h"


struct RasterizerData {
	float4 position [[position]];
	float4 previousPosition;
	float3 normal;
	uint32_t textureIndex;
	float2 textureCoordinate;
	bool isLandscape [[flat]];
};

// Reorient a world-space position to view-space.
// At pitch=0 and yaw=0, world +X is depth, world +Y is left (or... right? check this), and world +Z is up.
// 1024 world-space units = 1 view-space unit.
float3 fromWorldSpace(float3 worldPosition) {
	return float3(worldPosition.y, worldPosition.z, worldPosition.x) / 1024.0;
}

float3 fromWorldSpace(int3 worldPosition) {
	return fromWorldSpace(float3(worldPosition));
}

float4 transform(int3 worldPosition, Camera camera) {
	float4 result = float4(fromWorldSpace(worldPosition - camera.origin), 1.0);
	result = camera.yawMat * result;
	result = camera.pitchMat * result;
	result = camera.perspectiveMat * result;
	return result;
}

vertex RasterizerData
initialRenderVertexShader(uint vertexID [[vertex_id]],
						  constant WorldVertex *vertexData [[buffer(InitialRenderVertexShaderVertexDataIndex)]],
						  constant Uniforms &uniforms [[buffer(InitialRenderVertexShaderUniformsIndex)]])
{
	RasterizerData out;
	
	WorldVertex v = vertexData[vertexID];

	float4 position = transform(v.position, uniforms.camera);
	float4 previousPosition = transform(v.position, uniforms.previousCamera);
	
	out.position = position;
	out.previousPosition = previousPosition;
	out.normal = v.normal;
	out.textureIndex = v.textureIndex;
	out.textureCoordinate = v.textureCoordinate;
	out.isLandscape = v.material.isLandscape;
	
	return out;
}

struct GBuffer {
	float4 diffuseAlbedo [[ color(InitialRenderAttachmentDiffuseAlbedo) ]];
	float4 specularAlbedo [[ color(InitialRenderAttachmentSpecularAlbedo) ]];
	float roughness [[ color(InitialRenderAttachmentRoughness) ]];
	float depth [[ color(InitialRenderAttachmentDepth) ]];
	float4 normal [[ color(InitialRenderAttachmentNormal) ]];
	float2 motion [[ color(InitialRenderAttachmentMotion) ]];
};

struct TextureArgs {
	array<texture2d<float>, MAX_TEXTURES> textures [[id(0)]];
};

fragment GBuffer
initialRenderFragmentShader(RasterizerData in [[stage_in]],
							constant Uniforms &uniforms [[ buffer(InitialRenderFragmentShaderUniformsIndex) ]],
							constant TextureArgs &textures [[ buffer(InitialRenderFragmentShaderAlbedoTexturesIndex) ]])
{
	constexpr sampler textureSampler (mag_filter::nearest, min_filter::nearest, address::repeat);
	texture2d<float> colorTexture = textures.textures[in.textureIndex];
	float4 colorSample = colorTexture.sample(textureSampler, in.textureCoordinate);
	if (colorSample.a == 0) {
		discard_fragment();
	}
	if (in.isLandscape) {
		// Landscape textures aren't loaded in right now, so colorSample comes out as magenta - override it to white
		colorSample = float4(1.0);
	}

	float2 currentXY = in.position.xy / float2(uniforms.resolution) * 2.0 - 1.0;
	float2 previousXY = in.previousPosition.xy / in.previousPosition.w;
	previousXY.y = -previousXY.y;
	
	float2 motion = (previousXY - currentXY) * float2(uniforms.resolution) * 0.5;

	return {
		.diffuseAlbedo = float4(colorSample),
		.specularAlbedo = float4(0.0),
		.roughness = 1.0,
		.depth = in.position.z,
		.normal = float4(in.normal, 1.0),
		.motion = motion,
	};
}
