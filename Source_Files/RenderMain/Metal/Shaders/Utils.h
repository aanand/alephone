//
//  Utils.h
//  AlephOne
//
//  Created by Aanand Prasad on 16/09/2026.
//

#ifndef Utils_h
#define Utils_h

#include <metal_stdlib>
using namespace metal;
using namespace raytracing;

#include "ShaderTypes.h"
#include "Constants.h"

struct TextureArgs {
	array<texture2d<float>, MAX_TEXTURES> textures [[id(0)]];
};

inline float radians(float degrees) {
	return degrees * 8.0 * atan(1.0) / 360.0;
}

inline float2 getTriangleUV(float2 coordinates,
							float2 uv0, float2 uv1, float2 uv2)
{
	float3 bary = float3(1.0 - coordinates.x - coordinates.y,
						 coordinates.x,
						 coordinates.y);
	
	return uv0 * bary.x + uv1 * bary.y + uv2 * bary.z;
}

inline float2 getPolygonUV(float2 coordinates,
						   unsigned int primitiveIndex,
						   simd_float2 uv[MAXIMUM_VERTICES_PER_POLYGON])
{
	float2 uv0, uv1, uv2;
	
	uv0 = uv[0];
	uv1 = uv[primitiveIndex+1];
	uv2 = uv[primitiveIndex+2];
	
	return getTriangleUV(coordinates, uv0, uv1, uv2);
}

inline float2 getUV(float2 coordinates,
					unsigned int primitiveIndex,
					unsigned int instanceIndex,
					thread RayTracingData &data)
{
	if (instanceIndex > 0) {
		return getPolygonUV(coordinates, primitiveIndex, data.uv);
	}
	return getTriangleUV(coordinates, data.uv[0], data.uv[1], data.uv[2]);
}

inline float2 getUV(thread intersector<triangle_data, instancing>::result_type &intersection,
					thread RayTracingData &data)
{
	return getUV(intersection.triangle_barycentric_coord,
				 intersection.primitive_id,
				 intersection.user_instance_id,
				 data);
}

inline float3 sampleSky(Sky sky, float3 direction) {
	if (sky.hasSun) {
		float cosThetaToSun = dot(direction, sky.sunPosition);
		if (acos(cosThetaToSun) < sky.sunRadius) {
			return sky.sunEmission;
		}
	}
	
	float cosThetaToTop = dot(direction, float3(0.0, 0.0, 1.0));
	return mix(sky.bottomEmission, sky.topEmission, cosThetaToTop * 0.5 + 0.5);
}

inline float3 getPlayerLightPosition(float3 forward, constant Uniforms &uniforms) {
	return float3(uniforms.camera.origin) + (forward * 128.0) + float3(0.0, 0.0, -64.0);
}

inline float getPlayerLightIntensity(constant Uniforms &uniforms, float3 forward, float3 hitPoint) {
	float weaponFlare = uniforms.weaponFlare * weaponFlareMultiplier;

	float3 lightToHitPoint = hitPoint - getPlayerLightPosition(forward, uniforms);
	float angleFromCenter = acos(dot(normalize(lightToHitPoint), forward));
	float flashlightAngleWeight = 1.0 - clamp(angleFromCenter/flashlightConeRadius, 0.0, 1.0);
	float flashlight = uniforms.flashlight * flashlightAngleWeight;

	return weaponFlare + flashlight;
}

#endif /* Utils_h */
