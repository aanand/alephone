//
//  Terminal.metal
//  AlephOne
//
//  Created by Aanand Prasad on 08/11/2026.
//

#include <metal_stdlib>
using namespace metal;


#include "ShaderTypes.h"

constant float2 quadVertices[] = {
	float2(-1, -1),
	float2(-1,  1),
	float2( 1,  1),
	float2(-1, -1),
	float2( 1,  1),
	float2( 1, -1)
};

struct VertexOut {
	float4 position [[position]];
	float2 uv;
};

vertex VertexOut
terminalVertexShader(unsigned short vid [[vertex_id]])
{
	float2 position = quadVertices[vid];
	float2 textureSpace = position * 0.5f + 0.5f;

	return {
		.position = float4(position, 0.0, 1.0),
		.uv = float2(textureSpace.x, 1.0 - textureSpace.y),
	};
}

fragment float4
terminalFragmentShader(VertexOut in [[stage_in]],
					   texture2d<float> texture [[texture(0)]])
{
	constexpr sampler sam(mag_filter::nearest, min_filter::nearest);
	return float4(texture.sample(sam, in.uv));
}
