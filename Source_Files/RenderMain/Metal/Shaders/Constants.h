//
//  Constants.h
//  AlephOne
//
//  Created by Aanand Prasad on 16/09/2026.
//

#ifndef Constants_h
#define Constants_h

#include <metal_stdlib>
using namespace metal;


constant float defaultAttenuation = 0.9;
constant bool toneMap = false;

constant float weaponFlareMultiplier = 5.0;

constant uint samplesPerPixel = 2;
constant uint maxBounces = 4;
constant uint maxAlphaPassthroughs = 10;
constant int denoiseRadius = 1;

constant float rayEpsilon = 0.1;

#endif /* Constants_h */
