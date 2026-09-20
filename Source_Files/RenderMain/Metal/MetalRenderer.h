//
//  MetalRenderer.h
//  AlephOne
//
//  Created by Aanand Prasad on 28/08/2026.
//

#ifndef MetalRenderer_h
#define MetalRenderer_h

#import <Foundation/NSObject.h>
#import <simd/simd.h>

#import <SDL2/SDL.h>

#import "Metal/MetalTypes.h"

API_AVAILABLE(macos(26.0))
@interface MetalRenderer : NSObject

- (MetalRenderer *) initializeWithWindow:(SDL_Window *)window
								 width:(int)width
								height:(int)height;

/**
 Rendering
 */

- (void) updateViewWithOrigin:(simd_int3)origin
						pitch:(float)pitch
						  yaw:(float)yaw
						  FOV:(float)fov
				  weaponFlare:(float)weaponFlare;

- (void) begin;
- (void) end;

/**
 Geometry
 */

- (void) startUpdatingAllGeometry;
- (void) finishUpdatingAllGeometry;
- (void) startUpdatingDynamicGeometry;
- (void) finishUpdatingDynamicGeometry;

- (void) addPolygon:(MetalPolygon*)polygon withID:(int)ID dynamic:(BOOL)isDynamic;
- (void) addWall:(MetalWall*)wall dynamic:(BOOL)isDynamic;
- (void) updateSprite:(MetalSprite*)sprite;
- (void) updateLightSourceIntensities:(NSArray<NSNumber*>*)intensities;

/**
 Textures
 */

- (bool) hasTextureWithID:(NSString*)textureID;
- (void) addTextureWithID:(NSString*)textureID image:(MetalImage*)image;
- (void) addPlaceholderTextureWithID:(NSString *)textureID;

@end

#endif /* MetalRenderer_h */
