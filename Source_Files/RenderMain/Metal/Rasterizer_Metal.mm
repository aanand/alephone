//
//  Rasterizer_Metal.mm
//  AlephOne
//
//  Created by Aanand Prasad on 24/08/2026.
//

#include <SDL2/SDL.h>
#include <SDL2/SDL_syswm.h>

#include <vector>

#include <Foundation/Foundation.h>

#include "Rasterizer_Metal.h"

#include "Metal/MetalRenderer.h"
#include "Metal/VertexTypes.h"

#include "OGL_Textures.h"
#include "Logging.h"
#include "vbl.h"
#include "player.h"
#include "lightsource.h"

#include <simd/simd.h>

API_AVAILABLE(macos(26.0))
MetalRenderer *renderer;
view_data *view;
int16 lastLoadedLevelNumber = -1;

bool Metal_InitializeForWindow(SDL_Window* window, int width, int height) {
    logWarning("Metal_InitializeForWindow(window, %d, %d)", width, height);

	if (@available(macOS 26.0, *)) {
		if (renderer) {
			return true;
		}
				
		MetalRenderer *r = [[MetalRenderer alloc] initializeWithWindow:window width:width height:height];
		if (!r) {
			logWarning("Failed to initialize MetalRenderer");
			return false;
		}
		renderer = r;

		logWarning("Initialized MetalRenderer");
		return true;
	}

	logWarning("Metal 4 not supported");
	return false;
}

// Copied from RenderRasterize_Shader.cpp
const float FixedAngleToDegrees = 360.0/(float(FIXED_ONE)*float(FULL_CIRCLE));

void UpdateWorld();

void Rasterizer_Metal_Class::SetView(view_data &View) {
	view = &View;
	
	float weaponFlare = PIN(view->maximum_depth_intensity - NATURAL_LIGHT_INTENSITY, 0, FIXED_ONE)/float(FIXED_ONE);

	if (@available(macOS 26.0, *)) {
		if (renderer) {
			[renderer updateViewWithOrigin:simd_make_int3(View.origin.x, View.origin.y, View.origin.z)
								  pitch:View.virtual_pitch * FixedAngleToDegrees
									yaw:View.virtual_yaw * FixedAngleToDegrees
									   FOV:View.field_of_view
							   weaponFlare:weaponFlare];
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

bool SetupSpriteTexture(TextureManager *TMgr,
						object_data *object,
						shape_and_transfer_mode ShapeAndTransferMode,
						shape_information_data *ShapeInformationData)
{
	bitmap_definition *texture;
	void *shading_tables;
	extended_get_shape_bitmap_and_shading_table(ShapeAndTransferMode.collection_code, ShapeAndTransferMode.low_level_shape_index, &texture, &shading_tables, view->shading_mode);

	TMgr->ShapeDesc = BUILD_DESCRIPTOR(ShapeAndTransferMode.collection_code, 0);
	TMgr->LowLevelShape = ShapeAndTransferMode.low_level_shape_index;
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

NSString* LoadTextureIntoRenderer(TextureManager *TMgr, bool didSetupSucceed) {
	NSString *textureID = [NSString stringWithFormat:@"[ShapeDesc=%u/Collection=%d/CTable=%d/Frame=%d/Bitmap=%d]", TMgr->ShapeDesc, TMgr->GetCollection(), TMgr->GetCTable(), TMgr->GetFrame(), TMgr->GetBitmap()];
	
	if (@available(macOS 26.0, *)) {
		if (![renderer hasTextureWithID:textureID]) {
			if (!didSetupSucceed) {
				logWarning("Failed to set up texture %d - substituting placeholder", textureID.intValue);
				[renderer addPlaceholderTextureWithID:textureID];
				return textureID;
			}
			
			const ImageDescriptor *image = TMgr->GetNormal();
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
			
			MetalImage *metalImage = [[MetalImage alloc] initWithWidth:image->GetWidth()
																height:image->GetHeight()
																pixels:pixels.data()];

			[renderer addTextureWithID:textureID image:metalImage];
		}
	}
	
	return textureID;
}

std::unordered_map<std::string, simd_float3> emissiveTextures = {
	// Light panels (M1)
	{ "[ShapeDesc=4622/Collection=18/CTable=0/Frame=14/Bitmap=14]", simd_make_float3(2.0, 2.0, 2.0) },
	{ "[ShapeDesc=4357/Collection=17/CTable=0/Frame=5/Bitmap=5]", simd_make_float3(2.0, 2.0, 2.0) },
	{ "[ShapeDesc=4358/Collection=17/CTable=0/Frame=6/Bitmap=6]", simd_make_float3(2.0, 2.0, 2.0) },
	
	// Terminals and pattern buffers (M1)
	{ "[ShapeDesc=2048/Collection=8/CTable=0/Frame=0/Bitmap=0]", simd_make_float3(0.0, 1.0, 0.0) },
	
	// Health recharge panels
	{ "[ShapeDesc=2052/Collection=8/CTable=0/Frame=4/Bitmap=4]", simd_make_float3(0.0, 0.0, 1.0) },
	
	// Switches
	{ "[ShapeDesc=2049/Collection=8/CTable=0/Frame=1/Bitmap=1]", simd_make_float3(1.0, 1.0, 1.0) },
	{ "[ShapeDesc=2050/Collection=8/CTable=0/Frame=2/Bitmap=2]", simd_make_float3(1.0, 1.0, 1.0) },
	
	// Panels on columns in that one side room in Arrival (M1)
	{ "[ShapeDesc=4617/Collection=18/CTable=0/Frame=9/Bitmap=9]", simd_make_float3(0.2, 0.2, 0.2) },
	
	// Light panels (M2)
	{ "[ShapeDesc=4377/Collection=17/CTable=0/Frame=25/Bitmap=25]", simd_make_float3(2.0, 2.0, 2.0) },
	{ "[ShapeDesc=4886/Collection=19/CTable=0/Frame=22/Bitmap=22]", simd_make_float3(2.0, 2.0, 2.0) },
	
	// Green wall panels (M2)
	{ "[ShapeDesc=4361/Collection=17/CTable=0/Frame=9/Bitmap=9]", simd_make_float3(0.0, 1.0, 0.0) },
};

simd_float3 emissionForTextureID(NSString *textureID) {
	std::string key = textureID.UTF8String;
	auto iterator = emissiveTextures.find(key);
	if (iterator != emissiveTextures.end()) {
		return iterator->second;
	}
	return simd_make_float3(0.0, 0.0, 0.0);
}

void AddWall(polygon_data *polygon, line_data *line, short vertexIdx,
			 world_distance bottom, world_distance top,
			 side_texture_definition texDef,
			 short transferMode, int32_t lightSourceIndex,
			 bool isDynamic)
{
	if (transferMode == _xfer_landscape) {
		// Skip adding landscapes for now so the sun can get in
		return;
	}

	endpoint_data *ep0 = get_endpoint_data(polygon->endpoint_indexes[vertexIdx]);
	endpoint_data *ep1 = get_endpoint_data(polygon->endpoint_indexes[(vertexIdx+1) % polygon->vertex_count]);
	
	simd_int2 v0 = { ep0->vertex.x, ep0->vertex.y };
	simd_int2 v1 = { ep1->vertex.x, ep1->vertex.y };
	
	simd_float2 d = simd_make_float2(ep1->vertex.x - ep0->vertex.x, ep1->vertex.y - ep0->vertex.y);
	simd_float3 normal = simd_normalize(simd_make_float3(-d.y, d.x, 0.0));

	if (top <= bottom || texDef.texture == UNONE) return;
	
	auto TMgr = std::make_unique<TextureManager>();
	bool didSetup = SetupPolygonTexture(TMgr.get(), texDef.texture);
	NSString *textureID = LoadTextureIntoRenderer(TMgr.get(), didSetup);
	int div = GetTextureScale(TMgr.get(), transferMode, didSetup);
	world_distance x0 = texDef.x0 % div;
	world_distance y0 = texDef.y0 % div;
	float tOffset = polygon->ceiling_height + y0;
	
	simd_float4x2 uv = {
		(simd_float2){ (tOffset - bottom) / (float) div, (x0               ) / (float) div },
		(simd_float2){ (tOffset - top   ) / (float) div, (x0               ) / (float) div },
		(simd_float2){ (tOffset - top   ) / (float) div, (x0 + line->length) / (float) div },
		(simd_float2){ (tOffset - bottom) / (float) div, (x0 + line->length) / (float) div },
	};
	
	MetalSurface *surface = [[MetalSurface alloc] initWithTextureID:textureID
														   emission:emissionForTextureID(textureID)
															 normal:normal
												   lightSourceIndex:lightSourceIndex];

	MetalWall *wall = [[MetalWall alloc] initWithV0:v0
												 v1:v1
											 bottom:bottom
												top:top
												 uv:uv
											surface:surface];
	
	[renderer addWall:wall dynamic:isDynamic];
}

// For floors and ceilings, static vs. dynamic is simple: if it's a platform, it's dynamic
void AddFloorOrCeiling(short polygonIdx, polygon_data *polygon, bool isCeiling, bool isDynamicPass) {
	bool isPlatform = polygon->type == _polygon_is_platform;
	if (isPlatform != isDynamicPass) {
		return;
	}
	
	shape_descriptor shape         = isCeiling ? polygon->ceiling_texture       : polygon->floor_texture;
	world_point2d    origin        = isCeiling ? polygon->ceiling_origin        : polygon->floor_origin;
	world_distance   height        = isCeiling ? polygon->ceiling_height        : polygon->floor_height;
	int16            transfer_mode = isCeiling ? polygon->ceiling_transfer_mode : polygon->floor_transfer_mode;
	int32_t          lightsource_index = isCeiling ? polygon->ceiling_lightsource_index : polygon->floor_lightsource_index;
	
	if (shape == UNONE) {
		return;
	}
	
	if (transfer_mode == _xfer_landscape) {
		// Skip adding landscapes for now so the sun can get in
		return;
	}
	
	auto TMgr = std::make_unique<TextureManager>();
	bool didSetup = SetupPolygonTexture(TMgr.get(), shape);
	NSString *textureID = LoadTextureIntoRenderer(TMgr.get(), didSetup);
	
	float scale = (float) GetTextureScale(TMgr.get(), transfer_mode, didSetup);
	
	auto vertices = std::vector<simd_int2>(polygon->vertex_count);
	auto uv = std::vector<simd_float2>(polygon->vertex_count);
	
	// Pulled out of RenderRasterize_Shader::render_node_floor_or_ceiling()
	for (int i = 0; i < polygon->vertex_count; i++) {
		world_point2d position = get_endpoint_data(polygon->endpoint_indexes[isCeiling ? (polygon->vertex_count - 1 - i) : i])->vertex;
		vertices[i] = { position.x, position.y };
		uv[i] = { (position.x + origin.x) / scale, (position.y + origin.y) / scale };
	}
	
	MetalSurface *surface = [[MetalSurface alloc] initWithTextureID:textureID
														   emission:emissionForTextureID(textureID)
															 normal:simd_make_float3(0.0, 0.0, isCeiling ? -1.0 : 1.0)
												   lightSourceIndex:lightsource_index];

	MetalPolygon *mPolygon = [[MetalPolygon alloc] initWithVertexCount:polygon->vertex_count
															  vertices:vertices.data()
																	uv:uv.data()
																height:height
															   surface:surface];
	
	[renderer addPolygon:mPolygon withID:polygonIdx dynamic:isDynamicPass];
}

void AddFloor(short polygonIdx, polygon_data *polygon, bool isDynamicPass) {
	AddFloorOrCeiling(polygonIdx, polygon, false, isDynamicPass);
}

void AddCeiling(short polygonIdx, polygon_data *polygon, bool isDynamicPass) {
	AddFloorOrCeiling(polygonIdx, polygon, true, isDynamicPass);
}

// A wall is dynamic if it belongs to a platform polygon OR it's adjacent to a platform polygon.
void AddWalls(polygon_data *polygon, bool isDynamicPass) {
	bool isPlatform = polygon->type == _polygon_is_platform;

	for (short vertexIdx=0; vertexIdx < polygon->vertex_count; vertexIdx++) {
		short adjacentPolgyonIdx = polygon->adjacent_polygon_indexes[vertexIdx];
		bool isNextToPlatform = (adjacentPolgyonIdx != NONE && get_polygon_data(adjacentPolgyonIdx)->type == _polygon_is_platform);
		bool wallIsDynamic = isPlatform || isNextToPlatform;
		if (wallIsDynamic != isDynamicPass) continue;
		
		short sideIdx = polygon->side_indexes[vertexIdx];
		if (sideIdx == NONE) continue;;

		side_data *side = get_side_data(sideIdx);
		line_data *line = get_line_data(polygon->line_indexes[vertexIdx]);

		switch (side->type) {
			case _full_side:
				AddWall(polygon, line, vertexIdx,
						polygon->floor_height, polygon->ceiling_height,
						side->primary_texture,
						side->primary_transfer_mode,
						side->primary_lightsource_index,
						isDynamicPass);
				break;
			case _low_side:
				AddWall(polygon, line, vertexIdx,
						polygon->floor_height, line->highest_adjacent_floor,
						side->primary_texture,
						side->primary_transfer_mode,
						side->primary_lightsource_index,
						isDynamicPass);
				break;
			case _high_side:
				AddWall(polygon, line, vertexIdx,
						line->lowest_adjacent_ceiling, polygon->ceiling_height,
						side->primary_texture,
						side->primary_transfer_mode,
						side->primary_lightsource_index,
						isDynamicPass);
				break;
			case _split_side:
				AddWall(polygon, line, vertexIdx,
						line->lowest_adjacent_ceiling, polygon->ceiling_height,
						side->primary_texture,
						side->primary_transfer_mode,
						side->primary_lightsource_index,
						isDynamicPass);
				AddWall(polygon, line, vertexIdx,
						polygon->floor_height, line->highest_adjacent_floor,
						side->secondary_texture,
						side->secondary_transfer_mode,
						side->secondary_lightsource_index,
						isDynamicPass);
				break;
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
	
	auto TMgr = std::make_unique<TextureManager>();
	NSString *textureID = LoadTextureIntoRenderer(TMgr.get(), SetupSpriteTexture(TMgr.get(), object, data, shape_information));

	simd_int3 position = { object->location.x, object->location.y, object->location.z };

	short spriteL = shape_information->world_left;
	short spriteR = shape_information->world_right;
	short spriteT = shape_information->world_top;
	short spriteB = shape_information->world_bottom;
	
	simd_int2 size = { spriteR - spriteL, spriteT - spriteB };
	
	float texL = TMgr->V_Offset;
	float texR = TMgr->V_Scale+TMgr->V_Offset;
	float texT = TMgr->U_Offset;
	float texB = TMgr->U_Scale+TMgr->U_Offset;
	
	simd_float4x2 uv = {
		(simd_float2){ texB, texL },
		(simd_float2){ texT, texL },
		(simd_float2){ texT, texR },
		(simd_float2){ texB, texR },
	};
	
	// Normal is ignored here and set based on the sprite's rotation
	MetalSurface *surface = [[MetalSurface alloc] initWithTextureID:textureID
														   emission:emissionForTextureID(textureID)
															 normal:simd_make_float3(1.0, 0.0, 0.0)
												   lightSourceIndex:NONE];
	
	return [[MetalSprite alloc] initWithIndex:objectIdx
										   uv:uv
										 size:size
									 position:position
									  surface:surface];
}

void UpdateObject(short objectIdx, object_data *object) {
	MetalSprite *sprite = GetSprite(objectIdx, object);
	if (!sprite) return;

	if (@available(macOS 26.0, *)) {
		[renderer updateSprite:sprite];
	}
}

void LoadStaticGeometry() {
	for (short polyIdx = 0; polyIdx < dynamic_world->polygon_count; polyIdx++) {
		polygon_data *polygon = get_polygon_data(polyIdx);
		
		AddFloor(polyIdx, polygon, false);
		AddCeiling(polyIdx, polygon, false);
		AddWalls(polygon, false);
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
		
		AddFloor(polyIdx, polygon, true);
		AddCeiling(polyIdx, polygon, true);
		AddWalls(polygon, true);
	}
	
	NSMutableArray<NSNumber*> *intensities = [NSMutableArray array];
	for (int32_t lightSourceIndex = 0; lightSourceIndex < MAXIMUM_LIGHTS_PER_MAP; lightSourceIndex++) {
		float intensity = get_light_intensity(lightSourceIndex) / float(FIXED_ONE - 1);
		[intensities addObject:@(intensity)];
	}
	[renderer updateLightSourceIntensities:intensities];
}

void UpdateWorld() {
	if (lastLoadedLevelNumber != dynamic_world->current_level_number) {
		logWarning("Loading level number %d", dynamic_world->current_level_number);
		
		// This is unfortunately necessary while we're using TextureManager,
		// which is heavily coupled to OpenGL but too complex to recreate from scratch
		if (lastLoadedLevelNumber >= 0) { OGL_StopTextures(); }
		OGL_StartTextures();

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
