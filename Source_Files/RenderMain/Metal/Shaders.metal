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
};

vertex RasterizerData
vertexShader(uint vertexID [[vertex_id]],
			 constant Vertex *vertexData [[buffer(0)]],
			 constant float2 *viewportSize [[buffer(1)]],
			 constant float4x4 &perspectiveProjection [[buffer(2)]]) {
	
	RasterizerData out;
	
	Vertex v = vertexData[vertexID];

	float4 result = float4(v.position, 1.0);
	result = perspectiveProjection * result;

	out.position = result;
	out.textureCoordinate = v.textureCoordinate;
	
	return out;
}

fragment float4 fragmentShader(RasterizerData in [[stage_in]]) {
	return float4(0.0, in.textureCoordinate[0], in.textureCoordinate[1], 1.0);
}
