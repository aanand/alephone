//
//  Common.h
//  AlephOne
//
//  Created by Aanand Prasad on 31/10/2026.
//

#ifndef Common_h
#define Common_h

#import <Foundation/Foundation.h>
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>

#define MAX_TRIANGLES 10000
#define MAX_INSTANCES 2000

NSString* const PLACEHOLDER_TEXTURE_ID = @"PLACEHOLDER";

const MTLPixelFormat DiffuseAlbedoPixelFormat = MTLPixelFormatRGBA16Float;
const MTLPixelFormat SpecularAlbedoPixelFormat = MTLPixelFormatRGBA16Float;
const MTLPixelFormat RoughnessPixelFormat = MTLPixelFormatR32Float;
const MTLPixelFormat DepthPixelFormat = MTLPixelFormatR32Float;
const MTLPixelFormat NormalPixelFormat = MTLPixelFormatRGBA16Float;
const MTLPixelFormat MotionPixelFormat = MTLPixelFormatRG16Float;
const MTLPixelFormat RayTracingPixelFormat = MTLPixelFormatRGBA16Float;

typedef enum {
	NoPostProcessing,
	WaveletDenoise,
	TAA,
	TemporalUpscale,
	TemporalDenoisedUpscale,
} PostProcessingType;

#endif /* Common_h */
