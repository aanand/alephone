//
//  RayTracing.metal
//  AlephOne
//
//  Created by Aanand Prasad on 16/09/2026.
//

#include <metal_stdlib>
using namespace metal;
using namespace raytracing;

#include "ShaderTypes.h"
#include "Constants.h"
#include "Noise.h"
#include "Sampling.h"
#include "Utils.h"


struct Hit {
	bool didHit;
	float3 hitPoint;
	float3 surfaceNormal;
	float3 normal;
	float3 diffuse;
	float4 emission;
	Material material;
	int32_t lightSourceIndex;
};

typedef intersector<triangle_data, instancing>::result_type RayTracingResult;

struct RayTracer {
	intersector<triangle_data, instancing> intersector;
	instance_acceleration_structure accelerationStructure;
	constant RayTracingData *perInstanceData;
	constant TextureArgs *textures;
	constant TextureArgs *normalMaps;
	constant TextureArgs *emissionMaps;
	constant LightSource *lightSources;
	float3 forward; // Unit vector representing the player's look direction in world-space
};

float3 getPlayerLightPosition(constant Uniforms &uniforms) {
	return float3(uniforms.camera.origin + int3(0, 0, -128));
}

float getPlayerLightIntensity(constant Uniforms &uniforms, thread RayTracer &rayTracer, float3 hitPoint) {
	float weaponFlare = uniforms.weaponFlare * weaponFlareMultiplier;

	float3 lightToHitPoint = hitPoint - getPlayerLightPosition(uniforms);
	float angleFromCenter = acos(dot(normalize(lightToHitPoint), rayTracer.forward));
	float flashlightAngleWeight = 1.0 - clamp(angleFromCenter/(M_PI_F/6.0), 0.0, 1.0);
	float flashlight = uniforms.flashlight * flashlightAngleWeight;

	return weaponFlare + flashlight;
}

// Cast a ray, continuing in the case of hitting a transparent surface.
Hit castRay(thread RayTracer &rayTracer, ray ray)
{
	for (uint p = 0; p < maxAlphaPassthroughs; p++) {
		RayTracingResult intersection = rayTracer.intersector.intersect(ray, rayTracer.accelerationStructure);
		
		if (intersection.type == intersection_type::none) {
			return { .didHit = false };
		}
		
		float3 hitPoint = ray.origin + (ray.direction * intersection.distance);

		float2 uv = float2(0.0, 0.0);

		RayTracingData data = *((const device RayTracingData*) intersection.primitive_data);

		uint32_t instanceId = intersection.user_instance_id;
		if (instanceId > 0) {
			data = rayTracer.perInstanceData[instanceId];
		}
		uv = getUV(intersection, data);
		
		float3 surfaceNormal = data.surfaceNormal;
		float4 surfaceTangent = data.surfaceTangent;
		uint32_t textureIndex = data.textureIndex;
		
		float4 albedo = float4(defaultAttenuation, defaultAttenuation, defaultAttenuation, 1.0);
		float4 emission = float4(0.0);
		float3 normal = surfaceNormal;

		if (textureIndex > 0) {
			constexpr sampler sam(mag_filter::nearest, min_filter::nearest, address::repeat);
			texture2d<float> texture = rayTracer.textures->textures[textureIndex];
			texture2d<float> normalMap = rayTracer.normalMaps->textures[textureIndex];
			texture2d<float> emissionMap = rayTracer.emissionMaps->textures[textureIndex];

			albedo = texture.sample(sam, uv);
			emission = emissionMap.sample(sam, uv);
			
			if (length(surfaceTangent) > 0.0) {
				float3 T = normalize(surfaceTangent.xyz);
				float3 N = normalize(surfaceNormal);
				float3 B = cross(T, N) * surfaceTangent.w;
				float3x3 TBN = float3x3(T, B, N);

				float3 texelNormal = normalMap.sample(sam, uv).xyz * 2.0 - 1.0;
				normal = normalize(TBN * texelNormal);
				
				// Attempt to remove the baked-in lighting from the albedo texture.
				// This isn't perfect, but it helps get back some of the brightness.
				float3 L = normalize(float3(0.5, 1.0, 0.5));
				float3 lightIntensity = clamp(dot(L, texelNormal), 0.2, 1.0);
				float3 delit = mix(albedo.rgb, albedo.rgb/lightIntensity, 0.5);
				albedo = float4(delit, albedo.a);
			}
		}
		
		// We hit something transparent, so continue the ray... unless what we hit was a landscape,
		// which apparently CAN happen, and if not checked for, causes weird zebra stripes in the skies of M2 maps.
		if (albedo.a < 0.5 && !data.material.isLandscape) {
			ray.origin = hitPoint + ray.direction * rayEpsilon;
			ray.max_distance -= (intersection.distance + rayEpsilon);
		} else {
			return {
				.didHit = true,
				.hitPoint = hitPoint,
				.surfaceNormal = surfaceNormal,
				.normal = normal,
				.diffuse = albedo.rgb,
				.emission = emission,
				.material = data.material,
				.lightSourceIndex = data.lightSourceIndex,
			};
		}
	}
	
	return { .didHit = false };
}

float3 rayTraceSoft(float3 origin, float3 direction,
					thread RayTracer &rayTracer,
					constant Uniforms &uniforms,
					thread float &seed)
{
	ray ray;
	ray.origin = origin;
	ray.direction = direction;
	ray.min_distance = rayEpsilon;
	ray.max_distance = INFINITY;

	float3 tcol = float3(0.0);
	float3 fcol = float3(1.0);
	uint b;
	bool isInMedium = uniforms.isInMedium;
	
	for (b = 0; b < maxBounces; b++) {
		Hit hit = castRay(rayTracer, ray);

		if (!hit.didHit) {
			break;
		} else if (hit.material.isLandscape) {
			tcol += fcol * sampleSky(uniforms.sky, ray.direction);
			break;
		} else {
			float3 hitPoint = hit.hitPoint;
			float3 normal = hit.normal;
			
			// If we're not doing full path tracing, the initial ray shouldn't pick up the albedo of the surface it hits,
			// because that will be applied in the final pass
			float3 diffuse = (uniforms.fullPathTracing || b > 0) ? hit.diffuse : float3(1.0);

			float lightSourceMultiplier = 1.0;
			if (hit.lightSourceIndex >= 0) {
				lightSourceMultiplier = rayTracer.lightSources[hit.lightSourceIndex].intensity;
			}
			tcol += fcol * hit.emission.rgb * hit.emission.a * lightSourceMultiplier * 10.0;
			
			// Apply absorption if we just traversed a medium
			if (isInMedium) {
				float dist = distance(ray.origin, hitPoint);
				fcol *= exp(-float3(0.5, 0.3, 0.1) * dist * 0.001);
			}

			float f0 = hit.material.f0;
			float LdotH = clamp(dot(ray.direction, -normal), 0.0, 1.0);
			float schlick = f0 + (1.0 - f0) * pow(1.0 - LdotH, 5.0);
			
			float specularProbability = schlick * (1.0 - hit.material.roughness);
			
			// If the material we just hit is a medium, decide whether to enter it
			if (hit.material.isTransparent) {
				bool isEntering = dot(ray.direction, hit.surfaceNormal) < 0.0;

				if (isEntering && specularProbability > hash1(seed)) {
					ray.origin = hitPoint;
					ray.direction = reflect(ray.direction, normal);
					continue;
				}
				
				// This will produce the wrong result if transitioning from medium to medium, e.g. water to lava, but I don't know if that's possible
				isInMedium = !isInMedium;

				float3 refracted = refract(ray.direction,
										   isEntering ? normal : -normal,
										   isEntering ? 1.0/hit.material.refractiveIndex : hit.material.refractiveIndex);
				float3 direction = length(refracted) < 0.5 ? reflect(ray.direction, normal) : refracted;

				ray.origin = hitPoint;
				ray.direction = direction;
				b--; // Spend an extra bounce to get refracted light

				continue;
			}
			
			if (specularProbability > hash1(seed)) {
				ray.origin = hitPoint;
				ray.direction = reflect(ray.direction, normal);
				fcol *= clamp(dot(ray.direction, hit.surfaceNormal), 0.0, 1.0);
				continue;
			}
			
			float2 uv;

			bool couldHitSun = false;
			float3 towardSun;
			if (b == 0 && uniforms.sky.hasSun) {
				// Directly sample a light source - choose randomly between sun and weapon flare
				uv = hash2(seed);
				towardSun = sampleCone(uv, uniforms.sky.sunPosition, uniforms.sky.sunRadius);
				couldHitSun = dot(normal, towardSun) > 0;
			}

			float playerLight = getPlayerLightIntensity(uniforms, rayTracer, hitPoint);
			bool hasPlayerLight = playerLight > 0;
			
			bool sampleSun = false;
			bool samplePlayerLight = false;
			if (couldHitSun && !hasPlayerLight) {
				sampleSun = true;
			} else if (!couldHitSun && hasPlayerLight) {
				samplePlayerLight = true;
			} else if (couldHitSun && hasPlayerLight) {
				sampleSun = hash1(seed) <= 0.5;
				samplePlayerLight = !sampleSun;
			}

			if (sampleSun) {
				struct ray directRay;
				directRay.origin = hitPoint;
				directRay.direction = towardSun;
				directRay.min_distance = rayEpsilon;
				directRay.max_distance = INFINITY;

				Hit directRayHit = castRay(rayTracer, directRay);
				
				if (directRayHit.didHit && directRayHit.material.isLandscape) {
					// Modulate the irradiance by its incident angle on the surface
					float contribution = clamp(dot(normal, towardSun), 0.0, 1.0);
					// Weight by the PDF
					float weight = 2 * M_PI_F * (1.0f - cos(uniforms.sky.sunRadius));
					tcol += fcol * diffuse * uniforms.sky.sunEmission * contribution * weight;
				}
			} else if (samplePlayerLight) {
				float3 hitPointToLight = getPlayerLightPosition(uniforms) - hitPoint;

				struct ray directRay;
				directRay.origin = hitPoint;
				directRay.direction = normalize(hitPointToLight);
				directRay.min_distance = rayEpsilon;
				directRay.max_distance = length(hitPointToLight) - rayEpsilon;

				Hit directRayHit = castRay(rayTracer, directRay);
				
				if (!directRayHit.didHit){
					float angleWeight = clamp(dot(normal, directRay.direction), 0.0, 1.0);
					float distanceWeight = clamp(pow(length(hitPointToLight) * 0.001, -2.0), 0.0, 1.0);
					tcol += fcol * diffuse * playerLight * angleWeight * distanceWeight;
				}
			}
			
			{
				ray.origin = hitPoint;
				ray.direction = sampleUnitHemisphereCosineWeighted(hash2(seed), normal);
				fcol *= clamp(dot(ray.direction, hit.surfaceNormal), 0.0, 1.0);
				fcol *= diffuse;
			}
		}
	}

	return tcol;
}

kernel void rayTracingKernel(texture2d<float, access::write> outImage [[ texture(RayTracingKernelOutImageIndex) ]],
							 instance_acceleration_structure accelerationStructure [[ buffer(RayTracingKernelAccelerationStructureIndex) ]],
							 constant Uniforms &uniforms [[ buffer(RayTracingKernelUniformsIndex) ]],
							 constant RayTracingData *perInstanceData [[ buffer(RayTracingKernelPerInstanceDataIndex) ]],
							 constant TextureArgs &textures [[ buffer(RayTracingKernelAlbedoTexturesIndex) ]],
							 constant TextureArgs &normalMaps [[ buffer(RayTracingKernelNormalMapsIndex) ]],
							 constant TextureArgs &emissionMaps [[ buffer(RayTracingKernelEmissionMapsIndex) ]],
							 constant LightSource &lightSources [[ buffer(RayTracingKernelLightSourcesIndex) ]],
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
	
	float3 sumColor = float3(0.0);
	
	intersector<triangle_data, instancing> intersector;
	RayTracer rayTracer{
		.intersector = intersector,
		.accelerationStructure = accelerationStructure,
		.perInstanceData = perInstanceData,
		.textures = &textures,
		.normalMaps = &normalMaps,
		.emissionMaps = &emissionMaps,
		.lightSources = &lightSources,
		.forward = forward.zxy,
	};

	for (uint s = 0; s < samplesPerPixel; s++) {
		// FIXME: apply the same jitter to every pixel in the current frame
		float2 xyPerturbed = xy + deltaXY * hash2(seed);

		// Screen position in [-1, 1], with positive Y = up
		float2 uv = xyPerturbed * 2.0 - 1.0;
		uv.y = -uv.y;
		
		// Ray direction in world-space
		float3 direction = normalize(uv.x * right.zxy + uv.y * up.zxy + forward.zxy);
		
		sumColor += rayTraceSoft(float3(uniforms.camera.origin), direction, rayTracer, uniforms, seed);
	}
	
	float3 averageColor = sumColor / (float)samplesPerPixel;

	outImage.write(float4(averageColor, 1.0), tid);
}
