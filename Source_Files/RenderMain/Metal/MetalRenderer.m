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
#include "MetalTypes.h"
#include "Utils.h"
#include "Common.h"

const bool FULL_PATH_TRACING = true;
const PostProcessingType POST_PROCESSING_TYPE = NoPostProcessing;

NSArray<NSNumber*> *waveletDenoisePasses = @[@8, @4, @2, @1];

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
	
	id<MTLComputePipelineState> denoisePipeline;
	id<MTLComputePipelineState> taaPipeline;
	id<MTLRenderPipelineState> finalRenderPipeline;
	id<MTLDepthStencilState> depthState;

	id<MTL4ArgumentTable> fragmentArgumentTable;
	id<MTL4ArgumentTable> computeArgumentTable;

	// Using a Metal 3 command queue for the MetalFX upscalers because they seem to be buggy when using Metal 4
	id<MTLCommandQueue> mtl3queue;
	id<MTLFXTemporalScaler> temporalScaler;
	id<MTLFXTemporalDenoisedScaler> temporalDenoisedScaler;

	id<MTLResidencySet> postProcessingResidencySet;
	id<MTLResidencySet> finalRenderResidencySet;
	
	id<MTLFence> initialPassFence;
	id<MTLFence> computePassFence;
	id<MTLFence> postProcessingPassFence;
	
	id<MTLTexture> postProcessingScratchTexture;
	id<MTLTexture> postProcessingOutputTexture;

	// Constants shared across all pipelines
	id<MTLBuffer> uniformsBuffer;
	
	id<MTLBuffer> denoiseConfigBuffer;
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

	if (![self setupResidencySets]) {
		return nil;
	}
	[self addBuffersToResidencySets];
	
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

	[self setupIntermediateTextures];

	denoisePipeline = [self compileComputePipelineWithFunctionName:@"denoiseKernel"];
	if (!denoisePipeline) {
		return nil;
	}
	
	taaPipeline = [self compileComputePipelineWithFunctionName:@"TAA"];
	if (!taaPipeline) {
		return nil;
	}
	
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
	
	mtl3queue = [pipeline.device newCommandQueue];
	if (![self setupTemporalScaler]) {
		return nil;
	}
	if (![self setupTemporalDenoisedScaler]) {
		return nil;
	}

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
	
	MTL4ArgumentTableDescriptor *computeArgumentTableDescriptor = [MTL4ArgumentTableDescriptor new];
	computeArgumentTableDescriptor.maxBufferBindCount = DenoisePass_NumBuffers;
	computeArgumentTableDescriptor.maxTextureBindCount = DenoisePass_NumTextures;
	computeArgumentTableDescriptor.label = @"Compute argument table";
	computeArgumentTable = [pipeline.device newArgumentTableWithDescriptor:computeArgumentTableDescriptor error:&error];
	if (error) {
		NSLog(@"%@", error);
		return false;
	}

	return true;
}

- (bool) setupResidencySets {
	NSError *error;

	MTLResidencySetDescriptor *residencySetDescriptor = [MTLResidencySetDescriptor new];
	
	residencySetDescriptor.label = @"denoiseResidencySet";
	postProcessingResidencySet = [pipeline.device newResidencySetWithDescriptor:residencySetDescriptor
																   error:&error];
	if (error) {
		NSLog(@"%@", error);
		return false;
	}

	residencySetDescriptor.label = @"finalRenderResidencySet";
	finalRenderResidencySet = [pipeline.device newResidencySetWithDescriptor:residencySetDescriptor
															  error:&error];
	if (error) {
		NSLog(@"%@", error);
		return false;
	}
	
	[pipeline.commandQueue addResidencySet:postProcessingResidencySet];
	[pipeline.commandQueue addResidencySet:finalRenderResidencySet];
	[pipeline.commandQueue addResidencySet:metalLayer.residencySet];

	return true;
}

- (void) setupBuffers {
	uniformsBuffer = [pipeline.device newBufferWithLength:sizeof(Uniforms) options:MTLResourceStorageModeShared];
	uniformsBuffer.label = @"Uniforms";
	
	denoiseConfigBuffer = [pipeline.device newBufferWithLength:sizeof(DenoiseConfig) * waveletDenoisePasses.count options:MTLResourceStorageModeShared];
	denoiseConfigBuffer.label = @"Denoise config";
}

- (void) addBuffersToResidencySets {
	[postProcessingResidencySet addAllocation:uniformsBuffer];
	[finalRenderResidencySet addAllocation:uniformsBuffer];

	[postProcessingResidencySet addAllocation:denoiseConfigBuffer];
}

- (void) setupIntermediateTextures {
	MTLTextureDescriptor *denoised = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:RayTracingPixelFormat
																						width:_view.viewportSize.x
																					   height:_view.viewportSize.y
																					mipmapped:NO];
	denoised.storageMode = MTLStorageModePrivate;
	denoised.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
	postProcessingScratchTexture = [pipeline.device newTextureWithDescriptor:denoised];
	postProcessingScratchTexture.label = @"Denoise pass (scratch)";
	postProcessingOutputTexture = [pipeline.device newTextureWithDescriptor:denoised];
	postProcessingOutputTexture.label = @"Denoise pass (output)";
	
	for (id<MTLTexture> texture in initialRender.textures) {
		[postProcessingResidencySet addAllocation:texture];
	}

	[postProcessingResidencySet addAllocation:postProcessingScratchTexture];
	[postProcessingResidencySet addAllocation:postProcessingOutputTexture];

	[finalRenderResidencySet addAllocation:initialRender.diffuseAlbedoTexture];
	[finalRenderResidencySet addAllocation:rayTracer.outputTexture];
	[finalRenderResidencySet addAllocation:postProcessingScratchTexture];
	[finalRenderResidencySet addAllocation:postProcessingOutputTexture];
}

- (bool) setupTemporalScaler {
	if (![MTLFXTemporalScalerDescriptor supportsMetal4FX:pipeline.device]) {
		NSLog(@"Temporal scaler is unsupported");
		return false;
	}
	
	MTLFXTemporalScalerDescriptor *descriptor = [MTLFXTemporalScalerDescriptor new];
	descriptor.inputWidth = _view.viewportSize.x;
	descriptor.inputHeight = _view.viewportSize.y;
	descriptor.outputWidth = _view.viewportSize.x;
	descriptor.outputHeight = _view.viewportSize.y;

	descriptor.colorTextureFormat = RayTracingPixelFormat;
	descriptor.outputTextureFormat = RayTracingPixelFormat;
	descriptor.depthTextureFormat = DepthPixelFormat;
	descriptor.motionTextureFormat = MotionPixelFormat;
	
	descriptor.requiresSynchronousInitialization = YES;
	
	temporalScaler = [descriptor newTemporalScalerWithDevice:pipeline.device];
	
	if (temporalScaler == nil) {
		NSLog(@"Failed to create temporal scaler");
		return false;
	}
	
	return true;
}

- (bool) setupTemporalDenoisedScaler {
	if (![MTLFXTemporalDenoisedScalerDescriptor supportsMetal4FX:pipeline.device]) {
		NSLog(@"Temporal denoised scaler is unsupported");
		return false;
	}

	MTLFXTemporalDenoisedScalerDescriptor *descriptor = [MTLFXTemporalDenoisedScalerDescriptor new];
	descriptor.inputWidth = _view.viewportSize.x;
	descriptor.inputHeight = _view.viewportSize.y;
	descriptor.outputWidth = _view.viewportSize.x;
	descriptor.outputHeight = _view.viewportSize.y;

	descriptor.colorTextureFormat = RayTracingPixelFormat;
	descriptor.outputTextureFormat = RayTracingPixelFormat;
	descriptor.diffuseAlbedoTextureFormat = DiffuseAlbedoPixelFormat;
	descriptor.specularAlbedoTextureFormat = SpecularAlbedoPixelFormat;
	descriptor.roughnessTextureFormat = RoughnessPixelFormat;
	descriptor.depthTextureFormat = DepthPixelFormat;
	descriptor.normalTextureFormat = NormalPixelFormat;
	descriptor.motionTextureFormat = MotionPixelFormat;
	
	descriptor.requiresSynchronousInitialization = YES;
	
	temporalDenoisedScaler = [descriptor newTemporalDenoisedScalerWithDevice:pipeline.device];
	
	if (temporalDenoisedScaler == nil) {
		NSLog(@"Failed to create temporal denoised scaler");
		return false;
	}
	
	return true;
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

- (id<MTLComputePipelineState>) compileComputePipelineWithFunctionName:(NSString*)functionName {
	NSError *error;
	id<MTLFunction> function = [pipeline.defaultLibrary newFunctionWithName:functionName];
	
	id<MTLComputePipelineState> state = [pipeline.device newComputePipelineStateWithFunction:function
																					   error:&error];
	if (error) {
		NSLog(@"%@", error);
	}
	
	return state;
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
		[self encodeTemporalUpscaleUpdatingFence:postProcessingPassFence];
	}

	if (POST_PROCESSING_TYPE == TemporalDenoisedUpscale) {
		[self encodeTemporalDenoisedUpscaleUpdatingFence:postProcessingPassFence];
	}
	
	[commandBuffer beginCommandBufferWithAllocator:pipeline.commandAllocator];
	commandBuffer.label = [NSString stringWithFormat:@"Frame %llu (final pass)", _view.frameNumber];

	if (POST_PROCESSING_TYPE == WaveletDenoise) {
		[self encodeWaveletDenoiseUpdatingFence:postProcessingPassFence];
	}
	
	if (POST_PROCESSING_TYPE == TAA) {
		[self encodeTAAUpdatingFence:postProcessingPassFence];
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

-(void) encodeWaveletDenoiseUpdatingFence:(id<MTLFence>)fence {
	id<MTL4ComputeCommandEncoder> encoder = [self createComputeCommandEncoderForPipeline:denoisePipeline label:@"Denoise"];

	MTLSize threadsPerGrid = MTLSizeMake(rayTracer.outputTexture.width, rayTracer.outputTexture.height, 1);
	
	DenoiseConfig *configs = (DenoiseConfig*)denoiseConfigBuffer.contents;
	for (int i = 0; i < waveletDenoisePasses.count; i++) {
		configs[i].step = waveletDenoisePasses[i].unsignedIntValue;
	}
	
	id<MTLTexture> currentInput = rayTracer.outputTexture;
	id<MTLTexture> currentOutput = (waveletDenoisePasses.count % 2 == 1) ? postProcessingOutputTexture : postProcessingScratchTexture;

	for (int i = 0; i < waveletDenoisePasses.count; i++) {
		MTLGPUAddress configAddress = denoiseConfigBuffer.gpuAddress + (i * sizeof(DenoiseConfig));

		[computeArgumentTable setAddress:uniformsBuffer.gpuAddress atIndex:DenoisePassUniformsIndex];
		[computeArgumentTable setAddress:configAddress atIndex:DenoisePassConfigIndex];
		[computeArgumentTable setTexture:initialRender.normalTexture.gpuResourceID atIndex:DenoisePassNormalTextureIndex];
		[computeArgumentTable setTexture:initialRender.depthTexture.gpuResourceID atIndex:DenoisePassDepthTextureIndex];
		[computeArgumentTable setTexture:currentInput.gpuResourceID atIndex:DenoisePassInputTextureIndex];
		[computeArgumentTable setTexture:currentOutput.gpuResourceID atIndex:DenoisePassOutputTextureIndex];
		[encoder setArgumentTable:computeArgumentTable];
		
		[encoder dispatchThreads:threadsPerGrid
		   threadsPerThreadgroup:[self getThreadsPerThreadgroupForPipeline:denoisePipeline]];
		
		if (i < waveletDenoisePasses.count - 1) {
			[encoder barrierAfterEncoderStages:MTLStageDispatch
						   beforeEncoderStages:MTLStageDispatch
							 visibilityOptions:MTL4VisibilityOptionDevice];
			
			currentInput = currentOutput;
			currentOutput = (currentInput == postProcessingOutputTexture) ? postProcessingScratchTexture : postProcessingOutputTexture;
		}
	}

	[encoder updateFence:fence afterEncoderStages:MTLStageDispatch];
	[encoder endEncoding];
}

-(void) encodeTAAUpdatingFence:(id<MTLFence>)fence {
	id<MTL4ComputeCommandEncoder> encoder = [self createComputeCommandEncoderForPipeline:taaPipeline label:@"TAA"];
	
	MTLSize threadsPerGrid = MTLSizeMake(rayTracer.outputTexture.width, rayTracer.outputTexture.height, 1);

	id<MTLTexture> previousOutput = (_view.frameNumber % 2 == 0) ? postProcessingScratchTexture : postProcessingOutputTexture;
	id<MTLTexture> currentOutput  = (_view.frameNumber % 2 == 0) ? postProcessingOutputTexture : postProcessingScratchTexture;
	
	[computeArgumentTable setAddress:uniformsBuffer.gpuAddress atIndex:TAAKernelUniformsIndex];
	[computeArgumentTable setTexture:rayTracer.outputTexture.gpuResourceID atIndex:TAAKernelInputTextureIndex];
	[computeArgumentTable setTexture:initialRender.motionTexture.gpuResourceID atIndex:TAAKernelMotionTextureIndex];
	[computeArgumentTable setTexture:previousOutput.gpuResourceID atIndex:TAAKernelPreviousOutputTextureIndex];
	[computeArgumentTable setTexture:currentOutput.gpuResourceID atIndex:TAAKernelOutputTextureIndex];
	[encoder setArgumentTable:computeArgumentTable];
	
	[encoder dispatchThreads:threadsPerGrid
	   threadsPerThreadgroup:[self getThreadsPerThreadgroupForPipeline:taaPipeline]];
	
	[encoder updateFence:fence afterEncoderStages:MTLStageDispatch];
	[encoder endEncoding];
}

-(id<MTL4ComputeCommandEncoder>) createComputeCommandEncoderForPipeline:(id<MTLComputePipelineState>)pipelineState
																  label:(NSString*)label
{
	id<MTL4ComputeCommandEncoder> encoder = [pipeline.commandBuffer computeCommandEncoder];
	if (!encoder) {
		NSLog(@"Failed to create encoder for '%@'", label);
		return nil;
	}
	encoder.label = label;
	[encoder setComputePipelineState:pipelineState];
	return encoder;
}

-(MTLSize) getThreadsPerThreadgroupForPipeline:(id<MTLComputePipelineState>)pipelineState {
	NSUInteger w = pipelineState.threadExecutionWidth;
	NSUInteger h = pipelineState.maxTotalThreadsPerThreadgroup / w;
	return MTLSizeMake( w, h, 1 );
}

-(void) encodeTemporalUpscaleUpdatingFence:(id<MTLFence>)fence {
	id<MTLCommandBuffer> mtl3buffer = [mtl3queue commandBuffer];
	mtl3buffer.label = [NSString stringWithFormat:@"Frame %llu (denoise)", _view.frameNumber];
	
	temporalScaler.colorTexture = rayTracer.outputTexture;
	temporalScaler.depthTexture = initialRender.depthTexture;
	temporalScaler.motionTexture = initialRender.motionTexture;
	temporalScaler.motionVectorScaleX = 1.0;
	temporalScaler.motionVectorScaleY = 1.0;
	temporalScaler.outputTexture = postProcessingOutputTexture;
	temporalScaler.jitterOffsetX = _view.jitter.x;
	temporalScaler.jitterOffsetY = _view.jitter.y;
	temporalScaler.fence = fence;
	[temporalScaler encodeToCommandBuffer:mtl3buffer];
	[mtl3buffer commit];
	[mtl3buffer waitUntilCompleted];
}

-(void) encodeTemporalDenoisedUpscaleUpdatingFence:(id<MTLFence>)fence {
	id<MTLCommandBuffer> mtl3buffer = [mtl3queue commandBuffer];
	mtl3buffer.label = [NSString stringWithFormat:@"Frame %llu (denoise)", _view.frameNumber];
	
	temporalDenoisedScaler.colorTexture = rayTracer.outputTexture;
	temporalDenoisedScaler.diffuseAlbedoTexture = initialRender.diffuseAlbedoTexture;
	temporalDenoisedScaler.specularAlbedoTexture = initialRender.specularAlbedoTexture;
	temporalDenoisedScaler.roughnessTexture = initialRender.roughnessTexture;
	temporalDenoisedScaler.depthTexture = initialRender.depthTexture;
	temporalDenoisedScaler.normalTexture = initialRender.normalTexture;
	temporalDenoisedScaler.motionTexture = initialRender.motionTexture;
	temporalDenoisedScaler.motionVectorScaleX = 1.0;
	temporalDenoisedScaler.motionVectorScaleY = 1.0;
	temporalDenoisedScaler.outputTexture = postProcessingOutputTexture;
	temporalScaler.jitterOffsetX = _view.jitter.x;
	temporalScaler.jitterOffsetY = _view.jitter.y;
	temporalDenoisedScaler.fence = fence;
	[temporalDenoisedScaler encodeToCommandBuffer:mtl3buffer];
	[mtl3buffer commit];
	[mtl3buffer waitUntilCompleted];
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

	id<MTLTexture> processedOutput = (POST_PROCESSING_TYPE == NoPostProcessing) ? rayTracer.outputTexture : postProcessingOutputTexture;

	[fragmentArgumentTable setAddress:uniformsBuffer.gpuAddress atIndex:FinalRenderFragmentShaderUniformsIndex];
	[fragmentArgumentTable setTexture:initialRender.diffuseAlbedoTexture.gpuResourceID atIndex:FinalRenderFragmentShaderAlbedoTextureIndex];
	[fragmentArgumentTable setTexture:processedOutput.gpuResourceID atIndex:FinalRenderFragmentShaderRayTracingTextureIndex];
	[encoder setArgumentTable:fragmentArgumentTable atStages:MTLRenderStageFragment];
	[encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
	
	[encoder endEncoding];
}

@end
