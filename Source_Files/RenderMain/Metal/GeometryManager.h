//
//  GeometryManager.h
//  AlephOne
//
//  Created by Aanand Prasad on 31/10/2026.
//

#import <Foundation/Foundation.h>

#import "MetalTypes.h"
#import "MetalPipeline.h"
#import "TextureManager.h"
#import "View.h"

NS_ASSUME_NONNULL_BEGIN

@interface GeometryManager : NSObject

@property (nonatomic) View *view;
@property (nonatomic) TextureManager *textureManager;

// Triangle data for rasterizer
@property (nonatomic, readonly) NSMutableArray<Triangle*> *staticTriangles;
@property (nonatomic, readonly) NSMutableArray<Triangle*> *dynamicTriangles;

// Acceleration structure for raytracer
@property (nonatomic, readonly) id<MTLBuffer> perInstanceDataBuffer;
@property (nonatomic, readonly) id<MTLAccelerationStructure> topLevelIAS;

@property (nonatomic, readonly) id<MTLResidencySet> residencySet;

- (instancetype) initWithPipeline:(MetalPipeline*)pipeline;
- (bool) compile;

- (void) startUpdatingAllGeometry;
- (void) finishUpdatingAllGeometry;
- (void) startUpdatingDynamicGeometry;
- (void) finishUpdatingDynamicGeometry;

- (void) addStaticPolygon:(MetalPolygon*)polygon;
- (void) addDynamicPolygon:(MetalPolygon*)polygon withID:(int)ID enabled:(BOOL)isEnabled;
- (void) addStaticWall:(MetalWall*)wall;
- (void) addDynamicWall:(MetalWall*)wall enabled:(BOOL)isEnabled;
- (void) updateSprite:(MetalSprite*)sprite;

- (void) shutdown;

@end

NS_ASSUME_NONNULL_END
