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

bool Metal_InitializeForWindow(SDL_Window* window, int w, int h) {
    logWarning("Metal_InitializeForWindow(window, %d, %d)", w, h);
    
    SDL_Renderer *renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_PRESENTVSYNC);
    const CAMetalLayer *metalLayer = (__bridge CAMetalLayer*)SDL_RenderGetMetalLayer(renderer);
    const id<MTLDevice> device = metalLayer.device;
    const id<MTLCommandQueue> queue = [device newCommandQueue];
    
    MTLClearColor color = MTLClearColorMake(1, 0, 0, 0.5);
    
    id<CAMetalDrawable> surface = [metalLayer nextDrawable];
    
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].clearColor = color;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].texture = surface.texture;

    id<MTLCommandBuffer> buffer = [queue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
    [encoder endEncoding];
    [buffer presentDrawable:surface];
    [buffer commit];
    
    return true;
}
