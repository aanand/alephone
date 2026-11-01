//
//  RayTracer.h
//  AlephOne
//
//  Created by Aanand Prasad on 01/11/2026.
//

#import <Foundation/Foundation.h>

#import <Metal/Metal.h>

#import "MetalPipeline.h"
#import "GeometryManager.h"
#import "TextureManager.h"
#import "View.h"

NS_ASSUME_NONNULL_BEGIN

@interface RayTracer : NSObject

// Dependencies

@property (nonatomic) MetalPipeline *pipeline;
@property (nonatomic) View *view;
@property (nonatomic) GeometryManager *geometryManager;
@property (nonatomic) TextureManager *textureManager;

// Inputs

@property (nonatomic) id<MTLBuffer> uniformsBuffer;
@property (nonatomic) id<MTLTexture> depthTexture;
@property (nonatomic) id<MTLTexture> motionTexture;

// Owned resources

@property (nonatomic, readonly) id<MTLTexture> outputTexture;
@property (nonatomic, readonly) id<MTLResidencySet> residencySet;

// Lifecycle

- (bool) compile;
- (void) shutdown;

- (void) clearLightSources;
- (void) updateLightSourceIntensities:(NSArray<NSNumber *> *)intensities;
- (void) writeLightSources;

- (void) clearGeometryAllocations;
- (void) addGeometryAllocations;

- (void) encodeAndUpdateFence:(id<MTLFence>)fence;

@end

NS_ASSUME_NONNULL_END
