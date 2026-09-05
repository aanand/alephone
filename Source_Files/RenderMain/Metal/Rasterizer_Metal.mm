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

void LoadWorld();

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
		LoadWorld();

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

bool SetupSpriteTexture(TextureManager *TMgr, rectangle_definition rect) {
	TMgr->ShapeDesc = rect.ShapeDesc;
	TMgr->LowLevelShape = rect.LowLevelShape;
	TMgr->ShadingTables = rect.shading_tables;
	TMgr->Texture = rect.texture;
	TMgr->TransferMode = rect.transfer_mode;
	TMgr->TransferData = rect.transfer_data;
	TMgr->IsShadeless = (rect.flags&_SHADELESS_BIT) != 0;
	TMgr->TextureType = OGL_Txtr_Inhabitant;

	struct bitmap_definition* dummy;
	extended_get_shape_bitmap_and_shading_table(GET_DESCRIPTOR_COLLECTION(TMgr->ShapeDesc), TMgr->LowLevelShape, &dummy, &TMgr->ShadingTables, _shading_normal);

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

NSString* LoadWallTexture(vertical_surface_data *surface, simd_float3 *viewSpacePositions, simd_float2 *textureCoordinates) {
	shape_descriptor shape = surface->texture_definition->texture;

	auto TMgr = std::make_unique<TextureManager>();
	NSString* textureID = LoadTextureIntoRenderer(TMgr.get(), SetupPolygonTexture(TMgr.get(), shape));
	
	// Pulled out of RenderRasterize_Shader::render_node_side()
	int div = GetTextureScale(surface->transfer_mode, TMgr.get());
	
	world_distance x0 = surface->texture_definition->x0 % div;
	world_distance y0 = surface->texture_definition->y0 % div;

	double tOffset = surface->h1 + y0;
	
	for (int i = 0; i < 4; i++) {
		world_distance p2 = (i == 1 || i == 2) ? surface->length : 0;
		
		textureCoordinates[i] = simd_make_float2((tOffset - viewSpacePositions[i].y) / static_cast<float>(div),
												 (x0 + p2) / static_cast<float>(div));
	}

	return textureID;
}

NSString* LoadFloorOrCeilingTexture(horizontal_surface_data *surface, polygon_data *polygon, std::vector<simd_float2> &textureCoordinates) {
	shape_descriptor shape = surface->texture;
	
	auto TMgr = std::make_unique<TextureManager>();
	NSString *textureID = LoadTextureIntoRenderer(TMgr.get(), SetupPolygonTexture(TMgr.get(), shape));
	
	float scale = (float) GetTextureScale(surface->transfer_mode, TMgr.get());
	
	// Pulled out of RenderRasterize_Shader::render_node_floor_or_ceiling()
	for (int i = 0; i < polygon->vertex_count; i++) {
		// For some reason, doing the reverse-order iteration for ceilings (like RenderRasterize_Shader) gets a wrong-looking result, and going forwards in both cases looks right.
		world_point2d vertex = get_endpoint_data(polygon->endpoint_indexes[i])->vertex;
		textureCoordinates[i] = simd_make_float2((vertex.x + surface->origin.x) / scale,
												 (vertex.y + surface->origin.y) / scale);
	}
	
	return textureID;
}

bool isWorldLoaded = false;

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
		[renderer addPolygonWithVertices:vertices count:4 textureID:textureID];
	}
}

void AddFloor(polygon_data *polygon) {
	shape_descriptor shape = polygon->floor_texture;
	
	horizontal_surface_data surface;
	surface.origin= polygon->floor_origin;
	surface.height= polygon->floor_height;
	surface.texture= polygon->floor_texture;
	surface.lightsource_index= polygon->floor_lightsource_index;
	surface.transfer_mode= polygon->floor_transfer_mode;
	surface.transfer_mode_data= 0;
	
	simd_float3 surfaceNormal = simd_make_float3(0.0, 0.0, 1.0);

	auto TMgr = std::make_unique<TextureManager>();
	NSString *textureID = LoadTextureIntoRenderer(TMgr.get(), SetupPolygonTexture(TMgr.get(), shape));
	
	float scale = (float) GetTextureScale(surface.transfer_mode, TMgr.get());
	
	auto positions = std::vector<simd_int3>(polygon->vertex_count);
	auto textureCoordinates = std::vector<simd_float2>(polygon->vertex_count);

	// Pulled out of RenderRasterize_Shader::render_node_floor_or_ceiling()
	for (int i = 0; i < polygon->vertex_count; i++) {
		// For some reason, doing the reverse-order iteration for ceilings (like RenderRasterize_Shader) gets a wrong-looking result, and going forwards in both cases looks right.
		world_point2d position = get_endpoint_data(polygon->endpoint_indexes[i])->vertex;
		positions[i] = simd_make_int3(position.x, position.y, surface.height);
		textureCoordinates[i] = simd_make_float2((position.x + surface.origin.x) / scale,
												 (position.y + surface.origin.y) / scale);
	}
	
	auto vertices = std::vector<WorldVertex>(polygon->vertex_count);
	
	for (int i=0; i < polygon->vertex_count; i++) {
		vertices[i] = WorldVertex{ positions[i], textureCoordinates[i], surfaceNormal };
	}
	
	if (@available(macOS 26.0, *)) {
		if (renderer) {
			[renderer addPolygonWithVertices:vertices.data() count:polygon->vertex_count textureID:textureID];
		}
	}
}

void LoadWorld() {
	if (isWorldLoaded) return;
	
	for (short polyIdx = 0; polyIdx < dynamic_world->polygon_count; polyIdx++) {
		polygon_data *polygon = get_polygon_data(polyIdx);
		
		AddFloor(polygon);
		
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
	
	[renderer commitGeometry];
	
	isWorldLoaded = true;
}

/*
void RenderRasterize_Metal::render_node_floor_or_ceiling(clipping_window_data *window, polygon_data *polygon, horizontal_surface_data *surface,
														 bool void_present, bool ceil, RenderStep renderStep)
{
	auto viewSpacePositions = std::vector<simd_int3>(polygon->vertex_count);

	for (int i=0; i < polygon->vertex_count; i++) {
		endpoint_data *data = get_endpoint_data(polygon->endpoint_indexes[i]);
		viewSpacePositions[i] = simd_make_int3(data->vertex.x, data->vertex.y, surface->height - view->origin.z);
	}
	
	auto textureCoordinates = std::vector<simd_float2>(polygon->vertex_count);
	NSString* textureID = LoadFloorOrCeilingTexture(surface, polygon, textureCoordinates);
	
	simd_float3 surfaceNormal = simd_make_float3(0.0, ceil ? -1.0 : 1.0, 0.0);
	
	auto vertices = std::vector<WorldVertex>(polygon->vertex_count);
	
	for (int i=0; i < polygon->vertex_count; i++) {
		vertices[i] = WorldVertex{ viewSpacePositions[i], textureCoordinates[i], surfaceNormal };
	}
	
	if (@available(macOS 26.0, *)) {
		if (renderer) {
			[renderer addPolygonWithVertices:vertices.data() count:polygon->vertex_count textureID:textureID];
		}
	}
}

void RenderRasterize_Metal::render_node_side(clipping_window_data *window, vertical_surface_data *surface,
											 bool void_present, RenderStep renderStep)
{
	// surface->pN.i maps to viewspace Z (near to far)
	// surface->pN.j maps to viewspace X (left to right)
	// surface->hN   maps to viewspace Y (low to high)
	
	long bottom = surface->h0;
	long top = MIN(surface->h1, surface->hmax);
	
	simd_float3 viewSpacePositions[] = {
		simd_make_float3(surface->p0.j, top,    surface->p0.i),
		simd_make_float3(surface->p1.j, top,    surface->p1.i),
		simd_make_float3(surface->p1.j, bottom, surface->p1.i),
		simd_make_float3(surface->p0.j, bottom, surface->p0.i),
	};
	
	simd_float3 surfaceNormal = simd_normalize(simd_make_float3(surface->p0.j - surface->p1.j, 0.0, surface->p1.i - surface->p0.i));
	
	simd_float2 textureCoordinates[4];
	NSString *textureID = LoadWallTexture(surface, viewSpacePositions, textureCoordinates);
	
	Vertex vertices[] = {
		{ viewSpacePositions[0], textureCoordinates[0], surfaceNormal },
		{ viewSpacePositions[1], textureCoordinates[1], surfaceNormal },
		{ viewSpacePositions[2], textureCoordinates[2], surfaceNormal },
		{ viewSpacePositions[3], textureCoordinates[3], surfaceNormal },
	};

	if (@available(macOS 26.0, *)) {
		if (renderer) {
			[renderer addPolygonWithVertices:vertices count:4 textureID:textureID];
		}
	}
}

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
