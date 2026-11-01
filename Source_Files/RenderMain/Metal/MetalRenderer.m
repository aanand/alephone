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
	
	id<MTLRenderPipelineState> finalRenderPipeline;
	id<MTLDepthStencilState> depthState;

	id<MTL4ArgumentTable> fragmentArgumentTable;

	id<MTLResidencySet> finalRenderResidencySet;
	
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

	[self setupBuffers];
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
	
	if (![self setupResidencySets]) {
		return nil;
	}
	[self addBuffersToResidencySets];
	
	[self setupIntermediateTextures];
	
	finalRenderPipeline = [self compileFinalRenderPipeline:metalLayer.pixelFormat];
	if (!finalRenderPipeline) {
		return nil;
	}
	
	if (![self setupArgumentTables]) {
		return nil;
	}

	initialPassFence = [pipeline.device newFence];
	computePassFence = [pipeline.device newFence];
	postProcessingPassFence = [pipeline.device newFence];
	
	[finalRenderResidencySet commit];
	
	return self;
}

- (bool) setupArgumentTables {
	NSError *error;
	
	MTL4ArgumentTableDescriptor *fragmentArgumentTableDescriptor = [MTL4ArgumentTableDescriptor new];
	fragmentArgumentTableDescriptor.maxTextureBindCount = FinalRenderFragmentShader_NumTextures;
	fragmentArgumentTableDescriptor.maxBufferBindCount = FinalRenderFragmentShader_NumBuffers;
	fragmentArgumentTableDescriptor.label = @"Fragment argument table";
	fragmentArgumentTable = [pipeline.device newArgumentTableWithDescriptor:fragmentArgumentTableDescriptor error:&error];
	if (error) {
		NSLog(@"%@", error);
		return false;
	}
	
	return true;
}

- (bool) setupResidencySets {
	NSError *error;

	MTLResidencySetDescriptor *residencySetDescriptor = [MTLResidencySetDescriptor new];
	residencySetDescriptor.label = @"finalRenderResidencySet";
	finalRenderResidencySet = [pipeline.device newResidencySetWithDescriptor:residencySetDescriptor
															  error:&error];
	if (error) {
		NSLog(@"%@", error);
		return false;
	}
	
	[pipeline.commandQueue addResidencySet:finalRenderResidencySet];
	[pipeline.commandQueue addResidencySet:metalLayer.residencySet];

	return true;
}

- (void) setupBuffers {
	uniformsBuffer = [pipeline.device newBufferWithLength:sizeof(Uniforms) options:MTLResourceStorageModeShared];
	uniformsBuffer.label = @"Uniforms";
}

- (void) addBuffersToResidencySets {
	[finalRenderResidencySet addAllocation:uniformsBuffer];
}

- (void) setupIntermediateTextures {
	[finalRenderResidencySet addAllocation:initialRender.diffuseAlbedoTexture];
	[finalRenderResidencySet addAllocation:rayTracer.outputTexture];
	[finalRenderResidencySet addAllocation:postProcessor.scratchTexture];
	[finalRenderResidencySet addAllocation:postProcessor.outputTexture];
}

- (id<MTLRenderPipelineState>) compileFinalRenderPipeline:(MTLPixelFormat) colorPixelFormat {
	NSError *error;
	id<MTL4Compiler> compiler = [pipeline.device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
															error:&error];
	
	if (error) {
		NSLog(@"%@", error);
		return nil;
	}

	MTL4LibraryFunctionDescriptor *vertexFunction = [MTL4LibraryFunctionDescriptor new];
	vertexFunction.library = pipeline.defaultLibrary;
	vertexFunction.name = @"finalRenderVertexShader";
	
	MTL4LibraryFunctionDescriptor *fragmentFunction = [MTL4LibraryFunctionDescriptor new];
	fragmentFunction.library = pipeline.defaultLibrary;
	fragmentFunction.name = @"finalRenderFragmentShader";
	
	MTL4RenderPipelineDescriptor *descriptor = [MTL4RenderPipelineDescriptor new];
	descriptor.label = @"Final Render";
	descriptor.vertexFunctionDescriptor = vertexFunction;
	descriptor.fragmentFunctionDescriptor = fragmentFunction;
	
	MTL4RenderPipelineColorAttachmentDescriptor *colorAttachment = descriptor.colorAttachments[0];
	colorAttachment.pixelFormat = colorPixelFormat;
	
	id<MTLRenderPipelineState> state = [compiler newRenderPipelineStateWithDescriptor:descriptor
																  compilerTaskOptions:nil
																				error:&error];
	if (error) {
		NSLog(@"%@", error);
		return nil;
	}
	
	return state;
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

	[geometryManager shutdown];
	[textureManager shutdown];

	[finalRenderResidencySet removeAllAllocations];
	[pipeline.commandQueue removeResidencySet:finalRenderResidencySet];
	
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

	[self encodeFinalRenderToOutputTexture:currentDrawable.texture
							   afterFences:@[postProcessingPassFence]];
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

-(void) encodeFinalRenderToOutputTexture:(id<MTLTexture>)outputTexture
							 afterFences:(NSArray<id<MTLFence>>*)fences
{
	MTL4RenderPassDescriptor *configuration = [MTL4RenderPassDescriptor new];
	configuration.colorAttachments[0].texture = outputTexture;
	configuration.colorAttachments[0].loadAction = MTLLoadActionClear;
	configuration.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1.0);
	configuration.colorAttachments[0].storeAction = MTLStoreActionStore;

	id<MTL4RenderCommandEncoder> encoder = [pipeline.commandBuffer renderCommandEncoderWithDescriptor:configuration];
	if (!encoder) {
		NSLog(@"Failed to create render command encoder");
		return;
	}
	encoder.label = @"Final render";
	
	for (id<MTLFence> fence in fences) {
		[encoder waitForFence:fence beforeEncoderStages:MTLStageVertex];
	}
	
	[encoder setRenderPipelineState:finalRenderPipeline];
	[encoder setViewport:[_view getViewportWithPixelScaling:YES]];

	id<MTLTexture> processedOutput = (POST_PROCESSING_TYPE == NoPostProcessing) ? rayTracer.outputTexture : postProcessor.outputTexture;

	[fragmentArgumentTable setAddress:uniformsBuffer.gpuAddress atIndex:FinalRenderFragmentShaderUniformsIndex];
	[fragmentArgumentTable setTexture:initialRender.diffuseAlbedoTexture.gpuResourceID atIndex:FinalRenderFragmentShaderAlbedoTextureIndex];
	[fragmentArgumentTable setTexture:processedOutput.gpuResourceID atIndex:FinalRenderFragmentShaderRayTracingTextureIndex];
	[encoder setArgumentTable:fragmentArgumentTable atStages:MTLRenderStageFragment];
	[encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
	
	[encoder endEncoding];
}

@end
