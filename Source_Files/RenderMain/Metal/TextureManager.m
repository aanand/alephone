//
//  TextureManager.m
//  AlephOne
//
//  Created by Aanand Prasad on 31/10/2026.
//

#import "TextureManager.h"

#import <Metal/Metal.h>

@implementation TextureManager

-(instancetype)init {
	if (self = [super init]) {
		_textureIDs = [NSMutableOrderedSet new];
		_albedoTextures = [NSMutableDictionary dictionary];
		_normalMaps = [NSMutableDictionary dictionary];
		_emissionMaps = [NSMutableDictionary dictionary];
	}
	return self;
}

-(void)startUpdatingAllGeometry {
	[_textureIDs removeAllObjects];
	[_albedoTextures removeAllObjects];
	[_normalMaps removeAllObjects];
	[_emissionMaps removeAllObjects];
}

-(void)finishUpdatingAllGeometry {}

-(void)startUpdatingDynamicGeometry {}
-(void)finishUpdatingDynamicGeometry {}

-(void)shutdown {
	_albedoTextures = nil;
	_normalMaps = nil;
	_emissionMaps = nil;
}

- (bool) hasTextureWithID:(NSString*)textureID {
	return [_textureIDs containsObject:textureID];
}

-(void)addTextureWithID:(NSString *)textureID albedo:(MetalImage *)albedo normal:(MetalImage *)normal emission:(MetalImage *)emission {
	NSAssert(_textureIDs.count < MAX_TEXTURES, @"Exceeded texture limit");

	id<MTLTexture> albedoTexture = [self makeTextureFromImage:(albedo ? albedo : [self defaultAlbedoImage])];
	albedoTexture.label = textureID;
	[_albedoTextures setObject:albedoTexture forKey:textureID];

	id<MTLTexture> normalMap = [self makeTextureFromImage:(normal ? normal : [self defaultNormalMap])];
	normalMap.label = [NSString stringWithFormat:@"%@ (normal map)", textureID];
	[_normalMaps setObject:normalMap forKey:textureID];

	id<MTLTexture> emissionMap = [self makeTextureFromImage:(emission ? emission : [self defaultEmissionMap])];
	emissionMap.label = [NSString stringWithFormat:@"%@ (emission map)", textureID];
	[_emissionMaps setObject:emissionMap forKey:textureID];

	[_textureIDs addObject:textureID];
}

- (void) addPlaceholderTextureWithID:(NSString *)textureID {
	[self addTextureWithID:textureID albedo:nil normal:nil emission:nil];
}

- (MetalImage*) defaultAlbedoImage {
	uint32 albedoPixels[1] = { 255u | (0u << 8) | (255u << 16) | (255u << 24) };
	return [[MetalImage alloc] initWithWidth:1 height:1 pixels:albedoPixels];
}

- (MetalImage*) defaultNormalMap {
	uint32 normalPixels[1] = { 255u | (128u << 8) | (128u << 16) | (255u << 24) };
	return [[MetalImage alloc] initWithWidth:1 height:1 pixels:normalPixels];
}

- (MetalImage*) defaultEmissionMap {
	uint32 emissionPixels[1] = { 0u | (0u << 8) | (0u << 16) | (0u << 24) };
	return [[MetalImage alloc] initWithWidth:1 height:1 pixels:emissionPixels];
}

- (id<MTLTexture>) makeTextureFromImage:(MetalImage *)image {
	MTLTextureDescriptor *descriptor = [[MTLTextureDescriptor alloc] init];
	descriptor.pixelFormat = MTLPixelFormatBGRA8Unorm;
	descriptor.width = image.width;
	descriptor.height = image.height;
	
	MTLRegion region = {
		{ 0, 0, 0 },
		{ image.width, image.height, 1 }
	};

	id<MTLTexture> texture = [_pipeline.device newTextureWithDescriptor:descriptor];
	[texture replaceRegion:region
			   mipmapLevel:0
				 withBytes:image.data.bytes
			   bytesPerRow:sizeof(uint32) * image.width];

	return texture;
}

@end
