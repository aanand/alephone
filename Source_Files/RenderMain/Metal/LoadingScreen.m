//
//  LoadingScreen.m
//  AlephOne
//
//  Created by Aanand Prasad on 07/11/2026.
//

#import "LoadingScreen.h"

@implementation LoadingScreen
{
	MetalPipeline *_pipeline;
	id<MTLRenderPipelineState> _pipelineState;
	id<MTL4ArgumentTable> _vertexArgumentTable;
	id<MTLResidencySet> _residencySet;
	id<MTLBuffer> _stateBuffer;
}

- (instancetype) initWithPipeline:(MetalPipeline *)pipeline {
	if (self = [super init]) {
		_pipeline = pipeline;
	}
	return self;
}

- (bool) compileForPixelFormat:(MTLPixelFormat)pixelFormat {
	_pipelineState = [_pipeline renderPipelineStateWithVertexFunction:@"loadingScreenVertexShader"
													 fragmentFunction:@"loadingScreenFragmentShader"
																label:@"Loading screen"
														  pixelFormat:pixelFormat];
	if (!_pipelineState) {
		return false;
	}
	
	NSError *error;
	
	MTL4ArgumentTableDescriptor *argDesc = [MTL4ArgumentTableDescriptor new];
	argDesc.maxBufferBindCount = 1;
	
	_vertexArgumentTable = [_pipeline.device newArgumentTableWithDescriptor:argDesc error:&error];
	if (!_vertexArgumentTable) {
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

	_stateBuffer = [_pipeline.device newBufferWithLength:sizeof(LoadingScreenState) options:MTLResourceStorageModeShared];
	[_residencySet addAllocation:_stateBuffer];

	[_residencySet commit];
	
	return true;
}

-(void)dealloc {
	if (_pipeline && _residencySet) {
		[_pipeline.commandQueue removeResidencySet:_residencySet];
	}
}

-(void)renderToDrawable:(id<CAMetalDrawable>)currentDrawable progress:(float)progress {
	LoadingScreenState *state = (LoadingScreenState*)_stateBuffer.contents;
	state->progress = progress;

	MTL4RenderPassDescriptor *configuration = [MTL4RenderPassDescriptor new];
	configuration.colorAttachments[0].texture = currentDrawable.texture;
	configuration.colorAttachments[0].loadAction = MTLLoadActionClear;
	configuration.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0, 0, 1.0);
	configuration.colorAttachments[0].storeAction = MTLStoreActionStore;

	[_pipeline begin];
	
	id<MTL4RenderCommandEncoder> encoder = [_pipeline.commandBuffer renderCommandEncoderWithDescriptor:configuration];
	if (!encoder) {
		NSLog(@"Failed to create render command encoder");
		return;
	}
	encoder.label = @"Final render";
	
	[encoder setRenderPipelineState:_pipelineState];
	[encoder setViewport:[_view getViewportWithPixelScaling:YES]];

	[_vertexArgumentTable setAddress:_stateBuffer.gpuAddress atIndex:0];
	[encoder setArgumentTable:_vertexArgumentTable atStages:MTLRenderStageVertex];
	[encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:12];
	
	[encoder endEncoding];
	
	[_pipeline end];

	[_pipeline.commandQueue waitForDrawable:currentDrawable];
	[_pipeline.commandQueue signalDrawable:currentDrawable];
	[currentDrawable present];
}

@end
