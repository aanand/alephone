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
			 constant VertexData *vertexData [[buffer(0)]],
			 constant uint2 *viewportSizePointer [[buffer(1)]]) {
	RasterizerData out;

	float2 pixelSpacePosition = vertexData[vertexID].position.xy;
	float2 viewportSize = float2(*viewportSizePointer);
	
	out.position.xy = pixelSpacePosition / (viewportSize/2.0);
	out.position.z = 0.0;
	out.position.w = 1.0;
	
	out.color = vertexData[vertexID].color;
	
	return out;
}

fragment float4 fragmentShader(RasterizerData in [[stage_in]]) {
	return in.color;
}
