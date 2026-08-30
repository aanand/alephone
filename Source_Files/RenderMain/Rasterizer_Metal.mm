//
//  Rasterizer_Metal.mm
//  AlephOne
//
//  Created by Aanand Prasad on 24/08/2026.
//

#include <SDL2/SDL.h>
#include <SDL2/SDL_syswm.h>

#include <vector>

#include "Rasterizer_Metal.h"

#include "Metal/MetalRenderer.h"
#include "Metal/VertexTypes.h"

#include "OGL_Textures.h"
#include "Logging.h"

#include <simd/simd.h>

API_AVAILABLE(macos(26.0))
MetalRenderer *renderer;

typedef struct {
	shape_descriptor shape;
	bitmap_definition bitmap;
	void* shading_tables;
} WallTexture;

WallTexture *singleLoadedWallTexture;

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

const ImageDescriptor* GetTexture(shape_descriptor ShapeDesc) {
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
	
	return TMgr->GetNormal();
}

// Aleph One hands us camera-relative quad vertices whose dimensions seem to lie in the [-2000, 2000] range or so.
// Scaling them down doesn't affect their eventual position on the screen, but does stop them getting excised from Metal's clip-space range.
simd_float3 scaleToViewSpace(simd_float3 worldSpace) {
	return worldSpace / 2000.0;
}

void RenderRasterize_Metal::render_node_floor_or_ceiling(clipping_window_data *window, polygon_data *polygon, horizontal_surface_data *surface,
														 bool void_present, bool ceil, RenderStep renderStep)
{
	auto vertices = std::vector<Vertex>(polygon->vertex_count);

	for (int i=0; i < polygon->vertex_count; i++) {
		endpoint_data *data = get_endpoint_data(polygon->endpoint_indexes[i]);
		vertices[i] = Vertex{
			scaleToViewSpace(simd_make_float3(data->transformed.y, surface->height - view->origin.z, data->transformed.x)),
			simd_make_float2(0, 0)
		};
	}
	
	if (@available(macOS 26.0, *)) {
		if (renderer) {
			[renderer addPolygonWithVertices:vertices.data() count:polygon->vertex_count];
		}
	}
}

void RenderRasterize_Metal::render_node_side(clipping_window_data *window, vertical_surface_data *surface,
											 bool void_present, RenderStep renderStep)
{
	if (!singleLoadedWallTexture) {
		shape_descriptor shape = surface->texture_definition->texture;
		bitmap_definition *bitmap;
		void *shading_tables;
		
		get_shape_bitmap_and_shading_table(shape, &bitmap, &shading_tables, _shading_normal);
		
		logWarning("shape=%d", shape);
		logWarning("width=%d, height=%d", bitmap->width, bitmap->height);
		logWarning("bytes_per_row=%d", bitmap->bytes_per_row); /* if ==NONE this is a transparent RLE shape */
		
		logWarning("_COLUMN_ORDER_BIT=%d", (bitmap->flags & _COLUMN_ORDER_BIT) > 0);
		logWarning("_TRANSPARENT_BIT=%d", (bitmap->flags & _TRANSPARENT_BIT) > 0);
		logWarning("_PATCHED_BIT=%d", (bitmap->flags & _PATCHED_BIT) > 0);
		logWarning("bit_depth=%d", bitmap->bit_depth); /* should always be ==8 */
		
		logWarning("row_addresses[0]=%u", bitmap->row_addresses[0]);
		
		const ImageDescriptor *image = GetTexture(shape);
		const uint32* pixels = image->GetBuffer();
		
		for (int i = 0; i < image->GetNumPixels(); i += 29) {
			uint32 pixel = pixels[i];
			logWarning("pixels[%d]: (b=%u, g=%u, r=%u, a=%u)", i, pixel & 0xFF, (pixel >> 8) & 0xFF, (pixel >> 16) & 0xFF, (pixel >> 24) & 0xFF);
		}
		
		singleLoadedWallTexture = (WallTexture*)malloc(sizeof(WallTexture));
		singleLoadedWallTexture->shape = shape;
		singleLoadedWallTexture->bitmap = *bitmap;
		singleLoadedWallTexture->shading_tables = shading_tables;
	}
	
	// surface->pN.i maps to viewspace Z (near to far)
	// surface->pN.j maps to viewspace X (left to right)
	// surface->hN   maps to viewspace Y (low to high)
	
	long bottom = surface->h0;
	long top = MIN(surface->h1, surface->hmax);
	
	Vertex vertices[] = {
		Vertex{
			scaleToViewSpace(simd_make_float3(surface->p0.j, top,    surface->p0.i)),
			simd_make_float2(0, 0)
		},
		Vertex{
			scaleToViewSpace(simd_make_float3(surface->p1.j, top,    surface->p1.i)),
			simd_make_float2(0, 0)
		},
		Vertex{
			scaleToViewSpace(simd_make_float3(surface->p1.j, bottom, surface->p1.i)),
			simd_make_float2(0, 0)
		},
		Vertex{
			scaleToViewSpace(simd_make_float3(surface->p0.j, bottom, surface->p0.i)),
			simd_make_float2(0, 0)
		}
	};

	if (@available(macOS 26.0, *)) {
		if (renderer) {
			[renderer addPolygonWithVertices:vertices count:4];
		}
	}
}
