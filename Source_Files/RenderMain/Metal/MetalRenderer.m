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

@property (nonatomic, readonly) Vertex v0;
@property (nonatomic, readonly) Vertex v1;
@property (nonatomic, readonly) Vertex v2;
@property (nonatomic, readonly) NSNumber* textureID;

- (Triangle *) initWithV0:(Vertex)v0 v1:(Vertex)v1 v2:(Vertex)v2 textureID:(NSNumber*)textureID;

@end

@implementation Triangle

- (Triangle *) initWithV0:(Vertex)v0 v1:(Vertex)v1 v2:(Vertex)v2 textureID:(NSNumber *)textureID {
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

simd_float4x4 pitchMatrix(float angle) {
	simd_quatf quat = simd_quaternion(radians(angle), simd_make_float3(1.0, 0.0, 0.0));
	return simd_matrix4x4(quat);
}

simd_float4x4 toWorldSpaceMatrix(float yaw) {
	simd_quatf quat = simd_quaternion(radians(-yaw), simd_make_float3(0.0, 1.0, 0.0));
	return simd_matrix4x4(quat);
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
	float fov, pitch, yaw;
	simd_int3 origin;

	uint64_t frameNumber;
	
	// Metal pipeline internals
	
	id<MTLDevice> device;
	id<MTL4CommandQueue> commandQueue;
	id<MTL4CommandBuffer> commandBuffer;
	id<MTLLibrary> defaultLibrary;
	id<MTL4ArgumentTable> vertexArgumentTable;
	id<MTL4ArgumentTable> fragmentArgumentTable;
	id<MTLResidencySet> residencySet;
	id<MTL4CommandAllocator> commandAllocator;
	id<MTLSharedEvent> sharedEvent;
	id<MTLRenderPipelineState> renderPipelineState;
	id<MTLDepthStencilState> depthState;

	// Shader inputs
	
	id<MTLBuffer> triangleBuffer;
	id<MTLBuffer> cameraBuffer;

	NSMutableDictionary<NSNumber *, id<MTLTexture>> *textures;

	// Short-lived variables, created per frame

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

	NSError *error;
	
	MTL4ArgumentTableDescriptor *vertexArgumentTableDescriptor = [MTL4ArgumentTableDescriptor new];
	vertexArgumentTableDescriptor.maxBufferBindCount = 3;
	vertexArgumentTable = [device newArgumentTableWithDescriptor:vertexArgumentTableDescriptor error:&error];
	if (error) {
		NSLog(@"%@", error);
		return nil;
	}
	
	MTL4ArgumentTableDescriptor *fragmentArgumentTableDescriptor = [MTL4ArgumentTableDescriptor new];
	fragmentArgumentTableDescriptor.maxTextureBindCount = 1;
	fragmentArgumentTable = [device newArgumentTableWithDescriptor:fragmentArgumentTableDescriptor error:&error];
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
	
	textures = [NSMutableDictionary dictionary];
	
	commandAllocator = [device newCommandAllocator];
	
	renderPipelineState = [self compileRenderPipeline:metalLayer.pixelFormat];
	if (!renderPipelineState) {
		return nil;
	}
	
	depthState = [self configureDepth];
	
	sharedEvent = [device newSharedEvent];
	sharedEvent.signaledValue = frameNumber;
	
	[commandQueue addResidencySet:residencySet];
	[commandQueue addResidencySet:metalLayer.residencySet];
	
	return self;
}

- (void) setupConstantSizeBuffers {
	cameraBuffer = [device newBufferWithLength:sizeof(Camera) options:MTLResourceStorageModeShared];
	[residencySet addAllocation:cameraBuffer];
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
	descriptor.vertexFunctionDescriptor = vertexFunction;
	descriptor.fragmentFunctionDescriptor = fragmentFunction;

	MTL4RenderPipelineColorAttachmentDescriptor *colorAttachment = descriptor.colorAttachments[0];
	colorAttachment.pixelFormat = colorPixelFormat;
	colorAttachment.blendingState = MTL4BlendStateEnabled;
	colorAttachment.sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
	colorAttachment.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
	colorAttachment.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
	colorAttachment.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
	
	return descriptor;
}

- (id<MTLDepthStencilState>) configureDepth {
	MTLDepthStencilDescriptor *depthDescriptor = [MTLDepthStencilDescriptor new];
	depthDescriptor.depthCompareFunction = MTLCompareFunctionLessEqual;
	depthDescriptor.depthWriteEnabled = YES;
	return [device newDepthStencilStateWithDescriptor:depthDescriptor];
}

- (void) updateViewWithFOV:(float)newFOV pitch:(float)newPitch yaw:(float)newYaw {
	fov = newFOV;
	pitch = newPitch;
	yaw = newYaw;
}

- (void) begin {
	frameNumber += 1;
	
	triangles = [NSMutableArray array];
}

- (void) addPolygonWithVertices:(Vertex *)vertices count:(NSUInteger)vertexCount textureID:(NSNumber*)textureID {
	assert(vertexCount > 2);
	
	// Triangle fan: draw 0-1-2, 0-2-3, 0-3-4, etc
	for (int j = 0; j < vertexCount-2; j++) {
		[triangles addObject:[[Triangle alloc] initWithV0:*(vertices)
													   v1:*(vertices+j+1)
													   v2:*(vertices+j+2)
												textureID:textureID]];
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
	[residencySet addAllocation:texture];
}

- (void) end {
	simd_float4x4 perspective = perspectiveProjection(fov, (float)viewportSize.x/(float)viewportSize.y);
	simd_float4x4 rotation = pitchMatrix(pitch);
	simd_float4x4 toWorldSpace = toWorldSpaceMatrix(yaw);
	Camera camera = { perspective, rotation, toWorldSpace };
	memcpy(cameraBuffer.contents, &camera, sizeof(Camera));

	NSString *label = [NSString stringWithFormat:@"Frame %llu", frameNumber];
	
	id<CAMetalDrawable> currentDrawable = [metalLayer nextDrawable];
	
	[commandBuffer beginCommandBufferWithAllocator:commandAllocator];
	commandBuffer.label = label;
	
	MTL4RenderPassDescriptor *configuration = [MTL4RenderPassDescriptor new];
	configuration.colorAttachments[0].texture = currentDrawable.texture;
	configuration.colorAttachments[0].storeAction = MTLStoreActionStore;
	
	MTLViewport viewPort;
	viewPort.originX = 0.0;
	viewPort.originY = 0.0;
	viewPort.znear = 0.0;
	viewPort.zfar = 1.0;
	viewPort.width = (double)viewportSize.x;
	viewPort.height = (double)viewportSize.y;

	NSMutableArray<id<MTLBuffer>> *vertexBuffers = [NSMutableArray array];
	
	id<MTL4RenderCommandEncoder> renderPassEncoder = [commandBuffer renderCommandEncoderWithDescriptor:configuration];
	if (!renderPassEncoder) return;
	renderPassEncoder.label = label;
	
	[renderPassEncoder setRenderPipelineState:renderPipelineState];
	[renderPassEncoder setDepthStencilState:depthState];
	[renderPassEncoder setViewport:viewPort];
	
	[vertexArgumentTable setAddress:cameraBuffer.gpuAddress atIndex:1];

	for (int i = 0; i < triangles.count; i++) {
		Triangle *triangle = [triangles objectAtIndex:i];

		NSMutableData *vertexData = [NSMutableData data];
		Vertex vertex;
		vertex = triangle.v0; [vertexData appendBytes:&vertex length:sizeof(Vertex)];
		vertex = triangle.v1; [vertexData appendBytes:&vertex length:sizeof(Vertex)];
		vertex = triangle.v2; [vertexData appendBytes:&vertex length:sizeof(Vertex)];

		id<MTLBuffer> vertexBuffer = [device newBufferWithBytes:vertexData.bytes
														 length:vertexData.length
														options:MTLResourceStorageModeShared];
		[residencySet addAllocation:vertexBuffer];
		[vertexBuffers addObject:vertexBuffer];
		
		[vertexArgumentTable setAddress:vertexBuffer.gpuAddress atIndex:0];
		[renderPassEncoder setArgumentTable:vertexArgumentTable atStages:MTLRenderStageVertex];

		id<MTLTexture> texture = [textures objectForKey:triangle.textureID];
		[fragmentArgumentTable setTexture:texture.gpuResourceID atIndex:0];
		[renderPassEncoder setArgumentTable:fragmentArgumentTable atStages:MTLRenderStageFragment];
		
		[residencySet commit];
		[renderPassEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
	}

	[renderPassEncoder endEncoding];
	[commandBuffer endCommandBuffer];
	
	[commandQueue waitForDrawable:currentDrawable];
	[commandQueue commit:&commandBuffer count:1];
	[commandQueue signalDrawable:currentDrawable];
	[currentDrawable present];
	
	for (int i = 0; i < vertexBuffers.count; i++) {
		[residencySet removeAllocation:[vertexBuffers objectAtIndex:i]];
	}
	[residencySet commit];
}

@end
