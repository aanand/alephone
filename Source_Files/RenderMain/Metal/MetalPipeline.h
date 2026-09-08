//
//  MetalPipeline.h
//  AlephOne
//
//  Created by Aanand Prasad on 07/09/2026.
//

#ifndef MetalPipeline_h
#define MetalPipeline_h

#import <Foundation/NSObject.h>
#include <MetalKit/MetalKit.h>

@interface MetalPipeline : NSObject

@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTL4CommandQueue> commandQueue;
@property (nonatomic, strong) id<MTL4CommandBuffer> commandBuffer;
@property (nonatomic, strong) id<MTLLibrary> defaultLibrary;
@property (nonatomic, strong) id<MTL4CommandAllocator> commandAllocator;
@property (nonatomic, strong) id<MTLSharedEvent> sharedEvent;

@end

#endif /* MetalPipeline_h */
