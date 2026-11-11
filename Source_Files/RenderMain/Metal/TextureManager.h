//
//  TextureManager.h
//  AlephOne
//
//  Created by Aanand Prasad on 31/10/2026.
//

#import <Foundation/Foundation.h>

#import "MetalTypes.h"
#import "MetalPipeline.h"

NS_ASSUME_NONNULL_BEGIN

@interface TextureManager : NSObject

@property (nonatomic) MetalPipeline *pipeline;

@property (nonatomic, readonly) NSMutableOrderedSet<NSString*> *textureIDs;
@property (nonatomic, readonly) NSMutableDictionary<NSString *, id<MTLTexture>> *albedoTextures;
@property (nonatomic, readonly) NSMutableDictionary<NSString *, id<MTLTexture>> *normalMaps;
@property (nonatomic, readonly) NSMutableDictionary<NSString *, id<MTLTexture>> *emissionMaps;

- (void) startUpdatingAllGeometry;
- (void) finishUpdatingAllGeometry;
- (void) startUpdatingDynamicGeometry;
- (void) finishUpdatingDynamicGeometry;

- (NSUInteger) indexOfTextureWithID:(NSString*)textureID;

- (NSUInteger) addTextureWithID:(NSString*)textureID
						 albedo:(MetalImage*_Nullable)albedo
						 normal:(MetalImage*_Nullable)normal
					   emission:(MetalImage*_Nullable)emission;

- (NSUInteger) addPlaceholderTextureWithID:(NSString*)textureID;

@end

NS_ASSUME_NONNULL_END
