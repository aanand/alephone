//
//  Shaders.metal
//  libalephone
//
//  Created by Aanand Prasad on 27/08/2026.
//

#include <metal_stdlib>

using namespace metal;
using namespace raytracing;

#include "VertexTypes.h"

struct RasterizerData {
	float4 position [[position]];
	float2 textureCoordinate;
	float3 surfaceNormal;
};

// Reorient a world-space position to view-space.
// At pitch=0 and yaw=0, world +X is depth, world +Y is left (or... right? check this), and world +Z is up.
// 1024 world-space units = 1 view-space unit.
float3 fromWorldSpace(float3 worldPosition) {
	return float3(worldPosition.y, worldPosition.z, worldPosition.x) / 1024.0;
}

float3 fromWorldSpace(int3 worldPosition) {
	return fromWorldSpace(float3(worldPosition));
}

vertex RasterizerData
initialRenderVertexShader(uint vertexID [[vertex_id]],
						  constant WorldVertex *vertexData [[buffer(InitialRenderVertexShaderVertexDataIndex)]],
						  constant Uniforms &uniforms [[buffer(InitialRenderVertexShaderUniformsIndex)]])
{
	RasterizerData out;
	
	WorldVertex v = vertexData[vertexID];

	float4 result = float4(fromWorldSpace(v.position - uniforms.origin), 1.0);
	result = uniforms.yawMat * result;
	result = uniforms.pitchMat * result;
	result = uniforms.perspectiveMat * result;

	out.position = result;
	out.textureCoordinate = v.textureCoordinate;
	out.surfaceNormal = float4(fromWorldSpace(v.surfaceNormal), 1.0).xyz;
	
	return out;
}

constant float ambientLightIntensity = 0.1;
constant float gain = 1.5;
constant float defaultAttenuation = 0.99;

constant uint numSamples = 1;
constant uint numBounces = 4;
constant int denoiseRadius = 3;

fragment float4
initialRenderFragmentShader(RasterizerData in [[stage_in]],
			   texture2d<half> colorTexture [[ texture(InitialRenderFragmentShaderColorTextureIndex) ]])
{
	constexpr sampler textureSampler (mag_filter::nearest, min_filter::nearest, address::repeat);
	const half4 colorSample = colorTexture.sample(textureSampler, in.textureCoordinate);
	return float4(colorSample);
}

float radians(float degrees) {
	return degrees * 8.0 * atan(1.0) / 360.0;
}

// Hash/vector functions by Nimitz and reinder:
// https://www.shadertoy.com/view/Xt3cDn
// https://www.shadertoy.com/view/llVcDz
uint baseHash(uint2 p)
{
	p = 1103515245U*((p >> 1U)^(p.yx));
	uint h32 = 1103515245U*((p.x)^(p.y>>3U));
	return h32^(h32 >> 16);
}
uint randNext(thread float &seed) {
	float s1 = seed += 0.1;
	float s2 = seed += 0.1;
	return baseHash(uint2(as_type<uint>(s1), as_type<uint>(s2)));
}
float2 hash2(thread float &seed) {
	uint n = randNext(seed);
	uint2 rz = uint2(n, n*48271U);
	return float2(rz.xy & uint2(0x7fffffffU))/float(0x7fffffff);
}
float3 hash3(thread float &seed) {
	uint n = randNext(seed);
	uint3 rz = uint3(n, n*16807U, n*48271U);
	return float3(rz & uint3(0x7fffffffU))/float(0x7fffffff);
}
float3 randomInUnitSphere(thread float &seed) {
	float3 h = hash3(seed) * float3(2.,6.28318530718,1.)-float3(1,0,0);
	float phi = h.y;
	float r = pow(h.z, 1./3.);
	return r * float3(sqrt(1.-h.x*h.x)*float2(sin(phi),cos(phi)),h.x);
}

float getRandomSeed(float2 xy, float frameNumber) {
	return float(baseHash(uint2(as_type<uint>(xy.x), as_type<uint>(xy.y)))) / float(0xffffffffU) + (float)frameNumber;
}

float3 rayTraceSoft(float3 origin, float3 direction,
				instance_acceleration_structure accelerationStructure,
				Uniforms uniforms,
				thread float &seed)
{
	ray ray;
	ray.origin = origin;
	ray.direction = direction;
	ray.min_distance = 0.1;
	ray.max_distance = INFINITY;

	float tcol = 0.0;
	float fcol = 1.0;
	
	intersector<triangle_data, instancing> i;
	typename intersector<triangle_data, instancing>::result_type intersection;

	for (uint b = 0; b < numBounces; b++) {
		intersection = i.intersect(ray, accelerationStructure);
		
		if (intersection.type == intersection_type::none) {
			float cosTheta = dot(ray.direction, -uniforms.sunDirection);
			if (acos(cosTheta) < uniforms.sunRadius) {
				tcol += fcol * uniforms.sunIntensity;
			}

			break;
		} else {
			float3 hitPoint = ray.origin + (ray.direction * intersection.distance);

			const device TriangleRayTracingData *data;
			data = (const device TriangleRayTracingData*) intersection.primitive_data;

			if (length(data->emission) > 0) {
				// We hit a light source
				tcol += length(data->emission);
				break;
			}

			float3 normal = data->surfaceNormal;
			
			float directLightingProbability = 1 - cos(uniforms.sunRadius);
			float directLightingContribution = directLightingProbability * clamp(dot(normal, -uniforms.sunDirection), 0.0, 1.0);

			ray.origin = hitPoint;
			ray.direction = -uniforms.sunDirection;
			if (i.intersect(ray, accelerationStructure).type == intersection_type::none) {
				// We hit the sun
				tcol += fcol * uniforms.sunIntensity * directLightingContribution;
				fcol *= (1.0 - directLightingContribution);
			}
			
			float3 newDirection = normalize(randomInUnitSphere(seed));
			if (dot(newDirection, normal) < 0) {
				newDirection = -newDirection;
			}
			ray.origin = hitPoint;
			ray.direction = newDirection;
			
			fcol *= defaultAttenuation;
		}
	}
	
	return float3(tcol * fcol);
}

kernel void rayTracingKernel(texture2d<float, access::write> outImage [[ texture(RayTracingKernelOutImageIndex) ]],
							 instance_acceleration_structure accelerationStructure [[ buffer(RayTracingKernelAccelerationStructureIndex) ]],
							 constant Uniforms &uniforms [[ buffer(RayTracingKernelCameraIndex) ]],
							 uint2 tid [[thread_position_in_grid]])
{
	float2 deltaXY = float2(1.0) / float2(uniforms.resolution);

	// Screen position in [0, 1]
	float2 xy = float2(tid) * deltaXY;

	float seed = getRandomSeed(xy, uniforms.frameNumber);

	float frustumWidth = tan(radians(uniforms.fov/2));
	float frustumHeight = frustumWidth * uniforms.resolution.y / uniforms.resolution.x;
	
	// View-space directions, which then get transformed by the matrices (which expect view-space), then transposed to world-space.
	// This should probably all be reworked somehow
	float4 right   = float4(1.0, 0.0, 0.0, 1.0) * frustumWidth;
	float4 up      = float4(0.0, 1.0, 0.0, 1.0) * frustumHeight;
	float4 forward = float4(0.0, 0.0, 1.0, 1.0);

	right   = uniforms.rotateDirectionMat * right;
	up      = uniforms.rotateDirectionMat * up;
	forward = uniforms.rotateDirectionMat * forward;
	
	float3 sumColor = float3(0.0);
	
	for (uint s = 0; s < numSamples; s++) {
		float2 xyPerturbed = xy + deltaXY * hash2(seed);

		// Screen position in [-1, 1], with positive Y = up
		float2 uv = xyPerturbed * 2.0 - 1.0;
		uv.y = -uv.y;
		
		// Ray direction in world-space
		float3 direction = normalize(uv.x * right.zxy + uv.y * up.zxy + forward.zxy);
		
		sumColor += rayTraceSoft(float3(uniforms.origin), direction, accelerationStructure, uniforms, seed);
	}
	
	float3 averageColor = sumColor / (float)numSamples;
	float3 adjusted = mix(float3(ambientLightIntensity), float3(1.0), averageColor);

	outImage.write(float4(adjusted, 1.0), tid);
}

// Screen filling quad in normalized device coordinates.
constant float2 quadVertices[] = {
	float2(-1, -1),
	float2(-1,  1),
	float2( 1,  1),
	float2(-1, -1),
	float2( 1,  1),
	float2( 1, -1)
};

struct CopyVertexOut {
	float4 position [[position]];
	float2 uv;
};

// Adapted from https://developer.apple.com/documentation/metal/accelerating-ray-tracing-using-metal?language=objc
vertex CopyVertexOut
finalRenderVertexShader(unsigned short vid [[vertex_id]])
{
	float2 position = quadVertices[vid];

	CopyVertexOut out;

	out.position = float4(position, 0, 1);

	float2 textureSpace = position * 0.5f + 0.5f;
	out.uv = float2(textureSpace.x, 1.0 - textureSpace.y);

	return out;
}

float4 denoisedSample(texture2d<float> texture,
					  uint2 textureSize,
					  sampler sam,
					  float2 uv)
{
	float2 dXY = float2(1.0, 1.0) / float2(textureSize);
	float4 accumulation = float4(0.0);

	int c = 0;
	for (int i = -denoiseRadius; i <= denoiseRadius; i++) {
		for (int j = -denoiseRadius; j <= denoiseRadius; j++) {
			float2 pos = uv + dXY * float2(i, j);
			accumulation += texture.sample(sam, pos);
			c++;
		}
	}

	return accumulation/c;
}

// Adapted from https://developer.apple.com/documentation/metal/accelerating-ray-tracing-using-metal?language=objc
fragment float4
finalRenderFragmentShader(CopyVertexOut in [[stage_in]],
						  constant Uniforms &uniforms [[ buffer(FinalRenderFragmentShaderUniformsIndex) ]],
						  texture2d<float> initialPassTex [[ texture(FinalRenderFragmentShaderInitialPassTextureIndex) ]],
						  texture2d<float> rayTracingPassTex [[ texture(FinalRenderFragmentShaderRayTracingPassTextureIndex) ]])
{
	constexpr sampler sam(min_filter::nearest, mag_filter::nearest, mip_filter::none);

	float4 rayTracingPassColor = denoisedSample(rayTracingPassTex, uniforms.resolution, sam, in.uv);

	float4 initialPassColor = initialPassTex.sample(sam, in.uv);
	float3 color = clamp(initialPassColor.rgb * rayTracingPassColor.rgb * gain, 0.0, 1.0);
//	return float4(rayTracingPassColor.rgb, 1.0f);
	return float4(color, 1.0f);
}
