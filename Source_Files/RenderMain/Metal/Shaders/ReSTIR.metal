//
//  ReSTIR.metal
//  AlephOne
//
//  Created by Aanand Prasad on 20/10/2026.
//

#include <metal_stdlib>
using namespace metal;
using namespace raytracing;

#include "ShaderTypes.h"
#include "Constants.h"
#include "Noise.h"
#include "Utils.h"
#include "Sampling.h"


typedef intersector<triangle_data, instancing>::result_type RayTracingResult;

struct TextureArgs {
	array<texture2d<float>, MAX_TEXTURES> textures [[id(0)]];
};

struct RayTracer {
	intersector<triangle_data, instancing> intersector;
	instance_acceleration_structure accelerationStructure;
	constant RayTracingData *perInstanceData;
	constant TextureArgs *textures;
	constant TextureArgs *normalMaps;
	constant TextureArgs *emissionMaps;
	constant LightSource *lightSources;
	constant Reservoir *previousReservoirs;
	device Reservoir *currentReservoirs;
	uint32_t pixelIndex;
	float3 forward; // Unit vector representing the player's look direction in world-space
};

RayTracingData getData(thread RayTracingResult &intersection, thread RayTracer &rayTracer) {
	if (intersection.user_instance_id > 0) return rayTracer.perInstanceData[intersection.user_instance_id];
	return *((const device RayTracingData*) intersection.primitive_data);
}

float3 rayTrace(float3 origin, float3 direction, thread RayTracer &rayTracer, constant Uniforms &uniforms, thread float &seed) {
	ray ray;
	ray.origin = origin;
	ray.direction = direction;
	ray.min_distance = rayEpsilon;
	
	RayTracingResult intersection = rayTracer.intersector.intersect(ray, rayTracer.accelerationStructure);
	
	if (intersection.type == intersection_type::none) {
		return float3(0.0);
	}

	RayTracingData data = getData(intersection, rayTracer);

	float3 color = float3(0.0);

	if (data.material.isLandscape) {
		color = sampleSky(uniforms.sky, ray.direction);
	} else {
		Reservoir r = rayTracer.previousReservoirs[rayTracer.pixelIndex];

		float3 hitPoint = ray.origin + (ray.direction * intersection.distance);

		float3 newDirection = sampleUnitHemisphereCosineWeighted(hash2(seed), data.surfaceNormal);
		float3 newDirectionColor = sampleSky(uniforms.sky, newDirection) * clamp(dot(newDirection, data.surfaceNormal), 0.0, 1.0);
		float newDirectionWeight = length(sampleSky(uniforms.sky, newDirection));
		
		float3 previousDirection = r.direction;
		float3 previousDirectionColor = sampleSky(uniforms.sky, previousDirection) * clamp(dot(previousDirection, data.surfaceNormal), 0.0, 1.0);
		float previousDirectionWeight = clamp(r.sumWeight, 0.1, newDirectionWeight * 20.0);

		float3 selectedDirection;
		float3 selectedDirectionColor;
		float selectedDirectionWeight;
		float unselectedDirectionWeight;

		if (hash1(seed) < previousDirectionWeight/(previousDirectionWeight + newDirectionWeight)) {
			selectedDirection = previousDirection;
			selectedDirectionColor = previousDirectionColor;
			selectedDirectionWeight = previousDirectionWeight;
			unselectedDirectionWeight = newDirectionWeight;
		} else {
			selectedDirection = newDirection;
			selectedDirectionColor = newDirectionColor;
			selectedDirectionWeight = newDirectionWeight;
			unselectedDirectionWeight = previousDirectionWeight;
		}

		ray.origin = hitPoint;
		ray.direction = selectedDirection;
		intersection = rayTracer.intersector.intersect(ray, rayTracer.accelerationStructure);
		data = getData(intersection, rayTracer);

		float visibility = data.material.isLandscape ? 1.0 : 0.0;
		float finalSelectedDirectionWeight = selectedDirectionWeight * visibility;
		r.sumWeight = unselectedDirectionWeight + finalSelectedDirectionWeight;
		if (hash1(seed) < finalSelectedDirectionWeight/r.sumWeight) {
			r.direction = selectedDirection;
		}
		rayTracer.currentReservoirs[rayTracer.pixelIndex] = r;

		color = r.sumWeight * 0.5 * selectedDirectionColor * visibility / selectedDirectionWeight;
	}
	
	return color;
}

kernel void reSTIR(texture2d<float, access::write> outImage [[ texture(RayTracingKernelOutImageIndex) ]],
				   instance_acceleration_structure accelerationStructure [[ buffer(RayTracingKernelAccelerationStructureIndex) ]],
				   constant Uniforms &uniforms [[ buffer(RayTracingKernelUniformsIndex) ]],
				   constant RayTracingData *perInstanceData [[ buffer(RayTracingKernelPerInstanceDataIndex) ]],
				   constant TextureArgs &textures [[ buffer(RayTracingKernelAlbedoTexturesIndex) ]],
				   constant TextureArgs &normalMaps [[ buffer(RayTracingKernelNormalMapsIndex) ]],
				   constant TextureArgs &emissionMaps [[ buffer(RayTracingKernelEmissionMapsIndex) ]],
				   constant LightSource &lightSources [[ buffer(RayTracingKernelLightSourcesIndex) ]],
				   constant Reservoir *previousReservoirs [[ buffer(RayTracingKernelPreviousReservoirIndex) ]],
				   device Reservoir *currentReservoirs [[ buffer(RayTracingKernelCurrentReservoirIndex) ]],
				   uint2 tid [[thread_position_in_grid]])
{
	float2 deltaXY = float2(1.0) / float2(uniforms.resolution);

	// Screen position in [0, 1]
	float2 xy = float2(tid) * deltaXY;

	float seed = getRandomSeed(xy, uniforms.frameNumber);

	float frustumWidth = tan(radians(uniforms.camera.fov/2));
	float frustumHeight = frustumWidth * uniforms.resolution.y / uniforms.resolution.x;
	
	// View-space directions, which then get transformed by the matrices (which expect view-space), then transposed to world-space.
	// This should probably all be reworked somehow
	float4 right   = float4(1.0, 0.0, 0.0, 1.0) * frustumWidth;
	float4 up      = float4(0.0, 1.0, 0.0, 1.0) * frustumHeight;
	float4 forward = float4(0.0, 0.0, 1.0, 1.0);

	right   = uniforms.camera.rotateDirectionMat * right;
	up      = uniforms.camera.rotateDirectionMat * up;
	forward = uniforms.camera.rotateDirectionMat * forward;
	
	uint32_t pixelIndex = tid.y * uniforms.resolution.x + tid.x;
	
	intersector<triangle_data, instancing> intersector;
	RayTracer rayTracer{
		.intersector = intersector,
		.accelerationStructure = accelerationStructure,
		.perInstanceData = perInstanceData,
		.textures = &textures,
		.normalMaps = &normalMaps,
		.emissionMaps = &emissionMaps,
		.lightSources = &lightSources,
		.previousReservoirs = previousReservoirs,
		.currentReservoirs = currentReservoirs,
		.pixelIndex = pixelIndex,
		.forward = forward.zxy,
	};

	// Screen position in [-1, 1], with positive Y = up
	float2 uv = xy * 2.0 - 1.0;
	uv.y = -uv.y;
	
	// Ray direction in world-space
	float3 direction = normalize(uv.x * right.zxy + uv.y * up.zxy + forward.zxy);
	
	float3 color = rayTrace(float3(uniforms.camera.origin), direction, rayTracer, uniforms, seed);

	outImage.write(float4(color, 1.0), tid);
}
