//
//  Rasterizer_Metal.mm
//  AlephOne
//
//  Created by Aanand Prasad on 24/08/2026.
//

#include <SDL2/SDL.h>
#include <SDL2/SDL_syswm.h>

#include "Rasterizer_Metal.h"
#include "Logging.h"

#include "Metal/MetalRenderer.h"

#include <simd/simd.h>

API_AVAILABLE(macos(26.0))
MetalRenderer *renderer;

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

void RenderRasterize_Metal::render_node_floor_or_ceiling(clipping_window_data *window, polygon_data *polygon, horizontal_surface_data *surface,
														 bool void_present, bool ceil, RenderStep renderStep)
{
	simd_long3 *vertices = (simd_long3*)malloc(sizeof(simd_long3) * polygon->vertex_count);

	for (int i=0; i < polygon->vertex_count; i++) {
		endpoint_data *data = get_endpoint_data(polygon->endpoint_indexes[i]);
		vertices[i] = simd_make_long3(data->transformed.y, surface->height - view->origin.z, data->transformed.x);
	}
	
	if (@available(macOS 26.0, *)) {
		if (renderer) {
			[renderer addPolygonWithVertices:vertices count:polygon->vertex_count];
		}
	}
}

void RenderRasterize_Metal::render_node_side(clipping_window_data *window, vertical_surface_data *surface,
											 bool void_present, RenderStep renderStep)
{
	simd_long3 vertices[4];
	
	// surface->pN.i maps to viewspace Z (near to far)
	// surface->pN.j maps to viewspace X (left to right)
	// surface->hN   maps to viewspace Y (low to high)
	
	long bottom = surface->h0;
	long top = MIN(surface->h1, surface->hmax);
	
	vertices[0] = simd_make_long3(surface->p0.j, top,    surface->p0.i);
	vertices[1] = simd_make_long3(surface->p1.j, top,    surface->p1.i);
	vertices[2] = simd_make_long3(surface->p1.j, bottom, surface->p1.i);
	vertices[3] = simd_make_long3(surface->p0.j, bottom, surface->p0.i);
	
	if (@available(macOS 26.0, *)) {
		if (renderer) {
			[renderer addPolygonWithVertices:vertices count:4];
		}
	}
}
