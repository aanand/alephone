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

#include "Shaders/ShaderTypes.h"
#include "MetalPipeline.h"
#include "IASManager.h"
#include "MetalRenderer.h"
#include "MetalTypes.h"

float radians(float degrees) {
	return degrees * 8.0 * atan(1.0) / 360.0;
}

simd_float4x4 rotationMatrix(float angle, simd_float3 axis) {
	simd_quatf quat = simd_quaternion(radians(angle), axis);
	return simd_matrix4x4(quat);
}

simd_float4x4 perspectiveProjection(float horizontalFOV, float width, float height) {
	float xs = 1.0 / tanf(radians(horizontalFOV) * 0.5);
	float ys = xs * width / height;
	float nz = 0.01;
	
	return simd_matrix((simd_float4){  xs, 0.0, 0.0, 0.0 },
					   (simd_float4){ 0.0,  ys, 0.0, 0.0 },
					   (simd_float4){ 0.0, 0.0, 1.0, 1.0 },
					   (simd_float4){ 0.0, 0.0, -nz, 0.0 });
}

uint MAX_TRIANGLES = 10000;
uint MAX_INSTANCES = 1000;

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

	// Variables
	
	simd_uint2 viewportSize;
	float fov, pitch, yaw;
	simd_int3 origin;
	float weaponFlare;
	float flashlight;
	bool isInMedium;

	Sky sky;
	Camera camera;

	uint64_t frameNumber;
	
	// Metal pipeline internals
	
	MetalPipeline *pipeline;

	id<MTLRenderPipelineState> initialRenderPipeline;
	id<MTLComputePipelineState> rayTracingPipeline;
	id<MTLComputePipelineState> denoisePipeline;
	id<MTLComputePipelineState> taaPipeline;
	id<MTLRenderPipelineState> finalRenderPipeline;
	id<MTLDepthStencilState> depthState;

	id<MTL4ArgumentTable> vertexArgumentTable;
	id<MTL4ArgumentTable> fragmentArgumentTable;
	id<MTL4ArgumentTable> computeArgumentTable;

	id<MTLFXTemporalScaler> temporalScaler;
	id<MTLFXTemporalDenoisedScaler> temporalDenoisedScaler;

	id<MTLResidencySet> initialRenderResidencySet;
	id<MTLResidencySet> rayTracingResidencySet;
	id<MTLResidencySet> postProcessingResidencySet;
	id<MTLResidencySet> finalRenderResidencySet;
	
	id<MTLFence> initialPassFence;
	id<MTLFence> computePassFence;
	id<MTLFence> postProcessingPassFence;
	
	id<MTLTexture> initialRenderGBufferDiffuseAlbedo;
	id<MTLTexture> initialRenderGBufferSpecularAlbedo;
	id<MTLTexture> initialRenderGBufferRoughness;
	id<MTLTexture> initialRenderGBufferDepth;
	id<MTLTexture> initialRenderGBufferNormal;
	id<MTLTexture> initialRenderGBufferMotion;
	NSSet<id<MTLTexture>> *intermediateTextures;

	id<MTLTexture> rayTracingOutputTexture;
	id<MTLTexture> postProcessingScratchTexture;
	id<MTLTexture> postProcessingOutputTexture;

	// Constants shared across all pipelines
	id<MTLBuffer> uniformsBuffer;

	// Triangles for rasterization (static + dynamic)
	id<MTLBuffer> triangleBuffer;

	// Normals, UVs etc. for dynamic geometry
	id<MTLBuffer> perInstanceDataBuffer;
	uint32_t numInstances;

	NSMutableOrderedSet<NSString*> *textureIDs;

	id<MTLArgumentEncoder> albedoTextureArgumentEncoder;
	id<MTLArgumentEncoder> normalMapArgumentEncoder;
	id<MTLArgumentEncoder> emissionMapArgumentEncoder;

	id<MTLBuffer> albedoTextureArgumentBuffer;
	id<MTLBuffer> normalMapArgumentBuffer;
	id<MTLBuffer> emissionMapArgumentBuffer;

	NSMutableDictionary<NSString *, id<MTLTexture>> *albedoTextures;
	NSMutableDictionary<NSString *, id<MTLTexture>> *normalMaps;
	NSMutableDictionary<NSString *, id<MTLTexture>> *emissionMaps;

	// Geometry primitives that get reused across levels
	VerticalQuad *verticalQuadPrimitive;
	
	// Static geometry (walls, floors, ceilings)
	IASManager *staticIASManager;
	NSMutableArray<Triangle*> *staticTriangles;

	// Dynamic geometry (sprites, doors, platforms)
	IASManager *dynamicIASManager;
	NSMutableDictionary<NSNumber*, id<ASTrianglePrimitive>> *dynamicPolygonPrimitives;
	NSMutableArray<Triangle*> *dynamicTriangles;

	// Light sources
	NSArray<NSNumber*> *lightSourceIntensities;
	id<MTLBuffer> lightSourcesBuffer;

	id<MTLBuffer> topLevelIASInstanceBuffer;
	id<MTLAccelerationStructure> topLevelIAS;
	MTL4InstanceAccelerationStructureDescriptor *topLevelIASDescriptor;
	
	id<MTLBuffer> denoiseConfigBuffer;
}

- (MetalRenderer *) initializeWithWindow:(SDL_Window *)sdlWindow width:(int)width height:(int)height {
	window = sdlWindow;
	renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_PRESENTVSYNC);
	
	fov = 90.0;
	viewportSize = simd_make_uint2(width, height);
	frameNumber = 0;
	
	metalLayer = (__bridge CAMetalLayer*)SDL_RenderGetMetalLayer(renderer);

	pipeline = [[MetalPipeline alloc] init];
	pipeline.device = metalLayer.device;
	pipeline.commandQueue = [pipeline.device newMTL4CommandQueue];
	pipeline.commandBuffer = [pipeline.device newCommandBuffer];
	pipeline.defaultLibrary = [pipeline.device newDefaultLibrary];
	pipeline.commandAllocator = [pipeline.device newCommandAllocator];
	pipeline.sharedEvent = [pipeline.device newSharedEvent];

	if (![self setupResidencySets]) {
		return nil;
	}

	[self setupIntermediateTextures];
	[self setupBuffers];
	
	initialRenderPipeline = [self compileInitialRenderPipeline];
	if (!initialRenderPipeline) {
		return nil;
	}
	
	rayTracingPipeline = [self compileRayTracingPipeline];
	if (!rayTracingPipeline) {
		return nil;
	}
	
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
	
	depthState = [self configureDepth];
	
	if (![self setupArgumentTables]) {
		return nil;
	}

	initialPassFence = [pipeline.device newFence];
	computePassFence = [pipeline.device newFence];
	postProcessingPassFence = [pipeline.device newFence];
	
	if (![self setupTemporalScaler]) {
		return nil;
	}
	if (![self setupTemporalDenoisedScaler]) {
		return nil;
	}

	NSError *error;
	staticIASManager = [[IASManager alloc] initWithPipeline:pipeline
								   primitiveDataElementSize:sizeof(RayTracingData)
													  error:&error];
	if (!staticIASManager) {
		NSLog(@"%@", error);
		return nil;
	}
	staticIASManager.label = @"staticIASManager";

	dynamicIASManager = [[IASManager alloc] initWithPipeline:pipeline
									primitiveDataElementSize:sizeof(RayTracingData)
													   error:&error];
	if (!dynamicIASManager) {
		NSLog(@"%@", error);
		return nil;
	}
	dynamicIASManager.label = @"dynamicIASManager";
	
	[initialRenderResidencySet commit];
	[rayTracingResidencySet commit];
	[finalRenderResidencySet commit];
	
	return self;
}

- (bool) setupArgumentTables {
	NSError *error;
	
	MTL4ArgumentTableDescriptor *vertexArgumentTableDescriptor = [MTL4ArgumentTableDescriptor new];
	vertexArgumentTableDescriptor.maxBufferBindCount = MAX(InitialRenderVertexShader_NumBuffers, FinalRenderVertexShader_NumBuffers);
	vertexArgumentTableDescriptor.label = @"Vertex argument table";
	vertexArgumentTable = [pipeline.device newArgumentTableWithDescriptor:vertexArgumentTableDescriptor error:&error];
	if (error) {
		NSLog(@"%@", error);
		return false;
	}
	
	MTL4ArgumentTableDescriptor *fragmentArgumentTableDescriptor = [MTL4ArgumentTableDescriptor new];
	fragmentArgumentTableDescriptor.maxTextureBindCount = FinalRenderFragmentShader_NumTextures;
	fragmentArgumentTableDescriptor.maxBufferBindCount = MAX(InitialRenderFragmentShader_NumBuffers, FinalRenderFragmentShader_NumBuffers);
	fragmentArgumentTableDescriptor.label = @"Fragment argument table";
	fragmentArgumentTable = [pipeline.device newArgumentTableWithDescriptor:fragmentArgumentTableDescriptor error:&error];
	if (error) {
		NSLog(@"%@", error);
		return false;
	}
	
	MTL4ArgumentTableDescriptor *computeArgumentTableDescriptor = [MTL4ArgumentTableDescriptor new];
	computeArgumentTableDescriptor.maxBufferBindCount = MAX(RayTracingKernel_NumBuffers, DenoisePass_NumBuffers);
	computeArgumentTableDescriptor.maxTextureBindCount = MAX(RayTracingKernel_NumTextures, DenoisePass_NumTextures);
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
	residencySetDescriptor.label = @"initialRenderResidencySet";
	initialRenderResidencySet = [pipeline.device newResidencySetWithDescriptor:residencySetDescriptor
												   error:&error];
	if (error) {
		NSLog(@"%@", error);
		return false;
	}
	
	residencySetDescriptor.label = @"rayTracingResidencySet";
	rayTracingResidencySet = [pipeline.device newResidencySetWithDescriptor:residencySetDescriptor
															 error:&error];
	if (error) {
		NSLog(@"%@", error);
		return false;
	}
	
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
	
	[pipeline.commandQueue addResidencySet:initialRenderResidencySet];
	[pipeline.commandQueue addResidencySet:rayTracingResidencySet];
	[pipeline.commandQueue addResidencySet:postProcessingResidencySet];
	[pipeline.commandQueue addResidencySet:finalRenderResidencySet];
	[pipeline.commandQueue addResidencySet:metalLayer.residencySet];

	return true;
}

- (void) setupBuffers {
	uniformsBuffer = [pipeline.device newBufferWithLength:sizeof(Uniforms) options:MTLResourceStorageModeShared];
	uniformsBuffer.label = @"Uniforms";
	[initialRenderResidencySet addAllocation:uniformsBuffer];
	[rayTracingResidencySet addAllocation:uniformsBuffer];
	[postProcessingResidencySet addAllocation:uniformsBuffer];
	[finalRenderResidencySet addAllocation:uniformsBuffer];
	
	triangleBuffer = [pipeline.device newBufferWithLength:(sizeof(WorldVertex) * MAX_TRIANGLES * 3) options:MTLResourceStorageModeShared];
	triangleBuffer.label = @"Triangle vertices";
	[initialRenderResidencySet addAllocation:triangleBuffer];
	
	perInstanceDataBuffer = [pipeline.device newBufferWithLength:(sizeof(RayTracingData) * MAX_INSTANCES) options:MTLResourceStorageModeShared];
	perInstanceDataBuffer.label = @"Per-instance data";
	[rayTracingResidencySet addAllocation:perInstanceDataBuffer];
	
	denoiseConfigBuffer = [pipeline.device newBufferWithLength:sizeof(DenoiseConfig) * waveletDenoisePasses.count options:MTLResourceStorageModeShared];
	denoiseConfigBuffer.label = @"Denoise config";
	[postProcessingResidencySet addAllocation:denoiseConfigBuffer];
}

- (void) setupIntermediateTextures {
	MTLTextureDescriptor *initial = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:DiffuseAlbedoPixelFormat
																					   width:viewportSize.x
																					  height:viewportSize.y
																				   mipmapped:NO];
	initial.storageMode = MTLStorageModePrivate;
	initial.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
	initialRenderGBufferDiffuseAlbedo = [pipeline.device newTextureWithDescriptor:initial];
	initialRenderGBufferDiffuseAlbedo.label = @"Diffuse Albedo";
	
	initial.pixelFormat = SpecularAlbedoPixelFormat;
	initialRenderGBufferSpecularAlbedo = [pipeline.device newTextureWithDescriptor:initial];
	initialRenderGBufferSpecularAlbedo.label = @"Specular Albedo";
	
	initial.pixelFormat = RoughnessPixelFormat;
	initialRenderGBufferRoughness = [pipeline.device newTextureWithDescriptor:initial];
	initialRenderGBufferRoughness.label = @"Roughness";
	
	initial.pixelFormat = DepthPixelFormat;
	initialRenderGBufferDepth = [pipeline.device newTextureWithDescriptor:initial];
	initialRenderGBufferDepth.label = @"Depth";
	
	initial.pixelFormat = NormalPixelFormat;
	initialRenderGBufferNormal = [pipeline.device newTextureWithDescriptor:initial];
	initialRenderGBufferNormal.label = @"Normal";
	
	initial.pixelFormat = MotionPixelFormat;
	initialRenderGBufferMotion = [pipeline.device newTextureWithDescriptor:initial];
	initialRenderGBufferMotion.label = @"Motion";

	MTLTextureDescriptor *raytrace = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:RayTracingPixelFormat
																						width:viewportSize.x
																					   height:viewportSize.y
																					mipmapped:NO];
	raytrace.storageMode = MTLStorageModePrivate;
	raytrace.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
	rayTracingOutputTexture = [pipeline.device newTextureWithDescriptor:raytrace];
	rayTracingOutputTexture.label = @"Ray-tracing output";
	
	MTLTextureDescriptor *denoised = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:RayTracingPixelFormat
																						width:viewportSize.x
																					   height:viewportSize.y
																					mipmapped:NO];
	denoised.storageMode = MTLStorageModePrivate;
	denoised.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
	postProcessingScratchTexture = [pipeline.device newTextureWithDescriptor:denoised];
	postProcessingScratchTexture.label = @"Denoise pass (scratch)";
	postProcessingOutputTexture = [pipeline.device newTextureWithDescriptor:denoised];
	postProcessingOutputTexture.label = @"Denoise pass (output)";
	
	switch (POST_PROCESSING_TYPE) {
		case NoPostProcessing:
			intermediateTextures = [NSSet setWithArray:@[
				initialRenderGBufferDiffuseAlbedo,
			]];
			break;

		case WaveletDenoise:
			intermediateTextures = [NSSet setWithArray:@[
				initialRenderGBufferDiffuseAlbedo,
				initialRenderGBufferDepth,
				initialRenderGBufferNormal,
			]];
			break;
			
		case TAA:
			intermediateTextures = [NSSet setWithArray:@[
				initialRenderGBufferDiffuseAlbedo,
				initialRenderGBufferMotion,
			]];
			break;

		case TemporalUpscale:
			intermediateTextures = [NSSet setWithArray:@[
				initialRenderGBufferDiffuseAlbedo,
				initialRenderGBufferDepth,
				initialRenderGBufferMotion,
			]];
			break;

		case TemporalDenoisedUpscale:
			intermediateTextures = [NSSet setWithArray:@[
				initialRenderGBufferDiffuseAlbedo,
				initialRenderGBufferDepth,
				initialRenderGBufferNormal,
				initialRenderGBufferSpecularAlbedo,
				initialRenderGBufferRoughness,
				initialRenderGBufferMotion,
			]];
			break;
	}
	
	for (id<MTLTexture> texture in intermediateTextures) {
		[initialRenderResidencySet addAllocation:texture];
		[postProcessingResidencySet addAllocation:texture];
	}

	[rayTracingResidencySet addAllocation:rayTracingOutputTexture];
	
	[postProcessingResidencySet addAllocation:postProcessingScratchTexture];
	[postProcessingResidencySet addAllocation:postProcessingOutputTexture];

	[finalRenderResidencySet addAllocation:initialRenderGBufferDiffuseAlbedo];
	[finalRenderResidencySet addAllocation:rayTracingOutputTexture];
	[finalRenderResidencySet addAllocation:postProcessingScratchTexture];
	[finalRenderResidencySet addAllocation:postProcessingOutputTexture];
}

- (bool) setupTemporalScaler {
	if (![MTLFXTemporalScalerDescriptor supportsMetal4FX:pipeline.device]) {
		NSLog(@"Temporal scaler is unsupported");
		return false;
	}
	
	MTLFXTemporalScalerDescriptor *descriptor = [MTLFXTemporalScalerDescriptor new];
	descriptor.inputWidth = viewportSize.x;
	descriptor.inputHeight = viewportSize.y;
	descriptor.outputWidth = viewportSize.x;
	descriptor.outputHeight = viewportSize.y;

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
	descriptor.inputWidth = viewportSize.x;
	descriptor.inputHeight = viewportSize.y;
	descriptor.outputWidth = viewportSize.x;
	descriptor.outputHeight = viewportSize.y;

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

- (id<MTLRenderPipelineState>) compileInitialRenderPipeline {
	NSError *error;
	id<MTL4Compiler> compiler = [pipeline.device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
															error:&error];

	if (error) {
		NSLog(@"%@", error);
		return nil;
	}

	MTL4LibraryFunctionDescriptor *vertexFunction = [MTL4LibraryFunctionDescriptor new];
	vertexFunction.library = pipeline.defaultLibrary;
	vertexFunction.name = @"initialRenderVertexShader";
	
	MTL4LibraryFunctionDescriptor *fragmentFunction = [MTL4LibraryFunctionDescriptor new];
	fragmentFunction.library = pipeline.defaultLibrary;
	fragmentFunction.name = @"initialRenderFragmentShader";

	MTL4RenderPipelineDescriptor *descriptor = [MTL4RenderPipelineDescriptor new];
	descriptor.label = @"Initial Render";
	descriptor.vertexFunctionDescriptor = vertexFunction;
	descriptor.fragmentFunctionDescriptor = fragmentFunction;

	if ([intermediateTextures containsObject:initialRenderGBufferDiffuseAlbedo]) {
		MTL4RenderPipelineColorAttachmentDescriptor *albedoAttachment = descriptor.colorAttachments[InitialRenderAttachmentDiffuseAlbedo];
		albedoAttachment.pixelFormat = DiffuseAlbedoPixelFormat;
		albedoAttachment.blendingState = MTL4BlendStateEnabled;
		albedoAttachment.sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
		albedoAttachment.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
		albedoAttachment.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
		albedoAttachment.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
	}
	
	if ([intermediateTextures containsObject:initialRenderGBufferDepth]) {
		MTL4RenderPipelineColorAttachmentDescriptor *depthAttachment = descriptor.colorAttachments[InitialRenderAttachmentDepth];
		depthAttachment.pixelFormat = DepthPixelFormat;
	}
	
	if ([intermediateTextures containsObject:initialRenderGBufferNormal]) {
		MTL4RenderPipelineColorAttachmentDescriptor *normalAttachment = descriptor.colorAttachments[InitialRenderAttachmentNormal];
		normalAttachment.pixelFormat = NormalPixelFormat;
	}
	
	if ([intermediateTextures containsObject:initialRenderGBufferSpecularAlbedo]) {
		MTL4RenderPipelineColorAttachmentDescriptor *specularAlbedoAttachment = descriptor.colorAttachments[InitialRenderAttachmentSpecularAlbedo];
		specularAlbedoAttachment.pixelFormat = SpecularAlbedoPixelFormat;
	}
	
	if ([intermediateTextures containsObject:initialRenderGBufferRoughness]) {
		MTL4RenderPipelineColorAttachmentDescriptor *roughnessAttachment = descriptor.colorAttachments[InitialRenderAttachmentRoughness];
		roughnessAttachment.pixelFormat = RoughnessPixelFormat;
	}
	
	if ([intermediateTextures containsObject:initialRenderGBufferMotion]) {
		MTL4RenderPipelineColorAttachmentDescriptor *motionAttachment = descriptor.colorAttachments[InitialRenderAttachmentMotion];
		motionAttachment.pixelFormat = MotionPixelFormat;
	}

	id<MTLRenderPipelineState> state = [compiler newRenderPipelineStateWithDescriptor:descriptor
																  compilerTaskOptions:nil
																				error:&error];
	
	if (error) {
		NSLog(@"%@", error);
	}
	
	return state;
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

- (id<MTLComputePipelineState>) compileRayTracingPipeline {
	NSError *error;
	id<MTLFunction> function = [pipeline.defaultLibrary newFunctionWithName:@"rayTracingKernel"];
	
	albedoTextureArgumentEncoder = [function newArgumentEncoderWithBufferIndex:RayTracingKernelAlbedoTexturesIndex];
	albedoTextureArgumentEncoder.label = @"albedoTextureArgumentEncoder";
	albedoTextureArgumentBuffer = [pipeline.device newBufferWithLength:albedoTextureArgumentEncoder.encodedLength
															   options:MTLResourceStorageModeShared];
	albedoTextureArgumentBuffer.label = @"albedoTextureArgumentBuffer";
	[albedoTextureArgumentEncoder setArgumentBuffer:albedoTextureArgumentBuffer offset:0];
	[initialRenderResidencySet addAllocation:albedoTextureArgumentBuffer];
	[rayTracingResidencySet addAllocation:albedoTextureArgumentBuffer];

	normalMapArgumentEncoder = [function newArgumentEncoderWithBufferIndex:RayTracingKernelNormalMapsIndex];
	normalMapArgumentEncoder.label = @"normalMapArgumentEncoder";
	normalMapArgumentBuffer = [pipeline.device newBufferWithLength:normalMapArgumentEncoder.encodedLength
														   options:MTLResourceStorageModeShared];
	normalMapArgumentBuffer.label = @"normalMapArgumentBuffer";
	[normalMapArgumentEncoder setArgumentBuffer:normalMapArgumentBuffer offset:0];
	[initialRenderResidencySet addAllocation:normalMapArgumentBuffer];
	[rayTracingResidencySet addAllocation:normalMapArgumentBuffer];

	emissionMapArgumentEncoder = [function newArgumentEncoderWithBufferIndex:RayTracingKernelEmissionMapsIndex];
	emissionMapArgumentEncoder.label = @"emissionMapArgumentEncoder";
	emissionMapArgumentBuffer = [pipeline.device newBufferWithLength:emissionMapArgumentEncoder.encodedLength
														   options:MTLResourceStorageModeShared];
	emissionMapArgumentBuffer.label = @"emissionMapArgumentBuffer";
	[emissionMapArgumentEncoder setArgumentBuffer:emissionMapArgumentBuffer offset:0];
	[initialRenderResidencySet addAllocation:emissionMapArgumentBuffer];
	[rayTracingResidencySet addAllocation:emissionMapArgumentBuffer];

	id<MTLComputePipelineState> state = [pipeline.device newComputePipelineStateWithFunction:function
																			  error:&error];
	
	if (error) {
		NSLog(@"%@", error);
	}
	
	return state;
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
	[initialRenderResidencySet removeAllAllocations];
	[rayTracingResidencySet removeAllAllocations];
	[finalRenderResidencySet removeAllAllocations];
	[pipeline.commandQueue removeResidencySet:initialRenderResidencySet];
	[pipeline.commandQueue removeResidencySet:rayTracingResidencySet];
	[pipeline.commandQueue removeResidencySet:finalRenderResidencySet];
	
	staticIASManager = nil;
	dynamicIASManager = nil;
	pipeline = nil;
	
	textureIDs = nil;
	albedoTextures = nil;
	normalMaps = nil;
	emissionMaps = nil;
	staticTriangles = nil;
	dynamicTriangles = nil;
	dynamicPolygonPrimitives = nil;
	
	metalLayer = nil;
	
	if (renderer) {
		SDL_DestroyRenderer(renderer);
		renderer = nil;
	}
	
	window = nil;
}

- (void) updateViewWithOrigin:(simd_int3)newOrigin pitch:(float)newPitch yaw:(float)newYaw FOV:(float)newFOV weaponFlare:(float)newWeaponFlare flashlight:(float)newFlashlight isInMedium:(bool)newIsInMedium {
	origin = newOrigin;
	fov = newFOV;
	pitch = newPitch;
	yaw = newYaw;
	weaponFlare = newWeaponFlare;
	flashlight = newFlashlight;
	isInMedium = newIsInMedium;
}

- (void) updateSky:(Sky)newSky {
	sky = newSky;
}

simd_int3 transform(simd_int3 position, simd_float4x4 matrix) {
	simd_float4 transformed = simd_mul(matrix, simd_make_float4(position.x, position.y, position.z, 1.0));
	return simd_make_int3(transformed.x, transformed.y, transformed.z);
}

- (void)addStaticPolygon:(MetalPolygon *)polygon {
	[polygon eachTriangle:^(Triangle *triangle) {
		[self->staticTriangles addObject:triangle];
	}];
	assert(staticTriangles.count < MAX_TRIANGLES);
}

- (void)addStaticWall:(MetalWall *)wall {
	[wall eachTriangle:^(Triangle *triangle) {
		[self->staticTriangles addObject:triangle];
	}];
	assert(staticTriangles.count < MAX_TRIANGLES);
}

- (uint32_t)addInstanceData:(RayTracingData)instanceData {
	// Purposefully skip index 0, which is shorthand for "use the per-primitive data"
	uint32_t instanceID = ++numInstances;
	assert(numInstances < MAX_INSTANCES);
	*(RayTracingData*)(perInstanceDataBuffer.contents + sizeof(RayTracingData)*instanceID) = instanceData;
	return instanceID;
}

-(void)addDynamicPolygon:(MetalPolygon *)polygon withID:(int)ID enabled:(BOOL)isEnabled {
	Triangle __block *firstTriangle = nil;
	[polygon eachTriangle:^(Triangle *triangle) {
		if (firstTriangle == nil) firstTriangle = triangle;
		[self->dynamicTriangles addObject:triangle];
	}];
	assert(dynamicTriangles.count < MAX_TRIANGLES);

	id<ASTrianglePrimitive> primitive = [dynamicPolygonPrimitives objectForKey:[NSNumber numberWithInt:ID]];
	if (primitive == nil) {
		primitive = [polygon primitiveForTextureIDs:textureIDs];
		[dynamicIASManager addPrimitive:primitive];
		[dynamicPolygonPrimitives setObject:primitive forKey:[NSNumber numberWithInt:ID]];
	}
	
	NSUInteger textureIndex = [textureIDs indexOfObject:polygon.surface.textureID];
	NSAssert(textureIndex != NSNotFound, @"Missing dynamic polygon texture ID");

	RayTracingData instanceData = {
		.surfaceNormal = polygon.surface.normal,
		.surfaceTangent = firstTriangle.tangent,
		.material = polygon.surface.material,
		.numVertices = polygon.vertexCount,
		.textureIndex = (uint32_t)textureIndex,
		.lightSourceIndex = polygon.surface.lightSourceIndex,
	};
	for (int i = 0; i < polygon.vertexCount; i++) {
		instanceData.uv[i] = polygon.uv[i];
	}
	
	uint32_t instanceID = [self addInstanceData:instanceData];

	[dynamicIASManager addInstanceOfPrimitive:primitive
								withTransform:polygon.instanceTransform
								   instanceID:instanceID
										 mask:(isEnabled ? MASK_ALL : MASK_NONE)];
}

-(void)addDynamicWall:(MetalWall *)wall enabled:(BOOL)isEnabled {
	Triangle __block *firstTriangle = nil;
	[wall eachTriangle:^(Triangle *triangle) {
		if (firstTriangle == nil) firstTriangle = triangle;
		[self->dynamicTriangles addObject:triangle];
	}];
	assert(dynamicTriangles.count < MAX_TRIANGLES);
	
	NSUInteger textureIndex = [textureIDs indexOfObject:wall.surface.textureID];
	NSAssert(textureIndex != NSNotFound, @"Missing dynamic wall texture ID");

	RayTracingData instanceData = {
		.surfaceNormal = wall.surface.normal,
		.surfaceTangent = firstTriangle.tangent,
		.material = wall.surface.material,
		.numVertices = 4,
		.textureIndex = (uint32_t)textureIndex,
		.lightSourceIndex = wall.surface.lightSourceIndex,
	};
	instanceData.uv[0] = wall.uv.columns[0];
	instanceData.uv[1] = wall.uv.columns[1];
	instanceData.uv[2] = wall.uv.columns[2];
	instanceData.uv[3] = wall.uv.columns[3];

	uint32_t instanceID = [self addInstanceData:instanceData];

	[dynamicIASManager addInstanceOfPrimitive:verticalQuadPrimitive
								withTransform:wall.instanceTransform
								   instanceID:instanceID
										 mask:(isEnabled ? MASK_ALL : MASK_NONE)];
}

- (void) updateSprite:(MetalSprite *)sprite {
	float theta = radians(yaw);

	[sprite eachTriangle:^(Triangle *triangle) {
		[self->dynamicTriangles addObject:triangle];
	} forRotation:theta];
	assert(dynamicTriangles.count < MAX_TRIANGLES);

	NSUInteger textureIndex = [textureIDs indexOfObject:sprite.surface.textureID];
	NSAssert(textureIndex != NSNotFound, @"Missing sprite texture ID");

	RayTracingData instanceData = {
		.surfaceNormal = simd_make_float3(-cos(theta), -sin(theta), 0.0),
		// TODO: set surfaceTangent (need to take firstTriangle.tangent and rotate it)
		.material = sprite.surface.material,
		.numVertices = 4,
		.textureIndex = (uint32_t)textureIndex,
		.lightSourceIndex = -1,
	};
	instanceData.uv[0] = sprite.uv.columns[0];
	instanceData.uv[1] = sprite.uv.columns[1];
	instanceData.uv[2] = sprite.uv.columns[2];
	instanceData.uv[3] = sprite.uv.columns[3];

	uint32_t instanceID = [self addInstanceData:instanceData];

	[dynamicIASManager addInstanceOfPrimitive:verticalQuadPrimitive
								withTransform:[sprite instanceTransformForRotation:theta]
								   instanceID:instanceID
										 mask:MASK_ALL];
}

- (void) updateLightSourceIntensities:(NSArray<NSNumber *> *)intensities {
	lightSourceIntensities = intensities;
}

- (void) writeStaticTrianglesToIAS {
	NSUInteger numTriangles = staticTriangles.count;
	NSUInteger trianglesPerBatch = 100;
	
	for (int b = 0; b < numTriangles; b += trianglesPerBatch) {
		NSArray *triangles = [staticTriangles subarrayWithRange:NSMakeRange(b, MIN(trianglesPerBatch, numTriangles - b))];
		TriangleBatch *batch = [[TriangleBatch alloc] initWithTriangles:triangles
															 textureIDs:textureIDs];
		[staticIASManager addPrimitive:batch];
		simd_float4x3 transform = {
			.columns = {
				{ 1.0, 0.0, 0.0 },
				{ 0.0, 1.0, 0.0 },
				{ 0.0, 0.0, 1.0 },
				{ 0.0, 0.0, 0.0 },
			}
		};
		[staticIASManager addInstanceOfPrimitive:batch
								   withTransform:transform
									  instanceID:0
											mask:MASK_ALL];
	}
}

- (void) initializeTopLevelIAS {
	NSArray<IASManager*> *IASes = @[staticIASManager, dynamicIASManager];

	MTLIndirectAccelerationStructureInstanceDescriptor descriptors[IASes.count];

	for (int i = 0; i < IASes.count; i++) {
		descriptors[i] = (MTLIndirectAccelerationStructureInstanceDescriptor){};
		descriptors[i].accelerationStructureID = [IASes objectAtIndex:i].IASResourceID;
		descriptors[i].options = MTLAccelerationStructureInstanceOptionNone;
		descriptors[i].intersectionFunctionTableOffset = 0;
		descriptors[i].mask = 0xFF;
		descriptors[i].transformationMatrix.columns[0] = MTLPackedFloat3Make(1.0, 0.0, 0.0);
		descriptors[i].transformationMatrix.columns[1] = MTLPackedFloat3Make(0.0, 1.0, 0.0);
		descriptors[i].transformationMatrix.columns[2] = MTLPackedFloat3Make(0.0, 0.0, 1.0);
		descriptors[i].transformationMatrix.columns[3] = MTLPackedFloat3Make(0.0, 0.0, 0.0);
	}
	
	topLevelIASInstanceBuffer = [pipeline.device newBufferWithBytes:&descriptors
													length:sizeof(MTLIndirectAccelerationStructureInstanceDescriptor) * IASes.count
												   options:MTLResourceStorageModeShared];
	topLevelIASInstanceBuffer.label = @"topLevelIASInstanceBuffer";
	
	topLevelIASDescriptor = [[MTL4InstanceAccelerationStructureDescriptor alloc] init];
	topLevelIASDescriptor.instanceCount = IASes.count;
	topLevelIASDescriptor.instanceDescriptorBuffer = MTL4BufferRangeMake(topLevelIASInstanceBuffer.gpuAddress, topLevelIASInstanceBuffer.length);
	
	topLevelIAS = [pipeline.device newAccelerationStructureWithDescriptor:topLevelIASDescriptor];
	
	[rayTracingResidencySet addAllocation:topLevelIASInstanceBuffer];
	[rayTracingResidencySet addAllocation:topLevelIAS];
	[rayTracingResidencySet commit];
}

- (void) clearTopLevelIAS {
	if (topLevelIASInstanceBuffer) [rayTracingResidencySet removeAllocation:topLevelIASInstanceBuffer];
	if (topLevelIAS) [rayTracingResidencySet removeAllocation:topLevelIAS];
	topLevelIASInstanceBuffer = nil;
	topLevelIAS = nil;
}

- (void) clearLightSources {
	lightSourceIntensities = nil;
	if (lightSourcesBuffer) {
		[rayTracingResidencySet removeAllocation:lightSourcesBuffer];
		lightSourcesBuffer = nil;
	}
}

- (void) writeLightSources {
	if (lightSourceIntensities.count == 0) {
		return;
	}

	lightSourcesBuffer = [pipeline.device newBufferWithLength:sizeof(LightSource) * lightSourceIntensities.count
													  options:MTLResourceStorageModeShared];
	lightSourcesBuffer.label = @"lightSourcesBuffer";
	
	LightSource *lightSources = (LightSource*)lightSourcesBuffer.contents;
	
	for (NSUInteger i = 0; i < lightSourceIntensities.count; i++) {
		lightSources[i].intensity = lightSourceIntensities[i].floatValue;
	}
	
	[rayTracingResidencySet addAllocation:lightSourcesBuffer];
}

- (void) startUpdatingAllGeometry {
	staticTriangles = [NSMutableArray array];
	dynamicTriangles = [NSMutableArray array];
	dynamicPolygonPrimitives = [NSMutableDictionary dictionary];
	numInstances = 0;

	textureIDs = [NSMutableOrderedSet orderedSet];
	albedoTextures = [NSMutableDictionary dictionary];
	normalMaps = [NSMutableDictionary dictionary];
	emissionMaps = [NSMutableDictionary dictionary];
	[self addPlaceholderTextureWithID:PLACEHOLDER_TEXTURE_ID];

	if (!verticalQuadPrimitive) {
		// spriteQuad initializes exactly once and is reused across frames + level changes
		verticalQuadPrimitive = [[VerticalQuad alloc] init];
	}

	[staticIASManager clearGeometry];
	[dynamicIASManager clearGeometry];
	[dynamicIASManager addPrimitive:verticalQuadPrimitive];
	[self clearLightSources];

	[self clearTopLevelIAS];
}

- (void) finishUpdatingAllGeometry {
	[self writeStaticTrianglesToIAS];
	[staticIASManager commitGeometry];
	[dynamicIASManager commitGeometry];
	[self writeLightSources];

	[self initializeTopLevelIAS];
	
	[self buildAccelerationStructureWithChangesTo:@[staticIASManager, dynamicIASManager]
						  primitiveDataHasChanged:YES
											label:@"Full IAS build"];
}

- (void) startUpdatingDynamicGeometry {
	dynamicTriangles = [NSMutableArray array];
	numInstances = 0;
//	spriteTextureIDs = [NSMutableOrderedSet orderedSetWithObject:PLACEHOLDER_TEXTURE_ID];
	[dynamicIASManager clearInstances];
	[self clearLightSources];
	[self clearTopLevelIAS];
}

- (void) finishUpdatingDynamicGeometry {
	[dynamicIASManager commitInstances];
	[self writeLightSources];

	[self initializeTopLevelIAS];
	[self buildAccelerationStructureWithChangesTo:@[dynamicIASManager]
						  primitiveDataHasChanged:NO
											label:[NSString stringWithFormat:@"Dynamic IAS build (frame #%llu)", frameNumber]];
}

- (void) buildAccelerationStructureWithChangesTo:(NSArray<IASManager*>*)iasManagers
						 primitiveDataHasChanged:(BOOL)primitiveDataHasChanged
										   label:(NSString*)label {
	// Calculate largest scratch size needed
	NSMutableArray<MTL4AccelerationStructureDescriptor*> *allDescriptors = [NSMutableArray array];
	[allDescriptors addObject:topLevelIASDescriptor];
	for (IASManager *iasm in iasManagers) {
		[allDescriptors addObjectsFromArray:iasm.allASDescriptors];
	}
	
	NSUInteger scratchSize = 0;
	for (MTL4AccelerationStructureDescriptor *asd in allDescriptors) {
		NSUInteger primSize = [pipeline.device accelerationStructureSizesWithDescriptor:asd].buildScratchBufferSize;
		if (primSize > scratchSize) {
			scratchSize = primSize;
		}
	}
	
	// Build everything
	
	id<MTLBuffer> scratchBuffer = [pipeline.device newBufferWithLength:scratchSize options:MTLResourceStorageModePrivate];
	[rayTracingResidencySet addAllocation:scratchBuffer];
	[rayTracingResidencySet commit];
	
	id<MTL4CommandBuffer> commandBuffer = pipeline.commandBuffer;
	[commandBuffer beginCommandBufferWithAllocator:pipeline.commandAllocator];
	commandBuffer.label = label;

	id<MTL4ComputeCommandEncoder> encoder = [pipeline.commandBuffer computeCommandEncoder];
	encoder.label = @"Build acceleration structures";
	
	if (primitiveDataHasChanged) {
		for (IASManager *iasm in iasManagers) {
			[iasm encodeBuildCommandsForPASes:encoder
								scratchBuffer:MTL4BufferRangeMake(scratchBuffer.gpuAddress, scratchBuffer.length)];
		}
		
		[encoder barrierAfterEncoderStages:MTLStageAccelerationStructure
					   beforeEncoderStages:MTLStageAccelerationStructure
						 visibilityOptions:MTL4VisibilityOptionDevice];
	}
	
	for (IASManager *iasm in iasManagers) {
		[iasm encodeBuildCommandsForIAS:encoder
						  scratchBuffer:MTL4BufferRangeMake(scratchBuffer.gpuAddress, scratchBuffer.length)];
	}

	[encoder barrierAfterEncoderStages:MTLStageAccelerationStructure
				   beforeEncoderStages:MTLStageAccelerationStructure
					 visibilityOptions:MTL4VisibilityOptionDevice];

	[encoder buildAccelerationStructure:topLevelIAS
							 descriptor:topLevelIASDescriptor
						  scratchBuffer:MTL4BufferRangeMake(scratchBuffer.gpuAddress, scratchBuffer.length)];

	[encoder endEncoding];
	[commandBuffer endCommandBuffer];
	
	uint64_t buildSignalValue = pipeline.sharedEvent.signaledValue + 1;
	[pipeline.commandQueue commit:&commandBuffer count:1];
	[pipeline.commandQueue signalEvent:pipeline.sharedEvent value:buildSignalValue];
	bool didFinish = [pipeline.sharedEvent waitUntilSignaledValue:buildSignalValue timeoutMS:50];
	
	if (!didFinish) {
		NSLog(@"Timed out waiting for AS build at frameNumber=%llu", frameNumber);
	}
	
	[pipeline.commandAllocator reset];

	[rayTracingResidencySet removeAllocation:scratchBuffer];
	[rayTracingResidencySet commit];
}

- (bool) hasTextureWithID:(NSString*)textureID {
	return [textureIDs containsObject:textureID];
}

-(void)addTextureWithID:(NSString *)textureID albedo:(MetalImage *)albedo normal:(MetalImage *)normal emission:(MetalImage *)emission {
	NSAssert(textureIDs.count < MAX_TEXTURES, @"Exceeded texture limit");

	id<MTLTexture> albedoTexture = [self makeTextureFromImage:(albedo ? albedo : [self defaultAlbedoImage])];
	albedoTexture.label = textureID;
	[albedoTextures setObject:albedoTexture forKey:textureID];

	id<MTLTexture> normalMap = [self makeTextureFromImage:(normal ? normal : [self defaultNormalMap])];
	normalMap.label = [NSString stringWithFormat:@"%@ (normal map)", textureID];
	[normalMaps setObject:normalMap forKey:textureID];

	id<MTLTexture> emissionMap = [self makeTextureFromImage:(emission ? emission : [self defaultEmissionMap])];
	emissionMap.label = [NSString stringWithFormat:@"%@ (emission map)", textureID];
	[emissionMaps setObject:emissionMap forKey:textureID];

	[textureIDs addObject:textureID];
}

- (void) addPlaceholderTextureWithID:(NSString *)textureID {
	[self addTextureWithID:textureID albedo:nil normal:nil emission:nil];
}

- (MetalImage*) defaultAlbedoImage {
	uint32 albedoPixels[1] = { 255u | (0u << 8) | (255u << 16) | (255u << 24) };
	return [[MetalImage alloc] initWithWidth:1 height:1 pixels:albedoPixels];
}

- (MetalImage*) defaultNormalMap {
	uint32 normalPixels[1] = { 255u | (128u << 8) | (128u << 16) | (255u << 24) };
	return [[MetalImage alloc] initWithWidth:1 height:1 pixels:normalPixels];
}

- (MetalImage*) defaultEmissionMap {
	uint32 emissionPixels[1] = { 0u | (0u << 8) | (0u << 16) | (0u << 24) };
	return [[MetalImage alloc] initWithWidth:1 height:1 pixels:emissionPixels];
}

- (id<MTLTexture>) makeTextureFromImage:(MetalImage *)image {
	MTLTextureDescriptor *descriptor = [[MTLTextureDescriptor alloc] init];
	descriptor.pixelFormat = MTLPixelFormatBGRA8Unorm;
	descriptor.width = image.width;
	descriptor.height = image.height;
	
	MTLRegion region = {
		{ 0, 0, 0 },
		{ image.width, image.height, 1 }
	};

	id<MTLTexture> texture = [pipeline.device newTextureWithDescriptor:descriptor];
	[texture replaceRegion:region
			   mipmapLevel:0
				 withBytes:image.data.bytes
			   bytesPerRow:sizeof(uint32) * image.width];

	return texture;
}

- (void) begin {
	frameNumber += 1;
}

- (void) end {
	// Rotate sun and ensure position is a unit vector
	Sky adjustedSky = sky;
	simd_quatf sunRotation = simd_quaternion(fmod(frameNumber * sky.sunRotationSpeed, 2*M_PI), sky.sunRotationAxis);
	adjustedSky.sunPosition = simd_normalize(simd_mul(simd_matrix4x4(sunRotation), simd_make_float4(sky.sunPosition, 1.0)).xyz);

	Camera previousCamera = camera;
	camera.fov = fov;
	camera.origin = origin;
	camera.pitchMat = rotationMatrix(pitch, simd_make_float3(1.0, 0.0, 0.0));
	camera.yawMat = rotationMatrix(-yaw, simd_make_float3(0.0, 1.0, 0.0));
	camera.rotateDirectionMat = simd_mul(rotationMatrix(yaw, simd_make_float3(0.0, 1.0, 0.0)), rotationMatrix(-pitch, simd_make_float3(1.0, 0.0, 0.0)));
	camera.perspectiveMat = perspectiveProjection(fov, viewportSize.x, viewportSize.y);
	
	Uniforms uniforms;
	uniforms.fullPathTracing = FULL_PATH_TRACING;
	uniforms.resolution = viewportSize;
	uniforms.frameNumber = frameNumber;
	uniforms.camera = camera;
	uniforms.previousCamera = (frameNumber > 1) ? previousCamera : camera;
	uniforms.sky = adjustedSky;
	uniforms.weaponFlare = weaponFlare;
	uniforms.flashlight = flashlight;
	uniforms.isInMedium = isInMedium;
	memcpy(uniformsBuffer.contents, &uniforms, sizeof(Uniforms));
		
	id<CAMetalDrawable> currentDrawable = [metalLayer nextDrawable];

	id<MTL4CommandBuffer> commandBuffer = pipeline.commandBuffer;
	[commandBuffer beginCommandBufferWithAllocator:pipeline.commandAllocator];
	commandBuffer.label = [NSString stringWithFormat:@"Frame %llu (initial + raytracing)", frameNumber];

	[self populateTextureArgumentBuffers];
	
	[self encodeInitialRenderUpdatingFence:initialPassFence];

	[self encodeRayTracingPassToOutputTexture:rayTracingOutputTexture updatingFence:computePassFence];

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
	commandBuffer.label = [NSString stringWithFormat:@"Frame %llu (final pass)", frameNumber];

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

- (void) populateTextureArgumentBuffers {
	[albedoTextureArgumentEncoder setArgumentBuffer:albedoTextureArgumentBuffer offset:0];
	[normalMapArgumentEncoder setArgumentBuffer:normalMapArgumentBuffer offset:0];
	[emissionMapArgumentEncoder setArgumentBuffer:emissionMapArgumentBuffer offset:0];

	for (NSUInteger i = 0; i < textureIDs.count; i++) {
		id<MTLTexture> albedoTexture = albedoTextures[textureIDs[i]];
		id<MTLTexture> normalMap = normalMaps[textureIDs[i]];
		id<MTLTexture> emissionMap = emissionMaps[textureIDs[i]];

		[albedoTextureArgumentEncoder setTexture:albedoTexture atIndex:i];
		[normalMapArgumentEncoder setTexture:normalMap atIndex:i];
		[emissionMapArgumentEncoder setTexture:emissionMap atIndex:i];

		[initialRenderResidencySet addAllocation:albedoTexture];
		[initialRenderResidencySet addAllocation:normalMap];
		[initialRenderResidencySet addAllocation:emissionMap];

		[rayTracingResidencySet addAllocation:albedoTexture];
		[rayTracingResidencySet addAllocation:normalMap];
		[rayTracingResidencySet addAllocation:emissionMap];
	}

	[initialRenderResidencySet commit];
	[rayTracingResidencySet commit];
}

- (void) encodeInitialRenderUpdatingFence:(id<MTLFence>)fence
{
	// Commit any textures that were added
	[initialRenderResidencySet commit];

	MTL4RenderPassDescriptor *configuration = [MTL4RenderPassDescriptor new];

	if ([intermediateTextures containsObject:initialRenderGBufferDiffuseAlbedo]) {
		MTLRenderPassColorAttachmentDescriptor *diffuseAlbedo = configuration.colorAttachments[InitialRenderAttachmentDiffuseAlbedo];
		diffuseAlbedo.texture = initialRenderGBufferDiffuseAlbedo;
		diffuseAlbedo.loadAction = MTLLoadActionClear;
		// Render a white sky, which the raytracing pass will multiply down
		diffuseAlbedo.clearColor = MTLClearColorMake(1.0, 1.0, 1.0, 1.0);
		diffuseAlbedo.storeAction = MTLStoreActionStore;
	}

	if ([intermediateTextures containsObject:initialRenderGBufferDepth]) {
		MTLRenderPassColorAttachmentDescriptor *depth = configuration.colorAttachments[InitialRenderAttachmentDepth];
		depth.texture = initialRenderGBufferDepth;
		depth.loadAction = MTLLoadActionClear;
		depth.clearColor = MTLClearColorMake(1.0, 1.0, 1.0, 1.0);
		depth.storeAction = MTLStoreActionStore;
	}
	
	if ([intermediateTextures containsObject:initialRenderGBufferNormal]) {
		MTLRenderPassColorAttachmentDescriptor *normal = configuration.colorAttachments[InitialRenderAttachmentNormal];
		normal.texture = initialRenderGBufferNormal;
		normal.loadAction = MTLLoadActionClear;
		normal.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
		normal.storeAction = MTLStoreActionStore;
	}
	
	if ([intermediateTextures containsObject:initialRenderGBufferSpecularAlbedo]) {
		MTLRenderPassColorAttachmentDescriptor *specularAlbedo = configuration.colorAttachments[InitialRenderAttachmentSpecularAlbedo];
		specularAlbedo.texture = initialRenderGBufferSpecularAlbedo;
		specularAlbedo.loadAction = MTLLoadActionClear;
		specularAlbedo.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
		specularAlbedo.storeAction = MTLStoreActionStore;
	}
	
	if ([intermediateTextures containsObject:initialRenderGBufferRoughness]) {
		MTLRenderPassColorAttachmentDescriptor *roughness = configuration.colorAttachments[InitialRenderAttachmentRoughness];
		roughness.texture = initialRenderGBufferRoughness;
		roughness.loadAction = MTLLoadActionClear;
		roughness.clearColor = MTLClearColorMake(1.0, 1.0, 1.0, 1.0);
		roughness.storeAction = MTLStoreActionStore;
	}
	
	if ([intermediateTextures containsObject:initialRenderGBufferMotion]) {
		MTLRenderPassColorAttachmentDescriptor *motion = configuration.colorAttachments[InitialRenderAttachmentMotion];
		motion.texture = initialRenderGBufferMotion;
		motion.loadAction = MTLLoadActionClear;
		motion.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
		motion.storeAction = MTLStoreActionStore;
	}
	
	id<MTL4RenderCommandEncoder> renderPassEncoder = [pipeline.commandBuffer renderCommandEncoderWithDescriptor:configuration];
	if (!renderPassEncoder) {
		NSLog(@"Failed to create render command encoder");
		return;
	}
	renderPassEncoder.label = @"Initial render";
	
	[renderPassEncoder setRenderPipelineState:initialRenderPipeline];
	[renderPassEncoder setDepthStencilState:depthState];
	[renderPassEncoder setViewport:[self getViewportWithPixelScaling:NO]];
	
	[vertexArgumentTable setAddress:uniformsBuffer.gpuAddress atIndex:InitialRenderVertexShaderUniformsIndex];
	[vertexArgumentTable setAddress:triangleBuffer.gpuAddress atIndex:InitialRenderVertexShaderVertexDataIndex];

	[fragmentArgumentTable setAddress:uniformsBuffer.gpuAddress atIndex:InitialRenderFragmentShaderUniformsIndex];
	[fragmentArgumentTable setAddress:albedoTextureArgumentBuffer.gpuAddress atIndex:InitialRenderFragmentShaderAlbedoTexturesIndex];
	[fragmentArgumentTable setAddress:normalMapArgumentBuffer.gpuAddress atIndex:InitialRenderFragmentShaderNormalMapsIndex];
	[fragmentArgumentTable setAddress:emissionMapArgumentBuffer.gpuAddress atIndex:InitialRenderFragmentShaderEmissionMapsIndex];

	WorldVertex *target = (WorldVertex*)triangleBuffer.contents;
	NSUInteger __block numVertices = 0;

	void (^drawTriangle)(Triangle*) = ^(Triangle *triangle){
		NSAssert(numVertices/3 < MAX_TRIANGLES, @"Exceeded triangle buffer size");

		NSUInteger textureIndex = [self->textureIDs indexOfObject:triangle.surface.textureID];
		NSAssert(textureIndex != NSNotFound, @"Missing triangle texture ID");

		target[numVertices] = triangle.v0;
		target[numVertices].textureIndex = (uint32_t)textureIndex;
		target[numVertices].material = triangle.surface.material;
		target[numVertices+1] = triangle.v1;
		target[numVertices+1].textureIndex = (uint32_t)textureIndex;
		target[numVertices+1].material = triangle.surface.material;
		target[numVertices+2] = triangle.v2;
		target[numVertices+2].textureIndex = (uint32_t)textureIndex;
		target[numVertices+1].material = triangle.surface.material;

		numVertices += 3;
	};
	
	for (Triangle *triangle in staticTriangles) drawTriangle(triangle);
	for (Triangle *triangle in dynamicTriangles) drawTriangle(triangle);

	[renderPassEncoder setArgumentTable:vertexArgumentTable atStages:MTLRenderStageVertex];
	[renderPassEncoder setArgumentTable:fragmentArgumentTable atStages:MTLRenderStageFragment];
	[renderPassEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:numVertices];

	[renderPassEncoder updateFence:fence afterEncoderStages:MTLStageFragment];
	[renderPassEncoder endEncoding];
}

-(void) encodeRayTracingPassToOutputTexture:(id<MTLTexture>)outputTexture
							  updatingFence:(id<MTLFence>)fence
{
	id<MTL4ComputeCommandEncoder> encoder = [pipeline.commandBuffer computeCommandEncoder];
	if (!encoder) {
		NSLog(@"Failed to create compute command encoder");
		return;
	}
	encoder.label = @"Ray tracing";
	
	[encoder setComputePipelineState:rayTracingPipeline];
	
	[computeArgumentTable setResource:topLevelIAS.gpuResourceID atBufferIndex:RayTracingKernelAccelerationStructureIndex];
	[computeArgumentTable setAddress:uniformsBuffer.gpuAddress atIndex:RayTracingKernelUniformsIndex];
	[computeArgumentTable setAddress:perInstanceDataBuffer.gpuAddress atIndex:RayTracingKernelPerInstanceDataIndex];
	[computeArgumentTable setAddress:albedoTextureArgumentBuffer.gpuAddress atIndex:RayTracingKernelAlbedoTexturesIndex];
	[computeArgumentTable setAddress:normalMapArgumentBuffer.gpuAddress atIndex:RayTracingKernelNormalMapsIndex];
	[computeArgumentTable setAddress:emissionMapArgumentBuffer.gpuAddress atIndex:RayTracingKernelEmissionMapsIndex];
	[computeArgumentTable setAddress:lightSourcesBuffer.gpuAddress atIndex:RayTracingKernelLightSourcesIndex];
	[computeArgumentTable setTexture:outputTexture.gpuResourceID atIndex:RayTracingKernelOutImageIndex];
	[encoder setArgumentTable:computeArgumentTable];
	
	NSUInteger w = rayTracingPipeline.threadExecutionWidth;
	NSUInteger h = rayTracingPipeline.maxTotalThreadsPerThreadgroup / w;
	MTLSize threadsPerThreadgroup = MTLSizeMake( w, h, 1 );
	MTLSize threadsPerGrid = MTLSizeMake(outputTexture.width, outputTexture.height, 1);
	[encoder dispatchThreads:threadsPerGrid threadsPerThreadgroup:threadsPerThreadgroup];
	
	[encoder updateFence:fence afterEncoderStages:MTLStageDispatch];
	[encoder endEncoding];
}

-(void) encodeWaveletDenoiseUpdatingFence:(id<MTLFence>)fence {
	id<MTL4ComputeCommandEncoder> encoder = [self createComputeCommandEncoderForPipeline:denoisePipeline label:@"Denoise"];

	MTLSize threadsPerGrid = MTLSizeMake(rayTracingOutputTexture.width, rayTracingOutputTexture.height, 1);
	
	DenoiseConfig *configs = (DenoiseConfig*)denoiseConfigBuffer.contents;
	for (int i = 0; i < waveletDenoisePasses.count; i++) {
		configs[i].step = waveletDenoisePasses[i].unsignedIntValue;
	}
	
	id<MTLTexture> currentInput = rayTracingOutputTexture;
	id<MTLTexture> currentOutput = (waveletDenoisePasses.count % 2 == 1) ? postProcessingOutputTexture : postProcessingScratchTexture;

	for (int i = 0; i < waveletDenoisePasses.count; i++) {
		MTLGPUAddress configAddress = denoiseConfigBuffer.gpuAddress + (i * sizeof(DenoiseConfig));

		[computeArgumentTable setAddress:uniformsBuffer.gpuAddress atIndex:DenoisePassUniformsIndex];
		[computeArgumentTable setAddress:configAddress atIndex:DenoisePassConfigIndex];
		[computeArgumentTable setTexture:initialRenderGBufferNormal.gpuResourceID atIndex:DenoisePassNormalTextureIndex];
		[computeArgumentTable setTexture:initialRenderGBufferDepth.gpuResourceID atIndex:DenoisePassDepthTextureIndex];
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
	
	MTLSize threadsPerGrid = MTLSizeMake(rayTracingOutputTexture.width, rayTracingOutputTexture.height, 1);

	id<MTLTexture> previousOutput = (frameNumber % 2 == 0) ? postProcessingScratchTexture : postProcessingOutputTexture;
	id<MTLTexture> currentOutput  = (frameNumber % 2 == 0) ? postProcessingOutputTexture : postProcessingScratchTexture;
	
	[computeArgumentTable setAddress:uniformsBuffer.gpuAddress atIndex:TAAKernelUniformsIndex];
	[computeArgumentTable setTexture:rayTracingOutputTexture.gpuResourceID atIndex:TAAKernelInputTextureIndex];
	[computeArgumentTable setTexture:initialRenderGBufferMotion.gpuResourceID atIndex:TAAKernelMotionTextureIndex];
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
	id<MTLCommandQueue> mtl3queue = [pipeline.device newCommandQueue];
	id<MTLCommandBuffer> mtl3buffer = [mtl3queue commandBuffer];
	mtl3buffer.label = [NSString stringWithFormat:@"Frame %llu (denoise)", frameNumber];
	
	temporalScaler.colorTexture = rayTracingOutputTexture;
	temporalScaler.depthTexture = initialRenderGBufferDepth;
	temporalScaler.motionTexture = initialRenderGBufferMotion;
	temporalScaler.motionVectorScaleX = 1.0;
	temporalScaler.motionVectorScaleY = 1.0;
	temporalScaler.outputTexture = postProcessingOutputTexture;
	temporalScaler.fence = fence;
	[temporalScaler encodeToCommandBuffer:mtl3buffer];
	[mtl3buffer commit];
	[mtl3buffer waitUntilCompleted];
}

-(void) encodeTemporalDenoisedUpscaleUpdatingFence:(id<MTLFence>)fence {
	id<MTLCommandQueue> mtl3queue = [pipeline.device newCommandQueue];
	id<MTLCommandBuffer> mtl3buffer = [mtl3queue commandBuffer];
	mtl3buffer.label = [NSString stringWithFormat:@"Frame %llu (denoise)", frameNumber];
	
	temporalDenoisedScaler.colorTexture = rayTracingOutputTexture;
	temporalDenoisedScaler.diffuseAlbedoTexture = initialRenderGBufferDiffuseAlbedo;
	temporalDenoisedScaler.specularAlbedoTexture = initialRenderGBufferSpecularAlbedo;
	temporalDenoisedScaler.roughnessTexture = initialRenderGBufferRoughness;
	temporalDenoisedScaler.depthTexture = initialRenderGBufferDepth;
	temporalDenoisedScaler.normalTexture = initialRenderGBufferNormal;
	temporalDenoisedScaler.motionTexture = initialRenderGBufferMotion;
	temporalDenoisedScaler.motionVectorScaleX = 1.0;
	temporalDenoisedScaler.motionVectorScaleY = 1.0;
	temporalDenoisedScaler.outputTexture = postProcessingOutputTexture;
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
	[encoder setViewport:[self getViewportWithPixelScaling:YES]];

	[encoder setArgumentTable:vertexArgumentTable atStages:MTLRenderStageVertex];
	
	id<MTLTexture> processedOutput = (POST_PROCESSING_TYPE == NoPostProcessing) ? rayTracingOutputTexture : postProcessingOutputTexture;

	[fragmentArgumentTable setAddress:uniformsBuffer.gpuAddress atIndex:FinalRenderFragmentShaderUniformsIndex];
	[fragmentArgumentTable setTexture:initialRenderGBufferDiffuseAlbedo.gpuResourceID atIndex:FinalRenderFragmentShaderAlbedoTextureIndex];
	[fragmentArgumentTable setTexture:processedOutput.gpuResourceID atIndex:FinalRenderFragmentShaderRayTracingTextureIndex];
	[encoder setArgumentTable:fragmentArgumentTable atStages:MTLRenderStageFragment];
	[encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
	
	[encoder endEncoding];
}

- (MTLViewport) getViewportWithPixelScaling:(bool)scale {
	float multiplier = scale ? ((float) NSScreen.mainScreen.backingScaleFactor) : 1.0;

	MTLViewport viewPort;
	viewPort.originX = 0.0;
	viewPort.originY = 0.0;
	viewPort.znear = 0.0;
	viewPort.zfar = 1.0;
	viewPort.width = (double)viewportSize.x * multiplier;
	viewPort.height = (double)viewportSize.y * multiplier;
	return viewPort;
}

@end
