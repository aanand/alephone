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
	float4 color;
};

vertex RasterizerData
quadShader(uint vertexID [[vertex_id]],
		   constant QuadData *quadData [[buffer(0)]]) {

	RasterizerData out;

	uint quadIndex = vertexID / 6; // index into quadData
	uint abcdef = vertexID % 6;    // which point of the 6 we need to draw, from 0..5
	
	QuadData quad = quadData[quadIndex];
//	QuadData quad;
//	quad.v0 = float3(-0.5, -0.5, 0);
//	quad.v1 = float3(-0.5, +0.5, 0);
//	quad.v2 = float3(+0.5, +0.5, 0);
//	quad.v3 = float3(+0.5, -0.5, 0);
	
	float3 position;

	switch (abcdef) {
		// Top triangle is v0, v1, v2
		case 0:
			position = quad.v0;
			break;
		case 1:
			position = quad.v1;
			break;
		case 2:
			position = quad.v2;
			break;
		// Bottom triangle is v0, v2, v3
		case 3:
			position = quad.v0;
			break;
		case 4:
			position = quad.v2;
			break;
		case 5:
			position = quad.v3;
			break;
	}

	out.position = float4(position.xyz, 1.0);
	out.color = float4(1.0, 0.0, 0.0, 1.0);
	
	return out;
}

fragment float4 fragmentShader(RasterizerData in [[stage_in]]) {
	return in.color;
}
