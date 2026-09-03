//
//  Rasterizer_Metal.h
//  AlephOne
//
//  Created by Aanand Prasad on 24/08/2026.
//

#ifndef Rasterizer_Metal_h
#define Rasterizer_Metal_h

#if defined(__MACH__) && defined(__APPLE__)
#define PREFER_METAL
#endif

#include "Rasterizer.h"
#include "RenderRasterize.h"

extern bool Metal_InitializeForWindow(SDL_Window* window, int width, int height);

class Rasterizer_Metal_Class : public RasterizerClass {
	void SetView(view_data &View);
	void Begin();
	void End();
};

class RenderRasterize_Metal : public RenderRasterizerClass {
protected:
//	void render_node_floor_or_ceiling(clipping_window_data *window, polygon_data *polygon, horizontal_surface_data *surface,
//									  bool void_present, bool ceil, RenderStep renderStep) override;
//	
//	void render_node_side(clipping_window_data *window, vertical_surface_data *surface,
//						  bool void_present, RenderStep renderStep) override;
//	
//	virtual void render_node_object(render_object_data *object, bool other_side_of_media, RenderStep renderStep) override;

};

#endif /* Rasterizer_Metal_h */
