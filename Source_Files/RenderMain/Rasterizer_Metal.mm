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

void Rasterizer_Metal_Class::SetView(view_data &View) {
	if (@available(macOS 26.0, *)) {
		if (renderer) {
			[renderer updateViewWithFOV:View.field_of_view];
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

NSNumber* LoadWallTexture(vertical_surface_data *surface, simd_float3 *viewSpacePositions, simd_float2 *textureCoordinates) {
	shape_descriptor shape = surface->texture_definition->texture;
	NSNumber* textureID = @(shape);

	TextureManager *TMgr = GetTextureManager(shape);

	if (@available(macOS 26.0, *)) {
		if (![renderer hasTextureWithID:textureID]) {
			const ImageDescriptor *image = TMgr->GetNormal();

			MetalImage *metalImage = [[MetalImage alloc] initWithWidth:image->GetWidth()
																height:image->GetHeight()
																pixels:image->GetBuffer()];

			[renderer addTextureWithID:textureID image:metalImage];
		}
	}
	
	// Pulled out of RenderRasterize_Shader::render_node_side()
	uint16 div;
	switch (surface->transfer_mode) {
		case _xfer_2x:
			div = 2 * WORLD_ONE * TMgr->TileRatio();
			break;
		case _xfer_4x:
			div = 4 * WORLD_ONE * TMgr->TileRatio();
			break;
		default:
			div = WORLD_ONE * TMgr->TileRatio();
			break;
	}
	
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

void RenderRasterize_Metal::render_node_floor_or_ceiling(clipping_window_data *window, polygon_data *polygon, horizontal_surface_data *surface,
														 bool void_present, bool ceil, RenderStep renderStep)
{
//	auto vertices = std::vector<Vertex>(polygon->vertex_count);
//
//	for (int i=0; i < polygon->vertex_count; i++) {
//		endpoint_data *data = get_endpoint_data(polygon->endpoint_indexes[i]);
//		vertices[i] = Vertex{
//			scaleToViewSpace(simd_make_float3(data->transformed.y, surface->height - view->origin.z, data->transformed.x)),
//			simd_make_float2(0, 0)
//		};
//	}
//	
//	if (@available(macOS 26.0, *)) {
//		if (renderer) {
//			[renderer addPolygonWithVertices:vertices.data() count:polygon->vertex_count];
//		}
//	}
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
