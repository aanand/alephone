//
//  MetalRenderer.m
//  libalephone
//
//  Created by Aanand Prasad on 28/08/2026.
//

#import <Foundation/Foundation.h>

#include <SDL2/SDL.h>
#include <SDL2/SDL_syswm.h>

#include <Cocoa/Cocoa.h>
#include <MetalKit/MetalKit.h>
#include <MetalFX/MetalFX.h>
#include <dispatch/dispatch.h>

#include "MetalRenderer.h"
#include "Shaders/ShaderTypes.h"
#include "MetalPipeline.h"

#include "GeometryManager.h"
#include "TextureManager.h"
#include "InitialRender.h"
#include "RayTracer.h"
#include "PostProcessor.h"
#include "FinalRender.h"

#include "MetalTypes.h"
#include "Utils.h"
#include "Common.h"

const bool FULL_PATH_TRACING = true;
const PostProcessingType POST_PROCESSING_TYPE = NoPostProcessing;

API_AVAILABLE(macos(26.0))
@implementation MetalRenderer
{
	// External dependencies

	SDL_Window *window;
	SDL_Renderer *renderer;
	CAMetalLayer *metalLayer;

	Sky sky;
	Camera camera;
	
	// Metal pipeline internals
	
	MetalPipeline *pipeline;

	GeometryManager *geometryManager;
	TextureManager *textureManager;

	InitialRender *initialRender;
	RayTracer *rayTracer;
	PostProcessor *postProcessor;
	FinalRender *finalRender;
	
	id<MTLDepthStencilState> depthState;

	id<MTLFence> initialPassFence;
	id<MTLFence> computePassFence;
	id<MTLFence> postProcessingPassFence;
	
	// Constants shared across all pipelines
	id<MTLBuffer> uniformsBuffer;
}

- (MetalRenderer *) initializeWithWindow:(SDL_Window *)sdlWindow width:(int)width height:(int)height {
	window = sdlWindow;
	renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_PRESENTVSYNC);
	
	_view = [[View alloc] init];
	_view.viewportSize = simd_make_uint2(width, height);
	_view.frameNumber = 0;
	
	metalLayer = (__bridge CAMetalLayer*)SDL_RenderGetMetalLayer(renderer);

	pipeline = [[MetalPipeline alloc] init];
	pipeline.device = metalLayer.device;
	pipeline.commandQueue = [pipeline.device newMTL4CommandQueue];
	pipeline.commandBuffer = [pipeline.device newCommandBuffer];
	pipeline.defaultLibrary = [pipeline.device newDefaultLibrary];
	pipeline.commandAllocator = [pipeline.device newCommandAllocator];
	pipeline.sharedEvent = [pipeline.device newSharedEvent];
	[pipeline.commandQueue addResidencySet:metalLayer.residencySet];

	uniformsBuffer = [pipeline.device newBufferWithLength:sizeof(Uniforms) options:MTLResourceStorageModeShared];
	uniformsBuffer.label = @"Uniforms";

	depthState = [self configureDepth];
	
	textureManager = [[TextureManager alloc] init];
	textureManager.pipeline = pipeline;
	
	geometryManager = [[GeometryManager alloc] initWithPipeline:pipeline];
	geometryManager.view = _view;
	geometryManager.textureManager = textureManager;

	if (![geometryManager compile]) {
		return nil;
	}
	[pipeline.commandQueue addResidencySet:geometryManager.residencySet];

	initialRender = [[InitialRender alloc] initWithPipeline:pipeline];
	initialRender.view = _view;
	initialRender.postProcessingType = POST_PROCESSING_TYPE;
	initialRender.uniformsBuffer = uniformsBuffer;
	initialRender.depthState = depthState;
	initialRender.geometryManager = geometryManager;
	initialRender.textureManager = textureManager;

	if (![initialRender compile]) {
		return nil;
	}
	[pipeline.commandQueue addResidencySet:initialRender.residencySet];

	rayTracer = [[RayTracer alloc] init];
	rayTracer.pipeline = pipeline;
	rayTracer.view = _view;
	rayTracer.textureManager = textureManager;
	rayTracer.geometryManager = geometryManager;
	rayTracer.uniformsBuffer = uniformsBuffer;
	rayTracer.depthTexture = initialRender.depthTexture;
	rayTracer.motionTexture = initialRender.motionTexture;
	
	if (![rayTracer compile]) {
		return nil;
	}
	[pipeline.commandQueue addResidencySet:rayTracer.residencySet];

	postProcessor = [[PostProcessor alloc] init];
	postProcessor.pipeline = pipeline;
	postProcessor.view = _view;
	postProcessor.initialRender = initialRender;
	postProcessor.rayTracingOutputTexture = rayTracer.outputTexture;
	postProcessor.uniformsBuffer = uniformsBuffer;
	
	if (![postProcessor compile]) {
		return nil;
	}
	[pipeline.commandQueue addResidencySet:postProcessor.residencySet];
	
	finalRender = [[FinalRender alloc] init];
	finalRender.pipeline = pipeline;
	finalRender.view = _view;
	finalRender.postProcessingType = POST_PROCESSING_TYPE;
	finalRender.diffuseAlbedoTexture = initialRender.diffuseAlbedoTexture;
	finalRender.rayTracingOutputTexture = rayTracer.outputTexture;
	finalRender.postProcessingScratchTexture = postProcessor.scratchTexture;
	finalRender.postProcessingOutputTexture = postProcessor.outputTexture;
	finalRender.uniformsBuffer = uniformsBuffer;
	
	if (![finalRender compileForPixelFormat:metalLayer.pixelFormat]) {
		return nil;
	}
	[pipeline.commandQueue addResidencySet:finalRender.residencySet];
	
	initialPassFence = [pipeline.device newFence];
	computePassFence = [pipeline.device newFence];
	postProcessingPassFence = [pipeline.device newFence];
	
	return self;
}

- (id<MTLDepthStencilState>) configureDepth {
	MTLDepthStencilDescriptor *depthDescriptor = [MTLDepthStencilDescriptor new];
	depthDescriptor.depthCompareFunction = MTLCompareFunctionLessEqual;
	depthDescriptor.depthWriteEnabled = YES;
	return [pipeline.device newDepthStencilStateWithDescriptor:depthDescriptor];
}

- (void) shutdown {
	[pipeline.commandQueue removeResidencySet:initialRender.residencySet];
	[initialRender shutdown];
	initialRender = nil;

	[pipeline.commandQueue removeResidencySet:rayTracer.residencySet];
	[rayTracer shutdown];
	rayTracer = nil;
	
	[pipeline.commandQueue removeResidencySet:finalRender.residencySet];
	[finalRender shutdown];
	finalRender = nil;

	[geometryManager shutdown];
	[textureManager shutdown];

	pipeline = nil;
	
	metalLayer = nil;
	
	if (renderer) {
		SDL_DestroyRenderer(renderer);
		renderer = nil;
	}
	
	window = nil;
}

- (void) updateSky:(Sky)newSky {
	sky = newSky;
}

- (void)addStaticPolygon:(MetalPolygon *)polygon {
	[geometryManager addStaticPolygon:polygon];
}

- (void)addStaticWall:(MetalWall *)wall {
	[geometryManager addStaticWall:wall];
}

-(void)addDynamicPolygon:(MetalPolygon *)polygon withID:(int)ID enabled:(BOOL)isEnabled {
	[geometryManager addDynamicPolygon:polygon withID:ID enabled:isEnabled];
}

-(void)addDynamicWall:(MetalWall *)wall enabled:(BOOL)isEnabled {
	[geometryManager addDynamicWall:wall enabled:isEnabled];
}

- (void) updateSprite:(MetalSprite *)sprite {
	[geometryManager updateSprite:sprite yawRadians:radians(_view.yaw)];
}

-(void)updateLightSourceIntensities:(NSArray<NSNumber *> *)intensities {
	[rayTracer updateLightSourceIntensities:intensities];
}

- (void) startUpdatingAllGeometry {
	[rayTracer clearGeometryAllocations];

	[geometryManager startUpdatingAllGeometry];

	[textureManager startUpdatingAllGeometry];
	[textureManager addPlaceholderTextureWithID:PLACEHOLDER_TEXTURE_ID];

	[rayTracer clearLightSources];
}

- (void) finishUpdatingAllGeometry {
	[geometryManager finishUpdatingAllGeometry];
	[textureManager finishUpdatingAllGeometry];

	[rayTracer writeLightSources];
	[rayTracer addGeometryAllocations];
}

- (void) startUpdatingDynamicGeometry {
	[rayTracer clearGeometryAllocations];

	[geometryManager startUpdatingDynamicGeometry];
	[textureManager startUpdatingDynamicGeometry];

	[rayTracer clearLightSources];
}

- (void) finishUpdatingDynamicGeometry {
	[geometryManager finishUpdatingDynamicGeometry];
	[textureManager finishUpdatingDynamicGeometry];

	[rayTracer writeLightSources];
	[rayTracer addGeometryAllocations];
}

- (bool) hasTextureWithID:(NSString*)textureID {
	return [textureManager hasTextureWithID:textureID];
}

-(void)addTextureWithID:(NSString *)textureID albedo:(MetalImage *)albedo normal:(MetalImage *)normal emission:(MetalImage *)emission {
	[textureManager addTextureWithID:textureID albedo:albedo normal:normal emission:emission];
}

- (void) addPlaceholderTextureWithID:(NSString *)textureID {
	[textureManager addPlaceholderTextureWithID:textureID];
}

- (void) begin {
	_view.frameNumber += 1;

	if (POST_PROCESSING_TYPE == TemporalUpscale || POST_PROCESSING_TYPE == TemporalDenoisedUpscale) {
		_view.jitter = simd_make_float2(drand48(), drand48()) - 0.5;
	} else {
		_view.jitter = simd_make_float2(0.0, 0.0);
	}
}

- (void) end {
	// Rotate sun and ensure position is a unit vector
	Sky adjustedSky = sky;
	simd_quatf sunRotation = simd_quaternion(fmod(_view.frameNumber * sky.sunRotationSpeed, 2*M_PI), sky.sunRotationAxis);
	adjustedSky.sunPosition = simd_normalize(simd_mul(simd_matrix4x4(sunRotation), simd_make_float4(sky.sunPosition, 1.0)).xyz);

	Camera previousCamera = camera;
	camera = _view.camera;
	
	Uniforms uniforms;
	uniforms.fullPathTracing = FULL_PATH_TRACING;
	uniforms.resolution = _view.viewportSize;
	uniforms.frameNumber = _view.frameNumber;
	uniforms.camera = camera;
	uniforms.previousCamera = (_view.frameNumber > 1) ? previousCamera : camera;
	uniforms.sky = adjustedSky;
	uniforms.weaponFlare = _view.weaponFlare;
	uniforms.flashlight = _view.flashlight;
	uniforms.isInMedium = _view.isInMedium;
	memcpy(uniformsBuffer.contents, &uniforms, sizeof(Uniforms));
		
	id<CAMetalDrawable> currentDrawable = [metalLayer nextDrawable];

	id<MTL4CommandBuffer> commandBuffer = pipeline.commandBuffer;
	[commandBuffer beginCommandBufferWithAllocator:pipeline.commandAllocator];
	commandBuffer.label = [NSString stringWithFormat:@"Frame %llu (initial + raytracing)", _view.frameNumber];
	[initialRender encodeAndUpdateFence:initialPassFence];
	[rayTracer encodeAndUpdateFence:computePassFence];
	[commandBuffer endCommandBuffer];
	
	// Block until rendering has completed. This is inefficient, but Marathon is locked to 30fps,
	// so it probably doesn't slow us down and it simplifies things to not have to worry about concurrent
	// reads/writes to buffers and textures
	uint64_t renderSignalValue = pipeline.sharedEvent.signaledValue + 1;
	
	[pipeline.commandQueue commit:&commandBuffer count:1];
	[pipeline.commandQueue signalEvent:pipeline.sharedEvent value:renderSignalValue];
	[pipeline.sharedEvent waitUntilSignaledValue:renderSignalValue timeoutMS:5000];
	[pipeline.commandAllocator reset];
	
	if (POST_PROCESSING_TYPE == TemporalUpscale) {
		[postProcessor encodeTemporalUpscaleUpdatingFence:postProcessingPassFence];
	}

	if (POST_PROCESSING_TYPE == TemporalDenoisedUpscale) {
		[postProcessor encodeTemporalDenoisedUpscaleUpdatingFence:postProcessingPassFence];
	}
	
	[commandBuffer beginCommandBufferWithAllocator:pipeline.commandAllocator];
	commandBuffer.label = [NSString stringWithFormat:@"Frame %llu (final pass)", _view.frameNumber];

	if (POST_PROCESSING_TYPE == WaveletDenoise) {
		[postProcessor encodeWaveletDenoiseUpdatingFence:postProcessingPassFence];
	}
	
	if (POST_PROCESSING_TYPE == TAA) {
		[postProcessor encodeTAAUpdatingFence:postProcessingPassFence];
	}

	[finalRender encodeToOutputTexture:currentDrawable.texture afterFences:@[postProcessingPassFence]];
	[commandBuffer endCommandBuffer];

	renderSignalValue = pipeline.sharedEvent.signaledValue + 1;
	[pipeline.commandQueue waitForDrawable:currentDrawable];
	[pipeline.commandQueue commit:&commandBuffer count:1];
	[pipeline.commandQueue signalDrawable:currentDrawable];
	[currentDrawable present];
	[pipeline.commandQueue signalEvent:pipeline.sharedEvent value:renderSignalValue];
	[pipeline.sharedEvent waitUntilSignaledValue:renderSignalValue timeoutMS:5000];
	[pipeline.commandAllocator reset];
}

@end
