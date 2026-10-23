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
constant int SPATIAL_N = 4;
constant int SPATIAL_R = 16;

constant float MOTION_LIMIT = 128.0;

constant float EMISSION_MULTIPLIER = 10.0;

Reservoir newReservoir() {
	Reservoir r;
	r.wSum = 0.0;
	r.M = 0.0;
	return r;
}

void updateReservoir(thread Reservoir &r, Sample sample, float weight, thread float &seed) {
	r.wSum += weight;
	r.M += 1;
	if (r.wSum > 0.0 && hash1(seed) * r.wSum < weight) {
		r.sample = sample;
	}
}

float getTargetPDF(Sample sample) {
	float3 direction = sample.xS - sample.xV;
	float cosTheta = dot(direction, sample.nV);
	if (cosTheta <= 0.0f) {
		return 0.0f;
	}
	return length(sample.Lo) * cosTheta;
}

Reservoir combineReservoirs(Reservoir r1, Reservoir r2, thread float &seed) {
	Reservoir s = newReservoir();
	
	float w1 = getTargetPDF(r1.sample) * r1.W * r1.M;
	float w2 = getTargetPDF(r2.sample) * r2.W * r2.M;
	
	updateReservoir(s, r1.sample, w1, seed);
	updateReservoir(s, r2.sample, w2, seed);

	s.M = r1.M + r2.M;
	
	float pHatSelected = getTargetPDF(s.sample);
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
	thread texture2d<float> *motionData;
	uint2 tid;
	bool useReSTIR;
	float3 forward; // Unit vector representing the player's look direction in world-space
};

RayTracingData getData(thread RayTracingResult &intersection, thread RayTracer &rayTracer) {
	if (intersection.user_instance_id > 0) return rayTracer.perInstanceData[intersection.user_instance_id];
	return *((const device RayTracingData*) intersection.primitive_data);
}

float2 getUV(thread RayTracingResult &intersection, thread RayTracingData &data) {
	if (intersection.user_instance_id > 0) {
		return getPolygonUV(intersection, data.uv);
	}
	return getTriangleUV(intersection, data.uv[0], data.uv[1], data.uv[2]);
}

uint32_t getPixelIndex(uint2 tid, constant Uniforms &uniforms) {
	return tid.y * uniforms.resolution.x + tid.x;
}

RayTracingResult castRay(float3 origin, float3 direction, thread RayTracer &rayTracer) {
	ray ray;
	ray.origin = origin;
	ray.direction = direction;
	ray.min_distance = rayEpsilon;
	ray.max_distance = INFINITY;

	return rayTracer.intersector.intersect(ray, rayTracer.accelerationStructure);
}

constexpr sampler sam(mag_filter::nearest, min_filter::nearest, address::repeat);

float3 getEmission(RayTracingResult intersection, float3 direction, thread RayTracer &rayTracer, constant Uniforms &uniforms) {
	if (intersection.type == intersection_type::none) {
		return float3(0.0);
	}
	
	RayTracingData data = getData(intersection, rayTracer);
	
	if (data.material.isLandscape) {
		return sampleSky(uniforms.sky, direction);
	}

	uint32_t textureIndex = data.textureIndex;
	if (textureIndex > 0) {
		float2 uv = getUV(intersection, data);
		texture2d<float> emissionMap = rayTracer.emissionMaps->textures[textureIndex];
		float4 emission = emissionMap.sample(sam, uv);
		return emission.rgb * emission.a * EMISSION_MULTIPLIER;
	}
	
	return float3(0.0);
}

float3 getAlbedo(RayTracingResult intersection, thread RayTracer &rayTracer) {
	if (intersection.type == intersection_type::none) {
		return float3(0.0);
	}
	
	RayTracingData data = getData(intersection, rayTracer);
	
	if (data.material.isLandscape) {
		return float3(1.0);
	}
	
	uint32_t textureIndex = data.textureIndex;
	if (textureIndex > 0) {
		float2 uv = getUV(intersection, data);
		texture2d<float> texture = rayTracer.textures->textures[textureIndex];
		return texture.sample(sam, uv).rgb;
	}
	
	return float3(0.0);
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
	float3 directEmission = getEmission(intersection, direction, rayTracer, uniforms);
	float3 albedo = getAlbedo(intersection, rayTracer);

	if (data.material.isLandscape) {
		return sampleSky(uniforms.sky, ray.direction);
	} else {
		float3 surfaceNormal = data.surfaceNormal;
		float3 hitPoint = ray.origin + (ray.direction * intersection.distance);

		float3 newDirection = sampleUnitHemisphereCosineWeighted(hash2(seed), surfaceNormal);
		RayTracingResult result = castRay(hitPoint, newDirection, rayTracer);
		if (result.type == intersection_type::none) {
			return float3(0.0);
		}

		Sample initialSample = {
			.xV = hitPoint,
			.nV = surfaceNormal,
			.xS = hitPoint + newDirection * result.distance,
			.nS = getData(result, rayTracer).surfaceNormal,
			.Lo = getEmission(result, newDirection, rayTracer, uniforms),
		};

		Reservoir r = newReservoir();
		r.sample = initialSample;

		float pHat = getTargetPDF(initialSample);
		
		if (pHat > 0.0) {
			float q = clamp(dot(newDirection, surfaceNormal), 0.0, 1.0) / M_PI_F;
			float w = pHat/q;
			
			r.wSum = w;
			r.M = 1.0;
			r.W = (1.0 / pHat) * (r.wSum / r.M);
		} else {
			r.wSum = 0.0;
			r.M = 1.0;
			r.W = 0.0;
		}
		
		float initialW = r.W;
		
		float2 motion = rayTracer.motionData->read(rayTracer.tid).xy;
		if (length(motion) < MOTION_LIMIT) {
			int prevX = (int)rayTracer.tid.x + round(motion.x);
			int prevY = (int)rayTracer.tid.y + round(motion.y);

			if (prevX >= 0 && prevX < (int)uniforms.resolution.x &&
				prevY >= 0 && prevY < (int)uniforms.resolution.y)
			{
				uint32_t previousPixelIndex = getPixelIndex(uint2(prevX, prevY), uniforms);
				Reservoir p = rayTracer.previousReservoirs[previousPixelIndex];
				p.M = min(p.M, M_CAP);
				r = combineReservoirs(r, p, seed);
			}
		}

		uint32_t currentPixelIndex = getPixelIndex(rayTracer.tid, uniforms);

		// uncomment to leave spatial samples out of history
		rayTracer.currentReservoirs[currentPixelIndex] = r;

		for (int i = 0; i < SPATIAL_N; i++) {
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
			r = combineReservoirs(r, n, seed);
		}

		// uncomment to include spatial samples in history
		// rayTracer.currentReservoirs[currentPixelIndex] = r;

		Sample finalSample = rayTracer.useReSTIR ? r.sample : initialSample;
		float3 finalW = (rayTracer.useReSTIR ? r.W : initialW);
		
		float cosTheta = clamp(dot(finalSample.xS - hitPoint, surfaceNormal), 0.0, 1.0);
		float3 brdf = albedo / M_PI_F;
		
		float3 collectedEmission = finalSample.Lo * cosTheta * brdf * finalW;

		return directEmission + collectedEmission;
	}
}

kernel void reSTIR(texture2d<float, access::write> outImage [[ texture(RayTracingKernelOutImageIndex) ]],
				   texture2d<float> motionData [[ texture(RayTracingKernelMotionTextureIndex) ]],
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
		.motionData = &motionData,
		.tid = tid,
		.useReSTIR = true,
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
