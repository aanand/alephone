//
//  Utils.h
//  AlephOne
//
//  Created by Aanand Prasad on 16/09/2026.
//

#ifndef Utils_h
#define Utils_h

static float radians(float degrees) {
	return degrees * 8.0 * atan(1.0) / 360.0;
}

static float2 getTriangleUV(intersector<triangle_data, instancing>::result_type intersection,
							float2 uv0, float2 uv1, float2 uv2)
{
	float3 bary = float3(1.0 - intersection.triangle_barycentric_coord.x - intersection.triangle_barycentric_coord.y,
						 intersection.triangle_barycentric_coord.x,
						 intersection.triangle_barycentric_coord.y);
	
	return uv0 * bary.x + uv1 * bary.y + uv2 * bary.z;
}

static float2 getPolygonUV(intersector<triangle_data, instancing>::result_type intersection,
						   simd_float2 uv[MAXIMUM_VERTICES_PER_POLYGON])
{
	float2 uv0, uv1, uv2;
	
	uv0 = uv[0];
	uv1 = uv[intersection.primitive_id+1];
	uv2 = uv[intersection.primitive_id+2];
	
	return getTriangleUV(intersection, uv0, uv1, uv2);
}

static float3 sampleSky(Sky sky, float3 direction) {
	if (sky.hasSun) {
		float cosThetaToSun = dot(direction, sky.sunPosition);
		if (acos(cosThetaToSun) < sky.sunRadius) {
			return sky.sunEmission;
		}
	}
	
	float cosThetaToTop = dot(direction, float3(0.0, 0.0, 1.0));
	return mix(sky.bottomEmission, sky.topEmission, cosThetaToTop * 0.5 + 0.5);
}

#endif /* Utils_h */
