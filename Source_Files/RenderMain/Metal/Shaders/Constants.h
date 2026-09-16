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


constant float ambientLightIntensity = 0.1;
constant float gain = 1.0;
constant float defaultAttenuation = 0.9;

constant uint rayBudgetPerPixel = 8;
constant uint maxBounces = 4;
constant int denoiseRadius = 1;

constant float rayEpsilon = 0.1;

#endif /* Constants_h */
