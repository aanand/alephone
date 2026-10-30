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

constant float M_CAP_TEMPORAL = 30.0;
constant float M_CAP_SPATIAL = 500.0;

constant int SPATIAL_N = 4;
constant int SPATIAL_R = 16;

constant float REUSE_DEPTH_CHANGE_MAXIMUM = 0.3;  // Maximum fractional depth difference

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

void updateW(thread Reservoir &r, float pHat) {
	if (pHat <= 0.0 || r.M <= 0.0) {
		r.W = 0.0;
		return;
	}
	
	r.W = r.wSum / (r.M * pHat);
}

float getCosineTerm(Sample sample) {
	return clamp(dot(normalize(sample.xS - sample.xV), sample.nV), 0.0, 1.0);
}

float getTargetPDF(Sample sample) {
	return length(sample.Lo) * getCosineTerm(sample);
}

float getJacobianDeterminant(Sample source, Sample destination) {
	float3 surfaceToSource = source.xV - source.xS;
	float3 surfaceToDestination = destination.xV - source.xS;

	float distanceToSourceSquared = dot(surfaceToSource, surfaceToSource);
	float distanceToDestinationSquared = dot(surfaceToDestination, surfaceToDestination);
	
	if (distanceToSourceSquared <= 0.0 || distanceToDestinationSquared <= 0.0) {
		return 0.0;
	}
	
	float cosToSource = clamp(dot(normalize(surfaceToSource), source.nS), 0.0, 1.0);
	float cosToDestination = clamp(dot(normalize(surfaceToDestination), source.nS), 0.0, 1.0);
	
	if (cosToSource <= 0.0 || cosToDestination <= 0.0) {
		return 0.0;
	}
	
	return (cosToDestination / distanceToDestinationSquared) / (cosToSource / distanceToSourceSquared);
}

Reservoir combineReservoirs(Reservoir r1, Reservoir r2, thread float &seed) {
	Reservoir s = newReservoir();
	updateReservoir(s, r1.sample, getTargetPDF(r1.sample) * r1.W * r1.M, seed);

	Sample candidate = r2.sample;
	float J = getJacobianDeterminant(r2.sample, s.sample);

	candidate.xV = s.sample.xV;
	candidate.nV = s.sample.nV;
	
	updateReservoir(s, candidate, getTargetPDF(candidate) * J * r2.W * r2.M, seed);

	s.M = r1.M + r2.M;
	updateW(s, getTargetPDF(s.sample));
	
	return s;
}

typedef intersector<triangle_data, instancing>::result_type RayTracingResult;

struct RayTracer {
	intersector<triangle_data, instancing> intersector;
	instance_acceleration_structure accelerationStructure;
	intersection_function_table<triangle_data, instancing> intersectionFunctionTable;
	constant RayTracingData *perInstanceData;
	constant TextureArgs *textures;
	constant TextureArgs *normalMaps;
	constant TextureArgs *emissionMaps;
	constant LightSource *lightSources;
	constant Reservoir *previousReservoirs;
	device Reservoir *currentReservoirs;
	thread texture2d<float> *depthData;
	thread texture2d<float> *motionData;
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

RayTracingResult castRay(ray ray, uint mask, thread RayTracer &rayTracer) {
	return rayTracer.intersector.intersect(ray, rayTracer.accelerationStructure, mask, rayTracer.intersectionFunctionTable);
}

RayTracingResult castRay(ray ray, thread RayTracer &rayTracer) {
	return rayTracer.intersector.intersect(ray, rayTracer.accelerationStructure, MASK_ENABLED, rayTracer.intersectionFunctionTable);
}

RayTracingResult castRay(float3 origin, float3 direction, uint mask, thread RayTracer &rayTracer) {
	ray ray;
	ray.origin = origin;
	ray.direction = direction;
	ray.min_distance = rayEpsilon;
	ray.max_distance = INFINITY;

	return castRay(ray, mask, rayTracer);
}

RayTracingResult castRay(float3 origin, float3 direction, thread RayTracer &rayTracer) {
	return castRay(origin, direction, MASK_ENABLED, rayTracer);
}

bool isVisible(float3 from, float3 to, thread RayTracer &rayTracer) {
	ray ray;
	ray.origin = from;
	ray.direction = normalize(to - from);
	ray.min_distance = rayEpsilon;
	ray.max_distance = distance(from, to) - rayEpsilon;
	
	RayTracingResult result = castRay(ray, rayTracer);
	
	return result.type == intersection_type::none;
}

constexpr sampler sam(mag_filter::linear, min_filter::linear, address::repeat);

float3 getEmission(RayTracingResult intersection, float3 direction, thread RayTracer &rayTracer, constant Uniforms &uniforms) {
	if (intersection.type == intersection_type::none) {
		return float3(0.0);
	}
	
	RayTracingData data = getData(intersection, rayTracer);
	
	if (data.material.isLandscape) {
		return sampleSky(uniforms.sky, direction);
	}

	if (data.textureIndex > 0) {
		float2 uv = getUV(intersection, data);
		texture2d<float> emissionMap = rayTracer.emissionMaps->textures[data.textureIndex];
		float4 emission = emissionMap.sample(sam, uv);

		float lightSourceMultiplier = 1.0;
		if (data.lightSourceIndex >= 0) {
			lightSourceMultiplier = rayTracer.lightSources[data.lightSourceIndex].intensity;
		}

		return emission.rgb * emission.a * lightSourceMultiplier * EMISSION_MULTIPLIER;
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

float3 getNormal(RayTracingResult intersection, thread RayTracer &rayTracer) {
	if (intersection.type == intersection_type::none) {
		return float3(0.0, 0.0, 1.0);
	}
	
	RayTracingData data = getData(intersection, rayTracer);

	if (data.textureIndex == 0 || length(data.surfaceTangent) == 0.0) {
		return data.surfaceNormal;
	}

	texture2d<float> normalMap = rayTracer.normalMaps->textures[data.textureIndex];
	float2 uv = getUV(intersection, data);
	float3 texelNormal = normalMap.sample(sam, uv).xyz * 2.0 - 1.0;

	float3 T = normalize(data.surfaceTangent.xyz);
	float3 N = normalize(data.surfaceNormal);
	float3 B = cross(T, N) * data.surfaceTangent.w;
	float3x3 TBN = float3x3(T, B, N);

	return normalize(TBN * texelNormal);
}

// Expects xV, nV and random to be set.
// Sets xS, nS and Lo.
bool collectDiffuseSample(thread Sample &sample, thread RayTracer &rayTracer, constant Uniforms &uniforms)
{
	float3 newDirection = sampleUnitHemisphereCosineWeighted(sample.random.xy, sample.nV);
	RayTracingResult firstBounceResult = castRay(sample.xV, newDirection, MASK_SOLID, rayTracer);
	if (firstBounceResult.type == intersection_type::none) {
		return false;
	}

	sample.xS = sample.xV + newDirection * firstBounceResult.distance;
	sample.nS = getData(firstBounceResult, rayTracer).surfaceNormal;

	float3 Lo = getEmission(firstBounceResult, newDirection, rayTracer, uniforms);
	
	float3 albedo = getAlbedo(firstBounceResult, rayTracer);
	float3 bounceDirection = sampleUnitHemisphereCosineWeighted(sample.random.zw, sample.nS);
	RayTracingResult bounce = castRay(sample.xS, bounceDirection, rayTracer);
	Lo += albedo * getEmission(bounce, bounceDirection, rayTracer, uniforms);
	
	sample.Lo = Lo;
	
	return true;
}

Reservoir createInitialReservoir(Sample initialSample) {
	float pHat = getTargetPDF(initialSample);
	float q = getCosineTerm(initialSample) / M_PI_F;

	Reservoir r = newReservoir();
	r.sample = initialSample;
	r.M = 1.0;
	r.wSum = (q > 0.0) ? (pHat/q) : 0.0;
	updateW(r, pHat);
	
	return r;
}

bool acceptReuse(uint2 xy, thread RayTracer &rayTracer) {
	float prevDepth = 1.0 / (1.0 - rayTracer.depthData->read(xy).r);
	float currDepth = 1.0 / (1.0 - rayTracer.depthData->read(rayTracer.tid).r);
	float relativeDepthChange = abs((currDepth-prevDepth)/prevDepth);
	
	if (relativeDepthChange > REUSE_DEPTH_CHANGE_MAXIMUM) return false;
	
	return true;
}

Reservoir reuseTemporalSample(thread Reservoir &r,
							  thread RayTracer &rayTracer,
							  constant Uniforms &uniforms,
							  thread float &seed)
{
	float2 motion = rayTracer.motionData->read(rayTracer.tid).xy;

	int prevX = (int)rayTracer.tid.x + round(motion.x);
	int prevY = (int)rayTracer.tid.y + round(motion.y);

	if (prevX < 0 || prevX >= (int)uniforms.resolution.x) return r;
	if (prevY < 0 || prevY >= (int)uniforms.resolution.y) return r;

	uint2 prevXY = uint2(prevX, prevY);
	
	if (!acceptReuse(prevXY, rayTracer)) return r;

	uint32_t previousPixelIndex = getPixelIndex(prevXY, uniforms);
	Reservoir p = rayTracer.previousReservoirs[previousPixelIndex];
	p.M = min(p.M, M_CAP_TEMPORAL);
	r = combineReservoirs(r, p, seed);
	r.M = min(r.M, M_CAP_TEMPORAL);
	
	return r;
}

Reservoir reuseSpatialSamples(thread Reservoir &r,
							  thread RayTracer &rayTracer,
							  constant Uniforms &uniforms,
							  thread float &seed)
{
	Reservoir spatialReservoir = r;

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
		
		uint2 xy = uint2(x, y);
		if (!acceptReuse(xy, rayTracer)) {
			continue;
		}
		
		uint32_t neighborIndex = getPixelIndex(xy, uniforms);
		Reservoir n = rayTracer.previousReservoirs[neighborIndex];
		if (getTargetPDF(n.sample) > 0.0) {
			spatialReservoir = combineReservoirs(spatialReservoir, n, seed);
		}
	}
	
	spatialReservoir.M = min(spatialReservoir.M, M_CAP_SPATIAL);
	updateW(spatialReservoir, getTargetPDF(spatialReservoir.sample));

	return combineReservoirs(r, spatialReservoir, seed);
}

typedef struct {
	float contribution;
	float3 color;
} SpecularSample;

float getSpecularContribution(float3 direction, float3 normal, Material material) {
	float f0 = material.f0;
	float LdotH = clamp(dot(direction, -normal), 0.0, 1.0);
	float schlick = f0 + (1.0 - f0) * pow(1.0 - LdotH, 5.0);
	return schlick * (1.0 - material.roughness);
}

SpecularSample collectSpecularSample(float3 xV, float3 nV,
									 float3 incomingDirection,
									 RayTracingData hitData,
									 thread RayTracer &rayTracer,
									 constant Uniforms &uniforms)
{
	float contribution = getSpecularContribution(incomingDirection, nV, hitData.material);

	if (contribution > 0.0) {
		float3 outgoingDirection = reflect(incomingDirection, nV);
		if (dot(outgoingDirection, hitData.surfaceNormal) > 0.0) {
			RayTracingResult firstBounceResult = castRay(xV, outgoingDirection, rayTracer);
			if (firstBounceResult.type != intersection_type::none) {
				float3 color = getEmission(firstBounceResult, outgoingDirection, rayTracer, uniforms);
				return { .contribution = contribution, .color = color };
			}
		}
	}

	return { .contribution = 0.0, .color = float3(0.0) };
}

// For transparent materials, perform a naïve 3-ray Monte Carlo path trace.
// First ray continues into the medium, second ray hopefully bounces back up, third ray escapes and hopefully hits a light.
float3 collectRefractedSample(float3 xV, float3 nV,
							  float3 incomingDirection,
							  thread RayTracingResult &initialHitResult,
							  thread RayTracingData &initialHitData,
							  thread RayTracer &rayTracer,
							  constant Uniforms &uniforms,
							  thread float &seed)
{
	float3 currentPosition = xV;
	float3 currentNormal = nV;
	float3 currentDirection = incomingDirection;
	RayTracingResult currentResult = initialHitResult;
	RayTracingData currentData = initialHitData;
	
	float3 tcol = float3(0.0);
	float3 fcol = float3(1.0);

	int bounce = 0;
	while (true) {
		float3 outgoingDirection;

		if (currentData.material.isTransparent) {
			bool isEntering = dot(currentDirection, currentData.surfaceNormal) < 0.0;
			float refractiveIndex = currentData.material.refractiveIndex;
			
			float3 refractedDirection = refract(currentDirection,
												isEntering ? currentNormal : -currentNormal,
												isEntering ? 1.0/refractiveIndex : refractiveIndex);
			
			outgoingDirection = length(refractedDirection) < 0.5 ? reflect(currentDirection, currentNormal) : refractedDirection;
		} else {
			float3 emission = getEmission(currentResult, currentDirection, rayTracer, uniforms);
			tcol += fcol * emission;

			if (currentData.material.isLandscape) break;

			float3 albedo = getAlbedo(currentResult, rayTracer);
			fcol *= albedo;
			
			outgoingDirection = sampleUnitHemisphereCosineWeighted(hash2(seed), getNormal(currentResult, rayTracer));
		}
		
		if (bounce >= 3) break;
		
		RayTracingResult result = castRay(currentPosition, outgoingDirection, rayTracer);
		if (result.type == intersection_type::none) break;

		RayTracingData data = getData(result, rayTracer);
		float3 normal = getNormal(result, rayTracer);
		
		currentPosition = currentPosition + outgoingDirection * result.distance;
		currentNormal = normal;
		currentDirection = outgoingDirection;
		currentResult = result;
		currentData = data;
		bounce++;
	}
	
	return tcol * fcol;
}

float3 diffuseReSTIR(float3 xV, float3 nV, float3 albedo,
					 thread RayTracer &rayTracer,
					 constant Uniforms &uniforms,
					 thread float &seed)
{
	Sample initialSample = {
		.xV = xV,
		.nV = nV,
		.random = float4(hash2(seed), hash2(seed)),
	};
	if (!collectDiffuseSample(initialSample, rayTracer, uniforms)) {
		return float3(0.0);
	}

	Reservoir r = createInitialReservoir(initialSample);
	float initialW = r.W;
	
	r = reuseTemporalSample(r, rayTracer, uniforms, seed);

	uint32_t currentPixelIndex = getPixelIndex(rayTracer.tid, uniforms);
	rayTracer.currentReservoirs[currentPixelIndex] = r;

	r = reuseSpatialSamples(r, rayTracer, uniforms, seed);

	Sample finalSample = rayTracer.useReSTIR ? r.sample : initialSample;
	float3 finalW = (rayTracer.useReSTIR ? r.W : initialW);
	
	if (!isVisible(xV, finalSample.xV, rayTracer)) {
		return float3(0.0);
	}
	
	float cosTheta = getCosineTerm(finalSample);
	float3 brdf = albedo / M_PI_F;
	
	return finalSample.Lo * cosTheta * brdf * finalW;
}

float3 samplePlayerLightEmission(float3 xV, float3 nV, thread RayTracer &rayTracer, constant Uniforms &uniforms) {
	float3 playerLightPosition = getPlayerLightPosition(rayTracer.forward, uniforms);

	if (!isVisible(xV, playerLightPosition, rayTracer)) {
		return float3(0.0);
	}
	
	float playerLightIntensity = getPlayerLightIntensity(uniforms, rayTracer.forward, xV);

	float3 hitPointToLight = playerLightPosition - xV;
	float angleWeight = clamp(dot(nV, normalize(hitPointToLight)), 0.0, 1.0);
	float distanceWeight = clamp(pow(length(hitPointToLight) / 1024.0, -2.0), 0.0, 1.0);

	return playerLightIntensity * angleWeight * distanceWeight;
}

float3 rayTrace(float3 origin, float3 direction, thread RayTracer &rayTracer, constant Uniforms &uniforms, thread float &seed) {
	RayTracingResult initialRayResult = castRay(origin, direction, rayTracer);
	
	if (initialRayResult.type == intersection_type::none) {
		return float3(0.0);
	}

	RayTracingData initialHitData = getData(initialRayResult, rayTracer);
	float3 directEmission = getEmission(initialRayResult, direction, rayTracer, uniforms);

	if (initialHitData.material.isLandscape) {
		return directEmission;
	}
	
	float3 xV = origin + (direction * initialRayResult.distance);
	float3 nV = getNormal(initialRayResult, rayTracer);

	SpecularSample specular = collectSpecularSample(xV, nV, direction, initialHitData, rayTracer, uniforms);

	if (initialHitData.material.isTransparent) {
		float3 refractedComponent = collectRefractedSample(xV, nV, direction, initialRayResult, initialHitData, rayTracer, uniforms, seed);
		return mix(refractedComponent, specular.color, specular.contribution);
	}
	
	float3 playerLightEmission = samplePlayerLightEmission(xV, nV, rayTracer, uniforms);
	
	float3 albedo = getAlbedo(initialRayResult, rayTracer);
	float3 diffuseComponent = diffuseReSTIR(xV, nV, albedo, rayTracer, uniforms, seed);
	
	return directEmission + (playerLightEmission * albedo) + mix(diffuseComponent, specular.color, specular.contribution);
}

kernel void reSTIR(texture2d<float, access::write> outImage [[ texture(RayTracingKernelOutImageIndex) ]],
				   texture2d<float> depthData [[ texture(RayTracingKernelDepthTextureIndex) ]],
				   texture2d<float> motionData [[ texture(RayTracingKernelMotionTextureIndex) ]],
				   instance_acceleration_structure accelerationStructure [[ buffer(RayTracingKernelAccelerationStructureIndex) ]],
				   intersection_function_table<triangle_data, instancing> intersectionFunctionTable [[ buffer(RayTracingKernelIntersectionFunctionTableIndex) ]],
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
	float2 xy = (float2(tid) + uniforms.camera.jitter) * deltaXY;

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
		.intersectionFunctionTable = intersectionFunctionTable,
		.perInstanceData = perInstanceData,
		.textures = &textures,
		.normalMaps = &normalMaps,
		.emissionMaps = &emissionMaps,
		.lightSources = &lightSources,
		.previousReservoirs = previousReservoirs,
		.currentReservoirs = currentReservoirs,
		.depthData = &depthData,
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
