//
//  LoadingScreen.h
//  AlephOne
//
//  Created by Aanand Prasad on 07/11/2026.
//

#import <Foundation/Foundation.h>

#import "MetalPipeline.h"
#import "View.h"

NS_ASSUME_NONNULL_BEGIN

@interface LoadingScreen : NSObject

@property (nonatomic) View *view;

- (instancetype) initWithPipeline:(MetalPipeline*)pipeline;
- (bool) compileForPixelFormat:(MTLPixelFormat)pixelFormat;
- (void) renderToDrawable:(id<CAMetalDrawable>)currentDrawable progress:(float)progress;

@end

NS_ASSUME_NONNULL_END
