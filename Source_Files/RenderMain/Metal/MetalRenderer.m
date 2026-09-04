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
#include <dispatch/dispatch.h>

#include "VertexTypes.h"
#include "MetalRenderer.h"

@implementation MetalImage

- (MetalImage*) initWithWidth:(NSUInteger)width height:(NSUInteger)height pixels:(const uint32 *)pixels {
	if (self = [super init]) {
		_width = width;
		_height = height;
		_data = [NSData dataWithBytes:pixels length:sizeof(uint32) * width * height];
	}
	return self;
}

@end

@interface Triangle : NSObject

@property (nonatomic, readonly) WorldVertex v0;
@property (nonatomic, readonly) WorldVertex v1;
@property (nonatomic, readonly) WorldVertex v2;
@property (nonatomic, readonly) NSNumber* textureID;

- (Triangle *) initWithV0:(WorldVertex)v0 v1:(WorldVertex)v1 v2:(WorldVertex)v2 textureID:(NSNumber*)textureID;

@end

@implementation Triangle

- (Triangle *) initWithV0:(WorldVertex)v0 v1:(WorldVertex)v1 v2:(WorldVertex)v2 textureID:(NSNumber *)textureID {
	if (self = [super init]) {
		_v0 = v0;
		_v1 = v1;
		_v2 = v2;
		_textureID = textureID;
	}
	return self;
}

@end

float radians(float degrees) {
	return degrees * 8.0 * atan(1.0) / 360.0;
}

simd_float4x4 rotationMatrix(float angle, simd_float3 axis) {
	simd_quatf quat = simd_quaternion(radians(angle), axis);
	return simd_matrix4x4(quat);
}

// Assumes fov is the horizontal FOV, not the traditional vertical one
simd_float4x4 perspectiveProjection(float fov, float aspectRatio) {
	float xs = 1.0 / tanf(radians(fov) * 0.5);
	float ys = xs * aspectRatio;
	float nz = 0.01;
	
	return simd_matrix((simd_float4){  xs, 0.0, 0.0, 0.0 },
					   (simd_float4){ 0.0,  ys, 0.0, 0.0 },
					   (simd_float4){ 0.0, 0.0, 1.0, 1.0 },
					   (simd_float4){ 0.0, 0.0, -nz, 0.0 });
}

uint MAX_TRIANGLES = 10000;

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

	uint64_t frameNumber;
	
	// Metal pipeline internals
	
	id<MTLDevice> device;
	id<MTL4CommandQueue> commandQueue;
	id<MTL4CommandBuffer> commandBuffer;
	id<MTLLibrary> defaultLibrary;
	id<MTL4CommandAllocator> commandAllocator;
	id<MTLSharedEvent> sharedEvent;

	id<MTLRenderPipelineState> initialRenderPipeline;
	id<MTLComputePipelineState> rayTracingPipeline;
	id<MTLRenderPipelineState> finalRenderPipeline;
	id<MTLDepthStencilState> depthState;

	id<MTL4ArgumentTable> vertexArgumentTable;
	id<MTL4ArgumentTable> fragmentArgumentTable;
	id<MTL4ArgumentTable> computeArgumentTable;

	id<MTLResidencySet> initialRenderResidencySet;
	id<MTLResidencySet> rayTracingResidencySet;
	id<MTLResidencySet> finalRenderResidencySet;
	
	id<MTLTexture> initialRenderOutputTexture;
	id<MTLTexture> rayTracingOutputTexture;

	// Shader inputs
	
	id<MTLBuffer> triangleBuffer;
	id<MTLBuffer> cameraBuffer;

	id<MTLAccelerationStructure> primitiveAccelerationStructure;
	id<MTLAccelerationStructure> instanceAccelerationStructure;
	id<MTLBuffer> accelerationStructureVertexBuffer;
	id<MTLBuffer> accelerationStructureInstanceBuffer;

	// Data loaded in from the game

	NSMutableDictionary<NSNumber *, id<MTLTexture>> *textures;
	NSMutableArray<Triangle *> *triangles;
}

- (MetalRenderer *) initializeWithWindow:(SDL_Window *)sdlWindow width:(int)width height:(int)height {
	window = sdlWindow;
	renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_PRESENTVSYNC);
	
	fov = 90.0;
	viewportSize = simd_make_uint2(width, height) * ((uint) NSScreen.mainScreen.backingScaleFactor);
	frameNumber = 0;
	
	metalLayer = (__bridge CAMetalLayer*)SDL_RenderGetMetalLayer(renderer);

	device = metalLayer.device;

	commandQueue = [device newMTL4CommandQueue];
	commandBuffer = [device newCommandBuffer];
	defaultLibrary = [device newDefaultLibrary];
	commandAllocator = [device newCommandAllocator];
	sharedEvent = [device newSharedEvent];
	sharedEvent.signaledValue = frameNumber;

	initialRenderPipeline = [self compileInitialRenderPipeline:metalLayer.pixelFormat];
	if (!initialRenderPipeline) {
		return nil;
	}
	
	rayTracingPipeline = [self compileRayTracingPipeline];
	if (!rayTracingPipeline) {
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
	if (![self setupResidencySets]) {
		return nil;
	}

	[self setupIntermediateTextures];
	[self setupBuffers];
	
	[initialRenderResidencySet commit];
	[rayTracingResidencySet commit];
	[finalRenderResidencySet commit];
	
	textures = [NSMutableDictionary dictionary];
	triangles = [NSMutableArray array];
	
	return self;
}

- (bool) setupArgumentTables {
	NSError *error;
	
	MTL4ArgumentTableDescriptor *vertexArgumentTableDescriptor = [MTL4ArgumentTableDescriptor new];
	vertexArgumentTableDescriptor.maxBufferBindCount = MAX(InitialRenderVertexShader_NumBuffers, FinalRenderVertexShader_NumBuffers);
	vertexArgumentTable = [device newArgumentTableWithDescriptor:vertexArgumentTableDescriptor error:&error];
	if (error) {
		NSLog(@"%@", error);
		return false;
	}
	
	MTL4ArgumentTableDescriptor *fragmentArgumentTableDescriptor = [MTL4ArgumentTableDescriptor new];
	fragmentArgumentTableDescriptor.maxTextureBindCount = MAX(InitialRenderFragmentShader_NumTextures, FinalRenderFragmentShader_NumTextures);
	fragmentArgumentTable = [device newArgumentTableWithDescriptor:fragmentArgumentTableDescriptor error:&error];
	if (error) {
		NSLog(@"%@", error);
		return false;
	}
	
	MTL4ArgumentTableDescriptor *computeArgumentTableDescriptor = [MTL4ArgumentTableDescriptor new];
	computeArgumentTableDescriptor.maxBufferBindCount = RayTracingKernel_NumBuffers;
	computeArgumentTableDescriptor.maxTextureBindCount = RayTracingKernel_NumTextures;
	computeArgumentTable = [device newArgumentTableWithDescriptor:computeArgumentTableDescriptor error:&error];
	if (error) {
		NSLog(@"%@", error);
		return false;
	}

	return true;
}

- (bool) setupResidencySets {
	NSError *error;

	MTLResidencySetDescriptor *residencySetDescriptor = [MTLResidencySetDescriptor new];
	initialRenderResidencySet = [device newResidencySetWithDescriptor:residencySetDescriptor
												   error:&error];
	if (error) {
		NSLog(@"%@", error);
		return false;
	}
	
	rayTracingResidencySet = [device newResidencySetWithDescriptor:residencySetDescriptor
															 error:&error];
	if (error) {
		NSLog(@"%@", error);
		return false;
	}

	finalRenderResidencySet = [device newResidencySetWithDescriptor:residencySetDescriptor
															  error:&error];
	if (error) {
		NSLog(@"%@", error);
		return false;
	}
	
	[commandQueue addResidencySet:initialRenderResidencySet];
	[commandQueue addResidencySet:rayTracingResidencySet];
	[commandQueue addResidencySet:finalRenderResidencySet];
	[commandQueue addResidencySet:metalLayer.residencySet];

	return true;
}

- (void) setupBuffers {
	cameraBuffer = [device newBufferWithLength:sizeof(Camera) options:MTLResourceStorageModeShared];
	[initialRenderResidencySet addAllocation:cameraBuffer];
	
	triangleBuffer = [device newBufferWithLength:(sizeof(WorldVertex) * MAX_TRIANGLES * 3) options:MTLResourceStorageModeShared];
	[initialRenderResidencySet addAllocation:triangleBuffer];
}

- (void) setupIntermediateTextures {
	MTLTextureDescriptor *textureDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:metalLayer.pixelFormat
																								 width:viewportSize.x
																								height:viewportSize.y
																							 mipmapped:NO];
	textureDescriptor.storageMode = MTLStorageModePrivate;

	textureDescriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
	initialRenderOutputTexture = [device newTextureWithDescriptor:textureDescriptor];

	textureDescriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
	rayTracingOutputTexture = [device newTextureWithDescriptor:textureDescriptor];
	
	[rayTracingResidencySet addAllocation:rayTracingOutputTexture];
	[finalRenderResidencySet addAllocation:initialRenderOutputTexture];
	[finalRenderResidencySet addAllocation:rayTracingOutputTexture];
}

- (id<MTLRenderPipelineState>) compileInitialRenderPipeline:(MTLPixelFormat) colorPixelFormat {
	NSError *error;
	id<MTL4Compiler> compiler = [device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
															error:&error];

	if (error) {
		NSLog(@"%@", error);
		return nil;
	}

	MTL4LibraryFunctionDescriptor *vertexFunction = [MTL4LibraryFunctionDescriptor new];
	vertexFunction.library = defaultLibrary;
	vertexFunction.name = @"initialRenderVertexShader";
	
	MTL4LibraryFunctionDescriptor *fragmentFunction = [MTL4LibraryFunctionDescriptor new];
	fragmentFunction.library = defaultLibrary;
	fragmentFunction.name = @"initialRenderFragmentShader";

	MTL4RenderPipelineDescriptor *descriptor = [MTL4RenderPipelineDescriptor new];
	descriptor.label = @"Initial Render";
	descriptor.vertexFunctionDescriptor = vertexFunction;
	descriptor.fragmentFunctionDescriptor = fragmentFunction;

	MTL4RenderPipelineColorAttachmentDescriptor *colorAttachment = descriptor.colorAttachments[0];
	colorAttachment.pixelFormat = colorPixelFormat;
	colorAttachment.blendingState = MTL4BlendStateEnabled;
	colorAttachment.sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
	colorAttachment.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
	colorAttachment.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
	colorAttachment.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;

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
	id<MTL4Compiler> compiler = [device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
															error:&error];
	
	if (error) {
		NSLog(@"%@", error);
		return nil;
	}

	MTL4LibraryFunctionDescriptor *vertexFunction = [MTL4LibraryFunctionDescriptor new];
	vertexFunction.library = defaultLibrary;
	vertexFunction.name = @"finalRenderVertexShader";
	
	MTL4LibraryFunctionDescriptor *fragmentFunction = [MTL4LibraryFunctionDescriptor new];
	fragmentFunction.library = defaultLibrary;
	fragmentFunction.name = @"finalRenderFragmentShader";
	
	MTL4RenderPipelineDescriptor *descriptor = [MTL4RenderPipelineDescriptor new];
	descriptor.label = @"Final Render";
	descriptor.vertexFunctionDescriptor = vertexFunction;
	descriptor.fragmentFunctionDescriptor = fragmentFunction;
	
	MTL4RenderPipelineColorAttachmentDescriptor *colorAttachment = descriptor.colorAttachments[0];
	colorAttachment.pixelFormat = colorPixelFormat;
	// TODO: configure blending
	
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
	return [device newDepthStencilStateWithDescriptor:depthDescriptor];
}

- (id<MTLComputePipelineState>) compileRayTracingPipeline {
	NSError *error;
	id<MTLFunction> function = [defaultLibrary newFunctionWithName:@"rayTracingKernel"];
	
	id<MTLComputePipelineState> state = [device newComputePipelineStateWithFunction:function
																			  error:&error];
	
	if (error) {
		NSLog(@"%@", error);
	}
	
	return state;
}

- (void) updateViewWithOrigin:(simd_int3)newOrigin pitch:(float)newPitch yaw:(float)newYaw FOV:(float)newFOV {
	origin = newOrigin;
	fov = newFOV;
	pitch = newPitch;
	yaw = newYaw;
}

- (void) addPolygonWithVertices:(WorldVertex *)vertices count:(NSUInteger)vertexCount textureID:(NSNumber*)textureID {
	assert(vertexCount > 2);
	
	// Triangle fan: draw 0-1-2, 0-2-3, 0-3-4, etc
	for (int j = 0; j < vertexCount-2; j++) {
		[triangles addObject:[[Triangle alloc] initWithV0:*(vertices)
													   v1:*(vertices+j+1)
													   v2:*(vertices+j+2)
												textureID:textureID]];

		assert(triangles.count < MAX_TRIANGLES);
	}
}

- (void) commitGeometry {
	simd_float3 vertices[triangles.count * 3];
	for (int i = 0; i < triangles.count; i++) {
		Triangle *triangle = [triangles objectAtIndex:i];
		vertices[i*3+0] = simd_make_float3(triangle.v0.position.x, triangle.v0.position.y, triangle.v0.position.z);
		vertices[i*3+1] = simd_make_float3(triangle.v1.position.x, triangle.v1.position.y, triangle.v1.position.z);
		vertices[i*3+2] = simd_make_float3(triangle.v2.position.x, triangle.v2.position.y, triangle.v2.position.z);
	}
	
	accelerationStructureVertexBuffer = [device newBufferWithBytes:vertices
															length:sizeof(simd_float3) * triangles.count * 3
														   options:MTLResourceStorageModeShared];

	MTLAccelerationStructureTriangleGeometryDescriptor *geometryDescriptor = [MTLAccelerationStructureTriangleGeometryDescriptor descriptor];
	geometryDescriptor.triangleCount = triangles.count;
	geometryDescriptor.vertexBuffer = accelerationStructureVertexBuffer;
	geometryDescriptor.vertexFormat = MTLAttributeFormatFloat3;
	
	MTLPrimitiveAccelerationStructureDescriptor *primitiveASDescriptor = [MTLPrimitiveAccelerationStructureDescriptor descriptor];
	primitiveASDescriptor.geometryDescriptors = @[ geometryDescriptor ];
	
	primitiveAccelerationStructure = [device newAccelerationStructureWithDescriptor:primitiveASDescriptor];
	
	MTLAccelerationStructureInstanceDescriptor instanceDescriptor;
	instanceDescriptor.accelerationStructureIndex = 0;
	instanceDescriptor.options = MTLAccelerationStructureInstanceOptionOpaque;
	instanceDescriptor.intersectionFunctionTableOffset = 0;
	instanceDescriptor.mask = 0;
	instanceDescriptor.transformationMatrix.columns[0] = MTLPackedFloat3Make(1.0, 0.0, 0.0);
	instanceDescriptor.transformationMatrix.columns[1] = MTLPackedFloat3Make(0.0, 1.0, 0.0);
	instanceDescriptor.transformationMatrix.columns[2] = MTLPackedFloat3Make(0.0, 0.0, 1.0);

	uint instanceCount = 1;
	
	accelerationStructureInstanceBuffer = [device newBufferWithBytes:&instanceDescriptor
															  length:sizeof(instanceDescriptor) * instanceCount
															 options:MTLResourceStorageModeShared];

	MTLInstanceAccelerationStructureDescriptor *instanceASDescriptor = [MTLInstanceAccelerationStructureDescriptor descriptor];
	instanceASDescriptor.instanceCount = instanceCount;
	instanceASDescriptor.instanceDescriptorBuffer = accelerationStructureInstanceBuffer;

	instanceAccelerationStructure = [device newAccelerationStructureWithDescriptor:instanceASDescriptor];
	
	[self clearGeometry];

	[rayTracingResidencySet addAllocation:accelerationStructureVertexBuffer];
	[rayTracingResidencySet addAllocation:accelerationStructureInstanceBuffer];
	[rayTracingResidencySet addAllocation:primitiveAccelerationStructure];
	[rayTracingResidencySet addAllocation:instanceAccelerationStructure];
	[rayTracingResidencySet commit];
}

- (void) clearGeometry {
	if (instanceAccelerationStructure) {
		[rayTracingResidencySet removeAllocation:accelerationStructureVertexBuffer];
		[rayTracingResidencySet removeAllocation:accelerationStructureInstanceBuffer];
		[rayTracingResidencySet removeAllocation:primitiveAccelerationStructure];
		[rayTracingResidencySet removeAllocation:instanceAccelerationStructure];
		[rayTracingResidencySet commit];
	}
}

- (bool) hasTextureWithID:(NSNumber*)textureID {
	return [textures objectForKey:textureID] != nil;
}

- (void) addTextureWithID:(NSNumber*)textureID image:(MetalImage *)image {
	MTLTextureDescriptor *descriptor = [[MTLTextureDescriptor alloc] init];
	descriptor.pixelFormat = MTLPixelFormatBGRA8Unorm;
	descriptor.width = image.width;
	descriptor.height = image.height;
	
	MTLRegion region = {
		{ 0, 0, 0 },
		{ image.width, image.height, 1 }
	};

	id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
	[texture replaceRegion:region
			   mipmapLevel:0
				 withBytes:image.data.bytes
			   bytesPerRow:sizeof(uint32) * image.width];
	
	[textures setObject:texture forKey:textureID];
	[initialRenderResidencySet addAllocation:texture];
}

- (void) begin {
	frameNumber += 1;
}

- (void) end {
	Camera camera;
	camera.origin = origin;
	camera.pitchMat = rotationMatrix(pitch, simd_make_float3(1.0, 0.0, 0.0));
	camera.yawMat = rotationMatrix(-yaw, simd_make_float3(0.0, 1.0, 0.0));
	camera.perspectiveMat = perspectiveProjection(fov, (float)viewportSize.x/(float)viewportSize.y);
	memcpy(cameraBuffer.contents, &camera, sizeof(Camera));
		
	id<CAMetalDrawable> currentDrawable = [metalLayer nextDrawable];

	[commandBuffer beginCommandBufferWithAllocator:commandAllocator];
	commandBuffer.label = [NSString stringWithFormat:@"Frame %llu", frameNumber];
	
	[self encodeInitialRenderToOutputTexture:initialRenderOutputTexture];
	[self encodeRayTracingPassToOutputTexture:rayTracingOutputTexture];
	[self encodeFinalRenderFromInitialPassTexture:initialRenderOutputTexture
							rayTracingPassTexture:rayTracingOutputTexture
								  toOutputTexture:currentDrawable.texture];

	[commandBuffer endCommandBuffer];

	[commandQueue waitForDrawable:currentDrawable];
	[commandQueue commit:&commandBuffer count:1];
	[commandQueue signalDrawable:currentDrawable];
	[currentDrawable present];
}

- (void) encodeInitialRenderToOutputTexture:(id<MTLTexture>)outputTexture {
	// Commit any textures that were added
	[initialRenderResidencySet commit];

	MTL4RenderPassDescriptor *configuration = [MTL4RenderPassDescriptor new];
	configuration.colorAttachments[0].texture = outputTexture;
	configuration.colorAttachments[0].storeAction = MTLStoreActionStore;

	id<MTL4RenderCommandEncoder> renderPassEncoder = [commandBuffer renderCommandEncoderWithDescriptor:configuration];
	if (!renderPassEncoder) {
		NSLog(@"Failed to create render command encoder");
		return;
	}
	renderPassEncoder.label = @"Initial render";
	
	[renderPassEncoder setRenderPipelineState:initialRenderPipeline];
	[renderPassEncoder setDepthStencilState:depthState];
	[renderPassEncoder setViewport:[self getViewport]];
	
	[vertexArgumentTable setAddress:cameraBuffer.gpuAddress atIndex:InitialRenderVertexShaderCameraIndex];
	[vertexArgumentTable setAddress:triangleBuffer.gpuAddress atIndex:InitialRenderVertexShaderVertexDataIndex];

	WorldVertex *target = (WorldVertex*)triangleBuffer.contents;
	NSUInteger offset = 0;
	
	for (int i = 0; i < triangles.count; i++) {
		Triangle *triangle = [triangles objectAtIndex:i];

		target[offset] = triangle.v0;
		target[offset+1] = triangle.v1;
		target[offset+2] = triangle.v2;
		
		MTLGPUAddress address = triangleBuffer.gpuAddress + (offset * sizeof(WorldVertex));
		[vertexArgumentTable setAddress:address atIndex:InitialRenderVertexShaderVertexDataIndex];
		[renderPassEncoder setArgumentTable:vertexArgumentTable atStages:MTLRenderStageVertex];

		id<MTLTexture> texture = [textures objectForKey:triangle.textureID];
		[fragmentArgumentTable setTexture:texture.gpuResourceID atIndex:InitialRenderFragmentShaderColorTextureIndex];
		[renderPassEncoder setArgumentTable:fragmentArgumentTable atStages:MTLRenderStageFragment];
		
		[renderPassEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
		
		offset += 3;
	}

	[renderPassEncoder endEncoding];
}

-(void) encodeRayTracingPassToOutputTexture:(id<MTLTexture>)outputTexture {
	id<MTL4ComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
	if (!encoder) {
		NSLog(@"Failed to create compute command encoder");
		return;
	}
	encoder.label = @"Ray tracing";
	
	[encoder setComputePipelineState:rayTracingPipeline];
	
	[computeArgumentTable setResource:instanceAccelerationStructure.gpuResourceID atBufferIndex:RayTracingKernelAccelerationStructureIndex];
	[computeArgumentTable setAddress:cameraBuffer.gpuAddress atIndex:RayTracingKernelCameraIndex];
	[computeArgumentTable setTexture:outputTexture.gpuResourceID atIndex:RayTracingKernelOutImageIndex];
	[encoder setArgumentTable:computeArgumentTable];
	
	NSUInteger w = rayTracingPipeline.threadExecutionWidth;
	NSUInteger h = rayTracingPipeline.maxTotalThreadsPerThreadgroup / w;
	MTLSize threadsPerThreadgroup = MTLSizeMake( w, h, 1 );
	MTLSize threadsPerGrid = MTLSizeMake(outputTexture.width, outputTexture.height, 1);
	[encoder dispatchThreads:threadsPerGrid threadsPerThreadgroup:threadsPerThreadgroup];
	
	[encoder endEncoding];
}

-(void) encodeFinalRenderFromInitialPassTexture:(id<MTLTexture>)initialPassTexture
						  rayTracingPassTexture:(id<MTLTexture>)rayTracingPassTexture
								toOutputTexture:(id<MTLTexture>)outputTexture
{
	MTL4RenderPassDescriptor *configuration = [MTL4RenderPassDescriptor new];
	configuration.colorAttachments[0].texture = outputTexture;
	configuration.colorAttachments[0].storeAction = MTLStoreActionStore;

	id<MTL4RenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:configuration];
	if (!encoder) {
		NSLog(@"Failed to create render command encoder");
		return;
	}
	encoder.label = @"Final render";
	
	[encoder setRenderPipelineState:finalRenderPipeline];
	[encoder setViewport:[self getViewport]];

	[encoder setArgumentTable:vertexArgumentTable atStages:MTLRenderStageVertex];

	[fragmentArgumentTable setTexture:initialPassTexture.gpuResourceID atIndex:FinalRenderFragmentShaderInitialPassTextureIndex];
	[fragmentArgumentTable setTexture:rayTracingPassTexture.gpuResourceID atIndex:FinalRenderFragmentShaderRayTracingPassTextureIndex];
	[encoder setArgumentTable:fragmentArgumentTable atStages:MTLRenderStageFragment];
	[encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
	
	[encoder endEncoding];
}

- (MTLViewport) getViewport {
	MTLViewport viewPort;
	viewPort.originX = 0.0;
	viewPort.originY = 0.0;
	viewPort.znear = 0.0;
	viewPort.zfar = 1.0;
	viewPort.width = (double)viewportSize.x;
	viewPort.height = (double)viewportSize.y;
	return viewPort;
}

@end
