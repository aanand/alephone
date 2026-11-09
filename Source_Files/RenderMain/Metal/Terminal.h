//
//  Terminal.h
//  AlephOne
//
//  Created by Aanand Prasad on 08/11/2026.
//

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#import "MetalPipeline.h"
#import "View.h"

NS_ASSUME_NONNULL_BEGIN

@interface Terminal : NSObject

@property (nonatomic) View *view;
@property (nonatomic) id<MTLBuffer> uniformsBuffer;

- (instancetype) initWithPipeline:(MetalPipeline*)pipeline;
- (bool) compileForPixelFormat:(MTLPixelFormat)pixelFormat;
- (void) setTexture:(id<MTLTexture>)texture;
- (id<MTLTexture>)texture;
- (void) renderToDrawable:(id<CAMetalDrawable>)currentDrawable;

@end

NS_ASSUME_NONNULL_END
