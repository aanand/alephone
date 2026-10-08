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


float2 getTriangleUV(intersector<triangle_data, instancing>::result_type intersection,
					 float2 uv0, float2 uv1, float2 uv2)
{
	float3 bary = float3(1.0 - intersection.triangle_barycentric_coord.x - intersection.triangle_barycentric_coord.y,
						 intersection.triangle_barycentric_coord.x,
						 intersection.triangle_barycentric_coord.y);
	
	return uv0 * bary.x + uv1 * bary.y + uv2 * bary.z;
}

float2 getQuadUV(intersector<triangle_data, instancing>::result_type intersection,
				 matrix_float4x2 uv)
{
	float2 uv0, uv1, uv2;
	
	if (intersection.primitive_id == 0) {
		uv0 = uv[0];
		uv1 = uv[1];
		uv2 = uv[2];
	} else {
		uv0 = uv[0];
		uv1 = uv[2];
		uv2 = uv[3];
	}
	
	return getTriangleUV(intersection, uv0, uv1, uv2);
}

#define MAX_SPRITE_TEXTURES 1024

struct TextureArgs {
	array<texture2d<float>, MAX_SPRITE_TEXTURES> textures [[id(0)]];
};

struct Hit {
	bool didHit;
	float3 hitPoint;
	float3 normal;
	float3 diffuse;
	Material material;
	int32_t lightSourceIndex;
};

typedef intersector<triangle_data, instancing>::result_type RayTracingResult;

struct RayTracer {
	intersector<triangle_data, instancing> intersector;
	instance_acceleration_structure accelerationStructure;
	constant InstanceRayTracingData *perInstanceData;
	constant TextureArgs *textures;
	constant LightSource *lightSources;
	float3 forward; // Unit vector representing the player's look direction in world-space
};

float3 sampleSky(Sky sky, float3 direction) {
	if (sky.hasSun) {
		float cosThetaToSun = dot(direction, sky.sunPosition);
		if (acos(cosThetaToSun) < sky.sunRadius) {
			return sky.sunEmission;
		}
	}
	
	float cosThetaToTop = dot(direction, float3(0.0, 0.0, 1.0));
	return mix(sky.bottomEmission, sky.topEmission, cosThetaToTop * 0.5 + 0.5);
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

		// Texture-derived values
		float4 texel = float4(defaultAttenuation, defaultAttenuation, defaultAttenuation, 1.0);
		bool instanceHasTexture = false;
		constexpr sampler sam(mag_filter::nearest, min_filter::nearest, address::repeat);

		const device PrimitiveRayTracingData *primitiveData;
		primitiveData = (const device PrimitiveRayTracingData*) intersection.primitive_data;
		float3 normal = primitiveData->surfaceNormal;
		Material material = primitiveData->material;
		int32_t lightSourceIndex = primitiveData->lightSourceIndex;

		uint32_t instanceId = intersection.user_instance_id;
		if (instanceId > 0) {
			InstanceRayTracingData instanceData = rayTracer.perInstanceData[instanceId];
			normal = instanceData.surfaceNormal;
			material = instanceData.material;
			
			if (instanceData.textureIndex > 0) {
				instanceHasTexture = true;
				float2 uv = getQuadUV(intersection, instanceData.uv);
				texture2d<float> texture = rayTracer.textures->textures[instanceData.textureIndex];
				texel = texture.sample(sam, uv);
			}
		}
		
		if (!instanceHasTexture && primitiveData->textureIndex > 0) {
			float2 uv = getTriangleUV(intersection, primitiveData->uv.columns[0], primitiveData->uv.columns[1], primitiveData->uv.columns[2]);
			texture2d<float> texture = rayTracer.textures->textures[primitiveData->textureIndex];
			texel = texture.sample(sam, uv);
		}
		
		if (texel.a < 0.5) {
			// We hit something transparent - continue the ray.
			ray.origin = hitPoint + ray.direction * rayEpsilon;
			ray.max_distance -= (intersection.distance + rayEpsilon);
		} else {
			return {
				.didHit = true,
				.hitPoint = hitPoint,
				.normal = normal,
				.diffuse = texel.rgb,
				.material = material,
				.lightSourceIndex = lightSourceIndex,
			};
		}
	}
	
	return { .didHit = false };
}

float3 rayTraceSoft(float3 origin, float3 direction,
					thread RayTracer &rayTracer,
					Uniforms uniforms,
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
			tcol += fcol * sampleSky(uniforms.sky, ray.direction);
			break;
		} else {
			float3 hitPoint = hit.hitPoint;
			float3 normal = hit.normal;
			
			// If we're not doing full path tracing, the initial ray shouldn't pick up the albedo of the surface it hits,
			// because that will be applied in the final pass
			float3 diffuse = (uniforms.fullPathTracing || b > 0) ? hit.diffuse : float3(1.0);

			if (length(hit.material.emission) > 0) {
				if (b == 0) {
					tcol += diffuse;
				} else {
					float3 emission = hit.material.emission;
					
					if (hit.lightSourceIndex >= 0) {
						float intensity = rayTracer.lightSources[hit.lightSourceIndex].intensity;
						emission *= intensity;
					}
					
					if (length(emission) > 0) {
						// We hit a light source
						tcol += fcol * emission;
					}
				}
			}
			
			// Apply absorption if we just traversed a medium
			if (isInMedium) {
				float dist = distance(ray.origin, hitPoint);
				fcol *= exp(-float3(0.5, 0.3, 0.1) * dist * 0.001);
			}

			// If the material we just hit is a medium, decide whether to enter it
			if (hit.material.transparency > hash1(seed)) {
				// This will produce the wrong result if transitioning from medium to medium, e.g. water to lava, but I don't know if that's possible
				isInMedium = !isInMedium;

				bool isEntering = dot(ray.direction, normal) < 0.0;
				float3 refracted = refract(ray.direction,
										   isEntering ? normal : -normal,
										   isEntering ? 1.0/hit.material.refractiveIndex : hit.material.refractiveIndex);
				float3 direction = length(refracted) < 0.5 ? reflect(ray.direction, normal) : refracted;

				ray.origin = hitPoint;
				ray.direction = direction;

				continue;
			}
			
			if (hit.material.reflectivity > hash1(seed)) {
				ray.origin = hitPoint;
				ray.direction = reflect(ray.direction, normal);
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

			float weaponFlare = uniforms.weaponFlare * weaponFlareMultiplier;
			bool hasWeaponFlare = weaponFlare > 0;
			
			bool sampleSun = false;
			bool sampleWeaponFlare = false;
			if (couldHitSun && !hasWeaponFlare) {
				sampleSun = true;
			} else if (!couldHitSun && hasWeaponFlare) {
				sampleWeaponFlare = true;
			} else if (couldHitSun && hasWeaponFlare) {
				sampleSun = hash1(seed) <= 0.5;
				sampleWeaponFlare = !sampleSun;
			}

			if (sampleSun) {
				struct ray directRay;
				directRay.origin = hitPoint;
				directRay.direction = towardSun;
				directRay.min_distance = rayEpsilon;
				directRay.max_distance = INFINITY;

				Hit directRayHit = castRay(rayTracer, directRay);
				
				if (!directRayHit.didHit) {
					// Modulate the irradiance by its incident angle on the surface
					float contribution = clamp(dot(normal, towardSun), 0.0, 1.0);
					// Weight by the PDF
					float weight = 2 * M_PI_F * (1.0f - cos(uniforms.sky.sunRadius));
					tcol += fcol * diffuse * uniforms.sky.sunEmission * contribution * weight;
				}
			} else if (sampleWeaponFlare) {
				int3 weaponFlarePosition = uniforms.camera.origin + int3(0, 0, -256);
				float3 surfaceToWeapon = float3(weaponFlarePosition) - hitPoint;
				struct ray directRay;
				directRay.origin = hitPoint;
				directRay.direction = normalize(surfaceToWeapon);
				directRay.min_distance = rayEpsilon;
				directRay.max_distance = length(surfaceToWeapon) - rayEpsilon;

				Hit directRayHit = castRay(rayTracer, directRay);
				
				if (!directRayHit.didHit){
					float angleWeight = clamp(dot(normal, directRay.direction), 0.0, 1.0);
					float distanceWeight = clamp(pow(length(surfaceToWeapon) * 0.001, -2.0), 0.0, 1.0);
					tcol += fcol * diffuse * weaponFlare * angleWeight * distanceWeight;
				}
			}

			if (uniforms.flashlight > 0.0 && b == 0) {
				float angleWeight = clamp(dot(normal, -ray.direction), 0.0, 1.0);
				float distanceWeight = clamp(pow(distance(float3(uniforms.camera.origin), hitPoint) * 0.001, -2.0), 0.0, 1.0);
				float theta = acos(dot(ray.direction, rayTracer.forward));
				float coneWeight = 1.0 - clamp(theta/(M_PI_F/6.0), 0.0, 1.0);
				tcol += fcol * diffuse * uniforms.flashlight * angleWeight * distanceWeight * coneWeight;
			}
			
			{
				ray.origin = hitPoint;
				ray.direction = sampleUnitHemisphereCosineWeighted(hash2(seed), normal);
				fcol *= diffuse;
			}
		}
	}

	return tcol;
}

kernel void rayTracingKernel(texture2d<float, access::write> outImage [[ texture(RayTracingKernelOutImageIndex) ]],
							 instance_acceleration_structure accelerationStructure [[ buffer(RayTracingKernelAccelerationStructureIndex) ]],
							 constant Uniforms &uniforms [[ buffer(RayTracingKernelUniformsIndex) ]],
							 constant InstanceRayTracingData *perInstanceData [[ buffer(RayTracingKernelPerInstanceDataIndex) ]],
							 constant TextureArgs &textures [[ buffer(RayTracingKernelTexturesIndex) ]],
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
		.lightSources = &lightSources,
		.forward = forward.zxy,
	};

	for (uint s = 0; s < samplesPerPixel; s++) {
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
