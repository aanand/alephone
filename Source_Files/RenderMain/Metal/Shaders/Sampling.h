//
//  Sampling.h
//  AlephOne
//
//  Created by Aanand Prasad on 16/09/2026.
//

#ifndef Sampling_h
#define Sampling_h

#include <metal_stdlib>
using namespace metal;


// From https://www.scratchapixel.com/lessons/3d-basic-rendering/introduction-to-lighting//introduction-to-lighting-spherical-light-cone-sampling.html
// Although the orthonormal system they use there seems to glitch here when centerDirection.z is near-zero, so use regular Frisvad method
static void makeCoordinateSystem(float3 n, thread float3 &b1, thread float3 &b2) {
	if (n.z < - 0.9999999f) {
		b1 = float3( 0.0f, -1.0f, 0.0f);
		b2 = float3(-1.0f,  0.0f, 0.0f);
		return;
	}
	float a = 1.0f / (1.0f + n.z);
	float b = -n.x * n.y * a;
	b1 = float3(1.0f - n.x * n.x * a, b, -n.x);
	b2 = float3(b, 1.0f - n.y * n.y * a, -n.y);
}
static float3 sampleConeInCoordinateSystem(float2 uv, float cosThetaMax, float3 x, float3 y, float3 z) {
	float cosTheta = mix(cosThetaMax, 1.0f, uv.x);
	float sinTheta = sqrt(1.0f - cosTheta*cosTheta);
	float phi = 2 * M_PI_F * uv.y;
	return cos(phi) * sinTheta * x + sin(phi) * sinTheta * y + cosTheta * z;
}
static float3 sampleCone(float2 uv, float3 centerDirection, float maxAngle) {
	float cosThetaMax = cos(maxAngle);
	float3 b1, b2;
	makeCoordinateSystem(centerDirection, b1, b2);
	return sampleConeInCoordinateSystem(uv, cosThetaMax, b1, b2, centerDirection);
}

static float2 inUnitDisk(float2 uv) {
	float theta = 2.0 * M_PI_F * uv.x;
	float r = sqrt(uv.y);
	return float2(cos(theta), sin(theta)) * r;
}

static float3 projectOntoUnitHemisphereCosineWeighted(float2 uv) {
	float2 disk = inUnitDisk(uv);
	return float3(disk.x, disk.y, sqrt(max(0.0, 1.0 - dot(disk, disk))));
}

static float3 sampleUnitHemisphereCosineWeighted(float2 uv, float3 normal) {
	float3 z = normal;
	float3 x, y;
	makeCoordinateSystem(z, x, y);
	float3 h = projectOntoUnitHemisphereCosineWeighted(uv);
	return h.x * x + h.y * y + h.z * z;
}

#endif /* Sampling_h */
