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

@implementation MetalPolygon

- (MetalPolygon*) initWithVertices:(WorldVertex *)vertices vertexCount:(NSUInteger)vertexCount textureID:(NSString *)textureID emission:(simd_float3)emission {
	if (self = [super init]) {
		_vertices = malloc(sizeof(WorldVertex) * vertexCount);
		memcpy(_vertices, vertices, sizeof(WorldVertex) * vertexCount);
		_vertexCount = vertexCount;
		_textureID = textureID;
		_emission = emission;
	}
	return self;
}

- (void)dealloc {
	free(_vertices);
}

@end

@implementation MetalDynamicObject

- (MetalDynamicObject*) initWithID:(NSString *)objectId polygons:(NSArray<MetalPolygon *> *)polygons worldPosition:(simd_int3)worldPosition facing:(NSInteger)facing {
	if (self = [super init]) {
		_objectId = objectId;
		_polygons = polygons;
		_worldPosition = worldPosition;
		_facing = facing;
	}
	return self;
}

@end

@interface Triangle : NSObject

@property (nonatomic, readonly) WorldVertex v0;
@property (nonatomic, readonly) WorldVertex v1;
@property (nonatomic, readonly) WorldVertex v2;
@property (nonatomic, readonly) NSString* textureID;
@property (nonatomic, readonly) simd_float3 emission;

- (Triangle *) initWithV0:(WorldVertex)v0
					   v1:(WorldVertex)v1
					   v2:(WorldVertex)v2
				textureID:(NSString*)textureID
				 emission:(simd_float3)emission;

@end

@implementation Triangle

- (Triangle *) initWithV0:(WorldVertex)v0
					   v1:(WorldVertex)v1
					   v2:(WorldVertex)v2
				textureID:(NSString *)textureID
				 emission:(simd_float3)emission{
	if (self = [super init]) {
		_v0 = v0;
		_v1 = v1;
		_v2 = v2;
		_textureID = textureID;
		_emission = emission;
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

static const simd_float3 sunDirection    = { -1.0, 1.0, 0.0 }; // sun is to the northwest
static const simd_float3 sunRotationAxis = {  0.0, 1.0, 0.0 }; // sun rotates around the north-south axis
static const float sunIntensity = 50.0;
static const float sunDiameterDegrees = 30.0;

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
	id<MTLBuffer> uniformsBuffer;

	NSMutableArray<MetalPolygon*> *staticPolygons;
	NSMutableArray<MetalDynamicObject*> *dynamicObjects;
	NSMutableDictionary<NSString *, id<MTLTexture>> *textures;

	// Static geometry (walls, floors, ceilings)
	id<MTLBuffer> staticPASVertexBuffer;
	id<MTLBuffer> staticPASPrimitiveDataBuffer;
	id<MTLBuffer> staticIASInstanceBuffer;
	NSMutableArray<id<MTLAccelerationStructure>> *staticPASes;
	NSMutableArray<MTL4AccelerationStructureDescriptor*> *staticPASDescriptors;
	id<MTLAccelerationStructure> staticIAS;
	MTL4InstanceAccelerationStructureDescriptor *staticIASDescriptor;

	// TODO: Acceleration structures for dynamic geometry (sprites, doors, platforms)

	id<MTLBuffer> topLevelIASInstanceBuffer;
	id<MTLAccelerationStructure> topLevelIAS;
	MTL4InstanceAccelerationStructureDescriptor *topLevelIASDescriptor;
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
	
	return self;
}

- (bool) setupArgumentTables {
	NSError *error;
	
	MTL4ArgumentTableDescriptor *vertexArgumentTableDescriptor = [MTL4ArgumentTableDescriptor new];
	vertexArgumentTableDescriptor.maxBufferBindCount = MAX(InitialRenderVertexShader_NumBuffers, FinalRenderVertexShader_NumBuffers);
	vertexArgumentTableDescriptor.label = @"Vertex argument table";
	vertexArgumentTable = [device newArgumentTableWithDescriptor:vertexArgumentTableDescriptor error:&error];
	if (error) {
		NSLog(@"%@", error);
		return false;
	}
	
	MTL4ArgumentTableDescriptor *fragmentArgumentTableDescriptor = [MTL4ArgumentTableDescriptor new];
	fragmentArgumentTableDescriptor.maxTextureBindCount = MAX(InitialRenderFragmentShader_NumTextures, FinalRenderFragmentShader_NumTextures);
	fragmentArgumentTableDescriptor.maxBufferBindCount = FinalRenderFragmentShader_NumBuffers;
	fragmentArgumentTableDescriptor.label = @"Fragment argument table";
	fragmentArgumentTable = [device newArgumentTableWithDescriptor:fragmentArgumentTableDescriptor error:&error];
	if (error) {
		NSLog(@"%@", error);
		return false;
	}
	
	MTL4ArgumentTableDescriptor *computeArgumentTableDescriptor = [MTL4ArgumentTableDescriptor new];
	computeArgumentTableDescriptor.maxBufferBindCount = RayTracingKernel_NumBuffers;
	computeArgumentTableDescriptor.maxTextureBindCount = RayTracingKernel_NumTextures;
	computeArgumentTableDescriptor.label = @"Compute argument table";
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
	uniformsBuffer = [device newBufferWithLength:sizeof(Uniforms) options:MTLResourceStorageModeShared];
	[initialRenderResidencySet addAllocation:uniformsBuffer];
	
	triangleBuffer = [device newBufferWithLength:(sizeof(WorldVertex) * MAX_TRIANGLES * 3) options:MTLResourceStorageModeShared];
	[initialRenderResidencySet addAllocation:triangleBuffer];
}

- (void) setupIntermediateTextures {
	MTLTextureDescriptor *initial = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:metalLayer.pixelFormat
																								 width:viewportSize.x
																								height:viewportSize.y
																							 mipmapped:NO];
	initial.storageMode = MTLStorageModePrivate;
	initial.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
	initialRenderOutputTexture = [device newTextureWithDescriptor:initial];

	MTLTextureDescriptor *raytrace = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:metalLayer.pixelFormat
																								 width:viewportSize.x
																								height:viewportSize.y
																							 mipmapped:NO];
	raytrace.storageMode = MTLStorageModePrivate;
	raytrace.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
	rayTracingOutputTexture = [device newTextureWithDescriptor:raytrace];
	
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

- (void) addTrianglesForPolygon:(MetalPolygon *)polygon toArray:(NSMutableArray<Triangle*>*)triangles
{
	assert(polygon.vertexCount > 2);
	
	// Triangle fan: draw 0-1-2, 0-2-3, 0-3-4, etc
	for (int j = 0; j < polygon.vertexCount - 2; j++) {
		[triangles addObject:[[Triangle alloc] initWithV0:*(polygon.vertices)
													   v1:*(polygon.vertices+j+1)
													   v2:*(polygon.vertices+j+2)
												textureID:polygon.textureID
												 emission:polygon.emission]];

		assert(triangles.count < MAX_TRIANGLES);
	}
}

- (void)addStaticPolygon:(MetalPolygon *)polygon {
	[staticPolygons addObject:polygon];
}

- (void)addDynamicObject:(MetalDynamicObject *)object {
	[dynamicObjects addObject:object];
}

- (void)updateDynamicObjectWithID:(NSString *)objectID polygonTextureIDs:(NSArray<NSString *> *)textureIDs worldPosition:(simd_int3)worldPosition facing:(NSInteger)facing {
}

- (void) commitStaticGeometry {
	NSMutableArray *staticTriangles = [NSMutableArray array];
	for (MetalPolygon *polygon in staticPolygons) {
		[self addTrianglesForPolygon:polygon toArray:staticTriangles];
	}
	
	NSUInteger numTriangles = staticTriangles.count;
	NSUInteger trianglesPerBatch = 100;
	NSUInteger numBatches = numTriangles / trianglesPerBatch;
	
	simd_float3 vertices[numTriangles * 3];
	TriangleRayTracingData primitiveData[numTriangles];
	
	for (int i = 0; i < numTriangles; i++) {
		Triangle *triangle = [staticTriangles objectAtIndex:i];
		
		vertices[i*3+0] = simd_make_float3(triangle.v0.position.x, triangle.v0.position.y, triangle.v0.position.z);
		vertices[i*3+1] = simd_make_float3(triangle.v1.position.x, triangle.v1.position.y, triangle.v1.position.z);
		vertices[i*3+2] = simd_make_float3(triangle.v2.position.x, triangle.v2.position.y, triangle.v2.position.z);
		
		primitiveData[i].surfaceNormal = triangle.v0.surfaceNormal;
		primitiveData[i].emission = triangle.emission;
	}
	
	staticPASVertexBuffer = [device newBufferWithBytes:vertices
												length:sizeof(vertices)
											   options:MTLResourceStorageModeShared];
	staticPASVertexBuffer.label = @"staticPASVertexBuffer";
	
	staticPASPrimitiveDataBuffer = [device newBufferWithBytes:primitiveData
													   length:sizeof(primitiveData)
													  options:MTLResourceStorageModeShared];
	staticPASPrimitiveDataBuffer.label = @"staticPASPrimitiveDataBuffer";
	
	staticPASes = [NSMutableArray array];
	staticPASDescriptors = [NSMutableArray array];
	MTLIndirectAccelerationStructureInstanceDescriptor instanceDescriptors[numBatches];
	
	for (int b = 0; b < numBatches; b++) {
		NSUInteger batchOffset = b * trianglesPerBatch;
		NSUInteger trianglesInBatch = MIN(numTriangles - batchOffset, trianglesPerBatch);
		
		MTL4AccelerationStructureTriangleGeometryDescriptor *geometryDescriptor = [[MTL4AccelerationStructureTriangleGeometryDescriptor alloc] init];
		geometryDescriptor.triangleCount = trianglesInBatch;
		geometryDescriptor.vertexBuffer = MTL4BufferRangeMake(staticPASVertexBuffer.gpuAddress + sizeof(simd_float3) * batchOffset * 3,
															  sizeof(simd_float3) * trianglesInBatch * 3);
		geometryDescriptor.vertexFormat = MTLAttributeFormatFloat3;
		geometryDescriptor.vertexStride = sizeof(simd_float3);
		geometryDescriptor.primitiveDataBuffer = MTL4BufferRangeMake(staticPASPrimitiveDataBuffer.gpuAddress + sizeof(TriangleRayTracingData) * batchOffset,
																	 sizeof(TriangleRayTracingData) * trianglesInBatch);
		geometryDescriptor.primitiveDataElementSize = sizeof(TriangleRayTracingData);
		geometryDescriptor.primitiveDataStride = sizeof(TriangleRayTracingData);
		
		MTL4PrimitiveAccelerationStructureDescriptor *primitiveASDescriptor = [[MTL4PrimitiveAccelerationStructureDescriptor alloc] init];
		primitiveASDescriptor.geometryDescriptors = @[ geometryDescriptor ];
		
		id<MTLAccelerationStructure> primitiveAS = [device newAccelerationStructureWithDescriptor:primitiveASDescriptor];
		primitiveAS.label = [NSString stringWithFormat:@"Static geometry batch %d of %lu (triangles %lu-%lu)", b, (unsigned long)numBatches, (unsigned long)batchOffset, (unsigned long)(batchOffset+trianglesInBatch)];
		
		MTLIndirectAccelerationStructureInstanceDescriptor instanceDescriptor = {};
		instanceDescriptor.accelerationStructureID = primitiveAS.gpuResourceID;
		instanceDescriptor.options = MTLAccelerationStructureInstanceOptionNone;
		instanceDescriptor.intersectionFunctionTableOffset = 0;
		instanceDescriptor.mask = 0xFF;
		instanceDescriptor.transformationMatrix.columns[0] = MTLPackedFloat3Make(1.0, 0.0, 0.0);
		instanceDescriptor.transformationMatrix.columns[1] = MTLPackedFloat3Make(0.0, 1.0, 0.0);
		instanceDescriptor.transformationMatrix.columns[2] = MTLPackedFloat3Make(0.0, 0.0, 1.0);
		instanceDescriptor.transformationMatrix.columns[3] = MTLPackedFloat3Make(0.0, 0.0, 0.0);
		
		[staticPASes addObject:primitiveAS];
		[staticPASDescriptors addObject:primitiveASDescriptor];
		instanceDescriptors[b] = instanceDescriptor;
	}
	
	staticIASInstanceBuffer = [device newBufferWithBytes:&instanceDescriptors
												  length:sizeof(MTLIndirectAccelerationStructureInstanceDescriptor) * numBatches
												 options:MTLResourceStorageModeShared];
	staticIASInstanceBuffer.label = @"staticIASInstanceBuffer";
	
	staticIASDescriptor = [[MTL4InstanceAccelerationStructureDescriptor alloc] init];
	staticIASDescriptor.instanceCount = staticPASes.count;
	staticIASDescriptor.instanceDescriptorBuffer = MTL4BufferRangeMake(staticIASInstanceBuffer.gpuAddress, staticIASInstanceBuffer.length);
	
	staticIAS = [device newAccelerationStructureWithDescriptor:staticIASDescriptor];
	
	[rayTracingResidencySet addAllocation:staticPASVertexBuffer];
	[rayTracingResidencySet addAllocation:staticPASPrimitiveDataBuffer];
	for (id<MTLAccelerationStructure> staticPAS in staticPASes) {
		[rayTracingResidencySet addAllocation:staticPAS];
	}

	[rayTracingResidencySet addAllocation:staticIASInstanceBuffer];
	[rayTracingResidencySet addAllocation:staticIAS];
}

- (void) clearStaticGeometry {
	if (staticPASVertexBuffer) [rayTracingResidencySet removeAllocation:staticPASVertexBuffer];
	if (staticPASPrimitiveDataBuffer) [rayTracingResidencySet removeAllocation:staticPASPrimitiveDataBuffer];
	if (staticIASInstanceBuffer) [rayTracingResidencySet removeAllocation:staticIASInstanceBuffer];
	for (id<MTLAllocation> staticPAS in staticPASes) {
		[rayTracingResidencySet removeAllocation:staticPAS];
	}
	if (staticIAS) [rayTracingResidencySet removeAllocation:staticIAS];

	staticPolygons = [NSMutableArray array];

	staticPASVertexBuffer = nil;
	staticPASPrimitiveDataBuffer = nil;
	staticIASInstanceBuffer = nil;
	staticPASes = [NSMutableArray array];
	staticPASDescriptors = [NSMutableArray array];
	staticIAS = nil;
	staticIASDescriptor = nil;
}

- (void) initializeTopLevelIAS {
	MTLIndirectAccelerationStructureInstanceDescriptor staticInstanceDescriptor = {};
	staticInstanceDescriptor.accelerationStructureID = staticIAS.gpuResourceID;
	staticInstanceDescriptor.options = MTLAccelerationStructureInstanceOptionNone;
	staticInstanceDescriptor.intersectionFunctionTableOffset = 0;
	staticInstanceDescriptor.mask = 0xFF;
	staticInstanceDescriptor.transformationMatrix.columns[0] = MTLPackedFloat3Make(1.0, 0.0, 0.0);
	staticInstanceDescriptor.transformationMatrix.columns[1] = MTLPackedFloat3Make(0.0, 1.0, 0.0);
	staticInstanceDescriptor.transformationMatrix.columns[2] = MTLPackedFloat3Make(0.0, 0.0, 1.0);
	staticInstanceDescriptor.transformationMatrix.columns[3] = MTLPackedFloat3Make(0.0, 0.0, 0.0);
	
	topLevelIASInstanceBuffer = [device newBufferWithBytes:&staticInstanceDescriptor
													length:sizeof(MTLIndirectAccelerationStructureInstanceDescriptor)
												   options:MTLResourceStorageModeShared];
	topLevelIASInstanceBuffer.label = @"topLevelIASInstanceBuffer";
	
	topLevelIASDescriptor = [[MTL4InstanceAccelerationStructureDescriptor alloc] init];
	topLevelIASDescriptor.instanceCount = 1;
	topLevelIASDescriptor.instanceDescriptorBuffer = MTL4BufferRangeMake(topLevelIASInstanceBuffer.gpuAddress, topLevelIASInstanceBuffer.length);
	
	topLevelIAS = [device newAccelerationStructureWithDescriptor:topLevelIASDescriptor];
	
	[rayTracingResidencySet addAllocation:topLevelIASInstanceBuffer];
	[rayTracingResidencySet addAllocation:topLevelIAS];
}

- (void) clearGeometry {
	[self clearStaticGeometry];
	
	if (topLevelIASInstanceBuffer) [rayTracingResidencySet removeAllocation:topLevelIASInstanceBuffer];
	if (topLevelIAS) [rayTracingResidencySet removeAllocation:topLevelIAS];
	
	topLevelIASInstanceBuffer = nil;
	topLevelIAS = nil;
}

- (void) commitGeometry {
	// Build 3rd- and 2nd-level acceleration structures

	[self commitStaticGeometry];
	[self initializeTopLevelIAS];
	[rayTracingResidencySet commit];

	// Calculate largest scratch size needed
	
	NSMutableArray<MTL4AccelerationStructureDescriptor*> *allDescriptors = [NSMutableArray arrayWithArray:staticPASDescriptors];
	[allDescriptors addObject:staticIASDescriptor];
	[allDescriptors addObject:topLevelIASDescriptor];
	
	NSUInteger scratchSize = 0;
	for (MTL4AccelerationStructureDescriptor *asd in allDescriptors) {
		NSUInteger primSize = [device accelerationStructureSizesWithDescriptor:asd].buildScratchBufferSize;
		if (primSize > scratchSize) {
			scratchSize = primSize;
		}
	}
	
	// Build everything
	
	id<MTLBuffer> scratchBuffer = [device newBufferWithLength:scratchSize options:MTLResourceStorageModePrivate];
	
	[commandBuffer beginCommandBufferWithAllocator:commandAllocator];
	
	id<MTL4ComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
	encoder.label = @"Build acceleration structures";
	
	for (int i = 0; i < staticPASes.count; i++) {
		[encoder buildAccelerationStructure:[staticPASes objectAtIndex:i]
								 descriptor:[staticPASDescriptors objectAtIndex:i]
							  scratchBuffer:MTL4BufferRangeMake(scratchBuffer.gpuAddress, scratchBuffer.length)];
	}
	
	[encoder barrierAfterEncoderStages:MTLStageAccelerationStructure
				   beforeEncoderStages:MTLStageAccelerationStructure
					 visibilityOptions:MTL4VisibilityOptionDevice];
	
	[encoder buildAccelerationStructure:staticIAS
							 descriptor:staticIASDescriptor
						  scratchBuffer:MTL4BufferRangeMake(scratchBuffer.gpuAddress, scratchBuffer.length)];
	
	[encoder barrierAfterEncoderStages:MTLStageAccelerationStructure
				   beforeEncoderStages:MTLStageAccelerationStructure
					 visibilityOptions:MTL4VisibilityOptionDevice];

	[encoder buildAccelerationStructure:topLevelIAS
							 descriptor:topLevelIASDescriptor
						  scratchBuffer:MTL4BufferRangeMake(scratchBuffer.gpuAddress, scratchBuffer.length)];

	[encoder endEncoding];
	[commandBuffer endCommandBuffer];
	
	uint64_t buildSignalValue = sharedEvent.signaledValue + 1;
	[commandQueue commit:&commandBuffer count:1];
	[commandQueue signalEvent:sharedEvent value:buildSignalValue];
	[sharedEvent waitUntilSignaledValue:buildSignalValue timeoutMS:5000];
}

- (bool) hasTextureWithID:(NSString*)textureID {
	return [textures objectForKey:textureID] != nil;
}

- (void) addTextureWithID:(NSString*)textureID image:(MetalImage *)image {
	MTLTextureDescriptor *descriptor = [[MTLTextureDescriptor alloc] init];
	descriptor.pixelFormat = MTLPixelFormatBGRA8Unorm;
	descriptor.width = image.width;
	descriptor.height = image.height;
	
	MTLRegion region = {
		{ 0, 0, 0 },
		{ image.width, image.height, 1 }
	};

	id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
	texture.label = textureID;
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
	simd_float4x4 sunRotation = rotationMatrix(fmod(frameNumber, 360.0), sunRotationAxis);
	simd_float3 rotatedSunDirection = simd_mul(sunRotation, simd_make_float4(sunDirection, 1.0)).xyz;

	Uniforms uniforms;
	uniforms.resolution = viewportSize;
	uniforms.frameNumber = frameNumber;
	uniforms.fov = fov;
	uniforms.origin = origin;
	uniforms.pitchMat = rotationMatrix(pitch, simd_make_float3(1.0, 0.0, 0.0));
	uniforms.yawMat = rotationMatrix(-yaw, simd_make_float3(0.0, 1.0, 0.0));
	uniforms.rotateDirectionMat = simd_mul(rotationMatrix(yaw, simd_make_float3(0.0, 1.0, 0.0)), rotationMatrix(-pitch, simd_make_float3(1.0, 0.0, 0.0)));
	uniforms.perspectiveMat = perspectiveProjection(fov, (float)viewportSize.x/(float)viewportSize.y);
	uniforms.sunDirection = simd_normalize(rotatedSunDirection);
	uniforms.sunIntensity = sunIntensity;
	uniforms.sunRadius = radians(sunDiameterDegrees/2);
	memcpy(uniformsBuffer.contents, &uniforms, sizeof(Uniforms));
		
	id<CAMetalDrawable> currentDrawable = [metalLayer nextDrawable];

	[commandBuffer beginCommandBufferWithAllocator:commandAllocator];
	commandBuffer.label = [NSString stringWithFormat:@"Frame %llu", frameNumber];
	
	id<MTLFence> initialPassFence = [device newFence];
	id<MTLFence> computePassFence = [device newFence];
	
	[self encodeInitialRenderToOutputTexture:initialRenderOutputTexture updatingFence:initialPassFence];
	[self encodeRayTracingPassToOutputTexture:rayTracingOutputTexture updatingFence:computePassFence];
	[self encodeFinalRenderFromInitialPassTexture:initialRenderOutputTexture
							rayTracingPassTexture:rayTracingOutputTexture
								  toOutputTexture:currentDrawable.texture
									  afterFences:@[initialPassFence, computePassFence]];
	
	[commandBuffer endCommandBuffer];
	
	// Block until rendering has completed. This is inefficient, but Marathon is locked to 30fps,
	// so it probably doesn't slow us down and it simplifies things to not have to worry about concurrent
	// reads/writes to buffers and textures
	uint64_t renderSignalValue = sharedEvent.signaledValue + 1;
	
	[commandQueue waitForDrawable:currentDrawable];
	[commandQueue commit:&commandBuffer count:1];
	[commandQueue signalDrawable:currentDrawable];
	[currentDrawable present];
	
	[commandQueue signalEvent:sharedEvent value:renderSignalValue];
	[sharedEvent waitUntilSignaledValue:renderSignalValue timeoutMS:5000];
}

- (void) encodeInitialRenderToOutputTexture:(id<MTLTexture>)outputTexture updatingFence:(id<MTLFence>)fence {
	// Commit any textures that were added
	[initialRenderResidencySet commit];

	MTL4RenderPassDescriptor *configuration = [MTL4RenderPassDescriptor new];
	configuration.colorAttachments[0].texture = outputTexture;
	configuration.colorAttachments[0].loadAction = MTLLoadActionClear;
	// Render a white sky, which the raytracing pass will multiply down
	configuration.colorAttachments[0].clearColor = MTLClearColorMake(1.0, 1.0, 1.0, 1.0);
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
	
	[vertexArgumentTable setAddress:uniformsBuffer.gpuAddress atIndex:InitialRenderVertexShaderUniformsIndex];
	[vertexArgumentTable setAddress:triangleBuffer.gpuAddress atIndex:InitialRenderVertexShaderVertexDataIndex];

	WorldVertex *target = (WorldVertex*)triangleBuffer.contents;
	NSUInteger offset = 0;
	
	// FIXME: this should be built once in commitGeometry, not per-frame
	NSMutableArray *staticTriangles = [NSMutableArray array];
	for (MetalPolygon *polygon in staticPolygons) {
		[self addTrianglesForPolygon:polygon toArray:staticTriangles];
	}

	for (Triangle *triangle in staticTriangles) {
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
	
	[renderPassEncoder updateFence:fence afterEncoderStages:MTLStageFragment];
	[renderPassEncoder endEncoding];
}

-(void) encodeRayTracingPassToOutputTexture:(id<MTLTexture>)outputTexture updatingFence:(id<MTLFence>)fence {
	id<MTL4ComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
	if (!encoder) {
		NSLog(@"Failed to create compute command encoder");
		return;
	}
	encoder.label = @"Ray tracing";
	
	[encoder setComputePipelineState:rayTracingPipeline];
	
	[computeArgumentTable setResource:topLevelIAS.gpuResourceID atBufferIndex:RayTracingKernelAccelerationStructureIndex];
	[computeArgumentTable setAddress:uniformsBuffer.gpuAddress atIndex:RayTracingKernelCameraIndex];
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

-(void) encodeFinalRenderFromInitialPassTexture:(id<MTLTexture>)initialPassTexture
						  rayTracingPassTexture:(id<MTLTexture>)rayTracingPassTexture
								toOutputTexture:(id<MTLTexture>)outputTexture
									afterFences:(NSArray<id<MTLFence>>*)fences
{
	MTL4RenderPassDescriptor *configuration = [MTL4RenderPassDescriptor new];
	configuration.colorAttachments[0].texture = outputTexture;
	configuration.colorAttachments[0].loadAction = MTLLoadActionClear;
	configuration.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1.0);
	configuration.colorAttachments[0].storeAction = MTLStoreActionStore;

	id<MTL4RenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:configuration];
	if (!encoder) {
		NSLog(@"Failed to create render command encoder");
		return;
	}
	encoder.label = @"Final render";
	
	for (id<MTLFence> fence in fences) {
		[encoder waitForFence:fence beforeEncoderStages:MTLStageVertex];
	}
	
	[encoder setRenderPipelineState:finalRenderPipeline];
	[encoder setViewport:[self getViewport]];

	[encoder setArgumentTable:vertexArgumentTable atStages:MTLRenderStageVertex];

	[fragmentArgumentTable setAddress:uniformsBuffer.gpuAddress atIndex:FinalRenderFragmentShaderUniformsIndex];
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
