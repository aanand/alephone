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
	if (@available(macOS 26.0, *)) {
		if (renderer) {
			[renderer updateViewWithFOV:View.field_of_view
								  pitch:View.virtual_pitch * FixedAngleToDegrees];
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

TextureManager* GetTextureManager(shape_descriptor ShapeDesc) {
	TextureManager *TMgr = new TextureManager();
	TMgr->ShapeDesc = ShapeDesc;
	TMgr->LowLevelShape = 0;
	TMgr->TransferMode = _textured_transfer;
	TMgr->TransferData = 0;
	TMgr->IsShadeless = 0;
	
	get_shape_bitmap_and_shading_table(ShapeDesc, &TMgr->Texture, &TMgr->ShadingTables, _shading_normal);

	if (!TMgr->Setup()) {
		logError("Failed to set up TextureManager");
		return NULL;
	}
	
	return TMgr;
}

int GetTextureScale(short transfer_mode, int tile_ratio) {
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

void LoadTextureIntoRenderer(NSNumber *textureID, TextureManager *TMgr) {
	if (@available(macOS 26.0, *)) {
		if (![renderer hasTextureWithID:textureID]) {
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
}

NSNumber* LoadWallTexture(vertical_surface_data *surface, simd_float3 *viewSpacePositions, simd_float2 *textureCoordinates) {
	shape_descriptor shape = surface->texture_definition->texture;
	NSNumber* textureID = @(shape);

	TextureManager *TMgr = GetTextureManager(shape);
	LoadTextureIntoRenderer(textureID, TMgr);
	
	// Pulled out of RenderRasterize_Shader::render_node_side()
	int div = GetTextureScale(surface->transfer_mode, TMgr->TileRatio());
	
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
	NSNumber *textureID = @(shape);
	
	TextureManager *TMgr = GetTextureManager(shape);
	LoadTextureIntoRenderer(textureID, TMgr);
	
	float scale = (float) GetTextureScale(surface->transfer_mode, TMgr->TileRatio());
	
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
	
	auto vertices = std::vector<Vertex>(polygon->vertex_count);
	
	for (int i=0; i < polygon->vertex_count; i++) {
		vertices[i] = Vertex{ viewSpacePositions[i], textureCoordinates[i] };
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
	
	simd_float2 textureCoordinates[4];
	NSNumber *textureID = LoadWallTexture(surface, viewSpacePositions, textureCoordinates);
	
	Vertex vertices[] = {
		{ viewSpacePositions[0], textureCoordinates[0] },
		{ viewSpacePositions[1], textureCoordinates[1] },
		{ viewSpacePositions[2], textureCoordinates[2] },
		{ viewSpacePositions[3], textureCoordinates[3] },
	};

	if (@available(macOS 26.0, *)) {
		if (renderer) {
			[renderer addPolygonWithVertices:vertices count:4 textureID:textureID];
		}
	}
}
