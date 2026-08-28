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
		   constant QuadData *quadData [[buffer(0)]],
		   constant float2 *viewportSize [[buffer(1)]],
		   constant float4x4 &perspectiveProjection [[buffer(2)]]) {

	RasterizerData out;

	uint quadIndex = vertexID / 6; // index into quadData
	uint abcdef = vertexID % 6;    // which point of the 6 we need to draw, from 0..5
	
	QuadData quad = quadData[quadIndex];
	
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
	
	float4 result = float4(position, 1.0);
	result = perspectiveProjection * result;

	out.position = result;
	out.color = float4(clamp(float3(1, 1, 1) - result.zzz * 0.1, 0.0, 1.0), 1.0);
	
	return out;
}

vertex RasterizerData
mapShader(uint vertexID [[vertex_id]],
		  constant QuadData *quadData [[buffer(0)]],
		  constant float2 *viewportSize [[buffer(1)]],
		  constant float4x4 *perspectiveProjection [[buffer(2)]]) {
	
	RasterizerData out;

	uint quadIndex = vertexID / 2; // index into quadData
	uint pointIndex = vertexID % 2; // 0 = start, 1 = end
	float3 position = pointIndex == 0 ? quadData[quadIndex].v0 : quadData[quadIndex].v1;

	out.position = float4(position.xz, 0.0, 1.0);
	out.color = float4(normalize(position.xyz) * 0.5 + 0.5, 1.0);
	
	return out;
}

vertex RasterizerData
vertexShader(uint vertexID [[vertex_id]],
			 constant VertexFloat3 *vertexData [[buffer(0)]],
			 constant float2 *viewportSize [[buffer(1)]],
			 constant float4x4 &perspectiveProjection [[buffer(2)]]) {
	
	RasterizerData out;
	VertexFloat3 position = vertexData[vertexID];

	float4 result = float4(position, 1.0);
	result = perspectiveProjection * result;

	out.position = result;
	out.color = float4(clamp(float3(1, 1, 1) - result.zzz * 0.1, 0.0, 1.0), 1.0);
	
	return out;
}

fragment float4 fragmentShader(RasterizerData in [[stage_in]]) {
	return in.color;
}
