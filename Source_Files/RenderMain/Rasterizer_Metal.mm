//
//  Rasterizer_Metal.mm
//  AlephOne
//
//  Created by Aanand Prasad on 24/08/2026.
//

#include <SDL2/SDL.h>
#include <SDL2/SDL_syswm.h>

#include <Cocoa/Cocoa.h>
#include <MetalKit/MetalKit.h>
#include <dispatch/dispatch.h>

#include "Logging.h"
#include "VertexTypes.h"

API_AVAILABLE(macos(26.0))
@interface MetalRenderer : NSObject

- (MetalRenderer *) initializeWithWindow:(SDL_Window *)window
								 width:(int)width
								height:(int)height;

- (void) drawFrame;

@end

@implementation MetalRenderer
{
	SDL_Window *window;
	SDL_Renderer *renderer;
	CAMetalLayer *metalLayer;
	
	simd_uint2 viewportSize;
	uint64_t frameNumber;
	
	id<MTLDevice> device;
	id<MTL4CommandQueue> commandQueue;
	id<MTL4CommandBuffer> commandBuffer;
	id<MTLLibrary> defaultLibrary;
	id<MTL4ArgumentTable> argumentTable;
	id<MTLResidencySet> residencySet;
	id<MTL4CommandAllocator> commandAllocator;
	id<MTLBuffer> triangleVertexBuffer;
	id<MTLBuffer> viewportSizeBuffer;
	id<MTLSharedEvent> sharedEvent;
	
	id<MTLRenderPipelineState> renderPipelineState;
}

- (MetalRenderer *) initializeWithWindow:(SDL_Window *)sdlWindow width:(int)width height:(int)height {
	window = sdlWindow;
	renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_PRESENTVSYNC);
	
	viewportSize = simd_make_uint2(width, height);
	frameNumber = 0;
	
	metalLayer = (__bridge CAMetalLayer*)SDL_RenderGetMetalLayer(renderer);

	device = metalLayer.device;

	commandQueue = [device newMTL4CommandQueue];
	commandBuffer = [device newCommandBuffer];
	defaultLibrary = [device newDefaultLibrary];

	triangleVertexBuffer = [device newBufferWithLength:sizeof(TriangleData)
											   options:MTLResourceStorageModeShared];
	if (!triangleVertexBuffer) {
		logError("Couldn't create triangle vertex buffer");
		return nil;
	}
	
	NSError *error;
	
	MTL4ArgumentTableDescriptor *argumentTableDescriptor = [MTL4ArgumentTableDescriptor new];
	argumentTableDescriptor.maxBufferBindCount = 2;
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
	
	commandAllocator = [device newCommandAllocator];
	
	viewportSizeBuffer = [device newBufferWithLength:sizeof(viewportSize)
											 options:MTLResourceStorageModeShared];

	renderPipelineState = [self compileRenderPipeline:metalLayer.pixelFormat];
	if (!renderPipelineState) {
		return nil;
	}
	
	sharedEvent = [device newSharedEvent];
	sharedEvent.signaledValue = frameNumber;
	
	[residencySet addAllocation:viewportSizeBuffer];
	[residencySet addAllocation:triangleVertexBuffer];
	[residencySet commit];
	[commandQueue addResidencySet:residencySet];
	[commandQueue addResidencySet:metalLayer.residencySet];
	
	return self;
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

- (void) drawFrame {
	frameNumber += 1;
	
	NSString *label = [NSString stringWithFormat:@"Frame %llu", frameNumber];

	id<CAMetalDrawable> drawable = [metalLayer nextDrawable];

	[commandBuffer beginCommandBufferWithAllocator:commandAllocator];
	commandBuffer.label = label;
	
	id<MTL4RenderCommandEncoder> renderPassEncoder;
	MTL4RenderPassDescriptor *configuration = [MTL4RenderPassDescriptor new];
	configuration.colorAttachments[0].texture = drawable.texture;
	configuration.colorAttachments[0].loadAction = MTLLoadActionClear;
	configuration.colorAttachments[0].storeAction = MTLStoreActionStore;

	renderPassEncoder = [commandBuffer renderCommandEncoderWithDescriptor:configuration];
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
	
	const short radius = 350;
	const short angle = frameNumber % 360;
	
	TriangleData triangleData;
	triangleRedGreenBlue(radius, angle, &triangleData);
	memcpy(triangleVertexBuffer.contents, &triangleData, sizeof(TriangleData));
	memcpy(viewportSizeBuffer.contents, &viewportSize, sizeof(viewportSize));
	
	[argumentTable setAddress:triangleVertexBuffer.gpuAddress atIndex:0];
	[argumentTable setAddress:viewportSizeBuffer.gpuAddress atIndex:1];
	[renderPassEncoder setArgumentTable:argumentTable atStages:MTLRenderStageVertex];
	[renderPassEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
	[renderPassEncoder endEncoding];
	[commandBuffer endCommandBuffer];
	
	[commandQueue waitForDrawable:drawable];
	[commandQueue commit:&commandBuffer count:1];
	[commandQueue signalDrawable:drawable];
	[drawable present];
}

/// A four-component red color.
const simd_float4 red = { 1.0, 0.0, 0.0, 1.0 };

/// A four-component green color.
const simd_float4 green = { 0.0, 1.0, 0.0, 1.0 };

/// A four-component blue color.
const simd_float4 blue = { 0.0, 0.0, 1.0, 1.0 };

void triangleRedGreenBlue(float radius,
						  float rotationInDegrees,
						  TriangleData *triangleData)
{
	/// An angle, in radians, that's equal to the rotation.
	const float angle0 = (float)rotationInDegrees * M_PI / 180.0f;

	/// An angle, in radians, one-third of a circle more than the previous angle.
	///
	/// This is the equivalent of adding 120° to the first angle.
	const float angle1 = angle0 + (2.0f * M_PI  / 3.0f);

	/// An angle, in radians, one-third of a circle more than the previous angle.
	///
	/// This is the equivalent of adding 240° to the first angle.
	const float angle2 = angle0 + (4.0f * M_PI  / 3.0f);

	/// The position of the triangle's first vertex.
	simd_float2 position0 = {
		radius * cosf(angle0),
		radius * sinf(angle0)
	};

	/// The position of the triangle's second vertex.
	simd_float2 position1 = {
		radius * cosf(angle1),
		radius * sinf(angle1)
	};

	/// The position of the triangle's third vertex.
	simd_float2 position2 = {
		radius * cosf(angle2),
		radius * sinf(angle2)
	};

	// The triangle's red, bottom-right vertex.
	triangleData->vertex0.color = red;
	triangleData->vertex0.position = position0;

	// The triangle's green, bottom-left vertex.
	triangleData->vertex1.color = green;
	triangleData->vertex1.position = position1;

	// The triangle's blue, top-center vertex.
	triangleData->vertex2.color = blue;
	triangleData->vertex2.position = position2;
}

@end

API_AVAILABLE(macos(26.0))
MetalRenderer *renderer;

bool Metal_InitializeForWindow(SDL_Window* window, int width, int height) {
    logWarning("Metal_InitializeForWindow(window, %d, %d)", width, height);

	if (@available(macOS 26.0, *)) {
		if (renderer) {
			return true;
		}
		
		MetalRenderer *r = [[MetalRenderer alloc] initializeWithWindow:window width:width height:height];
		if (!r) {
			NSLog(@"Failed to initialize MetalRenderer");
			return false;
		}
		renderer = r;

		NSLog(@"Initialized MetalRenderer: %@", renderer);
		return true;
	}

	NSLog(@"Metal 4 not supported");
	return false;
}

void Metal_Begin() {
	if (@available(macOS 26.0, *)) {
		if (renderer) {
			[renderer drawFrame];
		}
	}
}
