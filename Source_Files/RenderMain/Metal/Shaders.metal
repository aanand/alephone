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
vertexShader(uint vertexID [[vertex_id]],
			 constant Vertex *vertexData [[buffer(0)]],
			 constant float2 *viewportSize [[buffer(1)]],
			 constant float4x4 &perspectiveProjection [[buffer(2)]]) {
	
	RasterizerData out;
	float3 position = vertexData[vertexID].position;

	float4 result = float4(position, 1.0);
	result = perspectiveProjection * result;

	out.position = result;
	out.color = float4(clamp(float3(1, 1, 1) - result.zzz * 0.25, 0.0, 1.0), 1.0);
	
	return out;
}

fragment float4 fragmentShader(RasterizerData in [[stage_in]]) {
	return in.color;
}
