//
//  Rasterizer_Metal.mm
//  AlephOne
//
//  Created by Aanand Prasad on 24/08/2026.
//

#include <SDL2/SDL.h>
#include <SDL2/SDL_syswm.h>

#include <vector>
#include <stack>
#include <unordered_set>
#include <unordered_map>

#include <Foundation/Foundation.h>

#include "Rasterizer_Metal.h"

#include "Metal/MetalRenderer.h"

#include "OGL_Textures.h"
#include "Logging.h"
#include "vbl.h"
#include "player.h"
#include "lightsource.h"
#include "media.h"
#include "Scenario.h"

#include <simd/simd.h>

#define FLASHLIGHT_HOTKEY 11
#define FLASHLIGHT_HOTKEY_FRAME_DECAY 10

API_AVAILABLE(macos(26.0))
MetalRenderer *renderer;
view_data *view;
int16 lastLoadedLevelNumber = -1;

bool isFlashlightOn = false;
uint framesSinceFlashlightToggled = 0;

const float flashlightIntensity = 5.0;

std::unordered_map<short, std::unordered_set<short>> overlaps;

@interface PolygonTexture : NSObject
@property (nonatomic) NSString *textureID;
@property (nonatomic) int scale;
@property (nonatomic) simd_float2x2 transform;
@property (nonatomic) bool hasNormalMap;
@end
@implementation PolygonTexture
@end

@interface SpriteTexture : NSObject
@property (nonatomic) NSString *textureID;
@property (nonatomic) simd_float4x2 uv;
@end
@implementation SpriteTexture
@end

NSMutableDictionary<NSString*, PolygonTexture*> *polygonTextureCache;
NSMutableDictionary<NSString*, SpriteTexture*> *spriteTextureCache;

bool Metal_InitializeForWindow(SDL_Window* window, int width, int height) {
    logWarning("Metal_InitializeForWindow(window, %d, %d)", width, height);

	if (@available(macOS 26.0, *)) {
		if (renderer) {
			[renderer shutdown];
			renderer = nil;
		}

		MetalRenderer *r = [[MetalRenderer alloc] initializeWithWindow:window width:width height:height];
		if (!r) {
			logWarning("Failed to initialize MetalRenderer");
			return false;
		}
		renderer = r;
		view = nil;
		lastLoadedLevelNumber = -1;
		
		isFlashlightOn = false;
		framesSinceFlashlightToggled = 0;

		logWarning("Initialized MetalRenderer");
		return true;
	}

	logWarning("Metal 4 not supported");
	return false;
}

// Copied from RenderRasterize_Shader.cpp
const float FixedAngleToDegrees = 360.0/(float(FIXED_ONE)*float(FULL_CIRCLE));

void UpdateWorld();

// Returns true if polygonA and polygonB overlap, using the separating axis theorem
bool polygonsOverlap(polygon_data *polygonA, polygon_data *polygonB) {
	auto aVertices = std::vector<long_vector2d>(polygonA->vertex_count);
	auto bVertices = std::vector<long_vector2d>(polygonB->vertex_count);
	auto axes = std::vector<long_vector2d>(polygonA->vertex_count + polygonB->vertex_count);

	for (short i = 0; i < polygonA->vertex_count; i++) {
		endpoint_data *ep = get_endpoint_data(polygonA->endpoint_indexes[i]);
		aVertices[i] = { ep->vertex.x, ep->vertex.y };
	}
	
	for (short i = 0; i < polygonB->vertex_count; i++) {
		endpoint_data *ep = get_endpoint_data(polygonB->endpoint_indexes[i]);
		bVertices[i] = { ep->vertex.x, ep->vertex.y };
	}
	
	for (short i = 0; i < aVertices.size(); i++) {
		long_vector2d line = aVertices[(i+1) % aVertices.size()] - aVertices[i];
		axes[i] = { -line.j, line.i };
	}
	
	for (short i = 0; i < bVertices.size(); i++) {
		long_vector2d line = bVertices[(i+1) % bVertices.size()] - bVertices[i];
		axes[aVertices.size() + i] = { -line.j, line.i };
	}
	
	for (auto &axis : axes) {
		int32 aMin = 0, aMax = 0, bMin = 0, bMax = 0;
		
		for (short i = 0; i < aVertices.size(); i++) {
			long_vector2d aVertex = aVertices[i];
			int32 dot = aVertex.i * axis.i + aVertex.j * axis.j;
			if (i == 0 || dot > aMax) aMax = dot;
			if (i == 0 || dot < aMin) aMin = dot;
		}
		
		for (short i = 0; i < bVertices.size(); i++) {
			long_vector2d bVertex = bVertices[i];
			int32 dot = bVertex.i * axis.i + bVertex.j * axis.j;
			if (i == 0 || dot > bMax) bMax = dot;
			if (i == 0 || dot < bMin) bMin = dot;
		}
		
		if ((aMin < bMax && aMin > bMin) || (bMin < aMax && bMin > aMin)) {
			continue;
		} else {
			return false;
		}
	}
	
	return true;
}

void findOverlaps() {
	overlaps = std::unordered_map<short, std::unordered_set<short>>();

	for (short i = 0; i < dynamic_world->polygon_count; i++) {
		for (short j = i+1; j < dynamic_world->polygon_count; j++) {
			if (polygonsOverlap(get_polygon_data(i), get_polygon_data(j))) {
				auto iterator = overlaps.find(i);
				if (iterator == overlaps.end()) {
					std::unordered_set<short> newSet = { j };
					overlaps.insert_or_assign(i, newSet);
				} else {
					iterator->second.insert(j);
				}
				
				iterator = overlaps.find(j);
				if (iterator == overlaps.end()) {
					std::unordered_set<short> newSet = { i };
					overlaps.insert_or_assign(j, newSet);
				} else {
					iterator->second.insert(i);
				}
			}
		}
	}
}

bool isPolygonDynamic(short polygonIdx, polygon_data *polygon) {
	if (polygon->type == _polygon_is_platform) {
		return true;
	}
	
//	if (overlaps.find(polygonIdx) != overlaps.end()) {
//		return true;
//	}
	
	return false;
}

bool overlapsWithVisiblePolygon(short polyIdx) {
	auto iterator = overlaps.find(polyIdx);
	if (iterator == overlaps.end()) return false;
	
//	for (auto &otherIdx : iterator->second) {
//		if (TEST_RENDER_FLAG(otherIdx, _polygon_is_visible)) {
//			return true;
//		}
//	}
	
	return false;
}

bool shouldMarkVisible(short polyIdx) {
	return TEST_RENDER_FLAG(polyIdx, _polygon_is_visible) || !overlapsWithVisiblePolygon(polyIdx);
}

void Rasterizer_Metal_Class::SetView(view_data &View) {
	view = &View;

	if (current_player_index != NONE) {
		player_data *player = get_player_data(current_player_index);
		if (player->hotkey == FLASHLIGHT_HOTKEY && framesSinceFlashlightToggled <= 0) {
			isFlashlightOn = !isFlashlightOn;
			framesSinceFlashlightToggled = FLASHLIGHT_HOTKEY_FRAME_DECAY;
		}
	}
	if (framesSinceFlashlightToggled > 0) {
		framesSinceFlashlightToggled--;
	}
	
	float weaponFlare = PIN(view->maximum_depth_intensity - NATURAL_LIGHT_INTENSITY, 0, FIXED_ONE)/float(FIXED_ONE);
	float flashlight = isFlashlightOn ? flashlightIntensity : 0.0;
	
	if (@available(macOS 26.0, *)) {
		if (renderer) {
			[renderer updateViewWithOrigin:simd_make_int3(View.origin.x, View.origin.y, View.origin.z)
								  pitch:View.virtual_pitch * FixedAngleToDegrees
									yaw:View.virtual_yaw * FixedAngleToDegrees
									   FOV:View.field_of_view
							   weaponFlare:weaponFlare
								flashlight:flashlight
								isInMedium:View.under_media_boundary];
		}
	}
}

void Rasterizer_Metal_Class::Begin() {
	if (@available(macOS 26.0, *)) {
		UpdateWorld();

		if (renderer) {
			[renderer begin];
		}
	}
}

void Rasterizer_Metal_Class::End() {
	if (@available(macOS 26.0, *)) {
		if (renderer) {
			[renderer end];
		}
	}
}

bool SetupPolygonTexture(TextureManager *TMgr, shape_descriptor ShapeDesc) {
	TMgr->ShapeDesc = ShapeDesc;
	TMgr->LowLevelShape = 0;
	TMgr->TransferMode = _textured_transfer;
	TMgr->TransferData = 0;
	TMgr->IsShadeless = 0;
	
	get_shape_bitmap_and_shading_table(ShapeDesc, &TMgr->Texture, &TMgr->ShadingTables, _shading_normal);

	return TMgr->Setup();
}

bool SetupSpriteTexture(TextureManager *TMgr, short collection_code, short low_level_shape_index)
{
	bitmap_definition *texture;
	void *shading_tables;
	extended_get_shape_bitmap_and_shading_table(collection_code, low_level_shape_index, &texture, &shading_tables, view->shading_mode);

	TMgr->ShapeDesc = BUILD_DESCRIPTOR(collection_code, 0);
	TMgr->LowLevelShape = low_level_shape_index;
	TMgr->ShadingTables = shading_tables;
	TMgr->Texture = texture;
	TMgr->TransferMode = _textured_transfer; // TODO: support other transfer modes
	TMgr->TransferData = 0; // TODO: support the transfer modes that use data (invisibility, static)
	TMgr->IsShadeless = (view->shading_mode == _shading_infravision);
	TMgr->TextureType = OGL_Txtr_Inhabitant; // TODO: support non-world sprites (weapons in hand, anything else?)

	return TMgr->Setup();
}

int GetTextureScale(TextureManager *TMgr, short transfer_mode, bool didSetup) {
	int tile_ratio = (TMgr && didSetup) ? TMgr->TileRatio() : 1;

	switch (transfer_mode) {
		case _xfer_2x:
			return 2 * WORLD_ONE * tile_ratio;
			break;
		case _xfer_4x:
			return 4 * WORLD_ONE * tile_ratio;
			break;
		default:
			return WORLD_ONE * tile_ratio;
			break;
	}
}

MetalImage* LoadTextureImage(const ImageDescriptor *image) {
	if (image == NULL || !image->IsPresent()) {
		return nil;
	}

	const uint32 *pixelsIn = image->GetBuffer();

	// Convert RGBA -> BGRA
	auto pixels = std::vector<uint32>(image->GetNumPixels());
	for (int i = 0; i < image->GetNumPixels(); i++) {
		uint32 pixel = pixelsIn[i];
		uint8 r = (pixel) & 0xFF;
		uint8 g = (pixel >> 8) & 0xFF;
		uint8 b = (pixel >> 16) & 0xFF;
		uint8 a = (pixel >> 24) & 0xFF;
		
		pixels[i] = b | (g << 8) | (r << 16) | (a << 24);
	}
	
	return [[MetalImage alloc] initWithWidth:image->GetWidth()
									  height:image->GetHeight()
									  pixels:pixels.data()];
}

NSString* LoadTextureIntoRenderer(TextureManager *TMgr, bool didSetupSucceed) {
	NSString *textureID = [NSString stringWithFormat:@"[ShapeDesc=%u/Collection=%d/CTable=%d/Frame=%d/Bitmap=%d]", TMgr->ShapeDesc, TMgr->GetCollection(), TMgr->GetCTable(), TMgr->GetFrame(), TMgr->GetBitmap()];
	
	if (@available(macOS 26.0, *)) {
		if (![renderer hasTextureWithID:textureID]) {
			if (!didSetupSucceed) {
				logWarning("Failed to set up texture %d - substituting placeholder", textureID.intValue);
				[renderer addPlaceholderTextureWithID:textureID];
				return textureID;
			}
			
			// In Aleph One, the colour texture is referred to as the "normal" texture,
			// and the normal map is referred to as the "bump" texture.
			MetalImage *albedo = LoadTextureImage(TMgr->GetNormal());
			MetalImage *normal = LoadTextureImage(TMgr->GetBump());
			MetalImage *emission = LoadTextureImage(TMgr->GetGlowing());

			[renderer addTextureWithID:textureID albedo:albedo normal:normal emission:emission];
		}
	}
	
	return textureID;
}

PolygonTexture *LoadPolygonTexture(shape_descriptor ShapeDesc, short TransferMode) {
	NSString *key = [NSString stringWithFormat:@"%u/%d", ShapeDesc, TransferMode];

	PolygonTexture *cachedResult = [polygonTextureCache objectForKey:key];
	if (cachedResult) {
		return cachedResult;
	}
	
	auto TMgr = std::make_unique<TextureManager>();
	bool didSetup = SetupPolygonTexture(TMgr.get(), ShapeDesc);
	NSString *textureID = LoadTextureIntoRenderer(TMgr.get(), didSetup);
	int scale = GetTextureScale(TMgr.get(), TransferMode, didSetup);

	PolygonTexture *result = [[PolygonTexture alloc] init];
	result.textureID = textureID;
	result.scale = scale;
	result.hasNormalMap = (TMgr->GetBump() && TMgr->GetBump()->IsPresent());
	
	if (TMgr->HasSubstitution()) {
		result.transform = (simd_float2x2){
			.columns = {
				{ 0.0, 1.0 },
				{ 1.0, 0.0 },
			}
		};
	} else {
		result.transform = (simd_float2x2){
			.columns = {
				{ 1.0, 0.0 },
				{ 0.0, 1.0 },
			}
		};
	}

	polygonTextureCache[key] = result;
	
	return result;
}

SpriteTexture *LoadSpriteTexture(short collection_code, short low_level_shape_index, shape_information_data *shape_information)
{
	NSString *key = [NSString stringWithFormat:@"%d/%d", collection_code, low_level_shape_index];
	
	SpriteTexture *cachedResult = [spriteTextureCache objectForKey:key];
	if (cachedResult) {
		return cachedResult;
	}

	auto TMgr = std::make_unique<TextureManager>();
	NSString *textureID = LoadTextureIntoRenderer(TMgr.get(), SetupSpriteTexture(TMgr.get(), collection_code, low_level_shape_index));

	SpriteTexture *result = [[SpriteTexture alloc] init];
	result.textureID = textureID;
	
	simd_float2 offset, scale;
	if (TMgr->HasSubstitution()) {
		offset = simd_make_float2(TMgr->U_Offset, TMgr->V_Offset);
		scale = simd_make_float2(TMgr->U_Scale, TMgr->V_Scale);
	} else {
		offset = simd_make_float2(TMgr->V_Offset, TMgr->U_Offset);
		scale = simd_make_float2(TMgr->V_Scale, TMgr->U_Scale);
	}

	float texL = offset.x;
	float texR = scale.x + offset.x;
	float texT = offset.y;
	float texB = scale.y + offset.y;

	if (TMgr->HasSubstitution()) {
		if (shape_information->flags & _X_MIRRORED_BIT) {
			std::swap(texB, texT);
		}
		if (shape_information->flags & _Y_MIRRORED_BIT) {
			std::swap(texL, texR);
		}
		
		result.uv = {
			(simd_float2){ texT, texR },
			(simd_float2){ texT, texL },
			(simd_float2){ texB, texL },
			(simd_float2){ texB, texR },
		};
	} else {
		if (shape_information->flags & _X_MIRRORED_BIT) {
			std::swap(texL, texR);
		}
		if (shape_information->flags & _Y_MIRRORED_BIT) {
			std::swap(texB, texT);
		}
		
		result.uv = {
			(simd_float2){ texB, texL },
			(simd_float2){ texT, texL },
			(simd_float2){ texT, texR },
			(simd_float2){ texB, texR },
		};
	}
		
	spriteTextureCache[key] = result;
	
	return result;
}

std::unordered_map<std::string, Material> materials = {
	/*
	// Light panels (M1)
	{ "[ShapeDesc=4622/Collection=18/CTable=0/Frame=14/Bitmap=14]", { .emission = simd_make_float3(2.0, 2.0, 2.0) } },
	{ "[ShapeDesc=4357/Collection=17/CTable=0/Frame=5/Bitmap=5]", { .emission = simd_make_float3(2.0, 2.0, 2.0) } },
	{ "[ShapeDesc=4358/Collection=17/CTable=0/Frame=6/Bitmap=6]", { .emission = simd_make_float3(2.0, 2.0, 2.0) } },
	
	// Terminals and pattern buffers (M1)
	{ "[ShapeDesc=2048/Collection=8/CTable=0/Frame=0/Bitmap=0]", { .emission = simd_make_float3(2.0, 10.0, 2.0) } },
	
	// Health recharge panels
	{ "[ShapeDesc=2052/Collection=8/CTable=0/Frame=4/Bitmap=4]", { .emission = simd_make_float3(0.0, 0.0, 6.0) } },
	
	// Switches (M1)
	{ "[ShapeDesc=2049/Collection=8/CTable=0/Frame=1/Bitmap=1]", { .emission = simd_make_float3(1.0, 1.0, 1.0) } },
	{ "[ShapeDesc=2050/Collection=8/CTable=0/Frame=2/Bitmap=2]", { .emission = simd_make_float3(1.0, 1.0, 1.0) } },
	
	// Panels on columns in that one side room in Arrival (M1)
	{ "[ShapeDesc=4617/Collection=18/CTable=0/Frame=9/Bitmap=9]", { .emission = simd_make_float3(6.0, 6.0, 6.0) } },
	
	// Green tiles (M1)
	{ "[ShapeDesc=4635/Collection=18/CTable=0/Frame=27/Bitmap=27]", { .emission = simd_make_float3(5.0, 5.0, 5.0) } },
	
	// Door with red biohazard symbol (M1)
	{ "[ShapeDesc=4879/Collection=19/CTable=0/Frame=15/Bitmap=15]", { .emission = simd_make_float3(1.0, 1.0, 1.0) } },
	
	// Wall with a big orange stripe in "Defend THIS!" (M1)
	{ "[ShapeDesc=4868/Collection=19/CTable=0/Frame=4/Bitmap=4]", { .emission = simd_make_float3(1.0, 1.0, 1.0) } },
	
	// Lava (M1)
	{ "[ShapeDesc=4893/Collection=19/CTable=0/Frame=29/Bitmap=29]", { .emission = simd_make_float3(10.0, 5.0, 0.0) } },
	 */
	
	// Water (M2)
	{ "[ShapeDesc=4371/Collection=17/CTable=0/Frame=19/Bitmap=19]", {
		.f0 = 0.2,
		.isTransparent = true,
		.refractiveIndex = 1.33,
	} },
};

std::unordered_map<std::string, Sky> skies = {
	{ "Marathon 1.2", (Sky){
		.bottomEmission = { 0.0, 0.0, 0.0 },
		.topEmission = { 0.0, 0.0, 0.0 },
		.hasSun = true,
		.sunEmission = { 50.0, 50.0, 50.0 },
		.sunPosition = { 1.0, -1.0, 0.0 },
		.sunRadius = 10.0 * M_PI / 180.0,
		.sunRotationSpeed = 1.0 * M_PI / 180.0,
		.sunRotationAxis = {  0.0, 1.0, 0.0 },
	} }
};

Sky defaultSky = {
	.bottomEmission = { 0.0, 0.0, 0.0 },
	.topEmission = { 5.0, 5.0, 5.0 },
	.hasSun = false,
};

//Sky defaultSky = {
//	.bottomEmission = { 1.0, 1.0, 1.0 },
//	.topEmission = { 5.0, 5.0, 5.0 },
//	.hasSun = true,
//	.sunEmission = { 10.0, 10.0, 10.0 },
//	.sunPosition = { 0.0, 0.0, 1.0 },
//	.sunRadius = 10.0 * M_PI / 180.0,
//};

Material getMaterial(NSString *textureID, bool isLandscape, bool hasNormalMap) {
	Material material = {};

	std::string key = textureID.UTF8String;
	auto iterator = materials.find(key);
	if (iterator != materials.end()) {
		material = iterator->second;
	}

	material.isLandscape = isLandscape;
	material.roughness = hasNormalMap ? 0.0 : 0.75;
	
	return material;
}

void AddWall(short polygonIdx,
			 polygon_data *polygon,
			 line_data *line,
			 short vertexIdx,
			 vertical_surface_data *surface,
			 bool isDynamic)
{
	endpoint_data *ep0 = get_endpoint_data(polygon->endpoint_indexes[vertexIdx]);
	endpoint_data *ep1 = get_endpoint_data(polygon->endpoint_indexes[(vertexIdx+1) % polygon->vertex_count]);
	
	simd_int2 v0 = { ep0->vertex.x, ep0->vertex.y };
	simd_int2 v1 = { ep1->vertex.x, ep1->vertex.y };
	
	simd_float2 d = simd_make_float2(ep1->vertex.x - ep0->vertex.x, ep1->vertex.y - ep0->vertex.y);
	simd_float3 normal = simd_normalize(simd_make_float3(-d.y, d.x, 0.0));

	if (surface->h1 <= surface->h0 || surface->texture_definition->texture == UNONE) return;
	
	PolygonTexture *texture = LoadPolygonTexture(surface->texture_definition->texture, surface->transfer_mode);
	NSString *textureID = texture.textureID;
	int div = texture.scale;

	world_distance x0 = surface->texture_definition->x0 % div;
	world_distance y0 = surface->texture_definition->y0 % div;
	float tOffset = surface->h1 + y0;
	
	simd_float4x2 uv = {
		(simd_float2){ (tOffset - surface->h0) / (float) div, (x0               ) / (float) div },
		(simd_float2){ (tOffset - surface->h1) / (float) div, (x0               ) / (float) div },
		(simd_float2){ (tOffset - surface->h1) / (float) div, (x0 + line->length) / (float) div },
		(simd_float2){ (tOffset - surface->h0) / (float) div, (x0 + line->length) / (float) div },
	};
	
	uv.columns[0] = simd_mul(texture.transform, uv.columns[0]);
	uv.columns[1] = simd_mul(texture.transform, uv.columns[1]);
	uv.columns[2] = simd_mul(texture.transform, uv.columns[2]);
	uv.columns[3] = simd_mul(texture.transform, uv.columns[3]);
	
	Material material = getMaterial(textureID, surface->transfer_mode == _xfer_landscape, texture.hasNormalMap);
	
	MetalSurface *mSurface = [[MetalSurface alloc] initWithTextureID:textureID
															material:material
															 normal:normal
												   lightSourceIndex:surface->lightsource_index];

	MetalWall *wall = [[MetalWall alloc] initWithV0:v0
												 v1:v1
											 bottom:surface->h0
												top:surface->h1
												 uv:uv
											surface:mSurface];
	
	if (isDynamic) {
		[renderer addDynamicWall:wall enabled:shouldMarkVisible(polygonIdx)];
	} else {
		[renderer addStaticWall:wall];
	}
}

void AddHorizontalSurface(short polygonIdx, polygon_data *polygon, horizontal_surface_data *surface, bool isCeiling, bool isDynamic) {
	if (surface->texture == UNONE) {
		return;
	}
	
	PolygonTexture *texture = LoadPolygonTexture(surface->texture, surface->transfer_mode);
	NSString *textureID = texture.textureID;
	float scale = (float) texture.scale;
	
	auto vertices = std::vector<simd_int2>(polygon->vertex_count);
	auto uv = std::vector<simd_float2>(polygon->vertex_count);
	
	// Pulled out of RenderRasterize_Shader::render_node_floor_or_ceiling()
	for (int i = 0; i < polygon->vertex_count; i++) {
		world_point2d position = get_endpoint_data(polygon->endpoint_indexes[isCeiling ? (polygon->vertex_count - 1 - i) : i])->vertex;
		vertices[i] = { position.x, position.y };

		simd_float2 baseUV = {
			(position.x + surface->origin.x) / scale,
			(position.y + surface->origin.y) / scale,
		};
		uv[i] = simd_mul(texture.transform, baseUV);
	}
	
	Material material = getMaterial(textureID, surface->transfer_mode == _xfer_landscape, texture.hasNormalMap);

	MetalSurface *mSurface = [[MetalSurface alloc] initWithTextureID:textureID
														   material:material
															 normal:simd_make_float3(0.0, 0.0, isCeiling ? -1.0 : 1.0)
												   lightSourceIndex:surface->lightsource_index];

	MetalPolygon *mPolygon = [[MetalPolygon alloc] initWithVertexCount:polygon->vertex_count
															  vertices:vertices.data()
																	uv:uv.data()
																height:surface->height
															   surface:mSurface];
	
	if (isDynamic) {
		int polyId = (polygonIdx * 2) + (isCeiling ? 1 : 0);
		[renderer addDynamicPolygon:mPolygon withID:polyId enabled:shouldMarkVisible(polygonIdx)];
	} else {
		[renderer addStaticPolygon:mPolygon];
	}
}

void AddHorizontalSurfaces(short polygonIdx, polygon_data *polygon, bool isDynamicPass) {
	bool isDynamicPolygon = isPolygonDynamic(polygonIdx, polygon);

	// If it's a platform, we add the floor/ceiling to the dynamic geometry.
	// If it's not a platform, we add them to the static geometry.
	if (isDynamicPolygon == isDynamicPass) {
		horizontal_surface_data floor, ceiling;
		
		floor.texture = polygon->floor_texture;
		floor.origin = polygon->floor_origin;
		floor.height = polygon->floor_height;
		floor.transfer_mode = polygon->floor_transfer_mode;
		floor.lightsource_index = polygon->floor_lightsource_index;
		AddHorizontalSurface(polygonIdx, polygon, &floor, false, isDynamicPass);
		
		ceiling.texture = polygon->ceiling_texture;
		ceiling.origin = polygon->ceiling_origin;
		ceiling.height = polygon->ceiling_height;
		ceiling.transfer_mode = polygon->ceiling_transfer_mode;
		ceiling.lightsource_index = polygon->ceiling_lightsource_index;
		AddHorizontalSurface(polygonIdx, polygon, &ceiling, true, isDynamicPass);
	}
	
	// Media goes in dynamic geometry because it animates up and down.
	if (isDynamicPass && polygon->media_index != NONE) {
		media_data *media = get_media_data(polygon->media_index);
		horizontal_surface_data media_surface;
		media_surface.texture = media->texture;
		media_surface.origin = media->origin;
		media_surface.height = media->height;
		media_surface.transfer_mode = media->transfer_mode;
		media_surface.lightsource_index = polygon->media_lightsource_index;
		AddHorizontalSurface(polygonIdx, polygon, &media_surface, false, isDynamicPass);
	}
}

// A wall is dynamic if any of the following are true:
//  - it belongs to a dynamic polygon
//  - it's adjacent to a platform polygon (because then its height will change).
//  - it's a control panel (because then its UV will change).
void AddWalls(short polygonIdx, polygon_data *polygon, bool isDynamicPass) {
	bool isDynamicPolygon = isPolygonDynamic(polygonIdx, polygon);

	for (short vertexIdx=0; vertexIdx < polygon->vertex_count; vertexIdx++) {
		short adjacentPolgyonIdx = polygon->adjacent_polygon_indexes[vertexIdx];
		bool isNextToPlatform = (adjacentPolgyonIdx != NONE && get_polygon_data(adjacentPolgyonIdx)->type == _polygon_is_platform);

		short sideIdx = polygon->side_indexes[vertexIdx];
		if (sideIdx == NONE) continue;;

		side_data *side = get_side_data(sideIdx);
		line_data *line = get_line_data(polygon->line_indexes[vertexIdx]);

		bool isControlPanel = SIDE_IS_CONTROL_PANEL(side);
		bool wallIsDynamic = isDynamicPolygon || isNextToPlatform || isControlPanel;
		if (wallIsDynamic != isDynamicPass) continue;
		
		vertical_surface_data wall;
		wall.texture_definition = &side->primary_texture;
		wall.transfer_mode = side->primary_transfer_mode;
		wall.lightsource_index = isControlPanel ? NONE : side->primary_lightsource_index;

		switch (side->type) {
			case _full_side:
				wall.h0 = polygon->floor_height;
				wall.h1 = polygon->ceiling_height;
				AddWall(polygonIdx, polygon, line, vertexIdx, &wall, isDynamicPass);
				break;

			case _low_side:
				wall.h0 = polygon->floor_height;
				wall.h1 = line->highest_adjacent_floor;
				AddWall(polygonIdx, polygon, line, vertexIdx, &wall, isDynamicPass);
				break;

			case _high_side:
				wall.h0 = line->lowest_adjacent_ceiling;
				wall.h1 = polygon->ceiling_height;
				AddWall(polygonIdx, polygon, line, vertexIdx, &wall, isDynamicPass);
				break;

			case _split_side:
				wall.h0 = line->lowest_adjacent_ceiling;
				wall.h1 = polygon->ceiling_height;
				AddWall(polygonIdx, polygon, line, vertexIdx, &wall, isDynamicPass);

				wall.h0 = polygon->floor_height;
				wall.h1 = line->highest_adjacent_floor;
				wall.texture_definition = &side->secondary_texture;
				wall.transfer_mode = side->secondary_transfer_mode;
				wall.lightsource_index = isControlPanel ? NONE : side->secondary_lightsource_index;
				AddWall(polygonIdx, polygon, line, vertexIdx, &wall, isDynamicPass);

				break;
		}
		
		if (side->transparent_texture.texture != UNONE) {
			wall.h0 = line->highest_adjacent_floor;
			wall.h1 = line->lowest_adjacent_ceiling;
			wall.texture_definition = &side->transparent_texture;
			wall.transfer_mode = side->transparent_transfer_mode;
			wall.lightsource_index = isControlPanel ? NONE : side->transparent_lightsource_index;
			AddWall(polygonIdx, polygon, line, vertexIdx, &wall, isDynamicPass);
		}
	}
}

float radians(float degrees) {
	return degrees * 8.0 * atan(1.0) / 360.0;
}

MetalSprite* GetSprite(short objectIdx, object_data *object) {
	shape_and_transfer_mode data;
	get_object_shape_and_transfer_mode(&view->origin, object, &data);
	if (data.collection_code == NONE) {
		return nil;
	}
	
	shape_information_data *shape_information = extended_get_shape_information(data.collection_code, data.low_level_shape_index);

	SpriteTexture *texture = LoadSpriteTexture(data.collection_code, data.low_level_shape_index, shape_information);

	simd_int3 position = { object->location.x, object->location.y, object->location.z };

	Rect rect = {
		.top = shape_information->world_top,
		.left = shape_information->world_left,
		.bottom = shape_information->world_bottom,
		.right = shape_information->world_right,
	};
	
	Material material = getMaterial(texture.textureID, false, false);
	
	// Normal is ignored here and set based on the sprite's rotation
	MetalSurface *surface = [[MetalSurface alloc] initWithTextureID:texture.textureID
														   material:material
															 normal:simd_make_float3(1.0, 0.0, 0.0)
												   lightSourceIndex:NONE];
	
	return [[MetalSprite alloc] initWithIndex:objectIdx
										   uv:texture.uv
										 rect:rect
									 position:position
									  surface:surface];
}

void UpdateObject(short objectIdx, object_data *object) {
	if (OBJECT_IS_INVISIBLE(object)) return;

	MetalSprite *sprite = GetSprite(objectIdx, object);
	if (!sprite) return;

	if (@available(macOS 26.0, *)) {
		[renderer updateSprite:sprite];
	}
}

void LoadStaticGeometry() {
	for (short polyIdx = 0; polyIdx < dynamic_world->polygon_count; polyIdx++) {
		polygon_data *polygon = get_polygon_data(polyIdx);
		
		AddHorizontalSurfaces(polyIdx, polygon, false);
		AddWalls(polyIdx, polygon, false);
	}
}

void UpdateDynamicGeometry() {
	for (short polyIdx = 0; polyIdx < dynamic_world->polygon_count; polyIdx++) {
		polygon_data *polygon = get_polygon_data(polyIdx);
		short objectIdx = polygon->first_object;
		
		while (objectIdx != NONE) {
			object_data *object = get_object_data(objectIdx);
			UpdateObject(objectIdx, object);
			objectIdx = object->next_object;
		}
		
		AddHorizontalSurfaces(polyIdx, polygon, true);
		AddWalls(polyIdx, polygon, true);
	}
	
	NSMutableArray<NSNumber*> *intensities = [NSMutableArray array];
	for (int32_t lightSourceIndex = 0; lightSourceIndex < MAXIMUM_LIGHTS_PER_MAP; lightSourceIndex++) {
		float intensity = get_light_intensity(lightSourceIndex) / float(FIXED_ONE - 1);
		[intensities addObject:@(intensity)];
	}
	[renderer updateLightSourceIntensities:intensities];
}

void UpdateWorld() {
	Sky sky = defaultSky;
	const std::string &scenarioId = Scenario::instance()->GetID();
	auto iterator = skies.find(scenarioId);
	if (iterator != skies.end()) {
		sky = iterator->second;
	}
	[renderer updateSky:sky];

	if (lastLoadedLevelNumber != dynamic_world->current_level_number) {
		logWarning("Loading level number %d", dynamic_world->current_level_number);
		
		// This is unfortunately necessary while we're using TextureManager,
		// which is heavily coupled to OpenGL but too complex to recreate from scratch
		if (lastLoadedLevelNumber >= 0) { OGL_StopTextures(); }
		OGL_StartTextures();
		
		for (short collection = 0; collection < MAXIMUM_COLLECTIONS; collection++) {
			if (is_collection_present(collection)) {
				OGL_LoadTextures(collection);
			}
		}
		
		polygonTextureCache = [NSMutableDictionary dictionary];
		spriteTextureCache = [NSMutableDictionary dictionary];

		findOverlaps();

		[renderer startUpdatingAllGeometry];
		LoadStaticGeometry();
		UpdateDynamicGeometry();
		[renderer finishUpdatingAllGeometry];

		lastLoadedLevelNumber = dynamic_world->current_level_number;
	} else {
		[renderer startUpdatingDynamicGeometry];
		UpdateDynamicGeometry();
		[renderer finishUpdatingDynamicGeometry];
	}
}
