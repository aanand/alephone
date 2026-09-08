//
//  IASManager.h
//  AlephOne
//
//  Created by Aanand Prasad on 07/09/2026.
//

#ifndef IASManager_h
#define IASManager_h

#import <Foundation/NSObject.h>
#import <MetalKit/MetalKit.h>
#import "MetalPipeline.h"

@interface IASManager : NSObject

- (IASManager*) initWithPipeline:(MetalPipeline*)p error:(NSError**)error;

/**
 clearGeometry MUST be called before the first commitGeometry
 */
- (void) clearGeometry;

- (void) commitGeometryWithVertices:(simd_float3*)vertices
					   numTriangles:(NSUInteger)numTriangles
				  trianglesPerBatch:(NSUInteger)trianglesPerBatch
					  primitiveData:(void*)primitiveData
				  primitiveDataElementSize:(NSUInteger)primitiveDataSize;

- (MTLResourceID) IASResourceID;
- (NSArray<MTL4AccelerationStructureDescriptor*>*) allASDescriptors;

- (void) encodeBuildCommandsForPASes:(id<MTL4ComputeCommandEncoder>)encoder scratchBuffer:(MTL4BufferRange)scratchBuffer;
- (void) encodeBuildCommandsForIAS:(id<MTL4ComputeCommandEncoder>)encoder scratchBuffer:(MTL4BufferRange)scratchBuffer;

@end

#endif /* IASManager_h */
