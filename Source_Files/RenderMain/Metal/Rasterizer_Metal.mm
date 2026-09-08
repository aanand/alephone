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
		
		// This is unfortunately necessary while we're using TextureManager,
		// which is heavily coupled to OpenGL but too complex to recreate from scratch
		OGL_StartTextures();
		
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

	if (@available(macOS 26.0, *)) {
		if (renderer) {
			[renderer updateViewWithOrigin:simd_make_int3(View.origin.x, View.origin.y, View.origin.z)
								  pitch:View.virtual_pitch * FixedAngleToDegrees
									yaw:View.virtual_yaw * FixedAngleToDegrees
									   FOV:View.field_of_view];
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

int GetTextureScale(short transfer_mode, TextureManager *TMgr) {
	int tile_ratio = TMgr ? TMgr->TileRatio() : 1;

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
				logWarning("Failed to set up texture %d - substituting magenta", textureID.intValue);
				uint32 pixels[1] = { 255u | (0u << 8) | (255u << 16) | (255u << 24) };
				MetalImage *substitute = [[MetalImage alloc] initWithWidth:1 height:1 pixels:pixels];
				[renderer addTextureWithID:textureID image:substitute];
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
	{ "[ShapeDesc=4622/Collection=18/CTable=0/Frame=14/Bitmap=14]", simd_make_float3(1.0, 1.0, 1.0) },
	
	// Terminals and pattern buffers (M1)
	{ "[ShapeDesc=2048/Collection=8/CTable=0/Frame=0/Bitmap=0]", simd_make_float3(0.0, 1.0, 0.0) },
	
	// Health recharge panels
	{ "[ShapeDesc=2052/Collection=8/CTable=0/Frame=4/Bitmap=4]", simd_make_float3(0.0, 0.0, 1.0) },
	
	// Switches
	{ "[ShapeDesc=2049/Collection=8/CTable=0/Frame=1/Bitmap=1]", simd_make_float3(1.0, 1.0, 1.0) },
	{ "[ShapeDesc=2050/Collection=8/CTable=0/Frame=2/Bitmap=2]", simd_make_float3(1.0, 1.0, 1.0) },
	
	// Panels on columns in that one side room in Arrival (M1)
	{ "[ShapeDesc=4617/Collection=18/CTable=0/Frame=9/Bitmap=9]", simd_make_float3(0.2, 0.2, 0.2) },
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
					short transferMode)
{
	if (transferMode == _xfer_landscape) {
		// Skip adding landscapes for now so the sun can get in
		return;
	}

	endpoint_data *ep0 = get_endpoint_data(polygon->endpoint_indexes[vertexIdx]);
	endpoint_data *ep1 = get_endpoint_data(polygon->endpoint_indexes[(vertexIdx+1) % polygon->vertex_count]);
	
	simd_float2 d = simd_make_float2(ep1->vertex.x - ep0->vertex.x, ep1->vertex.y - ep0->vertex.y);
	simd_float3 normal = simd_normalize(simd_make_float3(-d.y, d.x, 0.0));

	if (top <= bottom || texDef.texture == UNONE) return;
	
	simd_int3 p0 = simd_make_int3(ep0->vertex.x, ep0->vertex.y, top);
	simd_int3 p1 = simd_make_int3(ep1->vertex.x, ep1->vertex.y, top);
	simd_int3 p2 = simd_make_int3(ep1->vertex.x, ep1->vertex.y, bottom);
	simd_int3 p3 = simd_make_int3(ep0->vertex.x, ep0->vertex.y, bottom);
	
	auto TMgr = std::make_unique<TextureManager>();
	NSString *textureID = LoadTextureIntoRenderer(TMgr.get(), SetupPolygonTexture(TMgr.get(), texDef.texture));
	int div = GetTextureScale(transferMode, TMgr.get());
	world_distance x0 = texDef.x0 % div;
	world_distance y0 = texDef.y0 % div;
	float tOffset = polygon->ceiling_height + y0;
	
	simd_float2 uv0 = simd_make_float2((tOffset - top   ) / (float) div, (x0               ) / (float) div);
	simd_float2 uv1 = simd_make_float2((tOffset - top   ) / (float) div, (x0 + line->length) / (float) div);
	simd_float2 uv2 = simd_make_float2((tOffset - bottom) / (float) div, (x0 + line->length) / (float) div);
	simd_float2 uv3 = simd_make_float2((tOffset - bottom) / (float) div, (x0               ) / (float) div);
	
	WorldVertex vertices[4] = {
		{ p0, uv0, normal },
		{ p1, uv1, normal },
		{ p2, uv2, normal },
		{ p3, uv3, normal },
	};
	
	if (@available(macOS 26.0, *)) {
		[renderer addStaticPolygon:[[MetalPolygon alloc] initWithVertices:vertices
															  vertexCount:4
															 textureID:textureID
															  emission:emissionForTextureID(textureID)]];
	}
}

void AddFloorOrCeiling(polygon_data *polygon, bool ceil) {
	shape_descriptor shape         = ceil ? polygon->ceiling_texture       : polygon->floor_texture;
	world_point2d    origin        = ceil ? polygon->ceiling_origin        : polygon->floor_origin;
	world_distance   height        = ceil ? polygon->ceiling_height        : polygon->floor_height;
	int16            transfer_mode = ceil ? polygon->ceiling_transfer_mode : polygon->floor_transfer_mode;

	if (transfer_mode == _xfer_landscape) {
		// Skip adding landscapes for now so the sun can get in
		return;
	}

	simd_float3 surfaceNormal = simd_make_float3(0.0, 0.0, ceil ? -1.0 : 1.0);

	auto TMgr = std::make_unique<TextureManager>();
	NSString *textureID = LoadTextureIntoRenderer(TMgr.get(), SetupPolygonTexture(TMgr.get(), shape));
	
	float scale = (float) GetTextureScale(transfer_mode, TMgr.get());
	
	auto vertices = std::vector<WorldVertex>(polygon->vertex_count);
	
	// Pulled out of RenderRasterize_Shader::render_node_floor_or_ceiling()
	for (int i = 0; i < polygon->vertex_count; i++) {
		world_point2d position = get_endpoint_data(polygon->endpoint_indexes[ceil ? (polygon->vertex_count - 1 - i) : i])->vertex;
		
		vertices[i] = {
			simd_make_int3(position.x, position.y, height),
			simd_make_float2((position.x + origin.x) / scale,
							 (position.y + origin.y) / scale),
			surfaceNormal,
		};
	}
	
	if (@available(macOS 26.0, *)) {
		if (renderer) {
			[renderer addStaticPolygon:[[MetalPolygon alloc] initWithVertices:vertices.data()
																  vertexCount:polygon->vertex_count
																	textureID:textureID
																	 emission:emissionForTextureID(textureID)]];
		}
	}
}

void AddWalls(polygon_data *polygon) {
	for (short vertexIdx=0; vertexIdx < polygon->vertex_count; vertexIdx++) {
		short sideIdx = polygon->side_indexes[vertexIdx];
		if (sideIdx == NONE) continue;;
		
		side_data *side = get_side_data(sideIdx);
		line_data *line = get_line_data(polygon->line_indexes[vertexIdx]);

		switch (side->type) {
			case _full_side:
				AddWall(polygon, line, vertexIdx,
						polygon->floor_height, polygon->ceiling_height,
						side->primary_texture,
						side->primary_transfer_mode);
				break;
			case _low_side:
				AddWall(polygon, line, vertexIdx,
						polygon->floor_height, line->highest_adjacent_floor,
						side->primary_texture,
						side->primary_transfer_mode);
				break;
			case _high_side:
				AddWall(polygon, line, vertexIdx,
						line->lowest_adjacent_ceiling, polygon->ceiling_height,
						side->primary_texture,
						side->primary_transfer_mode);
				break;
			case _split_side:
				AddWall(polygon, line, vertexIdx,
						line->lowest_adjacent_ceiling, polygon->ceiling_height,
						side->primary_texture,
						side->primary_transfer_mode);
				AddWall(polygon, line, vertexIdx,
						polygon->floor_height, line->highest_adjacent_floor,
						side->secondary_texture,
						side->secondary_transfer_mode);
				break;
		}
	}
}

NSString *objectID(short objectIdx) {
	return [NSString stringWithFormat:@"[Object #%d]", objectIdx];
}

simd_int3 objectWorldPosition(object_data *object) {
	return simd_make_int3(object->location.x, object->location.y, object->location.z);
}

MetalPolygon* GetObjectPolygon(short objectIdx, object_data *object) {
	shape_and_transfer_mode data;
	get_object_shape_and_transfer_mode(&view->origin, object, &data);
	if (data.collection_code == NONE) {
		return nil;
	}
	
	shape_information_data *shape_information = extended_get_shape_information(data.collection_code, data.low_level_shape_index);
	
	auto TMgr = std::make_unique<TextureManager>();
	NSString *textureID = LoadTextureIntoRenderer(TMgr.get(), SetupSpriteTexture(TMgr.get(), object, data, shape_information));

	simd_float3 surfaceNormal = simd_make_float3(1.0, 0.0, 0.0);
	
	float spriteL = shape_information->world_left;
	float spriteR = shape_information->world_right;
	float spriteT = shape_information->world_top;
	float spriteB = shape_information->world_bottom;
	
	float texL = TMgr->V_Offset;
	float texR = TMgr->V_Scale+TMgr->V_Offset;
	float texT = TMgr->U_Offset;
	float texB = TMgr->U_Scale+TMgr->U_Offset;
	
	WorldVertex vertices[] = {
		{ simd_make_int3(0.0, spriteL, spriteB), simd_make_float2(texB, texL), surfaceNormal },
		{ simd_make_int3(0.0, spriteL, spriteT), simd_make_float2(texT, texL), surfaceNormal },
		{ simd_make_int3(0.0, spriteR, spriteT), simd_make_float2(texT, texR), surfaceNormal },
		{ simd_make_int3(0.0, spriteR, spriteB), simd_make_float2(texB, texR), surfaceNormal },
	};
	
	MetalPolygon *polygon = [[MetalPolygon alloc] initWithVertices:vertices
													   vertexCount:4
														 textureID:textureID
														  emission:emissionForTextureID(textureID)];
	
	return polygon;
}

void AddObject(short objectIdx, object_data *object) {
	MetalPolygon *polygon = GetObjectPolygon(objectIdx, object);
	if (!polygon) return;

	MetalDynamicObject *dynamicObject = [[MetalDynamicObject alloc] initWithID:objectID(objectIdx)
																	  polygons:@[polygon]
																 worldPosition:objectWorldPosition(object)
																		facing:object->facing];
	
	if (@available(macOS 26.0, *)) {
		[renderer addDynamicObject:dynamicObject];
	}
}

void UpdateObject(short objectIdx, object_data *object) {
	MetalPolygon *polygon = GetObjectPolygon(objectIdx, object);
	if (!polygon) return;

	if (@available(macOS 26.0, *)) {
		[renderer updateDynamicObjectWithID:objectID(objectIdx)
								   polygons:@[polygon]
							  worldPosition:objectWorldPosition(object)
									 facing:object->facing];
	}
}

void LoadAllData() {
	for (short polyIdx = 0; polyIdx < dynamic_world->polygon_count; polyIdx++) {
		polygon_data *polygon = get_polygon_data(polyIdx);
		
		AddFloorOrCeiling(polygon, true);
		AddFloorOrCeiling(polygon, false);
		AddWalls(polygon);
		
		short objectIdx = polygon->first_object;
		
		while (objectIdx != NONE) {
			object_data *object = get_object_data(objectIdx);
			AddObject(objectIdx, object);
			objectIdx = object->next_object;
		}
	}
}

void UpdateDynamicData() {
	for (short polyIdx = 0; polyIdx < dynamic_world->polygon_count; polyIdx++) {
		polygon_data *polygon = get_polygon_data(polyIdx);
		short objectIdx = polygon->first_object;
		
		while (objectIdx != NONE) {
			object_data *object = get_object_data(objectIdx);
			UpdateObject(objectIdx, object);
			objectIdx = object->next_object;
		}
	}
}

void LoadWorld() {
	if (lastLoadedLevelNumber == dynamic_world->current_level_number) return;
	
	logWarning("Loading level number %d", dynamic_world->current_level_number);
	
	[renderer clearGeometry];
	LoadAllData();
	[renderer commitGeometry];
	
	lastLoadedLevelNumber = dynamic_world->current_level_number;
}

void UpdateWorld() {
	LoadWorld();
	UpdateDynamicData();
}

/*
float radians(float degrees) {
	return degrees * 8.0 * atan(1.0) / 360.0;
}

void RenderRasterize_Metal::render_node_object(render_object_data *data, bool other_side_of_media, RenderStep renderStep) {
	rectangle_definition rect = data->rectangle;

	auto TMgr = std::make_unique<TextureManager>();
	NSString *textureID = LoadTextureIntoRenderer(TMgr.get(), SetupSpriteTexture(TMgr.get(), rect));
	
	float yaw = -(view->virtual_yaw * FixedAngleToDegrees);
	simd_float3 worldPosition = simd_make_float3(rect.Position.x, rect.Position.z, rect.Position.y);
	simd_float3 playerPosition = simd_make_float3(view->origin.x, view->origin.z, view->origin.y);
	simd_quatf yawRotation = simd_quaternion(radians(yaw), simd_make_float3(0.0, 1.0, 0.0));

	simd_float4 playerRelativePosition = simd_make_float4(worldPosition - playerPosition, 1.0);

	// World left = -X, world right = +X, world up = -Z, world down = +Z
	// At yaw=0, player is looking in the +X direction
	// Therefore -playerX = - worldZ, +playerRight = +worldZ, -playerZ = -worldX, +playerZ = +worldX
	playerRelativePosition = playerRelativePosition.zyxw;
	playerRelativePosition = simd_mul(simd_matrix4x4(yawRotation), playerRelativePosition);
	
	simd_float3 surfaceNormal = simd_make_float3(0, 0, -1);
	
	float spriteL = rect.WorldLeft * rect.HorizScale * rect.Scale;
	float spriteR = rect.WorldRight * rect.HorizScale * rect.Scale;
	float spriteT = rect.WorldTop * rect.Scale;
	float spriteB = rect.WorldBottom * rect.Scale;
	
	float texL = TMgr->V_Offset;
	float texR = TMgr->V_Scale+TMgr->V_Offset;
	float texT = TMgr->U_Offset;
	float texB = TMgr->U_Scale+TMgr->U_Offset;
	
	if (rect.flip_horizontal) {
		std::swap(texL, texR);
	}
	if (rect.flip_vertical) {
		std::swap(texT, texB);
	}

	// Per the comment in TextureManager::SetupTextureMatrix(), inhabitant textures
	// "come in right side up, but the renderer expects them to be upside down and sideways",
	// i.e. X and Y are transposed - so texture coordinates here are (Y, X)
	Vertex vertices[] = {
		{ (playerRelativePosition.xyz + simd_make_float3(spriteL, spriteB, 0.0)), simd_make_float2(texB, texL), surfaceNormal },
		{ (playerRelativePosition.xyz + simd_make_float3(spriteL, spriteT, 0.0)), simd_make_float2(texT, texL), surfaceNormal },
		{ (playerRelativePosition.xyz + simd_make_float3(spriteR, spriteT, 0.0)), simd_make_float2(texT, texR), surfaceNormal },
		{ (playerRelativePosition.xyz + simd_make_float3(spriteR, spriteB, 0.0)), simd_make_float2(texB, texR), surfaceNormal },
	};
	
	if (@available(macos 26.0, *)) {
		if (renderer) {
			[renderer addPolygonWithVertices:vertices count:4 textureID:textureID];
		}
	}
}
*/
