//
//  IASManager.m
//  AlephOne
//
//  Created by Aanand Prasad on 07/09/2026.
//

#import <Foundation/Foundation.h>
#import <MetalKit/MetalKit.h>

#import "IASManager.h"
#import "MetalPipeline.h"

static const NSUInteger verticesElementSize = sizeof(simd_float3) * 3;

@interface Instance : NSObject
@property (nonatomic, assign) NSUInteger primitiveIdx;
@property (nonatomic, assign) MTLPackedFloat4x3 transform;
@property (nonatomic, assign) uint32_t instanceID;
@end
@implementation Instance
@end

@implementation IASManager
{
	MetalPipeline* pipeline;
	NSUInteger primitiveDataElementSize;
	
	id<MTLResidencySet> residencySet;
	id<MTLBuffer> PASVertexBuffer;
	id<MTLBuffer> PASPrimitiveDataBuffer;
	id<MTLBuffer> IASInstanceBuffer;
	NSMutableArray<id<MTLAccelerationStructure>> *PASes;
	NSMutableArray<MTL4AccelerationStructureDescriptor*> *PASDescriptors;
	id<MTLAccelerationStructure> IAS;
	MTL4InstanceAccelerationStructureDescriptor *IASDescriptor;
	
	NSMutableArray<id<ASTrianglePrimitive>> *primitives;
	NSMutableArray<Instance*> *instances;
}

- (IASManager*) initWithPipeline:(MetalPipeline *)p
		primitiveDataElementSize:(NSUInteger)pdes
						   error:(NSError *__autoreleasing *)error
{
	if (self = [super init]) {
		pipeline = p;
		primitiveDataElementSize = pdes;

		MTLResidencySetDescriptor *residencySetDescriptor = [MTLResidencySetDescriptor new];
		residencySet = [pipeline.device newResidencySetWithDescriptor:residencySetDescriptor error:error];
		if (!residencySet) {
			return nil;
		}
		[pipeline.commandQueue addResidencySet:residencySet];
	}
	return self;
}

- (void) addPrimitive:(id<ASTrianglePrimitive>)primitive {
	[primitives addObject:primitive];
}

- (void) addInstanceOfPrimitive:(id<ASTrianglePrimitive>)primitive
				  withTransform:(MTLPackedFloat4x3)transform
					 instanceID:(uint32_t)instanceID
{
	NSUInteger primitiveIdx = [primitives indexOfObject:primitive];
	assert(primitiveIdx != NSNotFound);
	
	Instance *instance = [[Instance alloc] init];
	instance.primitiveIdx = primitiveIdx;
	instance.transform = transform;
	instance.instanceID = instanceID;
	
	[instances addObject:instance];
}

- (void) copyDataToBuffers
{
	NSUInteger numTriangles = 0;
	for (id<ASTrianglePrimitive> primitive in primitives) {
		numTriangles += primitive.numTriangles;
	}
	
	PASVertexBuffer = [pipeline.device newBufferWithLength:verticesElementSize * numTriangles
												   options:MTLResourceStorageModeShared];
	PASVertexBuffer.label = @"staticPASVertexBuffer";
	
	PASPrimitiveDataBuffer = [pipeline.device newBufferWithLength:primitiveDataElementSize * numTriangles
														  options:MTLResourceStorageModeShared];
	PASPrimitiveDataBuffer.label = @"staticPASPrimitiveDataBuffer";

	NSUInteger triangleIndex = 0;
	for (id<ASTrianglePrimitive> primitive in primitives) {
		memcpy(PASVertexBuffer.contents + triangleIndex * verticesElementSize,
			   primitive.vertices,
			   primitive.numTriangles * verticesElementSize);

		memcpy(PASPrimitiveDataBuffer.contents + triangleIndex * primitiveDataElementSize,
			   primitive.primitiveData,
			   primitive.numTriangles * primitiveDataElementSize);

		triangleIndex += primitive.numTriangles;
	}
}

- (void) createPrimitiveAccelerationStructures {
	PASes = [NSMutableArray array];
	PASDescriptors = [NSMutableArray array];

	NSUInteger triangleIndex = 0;
	for (int i = 0; i < primitives.count; i++) {
		NSUInteger trianglesInPrimitive = [primitives objectAtIndex:i].numTriangles;

		MTL4AccelerationStructureTriangleGeometryDescriptor *geometryDescriptor = [[MTL4AccelerationStructureTriangleGeometryDescriptor alloc] init];
		geometryDescriptor.triangleCount = trianglesInPrimitive;
		geometryDescriptor.vertexBuffer = MTL4BufferRangeMake(PASVertexBuffer.gpuAddress + verticesElementSize * triangleIndex,
															  verticesElementSize * trianglesInPrimitive);
		geometryDescriptor.vertexFormat = MTLAttributeFormatFloat3;
		geometryDescriptor.vertexStride = sizeof(simd_float3);
		geometryDescriptor.primitiveDataBuffer = MTL4BufferRangeMake(PASPrimitiveDataBuffer.gpuAddress + primitiveDataElementSize * triangleIndex,
																	 primitiveDataElementSize * trianglesInPrimitive);
		geometryDescriptor.primitiveDataElementSize = primitiveDataElementSize;
		geometryDescriptor.primitiveDataStride = primitiveDataElementSize;
		
		MTL4PrimitiveAccelerationStructureDescriptor *primitiveASDescriptor = [[MTL4PrimitiveAccelerationStructureDescriptor alloc] init];
		primitiveASDescriptor.geometryDescriptors = @[ geometryDescriptor ];
		
		id<MTLAccelerationStructure> primitiveAS = [pipeline.device newAccelerationStructureWithDescriptor:primitiveASDescriptor];
		primitiveAS.label = [NSString stringWithFormat:@"Primitive %d of %lu (%lu triangles)", i, (unsigned long)primitives.count, trianglesInPrimitive];
		
		[PASes addObject:primitiveAS];
		[PASDescriptors addObject:primitiveASDescriptor];
		
		triangleIndex += trianglesInPrimitive;
	}
}

- (void) createInstanceAccelerationStructure {
	MTLIndirectAccelerationStructureInstanceDescriptor instanceDescriptors[instances.count];
	
	for (int i = 0; i < instances.count; i++) {
		Instance *instance = [instances objectAtIndex:i];
		MTLIndirectAccelerationStructureInstanceDescriptor desc = {};
		desc.accelerationStructureID = [PASes objectAtIndex:instance.primitiveIdx].gpuResourceID;
		desc.intersectionFunctionTableOffset = 0;
		desc.mask = 0xFF;
		desc.transformationMatrix = instance.transform;
		desc.userID = instance.instanceID;
		instanceDescriptors[i] = desc;
	}

	IASInstanceBuffer = [pipeline.device newBufferWithBytes:&instanceDescriptors
												  length:sizeof(MTLIndirectAccelerationStructureInstanceDescriptor) * instances.count
												 options:MTLResourceStorageModeShared];
	IASInstanceBuffer.label = @"staticIASInstanceBuffer";
	
	IASDescriptor = [[MTL4InstanceAccelerationStructureDescriptor alloc] init];
	IASDescriptor.instanceCount = instances.count;
	IASDescriptor.instanceDescriptorBuffer = MTL4BufferRangeMake(IASInstanceBuffer.gpuAddress, IASInstanceBuffer.length);
	
	IAS = [pipeline.device newAccelerationStructureWithDescriptor:IASDescriptor];
}

- (void) commitGeometry
{
	[self copyDataToBuffers];
	[self createPrimitiveAccelerationStructures];
	[self createInstanceAccelerationStructure];
		
	[residencySet addAllocation:PASVertexBuffer];
	[residencySet addAllocation:PASPrimitiveDataBuffer];
	for (id<MTLAccelerationStructure> staticPAS in PASes) {
		[residencySet addAllocation:staticPAS];
	}

	[residencySet addAllocation:IASInstanceBuffer];
	[residencySet addAllocation:IAS];

	[residencySet commit];
}

- (void) clearGeometry {
	if (PASVertexBuffer) [residencySet removeAllocation:PASVertexBuffer];
	if (PASPrimitiveDataBuffer) [residencySet removeAllocation:PASPrimitiveDataBuffer];
	if (IASInstanceBuffer) [residencySet removeAllocation:IASInstanceBuffer];
	for (id<MTLAllocation> staticPAS in PASes) {
		[residencySet removeAllocation:staticPAS];
	}
	if (IAS) [residencySet removeAllocation:IAS];
	
	PASVertexBuffer = nil;
	PASPrimitiveDataBuffer = nil;
	IASInstanceBuffer = nil;
	PASes = [NSMutableArray array];
	PASDescriptors = [NSMutableArray array];
	IAS = nil;
	IASDescriptor = nil;
	
	primitives = [NSMutableArray array];
	instances = [NSMutableArray array];
}

- (MTLResourceID) IASResourceID {
	return IAS.gpuResourceID;
}

- (NSArray<MTL4AccelerationStructureDescriptor*>*) allASDescriptors {
	NSMutableArray<MTL4AccelerationStructureDescriptor*>* descriptors = [NSMutableArray array];
	[descriptors addObject:IASDescriptor];
	[descriptors addObjectsFromArray:PASDescriptors];
	return descriptors;
}

- (void) encodeBuildCommandsForPASes:(id<MTL4ComputeCommandEncoder>)encoder scratchBuffer:(MTL4BufferRange)scratchBuffer {
	for (int i = 0; i < PASes.count; i++) {
		[encoder buildAccelerationStructure:[PASes objectAtIndex:i]
								 descriptor:[PASDescriptors objectAtIndex:i]
							  scratchBuffer:scratchBuffer];
	}
}

- (void) encodeBuildCommandsForIAS:(id<MTL4ComputeCommandEncoder>)encoder scratchBuffer:(MTL4BufferRange)scratchBuffer {
	[encoder buildAccelerationStructure:IAS descriptor:IASDescriptor scratchBuffer:scratchBuffer];
}

@end
