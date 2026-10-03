//
//  Denoise.metal
//  AlephOne
//
//  Created by Aanand Prasad on 03/10/2026.
//

#include <metal_stdlib>
using namespace metal;

#include "ShaderTypes.h"


constant float weights[25] = {
	1.f/256.f, 1.f/64.f, 3.f/128.f, 1.f/64.f, 1.f/256.f,
	1.f/ 64.f, 1.f/16.f, 3.f/ 32.f, 1.f/16.f, 1.f/ 64.f,
	3.f/128.f, 3.f/32.f, 9.f/ 64.f, 3.f/32.f, 3.f/128.f,
	1.f/ 64.f, 1.f/16.f, 3.f/ 32.f, 1.f/16.f, 1.f/ 64.f,
	1.f/256.f, 1.f/64.f, 3.f/128.f, 1.f/64.f, 1.f/256.f,
};

constant float cPhi = 10.0;
constant float nPhi = 0.5;
constant float dPhi = 0.1;

kernel void denoiseKernel(constant Uniforms &uniforms [[ buffer(DenoisePassUniformsIndex) ]],
						  constant DenoiseConfig &config [[ buffer(DenoisePassConfigIndex) ]],
						  texture2d<float> normalTexture [[ texture(DenoisePassNormalTextureIndex) ]],
						  texture2d<float> depthTexture [[ texture(DenoisePassDepthTextureIndex) ]],
						  texture2d<float> inputTexture [[ texture(DenoisePassInputTextureIndex) ]],
						  texture2d<float, access::write> outputTexture [[ texture(DenoisePassOutputTextureIndex) ]],
						  uint2 xy [[thread_position_in_grid]])
{
	uint step = config.step;
	uint2 textureSize = uniforms.resolution;

	float4 centerColor = inputTexture.read(xy);
	float4 centerNormal = normalTexture.read(xy);
	float4 centerDepth = depthTexture.read(xy);
	
	float4 accumulation = float4(0.0);

	float totalWeight = 0.0;
	{
		for (int i = -2; i <= 2; i++) {
			for (int j = -2; j <= 2; j++) {
				float kernelWeight = weights[(i+2)*5 + (j+2)];

				uint2 pos = uint2(clamp(int(xy.x + i * step), 0, int(textureSize.x - 1)),
								  clamp(int(xy.y + j * step), 0, int(textureSize.y - 1)));

				float4 color = inputTexture.read(pos);
				float colorDistSquared = distance_squared(color, centerColor);
				float colorWeight = min(exp(-colorDistSquared/cPhi), 1.0);

				float4 normal = normalTexture.read(pos);
				float normalDistSquared = distance_squared(normal, centerNormal);
				float normalWeight = min(exp(-normalDistSquared/nPhi), 1.0);
				
				float4 depth = depthTexture.read(pos);
				float depthDistSquared = distance_squared(depth, centerDepth);
				float depthWeight = min(exp(-depthDistSquared/dPhi), 1.0);
				
				float weight = colorWeight * normalWeight * depthWeight * kernelWeight;

				accumulation += weight * color;
				totalWeight += weight;
			}
		}
	}

	outputTexture.write(accumulation/totalWeight, xy);
}
