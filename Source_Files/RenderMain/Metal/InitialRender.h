//
//  InitialRender.h
//  AlephOne
//
//  Created by Aanand Prasad on 31/10/2026.
//

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#import "MetalPipeline.h"
#import "MetalTypes.h"
#import "GeometryManager.h"
#import "TextureManager.h"
#import "View.h"
#import "Common.h"

NS_ASSUME_NONNULL_BEGIN

@interface InitialRender : NSObject

// Configuration + dependencies

@property (nonatomic) MetalPipeline *pipeline;
@property (nonatomic) View *view;
@property (nonatomic, assign) PostProcessingType postProcessingType;

@property (nonatomic) id<MTLDepthStencilState> depthState;
@property (nonatomic) id<MTLBuffer> uniformsBuffer;

@property (nonatomic) GeometryManager *geometryManager;
@property (nonatomic) TextureManager *textureManager;

// Owned resources

@property (readonly) id<MTLTexture> diffuseAlbedoTexture;
@property (readonly) id<MTLTexture> specularAlbedoTexture;
@property (readonly) id<MTLTexture> roughnessTexture;
@property (readonly) id<MTLTexture> depthTexture;
@property (readonly) id<MTLTexture> normalTexture;
@property (readonly) id<MTLTexture> motionTexture;

@property (readonly) NSSet<id<MTLTexture>> *textures;
@property (readonly) id<MTLResidencySet> residencySet;

// Lifecycle

- (instancetype) initWithPipeline:(MetalPipeline*)pipeline;
- (bool) compile;
- (void) encodeAndUpdateFence:(id<MTLFence>)fence;
- (void) shutdown;

@end

NS_ASSUME_NONNULL_END
