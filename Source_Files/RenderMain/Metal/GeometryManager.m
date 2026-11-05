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
	
	// Geometry primitives that get reused across levels
	VerticalQuad *verticalQuadPrimitive;
	
	// Static geometry (walls, floors, ceilings)
	IASManager *staticIASManager;

	// Dynamic geometry (sprites, doors, platforms)
	IASManager *dynamicIASManager;
	NSMutableDictionary<NSNumber*, id<ASTrianglePrimitive>> *dynamicPolygonPrimitives;
		
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
	
	_perInstanceDataBuffer = [_pipeline.device newBufferWithLength:(sizeof(RayTracingData) * MAX_INSTANCES) options:MTLResourceStorageModeShared];
	_perInstanceDataBuffer.label = @"Per-instance data";
	
	return true;
}

-(void)startUpdatingAllGeometry {
	_staticTriangles = [NSMutableArray array];
	_dynamicTriangles = [NSMutableArray array];

	dynamicPolygonPrimitives = [NSMutableDictionary dictionary];
	numInstances = 0;
	
	if (!verticalQuadPrimitive) {
		// spriteQuad initializes exactly once and is reused across frames + level changes
		verticalQuadPrimitive = [[VerticalQuad alloc] init];
	}

	[staticIASManager clearGeometry];
	[dynamicIASManager clearGeometry];
	[dynamicIASManager addPrimitive:verticalQuadPrimitive];

	[self clearTopLevelIAS];
}

-(void)finishUpdatingAllGeometry {
	[self writeStaticTrianglesToIAS];

	[staticIASManager commitGeometry];
	[dynamicIASManager commitGeometry];

	[self initializeTopLevelIAS];

	[self buildAccelerationStructureWithChangesTo:@[staticIASManager, dynamicIASManager]
						  primitiveDataHasChanged:YES
											label:@"Full IAS build"];
}

-(void)startUpdatingDynamicGeometry {
	_dynamicTriangles = [NSMutableArray array];
	numInstances = 0;

	[dynamicIASManager clearInstances];
	[self clearTopLevelIAS];
}

-(void)finishUpdatingDynamicGeometry {
	[dynamicIASManager commitInstances];
	[self initializeTopLevelIAS];

	[self buildAccelerationStructureWithChangesTo:@[dynamicIASManager]
						  primitiveDataHasChanged:NO
											label:[NSString stringWithFormat:@"Dynamic IAS build (frame #%llu)", _view.frameNumber]];
}

- (void)addStaticPolygon:(MetalPolygon *)polygon {
	[polygon eachTriangle:^(Triangle *triangle) {
		[self->_staticTriangles addObject:triangle];
	}];
	assert(_staticTriangles.count < MAX_TRIANGLES);
}

- (void)addStaticWall:(MetalWall *)wall {
	[wall eachTriangle:^(Triangle *triangle) {
		[self->_staticTriangles addObject:triangle];
	}];
	assert(_staticTriangles.count < MAX_TRIANGLES);
}

- (uint32_t)addInstanceData:(RayTracingData)instanceData {
	// Purposefully skip index 0, which is shorthand for "use the per-primitive data"
	uint32_t instanceID = ++numInstances;
	assert(numInstances < MAX_INSTANCES);
	*(RayTracingData*)(_perInstanceDataBuffer.contents + sizeof(RayTracingData)*instanceID) = instanceData;
	return instanceID;
}

-(void)addDynamicPolygon:(MetalPolygon *)polygon withID:(int)ID enabled:(BOOL)isEnabled {
	[polygon eachTriangle:^(Triangle *triangle) {
		[self->_dynamicTriangles addObject:triangle];
	}];
	assert(_dynamicTriangles.count < MAX_TRIANGLES);

	id<ASTrianglePrimitive> primitive = [dynamicPolygonPrimitives objectForKey:[NSNumber numberWithInt:ID]];
	if (primitive == nil) {
		primitive = [polygon primitiveForTextureIDs:_textureManager.textureIDs];
		[dynamicIASManager addPrimitive:primitive];
		[dynamicPolygonPrimitives setObject:primitive forKey:[NSNumber numberWithInt:ID]];
	}
	
	RayTracingData instanceData = {
		.numVertices = polygon.vertexCount,
		.surface = polygon.surface,
	};
	for (int i = 0; i < polygon.vertexCount; i++) {
		instanceData.uv[i] = polygon.uv[i];
	}
	
	uint32_t instanceID = [self addInstanceData:instanceData];

	[dynamicIASManager addInstanceOfPrimitive:primitive
								withTransform:polygon.instanceTransform
								   instanceID:instanceID
										 mask:getMask(isEnabled, polygon.surface.material.isTransparent)];
}

-(void)addDynamicWall:(MetalWall *)wall enabled:(BOOL)isEnabled {
	[wall eachTriangle:^(Triangle *triangle) {
		[self->_dynamicTriangles addObject:triangle];
	}];
	assert(_dynamicTriangles.count < MAX_TRIANGLES);
	
	RayTracingData instanceData = {
		.numVertices = 4,
		.surface = wall.surface,
	};
	instanceData.uv[0] = wall.uv.columns[0];
	instanceData.uv[1] = wall.uv.columns[1];
	instanceData.uv[2] = wall.uv.columns[2];
	instanceData.uv[3] = wall.uv.columns[3];

	uint32_t instanceID = [self addInstanceData:instanceData];

	[dynamicIASManager addInstanceOfPrimitive:verticalQuadPrimitive
								withTransform:wall.instanceTransform
								   instanceID:instanceID
										 mask:getMask(isEnabled, wall.surface.material.isTransparent)];
}

- (void) updateSprite:(MetalSprite *)sprite yawRadians:(float)theta {
	[sprite eachTriangle:^(Triangle *triangle) {
		[self->_dynamicTriangles addObject:triangle];
	} forRotation:theta];
	assert(_dynamicTriangles.count < MAX_TRIANGLES);

	RayTracingData instanceData = {
		.numVertices = 4,
		.surface = sprite.surface,
	};
	instanceData.uv[0] = sprite.uv.columns[0];
	instanceData.uv[1] = sprite.uv.columns[1];
	instanceData.uv[2] = sprite.uv.columns[2];
	instanceData.uv[3] = sprite.uv.columns[3];

	uint32_t instanceID = [self addInstanceData:instanceData];

	[dynamicIASManager addInstanceOfPrimitive:verticalQuadPrimitive
								withTransform:[sprite instanceTransformForRotation:theta]
								   instanceID:instanceID
										 mask:getMask(true, sprite.surface.material.isTransparent)];
}


// FIXME: the staticTriangles list powers both the initial render and the static IAS, but is owned by initial render.
- (void) writeStaticTrianglesToIAS {
	NSUInteger numTriangles = _staticTriangles.count;
	NSUInteger trianglesPerBatch = 100;
	
	for (int b = 0; b < numTriangles; b += trianglesPerBatch) {
		NSArray *triangles = [_staticTriangles subarrayWithRange:NSMakeRange(b, MIN(trianglesPerBatch, numTriangles - b))];
		TriangleBatch *batch = [[TriangleBatch alloc] initWithTriangles:triangles
															 textureIDs:_textureManager.textureIDs];
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
	[_residencySet commit];
}

- (void) clearTopLevelIAS {
	if (topLevelIASInstanceBuffer) [_residencySet removeAllocation:topLevelIASInstanceBuffer];
	if (_topLevelIAS) [_residencySet removeAllocation:_topLevelIAS];
	topLevelIASInstanceBuffer = nil;
	_topLevelIAS = nil;
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
	_staticTriangles = nil;
	_dynamicTriangles = nil;

	staticIASManager = nil;
	dynamicIASManager = nil;
	dynamicPolygonPrimitives = nil;
	
	[_residencySet removeAllAllocations];
}

@end
