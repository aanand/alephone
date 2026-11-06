//
//  GeometryManager.m
//  AlephOne
//
//  Created by Aanand Prasad on 31/10/2026.
//

#import "GeometryManager.h"
#import "Common.h"
#import "IASManager.h"

uint getMask(bool isEnabled, bool isTransparent) {
	if (!isEnabled) return MASK_NONE;

	uint mask = MASK_ENABLED;
	if (!isTransparent) mask |= MASK_SOLID;
	return mask;
}

@implementation GeometryManager
{
	MetalPipeline *_pipeline;

	uint32_t numInstances;

	Triangle staticTriangles[MAX_TRIANGLES], dynamicTriangles[MAX_TRIANGLES];
	uint32_t numStaticTriangles, numDynamicTriangles;
	
	// Geometry primitives that get reused across levels
	VerticalQuad *verticalQuadPrimitive;
	
	// Static geometry (walls, floors, ceilings)
	IASManager *staticIASManager;

	// Dynamic geometry (sprites, doors, platforms)
	IASManager *dynamicIASManager;
	NSMutableDictionary<NSNumber*, NSNumber*> *dynamicPolygonPrimitiveIndices;
		
	id<MTLBuffer> topLevelIASInstanceBuffer;
	MTL4InstanceAccelerationStructureDescriptor *topLevelIASDescriptor;
}

-(instancetype)initWithPipeline:(MetalPipeline *)pipeline {
	if (self = [super init]) {
		_pipeline = pipeline;

		NSError *error;
		
		MTLResidencySetDescriptor *residencySetDescriptor = [MTLResidencySetDescriptor new];
		residencySetDescriptor.label = @"[GeometryManager] residencySet";
		_residencySet = [_pipeline.device newResidencySetWithDescriptor:residencySetDescriptor
																  error:&error];

		if (error) {
			NSLog(@"%@", error);
			assert(_residencySet);
			return nil;
		}
	}
	return self;
}

-(bool)compile {
	NSError *error;
	staticIASManager = [[IASManager alloc] initWithPipeline:_pipeline
								   primitiveDataElementSize:sizeof(RayTracingData)
													  error:&error];
	if (!staticIASManager) {
		NSLog(@"Failed to create staticIASManager: %@", error);
		return false;
	}
	staticIASManager.label = @"staticIASManager";

	dynamicIASManager = [[IASManager alloc] initWithPipeline:_pipeline
									primitiveDataElementSize:sizeof(RayTracingData)
													   error:&error];
	if (!dynamicIASManager) {
		NSLog(@"Failed to create dynamicIASManager: %@", error);
		return false;
	}
	dynamicIASManager.label = @"dynamicIASManager";
	
	_rasterizerVertexBuffer = [_pipeline.device newBufferWithLength:(sizeof(WorldVertex) * MAX_TRIANGLES * 3) options:MTLResourceStorageModeShared];
	_rasterizerVertexBuffer.label = @"Triangle vertices";

	_perInstanceDataBuffer = [_pipeline.device newBufferWithLength:(sizeof(RayTracingData) * MAX_INSTANCES) options:MTLResourceStorageModeShared];
	_perInstanceDataBuffer.label = @"Per-instance data";
	
	[self initializeTopLevelIAS];
	
	[_residencySet commit];

	return true;
}

-(void)startUpdatingAllGeometry {
	numStaticTriangles = 0;
	numDynamicTriangles = 0;

	dynamicPolygonPrimitiveIndices = [NSMutableDictionary dictionary];
	numInstances = 0;
	
	if (!verticalQuadPrimitive) {
		// spriteQuad initializes exactly once and is reused across frames + level changes
		verticalQuadPrimitive = [[VerticalQuad alloc] init];
	}

	[staticIASManager clearGeometry];
	[dynamicIASManager clearGeometry];
	[dynamicIASManager addPrimitive:verticalQuadPrimitive];
}

-(void)finishUpdatingAllGeometry {
	[self writeStaticTrianglesToVertexBuffer];
	[self writeDynamicTrianglesToVertexBuffer];
	[self writeStaticTrianglesToIAS];

	[staticIASManager commitGeometry];
	[dynamicIASManager commitGeometry];

	[self initializeTopLevelIAS];

	[self buildAccelerationStructureWithChangesTo:@[staticIASManager, dynamicIASManager]
						  primitiveDataHasChanged:YES
											label:@"Full IAS build"];
}

-(void)startUpdatingDynamicGeometry {
	numDynamicTriangles = 0;
	numInstances = 0;

	[dynamicIASManager clearInstances];
}

-(void)finishUpdatingDynamicGeometry {
	[self writeDynamicTrianglesToVertexBuffer];
	[dynamicIASManager commitInstances];
	[self initializeTopLevelIAS];

	[self buildAccelerationStructureWithChangesTo:@[dynamicIASManager]
						  primitiveDataHasChanged:NO
											label:[NSString stringWithFormat:@"Dynamic IAS build (frame #%llu)", _view.frameNumber]];
}

- (NSUInteger) numRasterizerTriangles {
	return numStaticTriangles + numDynamicTriangles;
}

- (void)addStaticTriangle:(Triangle)triangle {
	staticTriangles[numStaticTriangles] = triangle;
	numStaticTriangles++;
	assert(self.numRasterizerTriangles < MAX_TRIANGLES);
}

- (void)addDynamicTriangle:(Triangle)triangle {
	dynamicTriangles[numDynamicTriangles] = triangle;
	numDynamicTriangles++;
	assert(self.numRasterizerTriangles < MAX_TRIANGLES);
}

- (void)writeStaticTrianglesToVertexBuffer {
	WorldVertex *target = _rasterizerVertexBuffer.contents;
	for (int i=0; i<numStaticTriangles; i++) {
		target[i*3+0] = staticTriangles[i].v0;
		target[i*3+1] = staticTriangles[i].v1;
		target[i*3+2] = staticTriangles[i].v2;
	}
}

- (void)writeDynamicTrianglesToVertexBuffer {
	WorldVertex *target = _rasterizerVertexBuffer.contents;
	for (int i=0; i<numDynamicTriangles; i++) {
		target[(numStaticTriangles+i)*3+0] = dynamicTriangles[i].v0;
		target[(numStaticTriangles+i)*3+1] = dynamicTriangles[i].v1;
		target[(numStaticTriangles+i)*3+2] = dynamicTriangles[i].v2;
	}
}

- (void)addStaticPolygon:(MetalPolygon *)polygon {
	[polygon eachTriangle:^(Triangle triangle) {
		[self addStaticTriangle:triangle];
	}];
}

- (void)addStaticWall:(MetalWall *)wall {
	[wall eachTriangle:^(Triangle triangle) {
		[self addStaticTriangle:triangle];
	}];
}

- (uint32_t)addInstanceData:(RayTracingData)instanceData {
	// Purposefully skip index 0, which is shorthand for "use the per-primitive data"
	uint32_t instanceID = ++numInstances;
	assert(numInstances < MAX_INSTANCES);
	*(RayTracingData*)(_perInstanceDataBuffer.contents + sizeof(RayTracingData)*instanceID) = instanceData;
	return instanceID;
}

-(void)addDynamicPolygon:(MetalPolygon *)polygon withID:(int)ID enabled:(BOOL)isEnabled {
	[polygon eachTriangle:^(Triangle triangle) {
		[self addDynamicTriangle:triangle];
	}];

	NSNumber *primitiveIdx = [dynamicPolygonPrimitiveIndices objectForKey:[NSNumber numberWithInt:ID]];
	if (primitiveIdx == nil) {
		id<ASTrianglePrimitive> primitive = [polygon primitiveForTextureIDs:_textureManager.textureIDs];
		primitiveIdx = [NSNumber numberWithUnsignedLong:[dynamicIASManager addPrimitive:primitive]];
		[dynamicPolygonPrimitiveIndices setObject:primitiveIdx forKey:[NSNumber numberWithInt:ID]];
	}
	
	RayTracingData instanceData = {
		.numVertices = polygon.vertexCount,
		.surface = polygon.surface,
	};
	for (int i = 0; i < polygon.vertexCount; i++) {
		instanceData.uv[i] = polygon.uv[i];
	}
	
	uint32_t instanceID = [self addInstanceData:instanceData];

	[dynamicIASManager addInstanceOfPrimitive:primitiveIdx.unsignedLongValue
								withTransform:polygon.instanceTransform
								   instanceID:instanceID
										 mask:getMask(isEnabled, polygon.surface.material.isTransparent)];
}

-(void)addDynamicWall:(MetalWall *)wall enabled:(BOOL)isEnabled {
	[wall eachTriangle:^(Triangle triangle) {
		[self addDynamicTriangle:triangle];
	}];

	RayTracingData instanceData = {
		.numVertices = 4,
		.surface = wall.surface,
	};
	instanceData.uv[0] = wall.uv.columns[0];
	instanceData.uv[1] = wall.uv.columns[1];
	instanceData.uv[2] = wall.uv.columns[2];
	instanceData.uv[3] = wall.uv.columns[3];

	uint32_t instanceID = [self addInstanceData:instanceData];

	[dynamicIASManager addInstanceOfPrimitive:0 // verticalQuadPrimitive
								withTransform:wall.instanceTransform
								   instanceID:instanceID
										 mask:getMask(isEnabled, wall.surface.material.isTransparent)];
}

- (void) updateSprite:(MetalSprite *)sprite {
	[sprite eachTriangle:^(Triangle triangle) {
		[self addDynamicTriangle:triangle];
	}];

	RayTracingData instanceData = {
		.numVertices = 4,
		.surface = sprite.surface,
	};
	instanceData.uv[0] = sprite.uv.columns[0];
	instanceData.uv[1] = sprite.uv.columns[1];
	instanceData.uv[2] = sprite.uv.columns[2];
	instanceData.uv[3] = sprite.uv.columns[3];

	uint32_t instanceID = [self addInstanceData:instanceData];

	[dynamicIASManager addInstanceOfPrimitive:0 // verticalQuadPrimitive
								withTransform:sprite.instanceTransform
								   instanceID:instanceID
										 mask:getMask(true, sprite.surface.material.isTransparent)];
}


- (void) writeStaticTrianglesToIAS {
	NSUInteger trianglesPerBatch = 100;
	
	for (int b = 0; b < numStaticTriangles; b += trianglesPerBatch) {
		NSUInteger trianglesInBatch = MIN(trianglesPerBatch, numStaticTriangles - b);
		TriangleBatch *batch = [[TriangleBatch alloc] initWithTriangles:(staticTriangles + b)
														  triangleCount:trianglesInBatch];
		NSUInteger primitiveIdx = [staticIASManager addPrimitive:batch];
		simd_float4x3 transform = {
			.columns = {
				{ 1.0, 0.0, 0.0 },
				{ 0.0, 1.0, 0.0 },
				{ 0.0, 0.0, 1.0 },
				{ 0.0, 0.0, 0.0 },
			}
		};
		[staticIASManager addInstanceOfPrimitive:primitiveIdx
								   withTransform:transform
									  instanceID:0
											mask:getMask(true, false)];
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
	
	topLevelIASInstanceBuffer = [_pipeline.device newBufferWithBytes:&descriptors
													length:sizeof(MTLIndirectAccelerationStructureInstanceDescriptor) * IASes.count
												   options:MTLResourceStorageModeShared];
	topLevelIASInstanceBuffer.label = @"topLevelIASInstanceBuffer";
	
	topLevelIASDescriptor = [[MTL4InstanceAccelerationStructureDescriptor alloc] init];
	topLevelIASDescriptor.instanceCount = IASes.count;
	topLevelIASDescriptor.instanceDescriptorBuffer = MTL4BufferRangeMake(topLevelIASInstanceBuffer.gpuAddress, topLevelIASInstanceBuffer.length);
	
	_topLevelIAS = [_pipeline.device newAccelerationStructureWithDescriptor:topLevelIASDescriptor];
	
	[_residencySet addAllocation:topLevelIASInstanceBuffer];
	[_residencySet addAllocation:_topLevelIAS];
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
		NSUInteger primSize = [_pipeline.device accelerationStructureSizesWithDescriptor:asd].buildScratchBufferSize;
		if (primSize > scratchSize) {
			scratchSize = primSize;
		}
	}
	
	// Build everything
	
	id<MTLBuffer> scratchBuffer = [_pipeline.device newBufferWithLength:scratchSize options:MTLResourceStorageModePrivate];
	[_residencySet addAllocation:scratchBuffer];
	[_residencySet commit];
	
	id<MTL4CommandBuffer> commandBuffer = _pipeline.commandBuffer;
	[commandBuffer beginCommandBufferWithAllocator:_pipeline.commandAllocator];
	commandBuffer.label = label;

	id<MTL4ComputeCommandEncoder> encoder = [_pipeline.commandBuffer computeCommandEncoder];
	encoder.label = @"Build acceleration structures";
	
	if (primitiveDataHasChanged) {
		for (IASManager *iasm in iasManagers) {
			[iasm encodeBuildCommandsForPASes:encoder
								scratchBuffer:MTL4BufferRangeMake(scratchBuffer.gpuAddress, scratchBuffer.length)];
		}
	}
	
	for (IASManager *iasm in iasManagers) {
		[iasm encodeBuildCommandsForIAS:encoder
						  scratchBuffer:MTL4BufferRangeMake(scratchBuffer.gpuAddress, scratchBuffer.length)];
	}

	[encoder buildAccelerationStructure:_topLevelIAS
							 descriptor:topLevelIASDescriptor
						  scratchBuffer:MTL4BufferRangeMake(scratchBuffer.gpuAddress, scratchBuffer.length)];

	[encoder endEncoding];
	[commandBuffer endCommandBuffer];
	
	uint64_t buildSignalValue = _pipeline.sharedEvent.signaledValue + 1;
	[_pipeline.commandQueue commit:&commandBuffer count:1];
	[_pipeline.commandQueue signalEvent:_pipeline.sharedEvent value:buildSignalValue];
	bool didFinish = [_pipeline.sharedEvent waitUntilSignaledValue:buildSignalValue timeoutMS:5000];
	
	if (!didFinish) {
		NSLog(@"Timed out waiting for AS build");
	}
	
	[_pipeline.commandAllocator reset];

	[_residencySet removeAllocation:scratchBuffer];
	[_residencySet commit];
}

-(void)shutdown {
	staticIASManager = nil;
	dynamicIASManager = nil;
	
	[_residencySet removeAllAllocations];
}

@end
