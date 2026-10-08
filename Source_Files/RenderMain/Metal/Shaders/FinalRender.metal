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

static float3 ToneMapACES(float3 x)
{
	float a = 2.51f;
	float b = 0.03f;
	float c = 2.43f;
	float d = 0.59f;
	float e = 0.14f;
	return saturate((x*(a*x+b))/(x*(c*x+d)+e));
}

fragment float4
finalRenderFragmentShader(CopyVertexOut in [[stage_in]],
						  constant Uniforms &uniforms [[ buffer(FinalRenderFragmentShaderUniformsIndex) ]],
						  texture2d<float> albedoTex [[ texture(FinalRenderFragmentShaderAlbedoTextureIndex) ]],
						  texture2d<float> rayTracingTex [[ texture(FinalRenderFragmentShaderRayTracingTextureIndex) ]])
{
	constexpr sampler sam(min_filter::nearest, mag_filter::nearest, mip_filter::none);
	
	float4 color;

	if (uniforms.fullPathTracing) {
		color = rayTracingTex.sample(sam, in.uv);
	} else {
		color = albedoTex.sample(sam, in.uv) * rayTracingTex.sample(sam, in.uv);
	}
	
	if (toneMap) {
		color = float4(ToneMapACES(color.rgb), 1.0);
	}
	
	return color;
}
