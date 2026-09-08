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

/**
 A protocol for exporting data from some game object to a Primitive Acceleration Structure
 */
@protocol ASTrianglePrimitive <NSObject>

- (NSUInteger) numTriangles;
- (simd_float3*) vertices;
- (void*) primitiveData;

@end

@interface IASManager : NSObject

- (IASManager*) initWithPipeline:(MetalPipeline*)pipeline
		primitiveDataElementSize:(NSUInteger)primitiveDataElementSize
						   error:(NSError**)error;

/**
 clearGeometry MUST be called before the first commitGeometry
 */
- (void) clearGeometry;
- (void) commitGeometry:(NSArray<id<ASTrianglePrimitive>>*)primitives;

- (MTLResourceID) IASResourceID;
- (NSArray<MTL4AccelerationStructureDescriptor*>*) allASDescriptors;

- (void) encodeBuildCommandsForPASes:(id<MTL4ComputeCommandEncoder>)encoder scratchBuffer:(MTL4BufferRange)scratchBuffer;
- (void) encodeBuildCommandsForIAS:(id<MTL4ComputeCommandEncoder>)encoder scratchBuffer:(MTL4BufferRange)scratchBuffer;

@end

#endif /* IASManager_h */
