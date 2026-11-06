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
#import "Metal/View.h"

API_AVAILABLE(macos(26.0))
@interface MetalRenderer : NSObject

- (MetalRenderer *) initializeWithWindow:(SDL_Window *)window
								 width:(int)width
								height:(int)height;

- (void) shutdown;

/**
 Rendering
 */

@property (readonly) View *view;

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
- (void) updateLightSourceCount:(NSUInteger)count;
- (void) updateLightSourceIntensities:(float*)intensities;

/**
 Textures
 */

- (NSUInteger) indexOfTextureWithID:(NSString*)textureID;

- (NSUInteger) addTextureWithID:(NSString*)textureID
						 albedo:(MetalImage*)albedo
						 normal:(MetalImage*)normal
					   emission:(MetalImage*)emission;

- (NSUInteger) addPlaceholderTextureWithID:(NSString*)textureID;

@end

#endif /* MetalRenderer_h */
