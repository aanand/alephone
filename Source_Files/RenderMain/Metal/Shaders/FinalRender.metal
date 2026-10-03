//
//  FinalRender.metal
//  AlephOne
//
//  Created by Aanand Prasad on 16/09/2026.
//

#include <metal_stdlib>
using namespace metal;

#include "ShaderTypes.h"
#include "Constants.h"


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

// Pulled from Apple's code examples. Might need this later
//static float3 ToneMapACES(float3 x)
//{
//	float a = 2.51f;
//	float b = 0.03f;
//	float c = 2.43f;
//	float d = 0.59f;
//	float e = 0.14f;
//	return saturate((x*(a*x+b))/(x*(c*x+d)+e));
//}

// Adapted from https://developer.apple.com/documentation/metal/accelerating-ray-tracing-using-metal?language=objc
fragment float4
finalRenderFragmentShader(CopyVertexOut in [[stage_in]],
						  constant Uniforms &uniforms [[ buffer(FinalRenderFragmentShaderUniformsIndex) ]],
						  texture2d<float> rawOutputTex [[ texture(FinalRenderFragmentShaderRawOutputTextureIndex) ]],
						  texture2d<float> processedOutputTex [[ texture(FinalRenderFragmentShaderProcessedOutputTextureIndex) ]])
{
	constexpr sampler sam(min_filter::nearest, mag_filter::nearest, mip_filter::none);
	return processedOutputTex.sample(sam, in.uv);
}
