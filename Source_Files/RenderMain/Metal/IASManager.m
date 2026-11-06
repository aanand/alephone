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
#import "Common.h"

static const NSUInteger verticesElementSize = sizeof(simd_float3) * 3;

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
	
	NSUInteger numPrimitives;
	NSUInteger numTriangles;
	NSUInteger numInstances;
}

- (IASManager*) initWithPipeline:(MetalPipeline *)p
		primitiveDataElementSize:(NSUInteger)pdes
						   error:(NSError *__autoreleasing *)error
{
	if (self = [super init]) {
		pipeline = p;
		primitiveDataElementSize = pdes;
		
		_label = [NSString stringWithFormat:@"%@", self];

		MTLResidencySetDescriptor *residencySetDescriptor = [MTLResidencySetDescriptor new];
		residencySetDescriptor.label = [NSString stringWithFormat:@"[%@] residencySet", _label];
		residencySet = [pipeline.device newResidencySetWithDescriptor:residencySetDescriptor error:error];
		if (!residencySet) {
			return nil;
		}
		[pipeline.commandQueue addResidencySet:residencySet];

		PASVertexBuffer = [pipeline.device newBufferWithLength:verticesElementSize * MAX_TRIANGLES
													   options:MTLResourceStorageModeShared];
		PASVertexBuffer.label = [NSString stringWithFormat:@"[%@] PASVertexBuffer", _label];
		[residencySet addAllocation:PASVertexBuffer];
		
		PASPrimitiveDataBuffer = [pipeline.device newBufferWithLength:primitiveDataElementSize * MAX_TRIANGLES
															  options:MTLResourceStorageModeShared];
		PASPrimitiveDataBuffer.label = [NSString stringWithFormat:@"[%@] PASPrimitiveDataBuffer", _label];
		[residencySet addAllocation:PASPrimitiveDataBuffer];

		IASInstanceBuffer = [pipeline.device newBufferWithLength:sizeof(MTLIndirectAccelerationStructureInstanceDescriptor) * MAX_INSTANCES
														 options:MTLResourceStorageModeShared];
		IASInstanceBuffer.label = [NSString stringWithFormat:@"[%@] IASInstanceBuffer", _label];
		[residencySet addAllocation:IASInstanceBuffer];

		// IASDescriptor's attributes are overwritten on each frame
		IASDescriptor = [[MTL4InstanceAccelerationStructureDescriptor alloc] init];
		IASDescriptor.instanceCount = MAX_INSTANCES;
		IASDescriptor.instanceDescriptorBuffer = MTL4BufferRangeMake(IASInstanceBuffer.gpuAddress, IASInstanceBuffer.length);
		
		IAS = [pipeline.device newAccelerationStructureWithDescriptor:IASDescriptor];
		IAS.label = [NSString stringWithFormat:@"[%@] IAS", _label];
		[residencySet addAllocation:IAS];
	}
	return self;
}

- (NSUInteger) addPrimitive:(id<ASTrianglePrimitive>)primitive {
	assert(numTriangles + primitive.numTriangles < MAX_TRIANGLES);

	size_t vertexDataOffset = numTriangles * verticesElementSize;
	size_t vertexDataSize = primitive.numTriangles * verticesElementSize;
	
	size_t primitiveDataOffset = numTriangles * primitiveDataElementSize;
	size_t primitiveDataSize = primitive.numTriangles * primitiveDataElementSize;
	
	memcpy(PASVertexBuffer.contents        + vertexDataOffset,    primitive.vertices,      vertexDataSize);
	memcpy(PASPrimitiveDataBuffer.contents + primitiveDataOffset, primitive.primitiveData, primitiveDataSize);

	MTL4AccelerationStructureTriangleGeometryDescriptor *geometryDescriptor = [[MTL4AccelerationStructureTriangleGeometryDescriptor alloc] init];
	geometryDescriptor.triangleCount = primitive.numTriangles;
	geometryDescriptor.vertexBuffer = MTL4BufferRangeMake(PASVertexBuffer.gpuAddress + vertexDataOffset, vertexDataSize);
	geometryDescriptor.vertexFormat = MTLAttributeFormatFloat3;
	geometryDescriptor.vertexStride = sizeof(simd_float3);
	geometryDescriptor.primitiveDataBuffer = MTL4BufferRangeMake(PASPrimitiveDataBuffer.gpuAddress + primitiveDataOffset, primitiveDataSize);
	geometryDescriptor.primitiveDataElementSize = primitiveDataElementSize;
	geometryDescriptor.primitiveDataStride = primitiveDataElementSize;
	
	// TODO: only set this for triangles that actually have any transparency (which is the minority)
	geometryDescriptor.intersectionFunctionTableOffset = 0;
	geometryDescriptor.opaque = NO;
	
	MTL4PrimitiveAccelerationStructureDescriptor *primitiveASDescriptor = [[MTL4PrimitiveAccelerationStructureDescriptor alloc] init];
	primitiveASDescriptor.geometryDescriptors = @[ geometryDescriptor ];
	
	id<MTLAccelerationStructure> primitiveAS = [pipeline.device newAccelerationStructureWithDescriptor:primitiveASDescriptor];
	primitiveAS.label = [NSString stringWithFormat:@"[%@] PAS %lu (%lu triangles)", _label, numPrimitives+1, primitive.numTriangles];
	
	[PASes addObject:primitiveAS];
	[PASDescriptors addObject:primitiveASDescriptor];

	numTriangles += primitive.numTriangles;
	
	NSUInteger primitiveIdx = numPrimitives;
	numPrimitives++;
	return primitiveIdx;
}

- (void) addInstanceOfPrimitive:(NSUInteger)primitiveIdx
				  withTransform:(simd_float4x3)transform
					 instanceID:(uint32_t)instanceID
						   mask:(uint)mask
{
	assert(numInstances + 1 < MAX_INSTANCES);
	assert(primitiveIdx < PASes.count);

	id<MTLAccelerationStructure> primitiveAS = [PASes objectAtIndex:primitiveIdx];

	MTLPackedFloat4x3 packedTransform = {
		.columns = {
			MTLPackedFloat3Make(transform.columns[0][0], transform.columns[0][1], transform.columns[0][2]),
			MTLPackedFloat3Make(transform.columns[1][0], transform.columns[1][1], transform.columns[1][2]),
			MTLPackedFloat3Make(transform.columns[2][0], transform.columns[2][1], transform.columns[2][2]),
			MTLPackedFloat3Make(transform.columns[3][0], transform.columns[3][1], transform.columns[3][2]),
		}
	};
	
	MTLIndirectAccelerationStructureInstanceDescriptor desc = {};
	desc.accelerationStructureID = primitiveAS.gpuResourceID;
	desc.intersectionFunctionTableOffset = 0;
	desc.mask = mask;
	desc.transformationMatrix = packedTransform;
	desc.userID = instanceID;

	MTLIndirectAccelerationStructureInstanceDescriptor *target = IASInstanceBuffer.contents;
	target[numInstances] = desc;
	numInstances++;
}

- (void) updateIASDescriptor {
	IASDescriptor.instanceCount = numInstances;
	IASDescriptor.instanceDescriptorBuffer = MTL4BufferRangeMake(IASInstanceBuffer.gpuAddress, sizeof(MTLIndirectAccelerationStructureInstanceDescriptor) * numInstances);
}

- (void) commitGeometry
{
	[self updateIASDescriptor];

	for (id<MTLAccelerationStructure> staticPAS in PASes) {
		[residencySet addAllocation:staticPAS];
	}
	[residencySet commit];
}

- (void) commitInstances {
	[self updateIASDescriptor];
}

- (void) clearGeometry {
	for (id<MTLAllocation> PAS in PASes) {
		[residencySet removeAllocation:PAS];
	}
	[residencySet commit];
	
	PASes = [NSMutableArray array];
	PASDescriptors = [NSMutableArray array];
	
	numTriangles = 0;
	numPrimitives = 0;
	
	[self clearInstances];
}

- (void) clearInstances {
	numInstances = 0;
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

		[encoder barrierAfterEncoderStages:MTLStageAccelerationStructure
					   beforeEncoderStages:MTLStageAccelerationStructure
						 visibilityOptions:MTL4VisibilityOptionDevice];
	}
}

- (void) encodeBuildCommandsForIAS:(id<MTL4ComputeCommandEncoder>)encoder scratchBuffer:(MTL4BufferRange)scratchBuffer {
	[encoder buildAccelerationStructure:IAS descriptor:IASDescriptor scratchBuffer:scratchBuffer];

	[encoder barrierAfterEncoderStages:MTLStageAccelerationStructure
				   beforeEncoderStages:MTLStageAccelerationStructure
					 visibilityOptions:MTL4VisibilityOptionDevice];
}

@end
