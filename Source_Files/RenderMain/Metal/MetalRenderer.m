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


@interface Quad : NSObject
@property (readonly, nonatomic) simd_float3 v0, v1, v2, v3;
- (Quad *) initWithV0:(simd_float3)v0 v1:(simd_float3)v1 v2:(simd_float3)v2 v3:(simd_float3)v3;
@end

@implementation Quad

- (Quad *) initWithV0:(simd_float3)v0 v1:(simd_float3)v1 v2:(simd_float3)v2 v3:(simd_float3)v3 {
	self = [super init];
	if (self) {
		_v0 = v0;
		_v1 = v1;
		_v2 = v2;
		_v3 = v3;
	}
	return self;
}

- (NSString *) description {
	return [NSString stringWithFormat:@"Quad{float3(%f,%f,%f),float3(%f,%f,%f),float3(%f,%f,%f),float3(%f,%f,%f)}", _v0.x, _v0.y, _v0.z, _v1.x, _v1.y, _v1.z, _v2.x, _v2.y, _v2.z, _v3.x, _v3.y, _v3.z];
}

@end

simd_float4x4 perspectiveProjection(float fov, float aspectRatio) {
	float fovRadians = fov * 8.0 * atan(1.0) / 360.0;
	float ys = 1.0 / tanf(fovRadians * 0.5);
	float xs = ys / aspectRatio;
	float nz = 0.1;
	
	return simd_matrix((simd_float4){  xs, 0.0, 0.0, 0.0 },
					   (simd_float4){ 0.0,  ys, 0.0, 0.0 },
					   (simd_float4){ 0.0, 0.0, 1.0, 0.0 },
					   (simd_float4){ 0.0, 0.0, -nz, 0.0 });
}

simd_float3 viewToClipSpace(VertexFloat3 worldSpace, simd_float4x4 projection) {
	VertexFloat3 clipSpace = worldSpace;

	// scale down
	clipSpace *= (1.0/8192.0);
	
	// clamp to [-1, 1]
	clipSpace = simd_clamp(clipSpace, -1.0, 1.0);

	// scale z down to [0, 1] (Metal differs from OpenGL here)
	clipSpace.z = 0.5 + 0.25 * clipSpace.z;
	
	simd_float4 homogenous = simd_make_float4(clipSpace, 1.0);
	simd_float4 projected = simd_mul(projection, homogenous);

	return projected.xyz;
}

API_AVAILABLE(macos(26.0))
@implementation MetalRenderer
{
	// External dependencies

	SDL_Window *window;
	SDL_Renderer *renderer;
	CAMetalLayer *metalLayer;

	// Variables
	
	simd_uint2 viewportSize;
	float fov;
	uint64_t frameNumber;
	
	// Metal pipeline insternals
	
	id<MTLDevice> device;
	id<MTL4CommandQueue> commandQueue;
	id<MTL4CommandBuffer> commandBuffer;
	id<MTLLibrary> defaultLibrary;
	id<MTL4ArgumentTable> argumentTable;
	id<MTLResidencySet> residencySet;
	id<MTL4CommandAllocator> commandAllocator;
	id<MTLSharedEvent> sharedEvent;
	id<MTLRenderPipelineState> renderPipelineState;

	// Shader inputs
	
	id<MTLBuffer> quadsVertexBuffer;
	id<MTLBuffer> viewportSizeBuffer;
	id<MTLBuffer> perspectiveProjectionBuffer;

	// Short-lived variables, created per frame

	NSMutableArray<Quad*> *quads;
}

- (MetalRenderer *) initializeWithWindow:(SDL_Window *)sdlWindow width:(int)width height:(int)height {
	window = sdlWindow;
	renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_PRESENTVSYNC);
	
	fov = 90.0;
	viewportSize = simd_make_uint2(width, height) * ((uint) NSScreen.mainScreen.backingScaleFactor);
	NSLog(@"viewportSize = %d, %d", viewportSize.x, viewportSize.y);
	frameNumber = 0;
	
	metalLayer = (__bridge CAMetalLayer*)SDL_RenderGetMetalLayer(renderer);

	device = metalLayer.device;

	commandQueue = [device newMTL4CommandQueue];
	commandBuffer = [device newCommandBuffer];
	defaultLibrary = [device newDefaultLibrary];

	NSError *error;
	
	MTL4ArgumentTableDescriptor *argumentTableDescriptor = [MTL4ArgumentTableDescriptor new];
	argumentTableDescriptor.maxBufferBindCount = 3;
	argumentTable = [device newArgumentTableWithDescriptor:argumentTableDescriptor
													 error:&error];
	
	if (error) {
		NSLog(@"%@", error);
		return nil;
	}
	
	MTLResidencySetDescriptor *residencySetDescriptor = [MTLResidencySetDescriptor new];
	residencySet = [device newResidencySetWithDescriptor:residencySetDescriptor
												   error:&error];
	if (error) {
		NSLog(@"%@", error);
		return nil;
	}
	
	[self setupConstantSizeBuffers];
	
	commandAllocator = [device newCommandAllocator];
	
	renderPipelineState = [self compileRenderPipeline:metalLayer.pixelFormat];
	if (!renderPipelineState) {
		return nil;
	}
	
	sharedEvent = [device newSharedEvent];
	sharedEvent.signaledValue = frameNumber;
	
	[commandQueue addResidencySet:residencySet];
	[commandQueue addResidencySet:metalLayer.residencySet];
	
	return self;
}

- (void) setupConstantSizeBuffers {
	viewportSizeBuffer = [device newBufferWithLength:sizeof(viewportSize) options:MTLResourceStorageModeShared];
	[residencySet addAllocation:viewportSizeBuffer];
	
	perspectiveProjectionBuffer = [device newBufferWithLength:sizeof(simd_float4x4) options:MTLResourceStorageModeShared];
	[residencySet addAllocation:perspectiveProjectionBuffer];
}

- (id<MTLRenderPipelineState>) compileRenderPipeline:(MTLPixelFormat) colorPixelFormat {
	NSError *error;
	id<MTL4Compiler> compiler = [device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
															error:&error];

	if (error) {
		NSLog(@"%@", error);
		return nil;
	}

	MTL4RenderPipelineDescriptor *descriptor = [self configureRenderPipeline:colorPixelFormat];
	
	id<MTLRenderPipelineState> state = [compiler newRenderPipelineStateWithDescriptor:descriptor
																  compilerTaskOptions:nil
																				error:&error];
	
	if (error) {
		NSLog(@"%@", error);
	}
	
	return state;
}

- (MTL4RenderPipelineDescriptor *) configureRenderPipeline:(MTLPixelFormat) colorPixelFormat {
	MTL4LibraryFunctionDescriptor *vertexFunction = [MTL4LibraryFunctionDescriptor new];
	vertexFunction.library = defaultLibrary;
	vertexFunction.name = @"quadShader";
	
	MTL4LibraryFunctionDescriptor *fragmentFunction = [MTL4LibraryFunctionDescriptor new];
	fragmentFunction.library = defaultLibrary;
	fragmentFunction.name = @"fragmentShader";

	MTL4RenderPipelineDescriptor *descriptor = [MTL4RenderPipelineDescriptor new];
	descriptor.label = @"Basic Metal 4 render pipeline";
	descriptor.colorAttachments[0].pixelFormat = colorPixelFormat;
	descriptor.vertexFunctionDescriptor = vertexFunction;
	descriptor.fragmentFunctionDescriptor = fragmentFunction;
	
	return descriptor;
}

- (void) updateViewWithFOV:(float)newFOV {
	NSLog(@"setting fov: %f", newFOV);
	fov = newFOV;
}

- (void) begin {
	frameNumber += 1;
	quads = [[NSMutableArray alloc] init];
}

- (void) addQuadWithVertices:(simd_long3 *)vertices {
	simd_float4x4 projection = perspectiveProjection(fov, (float)viewportSize.x/(float)viewportSize.y);

	NSLog(@"input quad: %@", [[Quad alloc] initWithV0:simd_make_float3(vertices[0].x, vertices[0].y, vertices[0].z)
												   v1:simd_make_float3(vertices[1].x, vertices[1].y, vertices[1].z)
												   v2:simd_make_float3(vertices[2].x, vertices[2].y, vertices[2].z)
												   v3:simd_make_float3(vertices[3].x, vertices[3].y, vertices[3].z)]);
	
	[quads addObject:[[Quad alloc] initWithV0:viewToClipSpace(simd_make_float3(vertices[0].x, vertices[0].y, vertices[0].z), projection)
										   v1:viewToClipSpace(simd_make_float3(vertices[1].x, vertices[1].y, vertices[1].z), projection)
										   v2:viewToClipSpace(simd_make_float3(vertices[2].x, vertices[2].y, vertices[2].z), projection)
										   v3:viewToClipSpace(simd_make_float3(vertices[3].x, vertices[3].y, vertices[3].z), projection)]];
}

- (void)loadQuads {
	NSLog(@"quads = %@", quads);
	
	QuadData quadArray[quads.count];
	for (int i = 0; i < quads.count; i++) {
		Quad *q = [quads objectAtIndex:i];
		quadArray[i].v0 = q.v0;
		quadArray[i].v1 = q.v1;
		quadArray[i].v2 = q.v2;
		quadArray[i].v3 = q.v3;
	}
	
	id<MTLBuffer> newBuffer = [device newBufferWithLength:(sizeof(QuadData) * quads.count)
													   options:MTLResourceStorageModeShared];
	memcpy(newBuffer.contents, quadArray, sizeof(QuadData) * quads.count);
	
	if (quadsVertexBuffer) {
		[residencySet removeAllocation:quadsVertexBuffer];
	}
	[residencySet addAllocation:newBuffer];
	[residencySet commit];

	quadsVertexBuffer = newBuffer;
}

- (void) end {
	[self loadQuads];

	memcpy(viewportSizeBuffer.contents, &viewportSize, sizeof(viewportSize));

	simd_float4x4 projection = perspectiveProjection(fov, (float)viewportSize.x/(float)viewportSize.y);
	memcpy(perspectiveProjectionBuffer.contents, &projection, sizeof(simd_float4x4));

	NSString *label = [NSString stringWithFormat:@"Frame %llu", frameNumber];
	
	id<CAMetalDrawable> currentDrawable = [metalLayer nextDrawable];
	
	[commandBuffer beginCommandBufferWithAllocator:commandAllocator];
	commandBuffer.label = label;
	
	MTL4RenderPassDescriptor *configuration = [MTL4RenderPassDescriptor new];
	configuration.colorAttachments[0].texture = currentDrawable.texture;
	configuration.colorAttachments[0].loadAction = MTLLoadActionClear;
	configuration.colorAttachments[0].storeAction = MTLStoreActionStore;
	
	id<MTL4RenderCommandEncoder> renderPassEncoder = [commandBuffer renderCommandEncoderWithDescriptor:configuration];
	if (!renderPassEncoder) return;
	renderPassEncoder.label = label;
	
	[renderPassEncoder setRenderPipelineState:renderPipelineState];
	
	MTLViewport viewPort;
	viewPort.originX = 0.0;
	viewPort.originY = 0.0;
	viewPort.znear = 0.0;
	viewPort.zfar = 1.0;
	viewPort.width = (double)viewportSize.x;
	viewPort.height = (double)viewportSize.y;
	[renderPassEncoder setViewport:viewPort];
	
	[argumentTable setAddress:quadsVertexBuffer.gpuAddress atIndex:0];
	[argumentTable setAddress:viewportSizeBuffer.gpuAddress atIndex:1];
	[argumentTable setAddress:perspectiveProjectionBuffer.gpuAddress atIndex:2];
	[renderPassEncoder setArgumentTable:argumentTable atStages:MTLRenderStageVertex];
	[renderPassEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:(6 * quads.count)]; // 2 triangles per quad * 3 vertices per triangle
//	[renderPassEncoder drawPrimitives:MTLPrimitiveTypeLine vertexStart:0 vertexCount:(2 * quads.count)]; // 2 line points per quad

	[renderPassEncoder endEncoding];
	[commandBuffer endCommandBuffer];
	
	[commandQueue waitForDrawable:currentDrawable];
	[commandQueue commit:&commandBuffer count:1];
	[commandQueue signalDrawable:currentDrawable];
	[currentDrawable present];
}

@end
