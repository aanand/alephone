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

constexpr sampler sam(mag_filter::nearest, min_filter::nearest, address::clamp_to_edge);

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
					   constant Uniforms &uniforms [[buffer(0)]],
					   texture2d<float> texture [[texture(0)]])
{
	float T = (float)texture.get_width() / (float)texture.get_height();
	float S = (float)uniforms.resolution.x / (float)uniforms.resolution.y;

	float2 scale = float2(1.0);
	float2 offset = float2(0.0);

	if (T > S) {
		scale.y = T/S;
		offset.y = (1.0 - T/S) / 2.0;
	} else {
		scale.x = S/T;
		offset.x = (1.0 - S/T) / 2.0;
	}
	
	float2 uv = in.uv * scale + offset;

	return float4(texture.sample(sam, uv));
}
