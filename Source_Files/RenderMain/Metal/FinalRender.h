//
//  FinalRender.h
//  AlephOne
//
//  Created by Aanand Prasad on 01/11/2026.
//

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#import "MetalPipeline.h"
#import "View.h"
#import "Common.h"

NS_ASSUME_NONNULL_BEGIN

@interface FinalRender : NSObject

// Dependencies

@property (nonatomic) MetalPipeline *pipeline;
@property (nonatomic) View *view;
@property (nonatomic, assign) PostProcessingType postProcessingType;

// Inputs

@property (nonatomic) id<MTLTexture> diffuseAlbedoTexture;
@property (nonatomic) id<MTLTexture> rayTracingOutputTexture;
@property (nonatomic) id<MTLTexture> postProcessingScratchTexture;
@property (nonatomic) id<MTLTexture> postProcessingOutputTexture;
@property (nonatomic) id<MTLBuffer> uniformsBuffer;

// Outputs

@property (nonatomic, readonly) id<MTLResidencySet> residencySet;

// Lifecycle

- (bool) compileForPixelFormat:(MTLPixelFormat)pixelFormat;
- (id<MTLTexture>)HUDTexture;
- (void) setHUDTexture:(id<MTLTexture>)hudTexture;
- (void) encodeToOutputTexture:(id<MTLTexture>)outputTexture afterFences:(NSArray<id<MTLFence>>*)fences;
- (void) shutdown;

@end

NS_ASSUME_NONNULL_END
