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
	float2 dXY;
	float depth;
	float3 normal;
	float2 textureCoordinate;
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
	out.dXY = position.xy - previousPosition.xy;
	out.depth = position.z/position.w;
	out.normal = v.normal;
	out.textureCoordinate = v.textureCoordinate;
	
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

fragment GBuffer
initialRenderFragmentShader(RasterizerData in [[stage_in]],
			   texture2d<half> colorTexture [[ texture(InitialRenderFragmentShaderColorTextureIndex) ]])
{
	constexpr sampler textureSampler (mag_filter::nearest, min_filter::nearest, address::repeat);
	const half4 colorSample = colorTexture.sample(textureSampler, in.textureCoordinate);
	if (colorSample.a == 0) {
		discard_fragment();
	}
	return {
		.diffuseAlbedo = float4(colorSample),
		.specularAlbedo = float4(0.0),
		.roughness = 1.0,
		.depth = in.depth,
		.normal = float4(in.normal, 1.0),
		.motion = in.dXY,
	};
}
