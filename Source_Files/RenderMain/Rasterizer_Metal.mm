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

void Rasterizer_Metal_Class::SetView(view_data &View) {
	view = &View;

	if (@available(macOS 26.0, *)) {
		if (renderer) {
			[renderer updateViewWithFOV:View.field_of_view
								  pitch:View.virtual_pitch * FixedAngleToDegrees
									yaw:View.virtual_yaw * FixedAngleToDegrees];
		}
	}
}

void Rasterizer_Metal_Class::Begin() {
	if (@available(macOS 26.0, *)) {
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

NSNumber* LoadTextureIntoRenderer(TextureManager *TMgr, bool didSetupSucceed) {
	uint32 identifier = TMgr->ShapeDesc << 16 | TMgr->LowLevelShape;
	NSNumber *textureID = @( identifier );

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

NSNumber* LoadWallTexture(vertical_surface_data *surface, simd_float3 *viewSpacePositions, simd_float2 *textureCoordinates) {
	shape_descriptor shape = surface->texture_definition->texture;

	auto TMgr = std::make_unique<TextureManager>();
	NSNumber* textureID = LoadTextureIntoRenderer(TMgr.get(), SetupPolygonTexture(TMgr.get(), shape));
	
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

NSNumber* LoadFloorOrCeilingTexture(horizontal_surface_data *surface, polygon_data *polygon, std::vector<simd_float2> &textureCoordinates) {
	shape_descriptor shape = surface->texture;
	
	auto TMgr = std::make_unique<TextureManager>();
	NSNumber *textureID = LoadTextureIntoRenderer(TMgr.get(), SetupPolygonTexture(TMgr.get(), shape));
	
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

void RenderRasterize_Metal::render_node_floor_or_ceiling(clipping_window_data *window, polygon_data *polygon, horizontal_surface_data *surface,
														 bool void_present, bool ceil, RenderStep renderStep)
{
	auto viewSpacePositions = std::vector<simd_float3>(polygon->vertex_count);

	for (int i=0; i < polygon->vertex_count; i++) {
		endpoint_data *data = get_endpoint_data(polygon->endpoint_indexes[i]);
		viewSpacePositions[i] = simd_make_float3(data->transformed.y, surface->height - view->origin.z, data->transformed.x);
	}
	
	auto textureCoordinates = std::vector<simd_float2>(polygon->vertex_count);
	NSNumber* textureID = LoadFloorOrCeilingTexture(surface, polygon, textureCoordinates);
	
	simd_float3 surfaceNormal = simd_make_float3(0.0, ceil ? -1.0 : 1.0, 0.0);
	
	auto vertices = std::vector<Vertex>(polygon->vertex_count);
	
	for (int i=0; i < polygon->vertex_count; i++) {
		vertices[i] = Vertex{ viewSpacePositions[i], textureCoordinates[i], surfaceNormal };
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
	NSNumber *textureID = LoadWallTexture(surface, viewSpacePositions, textureCoordinates);
	
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
	NSNumber *textureID = LoadTextureIntoRenderer(TMgr.get(), SetupSpriteTexture(TMgr.get(), rect));
	
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
	
	float spriteL = rect.WorldLeft * rect.HorizScale;
	float spriteR = rect.WorldRight * rect.HorizScale;
	float spriteT = rect.WorldTop * rect.Scale;
	float spriteB = rect.WorldBottom * rect.Scale;
	
	float texL = TMgr->V_Offset;
	float texR = TMgr->V_Scale+TMgr->V_Offset;
	float texT = TMgr->U_Offset;
	float texB = TMgr->U_Scale+TMgr->U_Offset;

	// Per the comment in TextureManager::SetupTextureMatrix(), inhabitant textures
	// "come in right side up, but the renderer expects them to be upside down and sideways",
	// so swap texture top-left and bottom-right
	Vertex vertices[] = {
		{ (playerRelativePosition.xyz + simd_make_float3(spriteL, spriteB, 0.0)), simd_make_float2(texR, texT), surfaceNormal },
		{ (playerRelativePosition.xyz + simd_make_float3(spriteL, spriteT, 0.0)), simd_make_float2(texL, texT), surfaceNormal },
		{ (playerRelativePosition.xyz + simd_make_float3(spriteR, spriteT, 0.0)), simd_make_float2(texL, texB), surfaceNormal },
		{ (playerRelativePosition.xyz + simd_make_float3(spriteR, spriteB, 0.0)), simd_make_float2(texR, texB), surfaceNormal },
	};
	
	if (@available(macos 26.0, *)) {
		if (renderer) {
			[renderer addPolygonWithVertices:vertices count:4 textureID:textureID];
		}
	}
}
