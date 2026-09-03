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
	float3 surfaceNormal;
};

vertex RasterizerData
vertexShader(uint vertexID [[vertex_id]],
			 constant Vertex *vertexData [[buffer(0)]],
			 constant Camera &camera [[buffer(1)]]) {
	
	RasterizerData out;
	
	Vertex v = vertexData[vertexID];

	float4 result = float4(v.position, 1.0);
	result = camera.rotation * result;
	result = camera.perspective * result;

	out.position = result;
	out.textureCoordinate = v.textureCoordinate;
	out.surfaceNormal = (camera.toWorldSpace * float4(v.surfaceNormal, 1.0)).xyz;
	
	return out;
}

fragment float4 fragmentShader(RasterizerData in [[stage_in]],
							   texture2d<half> colorTexture [[ texture(0) ]])
{
	float3 globalLightDirection = normalize(float3(-1, -1, -1));
	float globalLightIntensity = 1.0;
	float ambientLightIntensity = 0.5;

	float incoming = dot(-in.surfaceNormal, globalLightDirection);
	float intensity = mix(ambientLightIntensity, globalLightIntensity, incoming);

	constexpr sampler textureSampler (mag_filter::nearest, min_filter::nearest, address::repeat);
	const half4 colorSample = colorTexture.sample(textureSampler, in.textureCoordinate);
	return float4(float3(colorSample.xyz) * intensity, colorSample.w);
}
