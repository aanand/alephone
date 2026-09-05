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

fragment float4
initialRenderFragmentShader(RasterizerData in [[stage_in]],
			   texture2d<half> colorTexture [[ texture(InitialRenderFragmentShaderColorTextureIndex) ]])
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

float radians(float degrees) {
	return degrees * 8.0 * atan(1.0) / 360.0;
}

// Hash functions by Nimitz:
// https://www.shadertoy.com/view/Xt3cDn
uint baseHash(uint2 p)
{
	p = 1103515245U*((p >> 1U)^(p.yx));
	uint h32 = 1103515245U*((p.x)^(p.y>>3U));
	return h32^(h32 >> 16);
}
float3 hash3(thread float &seed) {
	float s1 = seed += 0.1;
	float s2 = seed += 0.1;
	uint n = baseHash(uint2(as_type<uint>(s1), as_type<uint>(s2)));
	uint3 rz = uint3(n, n*16807U, n*48271U);
	return float3(rz & uint3(0x7fffffffU))/float(0x7fffffff);
}

// By reinder:
// https://www.shadertoy.com/view/llVcDz
float3 randomInUnitSphere(thread float &seed) {
	float3 h = hash3(seed) * float3(2.,6.28318530718,1.)-float3(1,0,0);
	float phi = h.y;
	float r = pow(h.z, 1./3.);
	return r * float3(sqrt(1.-h.x*h.x)*float2(sin(phi),cos(phi)),h.x);
}

kernel void rayTracingKernel(texture2d<float, access::write> outImage [[ texture(RayTracingKernelOutImageIndex) ]],
							 instance_acceleration_structure accelerationStructure [[ buffer(RayTracingKernelAccelerationStructureIndex) ]],
							 constant Uniforms &uniforms [[ buffer(RayTracingKernelCameraIndex) ]],
							 uint2 tid [[thread_position_in_grid]])
{
	// Screen position in [0, 1]
	float2 xy = float2(tid) / float2(uniforms.resolution);

	float seed = float(baseHash(uint2(as_type<uint>(xy.x), as_type<uint>(xy.y)))) / float(0xffffffffU);
	
	// Screen position in [-1, 1], with positive Y = up
	float2 uv = xy * 2.0 - 1.0;
	uv.y = -uv.y;
	
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

	// Ray direction in world-space
	float3 direction = normalize(uv.x * right.zxy + uv.y * up.zxy + forward.zxy);
	
	ray ray;
	ray.origin = float3(uniforms.origin);
	ray.direction = direction;
	ray.max_distance = INFINITY;

	int numBounces = 10;
	float3 color = float3(1.0, 1.0, 1.0);
	
	for (int b = 0; b < numBounces; b++) {
		intersector<triangle_data, instancing> i;
		typename intersector<triangle_data, instancing>::result_type intersection = i.intersect(ray, accelerationStructure);
		
		if (intersection.type == intersection_type::none) {
			break;
		} else {
			color = color * 0.8;

			const device TriangleRayTracingData *data;
			data = (const device TriangleRayTracingData*) intersection.primitive_data;
			float3 normal = data->surfaceNormal;

			float3 hitPoint = ray.origin + (ray.direction * intersection.distance);
			float3 newDirection = randomInUnitSphere(seed);
			if (dot(newDirection, normal) < 0) {
				newDirection = -newDirection;
			}
			ray.origin = hitPoint;
			ray.direction = newDirection;
		}
	}
	
	outImage.write(float4(color, 1.0), tid);
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

// Adapted from https://developer.apple.com/documentation/metal/accelerating-ray-tracing-using-metal?language=objc
fragment float4
finalRenderFragmentShader(CopyVertexOut in [[stage_in]],
						  texture2d<float> initialPassTex [[ texture(FinalRenderFragmentShaderInitialPassTextureIndex) ]],
						  texture2d<float> rayTracingPassTex [[ texture(FinalRenderFragmentShaderRayTracingPassTextureIndex) ]])
{
	constexpr sampler sam(min_filter::nearest, mag_filter::nearest, mip_filter::none);
	float4 initialPassColor = initialPassTex.sample(sam, in.uv);
	float4 rayTracingPassColor = rayTracingPassTex.sample(sam, in.uv);
	float3 color = mix(initialPassColor.rgb, rayTracingPassColor.rgb, rayTracingPassColor.a);
	return float4(color, 1.0f);
}
