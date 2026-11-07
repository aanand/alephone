//
//  LoadingScreen.metal
//  AlephOne
//
//  Created by Aanand Prasad on 07/11/2026.
//

#include <metal_stdlib>
using namespace metal;

#include "ShaderTypes.h"

constant float left   = -0.5;
constant float right  =  0.5;
constant float bottom = -0.01;
constant float top    =  0.01;

constant float2 quadVertices[] = {
	float2(0, 0),
	float2(0, 1),
	float2(1, 1),
	float2(0, 0),
	float2(1, 1),
	float2(1, 0),
};

struct VertexOut {
	float4 position [[position]];
	float3 color;
};

vertex VertexOut
loadingScreenVertexShader(unsigned short vid [[vertex_id]],
						  constant LoadingScreenState &state [[buffer(0)]])
{
	float2 xy = quadVertices[vid % 6];
	float z;
	float3 color;
	
	if (vid < 6) {
		z = 1.0;
		color = float3(0.5);
	} else {
		xy.x *= state.progress;
		z = 0.0;
		color = float3(1.0);
	}
	
	return {
		.position = float4(mix(left, right, xy.x),
						   mix(bottom, top, xy.y),
						   0,
						   1),
		.color = color,
	};
}

fragment float4
loadingScreenFragmentShader(VertexOut in [[stage_in]])
{
	return float4(in.color, 1.0);
}
