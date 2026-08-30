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

NSUInteger LoadWallTexture(vertical_surface_data *surface) {
	shape_descriptor shape = surface->texture_definition->texture;

	if (@available(macOS 26.0, *)) {
		if (![renderer hasTextureWithID:shape]) {
			const ImageDescriptor *image = GetTexture(shape);

//			const uint32* pixels = image->GetBuffer();
//			for (int i = 0; i < image->GetNumPixels(); i += 129) {
//				uint32 pixel = pixels[i];
//				logWarning("pixels[%d]: (b=%u, g=%u, r=%u, a=%u)", i, pixel & 0xFF, (pixel >> 8) & 0xFF, (pixel >> 16) & 0xFF, (pixel >> 24) & 0xFF);
//			}
			
			MetalImage *metalImage = [[MetalImage alloc] initWithWidth:image->GetWidth()
																height:image->GetHeight()
																pixels:image->GetBuffer()];

			[renderer addTextureWithID:shape image:metalImage];
			return shape;
		}
	}
	
	return 0;
}

// Aleph One hands us camera-relative quad vertices whose dimensions seem to lie in the [-2000, 2000] range or so.
// Scaling them down doesn't affect their eventual position on the screen, but does stop them getting excised from Metal's clip-space range.
simd_float3 scaleToViewSpace(simd_float3 worldSpace) {
	return worldSpace / 2000.0;
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
	NSUInteger textureID = LoadWallTexture(surface);

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
			simd_make_float2(1, 0)
		},
		Vertex{
			scaleToViewSpace(simd_make_float3(surface->p1.j, bottom, surface->p1.i)),
			simd_make_float2(1, 1)
		},
		Vertex{
			scaleToViewSpace(simd_make_float3(surface->p0.j, bottom, surface->p0.i)),
			simd_make_float2(0, 1)
		}
	};

	if (@available(macOS 26.0, *)) {
		if (renderer) {
			[renderer addPolygonWithVertices:vertices count:4 textureID:textureID];
		}
	}
}
