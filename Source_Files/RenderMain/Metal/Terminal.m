//
//  Terminal.m
//  AlephOne
//
//  Created by Aanand Prasad on 08/11/2026.
//

#import "Terminal.h"

@implementation Terminal
{
	MetalPipeline *_pipeline;
	id<MTLRenderPipelineState> _pipelineState;
	id<MTL4ArgumentTable> _fragmentArgumentTable;
	id<MTLResidencySet> _residencySet;
	id<MTLTexture> _texture;
}

-(instancetype)initWithPipeline:(MetalPipeline *)pipeline {
	if (self = [super init]) {
		_pipeline = pipeline;
	}
	return self;
}

-(void)dealloc {
	if (_pipeline && _residencySet) {
		[_pipeline.commandQueue removeResidencySet:_residencySet];
	}
}

-(bool)compileForPixelFormat:(MTLPixelFormat)pixelFormat {
	_pipelineState = [_pipeline renderPipelineStateWithVertexFunction:@"terminalVertexShader"
													 fragmentFunction:@"terminalFragmentShader"
																label:@"terminal"
														  pixelFormat:pixelFormat];
	if (!_pipelineState) {
		return false;
	}
	
	NSError *error;
	
	MTL4ArgumentTableDescriptor *argDesc = [MTL4ArgumentTableDescriptor new];
	argDesc.maxTextureBindCount = 1;
	
	_fragmentArgumentTable = [_pipeline.device newArgumentTableWithDescriptor:argDesc error:&error];
	if (!_fragmentArgumentTable) {
		NSLog(@"%@", error);
		return false;
	}
	
	MTLResidencySetDescriptor *resDesc = [MTLResidencySetDescriptor new];
	_residencySet = [_pipeline.device newResidencySetWithDescriptor:resDesc error:&error];
	if (!_residencySet) {
		NSLog(@"%@", error);
		return false;
	}
	[_pipeline.commandQueue addResidencySet:_residencySet];

	[_residencySet commit];

	return true;
}

-(id<MTLTexture>)texture {
	return _texture;
}

-(void)setTexture:(id<MTLTexture>)texture {
	if (_texture) [_residencySet removeAllocation:_texture];
	_texture = texture;
	[_residencySet addAllocation:_texture];
	[_residencySet commit];
}

-(void)renderToDrawable:(id<CAMetalDrawable>)currentDrawable {
	MTL4RenderPassDescriptor *configuration = [MTL4RenderPassDescriptor new];
	configuration.colorAttachments[0].texture = currentDrawable.texture;
	configuration.colorAttachments[0].loadAction = MTLLoadActionClear;
	configuration.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0, 0, 1.0);
	configuration.colorAttachments[0].storeAction = MTLStoreActionStore;

	id<MTL4CommandBuffer> commandBuffer = _pipeline.commandBuffer;
	[commandBuffer beginCommandBufferWithAllocator:_pipeline.commandAllocator];
	
	id<MTL4RenderCommandEncoder> encoder = [_pipeline.commandBuffer renderCommandEncoderWithDescriptor:configuration];
	if (!encoder) {
		NSLog(@"Failed to create render command encoder");
		return;
	}
	encoder.label = @"Terminal";
	
	[encoder setRenderPipelineState:_pipelineState];
	[encoder setViewport:[_view getViewportWithPixelScaling:YES]];

	[_fragmentArgumentTable setTexture:_texture.gpuResourceID atIndex:0];
	[encoder setArgumentTable:_fragmentArgumentTable atStages:MTLRenderStageFragment];
	[encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
	
	[encoder endEncoding];
	
	[commandBuffer endCommandBuffer];

	[_pipeline.commandQueue waitForDrawable:currentDrawable];
	[_pipeline.commandQueue commit:&commandBuffer count:1];
	[_pipeline.commandQueue signalDrawable:currentDrawable];
	[_pipeline.commandAllocator reset];
}

@end
