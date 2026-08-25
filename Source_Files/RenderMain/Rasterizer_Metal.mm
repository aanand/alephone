//
//  Rasterizer_Metal.mm
//  AlephOne
//
//  Created by Aanand Prasad on 24/08/2026.
//

#include <SDL2/SDL.h>
#include <SDL2/SDL_syswm.h>

#include <Cocoa/Cocoa.h>
#include <MetalKit/MetalKit.h>
#include <dispatch/dispatch.h>

#include "Logging.h"

@interface MetalConfig : NSObject

@property (nonatomic, assign) SDL_Window *window;
@property (nonatomic, assign) SDL_Renderer *renderer;
@property (nonatomic, strong) CAMetalLayer *metalLayer;
@property (nonatomic, strong) id<MTLCommandQueue> queue;

@end

@implementation MetalConfig
@end

MetalConfig *config;

void Metal_DrawSolidColor(MTLClearColor color) {
    id<CAMetalDrawable> surface = [config.metalLayer nextDrawable];
    
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].clearColor = color;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].texture = surface.texture;

    id<MTLCommandBuffer> buffer = [config.queue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
    [encoder endEncoding];
    [buffer presentDrawable:surface];
    [buffer commit];
}

bool Metal_InitializeForWindow(SDL_Window* window) {
    logWarning("Metal_InitializeForWindow(window)");

    if (config) {
        return true;
    }
    
    MetalConfig *c = [[MetalConfig alloc] init];
    c.window = window;
    c.renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_PRESENTVSYNC);
    c.metalLayer = (__bridge CAMetalLayer*)SDL_RenderGetMetalLayer(c.renderer);
    c.queue = [c.metalLayer.device newCommandQueue];
    config = c;
    
    Metal_DrawSolidColor(MTLClearColorMake(1, 0, 0, 1));
    
    return true;
}

void Metal_DrawFrame() {
    Metal_DrawSolidColor(MTLClearColorMake(0, 0, 1, 1));
}
