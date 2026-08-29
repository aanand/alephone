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


// Assumes fov is the horizontal FOV, not the traditional vertical one
simd_float4x4 perspectiveProjection(float fov, float aspectRatio) {
	float fovRadians = fov * 8.0 * atan(1.0) / 360.0;
	float xs = 1.0 / tanf(fovRadians * 0.5);
	float ys = xs * aspectRatio;
	float nz = 0.01;
	
	return simd_matrix((simd_float4){  xs, 0.0, 0.0, 0.0 },
					   (simd_float4){ 0.0,  ys, 0.0, 0.0 },
					   (simd_float4){ 0.0, 0.0, 1.0, 1.0 },
					   (simd_float4){ 0.0, 0.0, -nz, 0.0 });
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
	simd_int3 origin;

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
	
	id<MTLBuffer> trianglesVertexBuffer;

	id<MTLBuffer> viewportSizeBuffer;
	id<MTLBuffer> perspectiveProjectionBuffer;

	// Short-lived variables, created per frame

	int numTriangleVertices;
	NSMutableData *triangleVertexData;
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
	vertexFunction.name = @"vertexShader";
	
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
	fov = newFOV;
}

- (void) begin {
	frameNumber += 1;
	
	numTriangleVertices = 0;
	triangleVertexData = [NSMutableData data];
}

- (void) addPolygonWithVertices:(simd_float3 *)vertices count:(int)vertexCount {
	assert(vertexCount > 2);
	
	// Triangle fan: draw 0-1-2, 0-2-3, 0-3-4, etc
	for (int j = 0; j < vertexCount-2; j++) {
		[self addVertex:vertices];
		[self addVertex:vertices+j+1];
		[self addVertex:vertices+j+2];
		numTriangleVertices += 3;
	}
}

- (void) addVertex:(simd_float3*)position {
	Vertex vertex;
	vertex.position = *position;
	vertex.textureCoordinate = simd_make_float2(0.0, 0.0);
	[triangleVertexData appendBytes:&vertex length:sizeof(Vertex)];
}

- (void) loadVariableSizeBuffers {
	id<MTLBuffer> newBuffer = [device newBufferWithBytes:triangleVertexData.bytes
												  length:triangleVertexData.length
												 options:MTLResourceStorageModeShared];
	
	if (trianglesVertexBuffer) {
		[residencySet removeAllocation:trianglesVertexBuffer];
	}
	[residencySet addAllocation:newBuffer];
	[residencySet commit];

	trianglesVertexBuffer = newBuffer;
}

- (void) end {
	[self loadVariableSizeBuffers];

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
	
	[argumentTable setAddress:trianglesVertexBuffer.gpuAddress atIndex:0];
	[argumentTable setAddress:viewportSizeBuffer.gpuAddress atIndex:1];
	[argumentTable setAddress:perspectiveProjectionBuffer.gpuAddress atIndex:2];
	[renderPassEncoder setArgumentTable:argumentTable atStages:MTLRenderStageVertex];
	[renderPassEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:numTriangleVertices];

	[renderPassEncoder endEncoding];
	[commandBuffer endCommandBuffer];
	
	[commandQueue waitForDrawable:currentDrawable];
	[commandQueue commit:&commandBuffer count:1];
	[commandQueue signalDrawable:currentDrawable];
	[currentDrawable present];
}

@end
