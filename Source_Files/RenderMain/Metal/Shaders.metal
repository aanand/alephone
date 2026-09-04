//
//  Shaders.metal
//  libalephone
//
//  Created by Aanand Prasad on 27/08/2026.
//

#include <metal_stdlib>

using namespace metal;
using namespace raytracing;

#include "VertexTypes.h"

struct RasterizerData {
	float4 position [[position]];
	float2 textureCoordinate;
	float3 surfaceNormal;
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

vertex RasterizerData
initialRenderVertexShader(uint vertexID [[vertex_id]],
						  constant WorldVertex *vertexData [[buffer(InitialRenderVertexShaderVertexDataIndex)]],
						  constant Camera &camera [[buffer(InitialRenderVertexShaderCameraIndex)]])
{
	RasterizerData out;
	
	WorldVertex v = vertexData[vertexID];

	float4 result = float4(fromWorldSpace(v.position - camera.origin), 1.0);
	result = camera.yawMat * result;
	result = camera.pitchMat * result;
	result = camera.perspectiveMat * result;

	out.position = result;
	out.textureCoordinate = v.textureCoordinate;
	out.surfaceNormal = float4(fromWorldSpace(v.surfaceNormal), 1.0).xyz;
	
	return out;
}

fragment float4
initialRenderFragmentShader(RasterizerData in [[stage_in]],
			   texture2d<half> colorTexture [[ texture(InitialRenderFragmentShaderColorTextureIndex) ]])
{
	float3 globalLightDirection = normalize(float3(-1, -1, -1));
	float globalLightIntensity = 1.0;
	float ambientLightIntensity = 0.5;

	float incoming = dot(-in.surfaceNormal, globalLightDirection);
	float intensity = mix(ambientLightIntensity, globalLightIntensity, incoming);

	constexpr sampler textureSampler (mag_filter::nearest, min_filter::nearest, address::repeat);
	const half4 colorSample = colorTexture.sample(textureSampler, in.textureCoordinate);
	return float4(float3(colorSample.xyz) * intensity, colorSample.w);
}

kernel void rayTracingKernel(texture2d<float, access::write> outImage [[ texture(RayTracingKernelOutImageIndex) ]],
							 instance_acceleration_structure accelerationStructure [[ buffer(RayTracingKernelAccelerationStructureIndex) ]],
							 constant Camera &camera [[ buffer(RayTracingKernelCameraIndex) ]],
							 uint2 tid [[thread_position_in_grid]])
{
	outImage.write(float4(0.0, 0.0, 1.0, 1.0), tid);
}

// Screen filling quad in normalized device coordinates.
constant float2 quadVertices[] = {
	float2(-1, -1),
	float2(-1,  1),
	float2( 1,  1),
	float2(-1, -1),
	float2( 1,  1),
	float2( 1, -1)
};

struct CopyVertexOut {
	float4 position [[position]];
	float2 uv;
};

// Adapted from https://developer.apple.com/documentation/metal/accelerating-ray-tracing-using-metal?language=objc
vertex CopyVertexOut
finalRenderVertexShader(unsigned short vid [[vertex_id]])
{
	float2 position = quadVertices[vid];

	CopyVertexOut out;

	out.position = float4(position, 0, 1);

	float2 textureSpace = position * 0.5f + 0.5f;
	out.uv = float2(textureSpace.x, 1.0 - textureSpace.y);

	return out;
}

// Adapted from https://developer.apple.com/documentation/metal/accelerating-ray-tracing-using-metal?language=objc
fragment float4
finalRenderFragmentShader(CopyVertexOut in [[stage_in]],
						  texture2d<float> initialPassTex [[ texture(FinalRenderFragmentShaderInitialPassTextureIndex) ]],
						  texture2d<float> rayTracingPassTex [[ texture(FinalRenderFragmentShaderRayTracingPassTextureIndex) ]])
{
	constexpr sampler sam(min_filter::nearest, mag_filter::nearest, mip_filter::none);
	float3 initialPassColor = initialPassTex.sample(sam, in.uv).xyz;
	float3 rayTracingPassColor = rayTracingPassTex.sample(sam, in.uv).xyz;
	float3 color = mix(initialPassColor, rayTracingPassColor, 0.5);
	return float4(color, 1.0f);
}
