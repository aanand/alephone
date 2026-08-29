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


@interface Poly : NSObject
@property (readonly, nonatomic) simd_float3 *vertices;
@property (readonly, nonatomic) int vertexCount;
- (Poly *) initWithVertices:(simd_float3*)vertices count:(int)vertexCount;
@end

@implementation Poly

- (Poly *) initWithVertices:(simd_float3 *)vertices count:(int)vertexCount {
	self = [super init];
	if (self) {
		_vertices = vertices;
		_vertexCount = vertexCount;
	}
	return self;
}

- (NSString *) description {
	NSMutableString *string = [NSMutableString stringWithFormat:@"Poly(%d){", self.vertexCount];
	
	for (int i=0; i<self.vertexCount; i++) {
		simd_float3 vertex = self.vertices[i];
		[string appendString:[NSString stringWithFormat:@"float3(%f,%f,%f)", vertex.x, vertex.y, vertex.z]];
		
		if (i < self.vertexCount - 1) {
			[string appendString:@","];
		}
	}
	
	[string appendString:@"}"];
	
	return string;
}

@end

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

// Aleph One hands us camera-relative quad vertices whose dimensions seem to lie in the [-2000, 2000] range or so.
// Scaling them down doesn't affect their eventual position on the screen, but does stop them getting excised from Metal's clip-space range.
simd_float3 scaleToViewSpace(simd_float3 worldSpace) {
	return worldSpace / 2000.0;
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

	NSMutableArray<Poly*> *polygons;
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
	polygons = [[NSMutableArray alloc] init];
}

- (void) addPolygonWithVertices:(simd_float3 *)vertices count:(int)vertexCount {
	simd_float3 *scaledVertices = (simd_float3*) malloc(sizeof(simd_float3) * vertexCount);
	
	for (int i=0; i<vertexCount; i++) {
		scaledVertices[i] = scaleToViewSpace(vertices[i]);
	}
	
	Poly *polygon = [[Poly alloc] initWithVertices:scaledVertices count:vertexCount];
	[polygons addObject:polygon];
}

- (int)loadVariableSizeBuffers {
	int numTriangles = 0;
	for (int i=0; i<polygons.count; i++) {
		Poly *poly = [polygons objectAtIndex:i];
		numTriangles += poly.vertexCount - 2;
	}
		
	uint numVertices = numTriangles * 3;
	uint vertexBufferSize = sizeof(simd_float3) * numVertices;

	simd_float3 *allVertices = malloc(vertexBufferSize);

	int vertexIndex = 0;
	for (int i=0; i<polygons.count; i++) {
		Poly *poly = [polygons objectAtIndex:i];
		for (int j = 0; j < poly.vertexCount-2; j++) {
			allVertices[vertexIndex]   = poly.vertices[0];
			allVertices[vertexIndex+1] = poly.vertices[j+1];
			allVertices[vertexIndex+2] = poly.vertices[j+2];
			vertexIndex += 3;
		}
	}
	
	id<MTLBuffer> newBuffer = [device newBufferWithLength:vertexBufferSize
													   options:MTLResourceStorageModeShared];
	memcpy(newBuffer.contents, allVertices, vertexBufferSize);
	
	if (trianglesVertexBuffer) {
		[residencySet removeAllocation:trianglesVertexBuffer];
	}
	[residencySet addAllocation:newBuffer];
	[residencySet commit];

	trianglesVertexBuffer = newBuffer;
	
	return numVertices;
}

- (void) end {
	int numVertices = [self loadVariableSizeBuffers];

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
	[renderPassEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:numVertices];

	[renderPassEncoder endEncoding];
	[commandBuffer endCommandBuffer];
	
	[commandQueue waitForDrawable:currentDrawable];
	[commandQueue commit:&commandBuffer count:1];
	[commandQueue signalDrawable:currentDrawable];
	[currentDrawable present];
}

@end
