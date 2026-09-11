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

@property (nonatomic, strong) NSString *label;

/**
 For rebuilding everything. Avoid calling per-frame.
 clearGeometry MUST be called before the first commitGeometry
 */
- (void) clearGeometry;
- (void) commitGeometry;

/**
 For rebuilding only the instances. Better for per-frame updates.
 */
- (void) clearInstances;
- (void) commitInstances;

/**
 Must be called between clearGeometry and commitGeometry.
 */
- (void) addPrimitive:(id<ASTrianglePrimitive>)primitive;

/**
 Can be called either between clearGeometry/commitGeometry or clearInstances/commitInstances.
 */
- (void) addInstanceOfPrimitive:(id<ASTrianglePrimitive>)primitive
				  withTransform:(MTLPackedFloat4x3)transform
					 instanceID:(uint32_t)instanceID;

- (MTLResourceID) IASResourceID;
- (NSArray<MTL4AccelerationStructureDescriptor*>*) allASDescriptors;

- (void) encodeBuildCommandsForPASes:(id<MTL4ComputeCommandEncoder>)encoder scratchBuffer:(MTL4BufferRange)scratchBuffer;
- (void) encodeBuildCommandsForIAS:(id<MTL4ComputeCommandEncoder>)encoder scratchBuffer:(MTL4BufferRange)scratchBuffer;

@end

#endif /* IASManager_h */
