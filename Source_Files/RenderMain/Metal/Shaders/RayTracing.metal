//
//  RayTracing.metal
//  AlephOne
//
//  Created by Aanand Prasad on 16/09/2026.
//

#include <metal_stdlib>
using namespace metal;
using namespace raytracing;

#include "../VertexTypes.h"
#include "Constants.h"
#include "Noise.h"
#include "Sampling.h"
#include "Utils.h"


float2 getQuadUV(intersector<triangle_data, instancing>::result_type intersection,
				 InstanceRayTracingData instanceData)
{
	float3 bary = float3(1.0 - intersection.triangle_barycentric_coord.x - intersection.triangle_barycentric_coord.y,
						 intersection.triangle_barycentric_coord.x,
						 intersection.triangle_barycentric_coord.y);
	
	float2 uv0, uv1, uv2;
	
	if (intersection.primitive_id == 0) {
		uv0 = instanceData.uv[0];
		uv1 = instanceData.uv[1];
		uv2 = instanceData.uv[2];
	} else {
		uv0 = instanceData.uv[0];
		uv1 = instanceData.uv[2];
		uv2 = instanceData.uv[3];
	}
	
	return uv0 * bary.x + uv1 * bary.y + uv2 * bary.z;
}

#define MAX_SPRITE_TEXTURES 1024

struct SpriteTextureArgs {
	array<texture2d<float>, MAX_SPRITE_TEXTURES> textures [[id(0)]];
};

struct Hit {
	bool didHit;
	float3 hitPoint;
	float3 normal;
	float3 emission;
	int32_t lightSourceIndex;
};

typedef intersector<triangle_data, instancing>::result_type RayTracingResult;

struct RayTracer {
	intersector<triangle_data, instancing> intersector;
	instance_acceleration_structure accelerationStructure;
	constant InstanceRayTracingData *perInstanceData;
	constant SpriteTextureArgs *spriteTextures;
	constant LightSource *lightSources;
	uint rayBudget;
};

// Cast a ray, continuing in the case of hitting a transparent surface. Populates `hit` with the result.
// Returns false if the ray budget was exhausted, in which case `hit` should not be read.
bool castRay(thread RayTracer &rayTracer, ray ray, thread Hit &hit)
{
	if (rayTracer.rayBudget <= 0) {
		return false;
	}
	rayTracer.rayBudget -= 1;

	RayTracingResult intersection = rayTracer.intersector.intersect(ray, rayTracer.accelerationStructure);

	if (intersection.type == intersection_type::none) {
		hit.didHit = false;
		return true;
	}
	
	float3 hitPoint = ray.origin + (ray.direction * intersection.distance);

	const device PrimitiveRayTracingData *primitiveData;
	primitiveData = (const device PrimitiveRayTracingData*) intersection.primitive_data;
	float3 normal = primitiveData->surfaceNormal;
	float3 emission = primitiveData->emission;
	int32_t lightSourceIndex = primitiveData->lightSourceIndex;
	float alpha = 1.0;
	
	uint32_t instanceId = intersection.user_instance_id;
	if (instanceId > 0) {
		InstanceRayTracingData instanceData = rayTracer.perInstanceData[instanceId];
		normal = instanceData.surfaceNormal;
		emission = instanceData.emission;
		
		if (instanceData.textureIndex > 0) {
			float2 uv = getQuadUV(intersection, instanceData);
			texture2d<float> spriteTexture = rayTracer.spriteTextures->textures[instanceData.textureIndex];
			constexpr sampler spriteSampler(mag_filter::nearest, min_filter::nearest, address::clamp_to_edge);
			alpha = spriteTexture.sample(spriteSampler, uv).a;
		}
	}
	
	// We hit something transparent - continue the ray.
	// Artificially inflate the ray budget, because otherwise transparent materials will be biased.
	if (alpha < 0.5) {
		rayTracer.rayBudget += 1;

		ray.origin = hitPoint + ray.direction * rayEpsilon;
		ray.max_distance -= (intersection.distance + rayEpsilon);
		return castRay(rayTracer, ray, hit);
	}
	
	hit.didHit = true;
	hit.hitPoint = hitPoint;
	hit.normal = normal;
	hit.emission = emission;
	hit.lightSourceIndex = lightSourceIndex;
	
	return true;
}

// Casts a ray and bounces it until the ray budget is exhausted. Populates `color`.
// If we couldn't afford a single raycast, returns `false`, in which case `color` should not be read.
bool rayTraceSoft(float3 origin, float3 direction,
					thread RayTracer &rayTracer,
					Uniforms uniforms,
					thread float &seed,
					thread float3 &color)
{
	ray ray;
	ray.origin = origin;
	ray.direction = direction;
	ray.min_distance = rayEpsilon;
	ray.max_distance = INFINITY;

	float3 tcol = float3(0.0);
	float fcol = 1.0;
	uint b;
	
	for (b = 0; b < maxBounces; b++) {
		Hit hit;
		if (!castRay(rayTracer, ray, hit)) break;

		if (!hit.didHit) {
			float cosTheta = dot(ray.direction, -uniforms.sunDirection);
			if (acos(cosTheta) < uniforms.sunRadius) {
				tcol += fcol * uniforms.sunIntensity;
			}

			break;
		} else {
			float3 hitPoint = hit.hitPoint;
			float3 normal = hit.normal;
			float3 emission = hit.emission;
			
			if (hit.lightSourceIndex >= 0) {
				float intensity = rayTracer.lightSources[hit.lightSourceIndex].intensity;
				emission *= intensity;
			}

			if (length(emission) > 0) {
				// We hit a light source
				if (b == 0) {
					// Desaturate the light value if we haven't bounced yet, so the texture doesn't appear tinted
					float3 e = emission;
					tcol += float3(e.r + e.g + e.b) / 3.0;
				} else {
					tcol += emission;
				}
			}

			// Directly sample a light source - choose randomly between sun and weapon flare
			float2 random = hash2(seed);
			float3 towardSun = randomDirectionInCone(random.x, random.y, -uniforms.sunDirection, uniforms.sunRadius);
			bool couldHitSun = dot(normal, towardSun) > 0;

			float weaponFlare = uniforms.weaponFlare;
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

				// *Did* our ray hit the sun?
				Hit directRayHit;
				if (!castRay(rayTracer, directRay, directRayHit)) break;
				
				if (!directRayHit.didHit) {
					// Modulate the irradiance by its incident angle on the surface
					float contribution = clamp(dot(normal, towardSun), 0.0, 1.0);
					// Weight by the PDF
					float weight = 2 * M_PI_F * (1.0f - cos(uniforms.sunRadius));
					tcol += fcol * uniforms.sunIntensity * contribution * weight;
				}
			} else if (sampleWeaponFlare) {
				int3 weaponFlarePosition = uniforms.origin + int3(0, 0, -256);
				float3 surfaceToWeapon = float3(weaponFlarePosition) - hitPoint;
				struct ray directRay;
				directRay.origin = hitPoint;
				directRay.direction = normalize(surfaceToWeapon);
				directRay.min_distance = rayEpsilon;
				directRay.max_distance = length(surfaceToWeapon) - rayEpsilon;

				Hit directRayHit;
				if (!castRay(rayTracer, directRay, directRayHit)) break;
				
				if (!directRayHit.didHit){
					float contribution = clamp(dot(normal, directRay.direction), 0.0, 1.0);
					tcol += fcol * weaponFlare * contribution;
				}
			}

			// Bounce
			ray.origin = hitPoint;
			ray.direction = randomDirectionOnUnitHemisphereCosineWeighted(normal, seed);
			
			fcol *= defaultAttenuation;
		}
	}
	
	// We didn't manage a single sample before exhausting the ray budget
	if (b == 0) return false;

	color = float3(tcol);
	return true;
}

kernel void rayTracingKernel(texture2d<float, access::write> outImage [[ texture(RayTracingKernelOutImageIndex) ]],
							 instance_acceleration_structure accelerationStructure [[ buffer(RayTracingKernelAccelerationStructureIndex) ]],
							 constant Uniforms &uniforms [[ buffer(RayTracingKernelUniformsIndex) ]],
							 constant InstanceRayTracingData *perInstanceData [[ buffer(RayTracingKernelPerInstanceDataIndex) ]],
							 constant SpriteTextureArgs &spriteTextures [[ buffer(RayTracingKernelSpriteTexturesIndex) ]],
							 constant LightSource &lightSources [[ buffer(RayTracingKernelLightSourcesIndex) ]],
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
	
	intersector<triangle_data, instancing> intersector;
	RayTracer rayTracer{
		.intersector = intersector,
		.accelerationStructure = accelerationStructure,
		.perInstanceData = perInstanceData,
		.spriteTextures = &spriteTextures,
		.lightSources = &lightSources,
		.rayBudget = rayBudgetPerPixel,
	};

	uint numSamples = 0;
	while (rayTracer.rayBudget > 0) {
		float2 xyPerturbed = xy + deltaXY * hash2(seed);

		// Screen position in [-1, 1], with positive Y = up
		float2 uv = xyPerturbed * 2.0 - 1.0;
		uv.y = -uv.y;
		
		// Ray direction in world-space
		float3 direction = normalize(uv.x * right.zxy + uv.y * up.zxy + forward.zxy);
		
		float3 sampleColor;
		if (rayTraceSoft(float3(uniforms.origin), direction, rayTracer, uniforms, seed, sampleColor)) {
			sumColor += sampleColor;
			numSamples += 1;
		} else {
			break;
		}
	}
	
	float3 averageColor = sumColor / (float)numSamples;
	float3 adjusted = mix(float3(ambientLightIntensity), float3(1.0), averageColor);

	outImage.write(float4(adjusted, 1.0), tid);
}
