//
//  Noise.h
//  AlephOne
//
//  Created by Aanand Prasad on 16/09/2026.
//

#ifndef Noise_h
#define Noise_h

#include <metal_stdlib>
using namespace metal;


// Hash/vector functions by Nimitz and reinder:
// https://www.shadertoy.com/view/Xt3cDn
// https://www.shadertoy.com/view/llVcDz
uint baseHash(uint2 p)
{
	p = 1103515245U*((p >> 1U)^(p.yx));
	uint h32 = 1103515245U*((p.x)^(p.y>>3U));
	return h32^(h32 >> 16);
}
uint randNext(thread float &seed) {
	float s1 = seed += 0.1;
	float s2 = seed += 0.1;
	return baseHash(uint2(as_type<uint>(s1), as_type<uint>(s2)));
}
float hash1(thread float &seed) {
	uint n = randNext(seed);
	return float(n) * 2.3283064365386963e-10f;
}
float2 hash2(thread float &seed) {
	uint n = randNext(seed);
	uint2 rz = uint2(n, n*48271U);
	return float2(rz.xy & uint2(0x7fffffffU))/float(0x7fffffff);
}
float3 hash3(thread float &seed) {
	uint n = randNext(seed);
	uint3 rz = uint3(n, n*16807U, n*48271U);
	return float3(rz & uint3(0x7fffffffU))/float(0x7fffffff);
}

float getRandomSeed(float2 xy, float frameNumber) {
	return float(baseHash(uint2(as_type<uint>(xy.x), as_type<uint>(xy.y)))) / float(0xffffffffU) + (float)frameNumber;
}

#endif
