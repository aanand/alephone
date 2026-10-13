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

- (void) shutdown;

/**
 Rendering
 */

- (void) updateViewWithOrigin:(simd_int3)origin
						pitch:(float)pitch
						  yaw:(float)yaw
						  FOV:(float)fov
				  weaponFlare:(float)weaponFlare
				   flashlight:(float)flashlight
				   isInMedium:(bool)isInMedium;

- (void) updateSky:(Sky)sky;

- (void) begin;
- (void) end;

/**
 Geometry
 */

- (void) startUpdatingAllGeometry;
- (void) finishUpdatingAllGeometry;
- (void) startUpdatingDynamicGeometry;
- (void) finishUpdatingDynamicGeometry;

- (void) addStaticPolygon:(MetalPolygon*)polygon;
- (void) addDynamicPolygon:(MetalPolygon*)polygon withID:(int)ID enabled:(BOOL)isEnabled;
- (void) addStaticWall:(MetalWall*)wall;
- (void) addDynamicWall:(MetalWall*)wall enabled:(BOOL)isEnabled;
- (void) updateSprite:(MetalSprite*)sprite;
- (void) updateLightSourceIntensities:(NSArray<NSNumber*>*)intensities;

/**
 Textures
 */

- (bool) hasTextureWithID:(NSString*)textureID;

- (void) addTextureWithID:(NSString*)textureID
				   albedo:(MetalImage*)albedo
				   normal:(MetalImage*)normal
				 emission:(MetalImage*)emission;

- (void) addPlaceholderTextureWithID:(NSString *)textureID;

@end

#endif /* MetalRenderer_h */
