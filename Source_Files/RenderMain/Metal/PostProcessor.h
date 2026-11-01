//
//  PostProcessor.h
//  AlephOne
//
//  Created by Aanand Prasad on 01/11/2026.
//

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#import "MetalPipeline.h"
#import "View.h"
#import "InitialRender.h"

NS_ASSUME_NONNULL_BEGIN

@interface PostProcessor : NSObject

// Dependencies

@property (nonatomic) MetalPipeline *pipeline;
@property (nonatomic) View *view;
@property (nonatomic) InitialRender *initialRender;

// Inputs

@property (nonatomic) id<MTLTexture> rayTracingOutputTexture;
@property (nonatomic) id<MTLBuffer> uniformsBuffer;

// Outputs

@property (nonatomic, readonly) id<MTLTexture> scratchTexture;
@property (nonatomic, readonly) id<MTLTexture> outputTexture;
@property (nonatomic, readonly) id<MTLResidencySet> residencySet;

// Lifecycle

- (bool) compile;
- (void) encodeWaveletDenoiseUpdatingFence:(id<MTLFence>)fence;
- (void) encodeTAAUpdatingFence:(id<MTLFence>)fence;
- (void) encodeTemporalUpscaleUpdatingFence:(id<MTLFence>)fence;
- (void) encodeTemporalDenoisedUpscaleUpdatingFence:(id<MTLFence>)fence;

@end

NS_ASSUME_NONNULL_END
