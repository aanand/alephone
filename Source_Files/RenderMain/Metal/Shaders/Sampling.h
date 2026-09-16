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

#include "Noise.h"


float3 randomInUnitSphere(thread float &seed) {
	float3 h = hash3(seed) * float3(2.,6.28318530718,1.)-float3(1,0,0);
	float phi = h.y;
	float r = pow(h.z, 1./3.);
	return r * float3(sqrt(1.-h.x*h.x)*float2(sin(phi),cos(phi)),h.x);
}

// From https://www.scratchapixel.com/lessons/3d-basic-rendering/introduction-to-lighting//introduction-to-lighting-spherical-light-cone-sampling.html
// Although the orthonormal system they use there seems to glitch here when centerDirection.z is near-zero, so use regular Frisvad method
void coordinateSystem(float3 n, thread float3 &b1, thread float3 &b2) {
	if (n.z < - 0.9999999f) {
		b1 = float3( 0.0f, -1.0f, 0.0f);
		b2 = float3(-1.0f,  0.0f, 0.0f);
		return;
	}
	float a = 1.0f / (1.0f + n.z);
	float b = -n.x * n.y * a;
	b1 = float3(1.0f + n.x * n.x * a, b, -n.x);
	b2 = float3(b, 1.0f - n.y * n.y * a, -n.y);
}
float3 uniformSampleCone(float r1, float r2, float cosThetaMax, float3 x, float3 y, float3 z) {
	float cosTheta = mix(cosThetaMax, 1.0f, r1);
	float sinTheta = sqrt(1.0f - cosTheta*cosTheta);
	float phi = M_2_PI_F * r2;
	return cos(phi) * sinTheta * x + sin(phi) * sinTheta * y + cosTheta * z;
}
float3 randomDirectionInCone(float r1, float r2, float3 centerDirection, float maxAngle) {
	float cosThetaMax = cos(maxAngle);
	float3 b1, b2;
	coordinateSystem(centerDirection, b1, b2);
	return uniformSampleCone(r1, r2, cosThetaMax, b1, b2, centerDirection);
}

#endif /* Sampling_h */
