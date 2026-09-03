//
//  Shaders.metal
//  libalephone
//
//  Created by Aanand Prasad on 27/08/2026.
//

#include <metal_stdlib>
using namespace metal;

#include "VertexTypes.h"

struct RasterizerData {
	float4 position [[position]];
	float2 textureCoordinate;
	float3 surfaceNormal;
};

vertex RasterizerData
initialRenderVertexShader(uint vertexID [[vertex_id]],
						  constant Vertex *vertexData [[buffer(InitialRenderVertexShaderVertexDataIndex)]],
						  constant Camera &camera [[buffer(InitialRenderVertexShaderCameraIndex)]])
{
	RasterizerData out;
	
	Vertex v = vertexData[vertexID];

	float4 result = float4(v.position, 1.0);
	result = camera.rotation * result;
	result = camera.perspective * result;

	out.position = result;
	out.textureCoordinate = v.textureCoordinate;
	out.surfaceNormal = (camera.toWorldSpace * float4(v.surfaceNormal, 1.0)).xyz;
	
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
							 uint2 tid [[thread_position_in_grid]])
{
	outImage.write(float4(1.0, 0.0, 1.0, 1.0), tid);
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
						  texture2d<float> tex [[ texture(FinalRenderFragmentShaderInputTextureIndex) ]])
{
	constexpr sampler sam(min_filter::nearest, mag_filter::nearest, mip_filter::none);
	float3 color = tex.sample(sam, in.uv).xyz;
	return float4(color, 1.0f);
}
