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

constant float M_CAP = 20.0;
constant int SPATIAL_R = 16;

Reservoir newReservoir() {
	Reservoir r;
	r.wSum = 0.0;
	r.M = 0.0;
	return r;
}

void updateReservoir(thread Reservoir &r, float3 direction, float weight, thread float &seed) {
	r.wSum += weight;
	r.M += 1;
	if (r.wSum > 0.0 && hash1(seed) * r.wSum < weight) {
		r.direction = direction;
	}
}

float getTargetPDF(Sky sky, float3 direction, float3 normal) {
	if (dot(direction, normal) <= 0.0f) {
		return 0.0f;
	}
	return length(sampleSky(sky, direction));
}

Reservoir combineReservoirs(Reservoir r1, Reservoir r2, float3 normal, Sky sky, thread float &seed) {
	Reservoir s = newReservoir();
	
	float w1 = getTargetPDF(sky, r1.direction, normal) * r1.W * r1.M;
	float w2 = getTargetPDF(sky, r2.direction, normal) * r2.W * r2.M;
	
	updateReservoir(s, r1.direction, w1, seed);
	updateReservoir(s, r2.direction, w2, seed);

	s.M = r1.M + r2.M;
	
	float pHatSelected = getTargetPDF(sky, s.direction, normal);
	if (pHatSelected > 0.0 && s.M > 0.0) {
		s.W = (s.wSum / s.M) / pHatSelected;
	} else {
		s.W = 0.0;
	}
	
	return s;
}

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
	uint2 tid;
	bool useReSTIR;
	float3 forward; // Unit vector representing the player's look direction in world-space
};

RayTracingData getData(thread RayTracingResult &intersection, thread RayTracer &rayTracer) {
	if (intersection.user_instance_id > 0) return rayTracer.perInstanceData[intersection.user_instance_id];
	return *((const device RayTracingData*) intersection.primitive_data);
}

uint32_t getPixelIndex(uint2 tid, constant Uniforms &uniforms) {
	return tid.y * uniforms.resolution.x + tid.x;
}

bool isSky(float3 origin, float3 direction, thread RayTracer &rayTracer) {
	ray ray;
	ray.origin = origin;
	ray.direction = direction;
	ray.min_distance = rayEpsilon;
	ray.max_distance = INFINITY;

	RayTracingResult intersection = rayTracer.intersector.intersect(ray, rayTracer.accelerationStructure);
	
	if (intersection.type == intersection_type::none) {
		return false;
	}
	
	RayTracingData data = getData(intersection, rayTracer);
	
	return data.material.isLandscape;
}

float3 rayTrace(float3 origin, float3 direction, thread RayTracer &rayTracer, constant Uniforms &uniforms, thread float &seed) {
	ray ray;
	ray.origin = origin;
	ray.direction = direction;
	ray.min_distance = rayEpsilon;
	ray.max_distance = INFINITY;
	
	RayTracingResult intersection = rayTracer.intersector.intersect(ray, rayTracer.accelerationStructure);
	
	if (intersection.type == intersection_type::none) {
		return float3(0.0);
	}

	RayTracingData data = getData(intersection, rayTracer);

	float3 color = float3(0.0);

	if (data.material.isLandscape) {
		color = sampleSky(uniforms.sky, ray.direction);
	} else {
		float3 surfaceNormal = data.surfaceNormal;
		float3 hitPoint = ray.origin + (ray.direction * intersection.distance);

		Reservoir r = newReservoir();

		float3 newDirection = sampleUnitHemisphereCosineWeighted(hash2(seed), surfaceNormal);
		bool newDirectionIsSky = isSky(hitPoint, newDirection, rayTracer);
		float pHat = length(sampleSky(uniforms.sky, newDirection)) * (newDirectionIsSky ? 1.0 : 0.0);
		float cosTheta = clamp(dot(newDirection, surfaceNormal), 0.0, 1.0);
		
		if (pHat > 0.0 && cosTheta > 0.0) {
			float q = cosTheta / M_PI_F;
			float w = pHat/q;
			
			r.direction = newDirection;
			r.wSum = w;
			r.M = 1.0;
			r.W = (1.0 / pHat) * (r.wSum / r.M);
		} else {
			r.direction = newDirection;
			r.wSum = 0.0;
			r.M = 1.0;
			r.W = 0.0;
		}
		
		float3 rawDirection = newDirection;
		float rawW = r.W;
		
		uint32_t currentPixelIndex = getPixelIndex(rayTracer.tid, uniforms);

		Reservoir p = rayTracer.previousReservoirs[currentPixelIndex];
		p.M = min(p.M, M_CAP);
		r = combineReservoirs(r, p, surfaceNormal, uniforms.sky, seed);

		// uncomment to leave spatial samples out of history
		rayTracer.currentReservoirs[currentPixelIndex] = r;

		for (int i = 0; i < 4; i++) {
			int xOffset = floor(hash1(seed) * (SPATIAL_R * 2 + 1)) - SPATIAL_R;
			int yOffset = floor(hash1(seed) * (SPATIAL_R * 2 + 1)) - SPATIAL_R;
			
			int x = (int)rayTracer.tid.x + xOffset;
			if (x < 0 || x >= (int)uniforms.resolution.x) {
				continue;
			}

			int y = (int)rayTracer.tid.y + yOffset;
			if (y < 0 || y >= (int)uniforms.resolution.y) {
				continue;
			}
			
			uint32_t neighborIndex = getPixelIndex(uint2(x, y), uniforms);
			Reservoir n = rayTracer.previousReservoirs[neighborIndex];
			n.M = min(n.M, M_CAP);
			r = combineReservoirs(r, n, surfaceNormal, uniforms.sky, seed);
		}

		// uncomment to include spatial samples in history
		// rayTracer.currentReservoirs[currentPixelIndex] = r;

		float3 finalDirection = rayTracer.useReSTIR ? r.direction : rawDirection;
		float3 finalW = (rayTracer.useReSTIR ? r.W : rawW);
		
		bool isVisible = isSky(hitPoint, finalDirection, rayTracer);
		
		if (isVisible) {
			float3 skyColor = sampleSky(uniforms.sky, finalDirection);
			float cosTheta = clamp(dot(finalDirection, surfaceNormal), 0.0, 1.0);
			float brdf = defaultAttenuation / M_PI_F;
			
			color = skyColor * cosTheta * brdf * finalW;
		}
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
		.tid = tid,
		.useReSTIR = tid.x > uniforms.resolution.x/2,
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
