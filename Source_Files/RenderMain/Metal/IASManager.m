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

@implementation IASManager
{
	MetalPipeline* pipeline;
	id<MTLResidencySet> residencySet;
	id<MTLBuffer> PASVertexBuffer;
	id<MTLBuffer> PASPrimitiveDataBuffer;
	id<MTLBuffer> IASInstanceBuffer;
	NSMutableArray<id<MTLAccelerationStructure>> *PASes;
	NSMutableArray<MTL4AccelerationStructureDescriptor*> *PASDescriptors;
	id<MTLAccelerationStructure> IAS;
	MTL4InstanceAccelerationStructureDescriptor *IASDescriptor;
}

- (IASManager*) initWithPipeline:(MetalPipeline*)p error:(NSError *__nullable*)error {
	if (self = [super init]) {
		pipeline = p;

		MTLResidencySetDescriptor *residencySetDescriptor = [MTLResidencySetDescriptor new];
		residencySet = [pipeline.device newResidencySetWithDescriptor:residencySetDescriptor error:error];
		if (!residencySet) {
			return nil;
		}
		[pipeline.commandQueue addResidencySet:residencySet];
	}
	return self;
}

- (void) commitGeometryWithVertices:(simd_float3*)vertices
					   numTriangles:(NSUInteger)numTriangles
				  trianglesPerBatch:(NSUInteger)trianglesPerBatch
					  primitiveData:(void*)primitiveData
				  primitiveDataElementSize:(NSUInteger)primitiveDataSize
{
	NSUInteger numBatches = numTriangles / trianglesPerBatch;

	PASVertexBuffer = [pipeline.device newBufferWithBytes:vertices
												length:sizeof(simd_float3) * numTriangles * 3
											   options:MTLResourceStorageModeShared];
	PASVertexBuffer.label = @"staticPASVertexBuffer";
	
	PASPrimitiveDataBuffer = [pipeline.device newBufferWithBytes:primitiveData
													   length:primitiveDataSize * numTriangles
													  options:MTLResourceStorageModeShared];
	PASPrimitiveDataBuffer.label = @"staticPASPrimitiveDataBuffer";
	
	PASes = [NSMutableArray array];
	PASDescriptors = [NSMutableArray array];
	MTLIndirectAccelerationStructureInstanceDescriptor instanceDescriptors[numBatches];
	
	for (int b = 0; b < numBatches; b++) {
		NSUInteger batchOffset = b * trianglesPerBatch;
		NSUInteger trianglesInBatch = MIN(numTriangles - batchOffset, trianglesPerBatch);
		
		MTL4AccelerationStructureTriangleGeometryDescriptor *geometryDescriptor = [[MTL4AccelerationStructureTriangleGeometryDescriptor alloc] init];
		geometryDescriptor.triangleCount = trianglesInBatch;
		geometryDescriptor.vertexBuffer = MTL4BufferRangeMake(PASVertexBuffer.gpuAddress + sizeof(simd_float3) * batchOffset * 3,
															  sizeof(simd_float3) * trianglesInBatch * 3);
		geometryDescriptor.vertexFormat = MTLAttributeFormatFloat3;
		geometryDescriptor.vertexStride = sizeof(simd_float3);
		geometryDescriptor.primitiveDataBuffer = MTL4BufferRangeMake(PASPrimitiveDataBuffer.gpuAddress + primitiveDataSize * batchOffset,
																	 primitiveDataSize * trianglesInBatch);
		geometryDescriptor.primitiveDataElementSize = primitiveDataSize;
		geometryDescriptor.primitiveDataStride = primitiveDataSize;
		
		MTL4PrimitiveAccelerationStructureDescriptor *primitiveASDescriptor = [[MTL4PrimitiveAccelerationStructureDescriptor alloc] init];
		primitiveASDescriptor.geometryDescriptors = @[ geometryDescriptor ];
		
		id<MTLAccelerationStructure> primitiveAS = [pipeline.device newAccelerationStructureWithDescriptor:primitiveASDescriptor];
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
		
		[PASes addObject:primitiveAS];
		[PASDescriptors addObject:primitiveASDescriptor];
		instanceDescriptors[b] = instanceDescriptor;
	}
	
	IASInstanceBuffer = [pipeline.device newBufferWithBytes:&instanceDescriptors
												  length:sizeof(MTLIndirectAccelerationStructureInstanceDescriptor) * numBatches
												 options:MTLResourceStorageModeShared];
	IASInstanceBuffer.label = @"staticIASInstanceBuffer";
	
	IASDescriptor = [[MTL4InstanceAccelerationStructureDescriptor alloc] init];
	IASDescriptor.instanceCount = PASes.count;
	IASDescriptor.instanceDescriptorBuffer = MTL4BufferRangeMake(IASInstanceBuffer.gpuAddress, IASInstanceBuffer.length);
	
	IAS = [pipeline.device newAccelerationStructureWithDescriptor:IASDescriptor];
	
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
