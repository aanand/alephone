//
//  TAA.metal
//  AlephOne
//
//  Created by Aanand Prasad on 14/10/2026.
//

#include <metal_stdlib>
using namespace metal;

#include "ShaderTypes.h"

constant float weight = 0.9;

kernel void TAA(constant Uniforms &uniforms [[ buffer(TAAKernelUniformsIndex) ]],
				texture2d<float> inputTexture [[ texture(TAAKernelInputTextureIndex) ]],
				texture2d<float> motionTexture [[ texture(TAAKernelMotionTextureIndex) ]],
				texture2d<float> previousOutputTexture [[ texture(TAAKernelPreviousOutputTextureIndex) ]],
				texture2d<float, access::read_write> outputTexture [[ texture(TAAKernelOutputTextureIndex) ]],
				uint2 tid [[ thread_position_in_grid ]])
{
	float3 current = inputTexture.read(tid).rgb;
	float2 offset = motionTexture.read(tid).rg;

//	float offsetX = (offset.x / uniforms.resolution.x) + 0.5;
//	float offsetY = (offset.y / uniforms.resolution.y) + 0.5;
//	outputTexture.write(float4(offsetX, offsetY, 0.0, 1.0), tid);

	if (-100 < offset.x && offset.x < 100 &&
		-100 < offset.y && offset.y < 100)
	{
		float x = (float)tid.x + offset.x;
		float y = (float)tid.y + offset.y;

		if (0 <= x && x < uniforms.resolution.x &&
			0 <= y && y < uniforms.resolution.y)
		{
			constexpr sampler sam(mag_filter::linear, min_filter::linear);
			float2 uv = (float2(x, y) + 0.5) / float2(uniforms.resolution);
			float3 previous = previousOutputTexture.sample(sam, uv).rgb;
			float3 merged = mix(current, previous, weight);
			outputTexture.write(float4(merged, 1.0), tid);
			return;
		}
	}

	outputTexture.write(float4(current, 1.0), tid);
}
