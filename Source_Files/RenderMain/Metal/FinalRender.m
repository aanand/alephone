//
//  FinalRender.m
//  AlephOne
//
//  Created by Aanand Prasad on 01/11/2026.
//

#import "FinalRender.h"

@implementation FinalRender
{
	id<MTLRenderPipelineState> pipelineState;
	id<MTL4ArgumentTable> fragmentArgumentTable;
	id<MTLTexture> hudTexture;
}

-(bool)compileForPixelFormat:(MTLPixelFormat)pixelFormat {
	pipelineState = [_pipeline renderPipelineStateWithVertexFunction:@"finalRenderVertexShader"
													fragmentFunction:@"finalRenderFragmentShader"
															   label:@"Final render"
														 pixelFormat:pixelFormat];
	if (!pipelineState) {
		return false;
	}

	NSError *error;
	
	MTL4ArgumentTableDescriptor *fragmentArgumentTableDescriptor = [MTL4ArgumentTableDescriptor new];
	fragmentArgumentTableDescriptor.maxTextureBindCount = FinalRenderFragmentShader_NumTextures;
	fragmentArgumentTableDescriptor.maxBufferBindCount = FinalRenderFragmentShader_NumBuffers;
	fragmentArgumentTableDescriptor.label = @"[FinalRender] Fragment argument table";
	fragmentArgumentTable = [_pipeline.device newArgumentTableWithDescriptor:fragmentArgumentTableDescriptor error:&error];
	if (error) {
		NSLog(@"%@", error);
		return false;
	}
	
	MTLResidencySetDescriptor *residencySetDescriptor = [MTLResidencySetDescriptor new];
	residencySetDescriptor.label = @"[FinalRender] residencySet";
	_residencySet = [_pipeline.device newResidencySetWithDescriptor:residencySetDescriptor error:&error];
	if (error) {
		NSLog(@"%@", error);
		return false;
	}
	
	NSAssert(_uniformsBuffer != nil, @"uniformsBuffer is not set");
	[_residencySet addAllocation:_uniformsBuffer];

	[_residencySet addAllocation:_diffuseAlbedoTexture];
	[_residencySet addAllocation:_rayTracingOutputTexture];
	[_residencySet addAllocation:_postProcessingScratchTexture];
	[_residencySet addAllocation:_postProcessingOutputTexture];

	[_residencySet commit];
	
	return true;
}

-(void)shutdown {
	[_residencySet removeAllAllocations];
}

-(id<MTLTexture>)HUDTexture {
	return hudTexture;
}

-(void)setHUDTexture:(id<MTLTexture>)texture {
	if (hudTexture) [_residencySet removeAllocation:hudTexture];
	hudTexture = texture;
	[_residencySet addAllocation:hudTexture];
	[_residencySet commit];
}

-(void) encodeToOutputTexture:(id<MTLTexture>)outputTexture afterFences:(NSArray<id<MTLFence>>*)fences
{
	MTL4RenderPassDescriptor *configuration = [MTL4RenderPassDescriptor new];
	configuration.colorAttachments[0].texture = outputTexture;
	configuration.colorAttachments[0].loadAction = MTLLoadActionClear;
	configuration.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1.0);
	configuration.colorAttachments[0].storeAction = MTLStoreActionStore;

	id<MTL4RenderCommandEncoder> encoder = [_pipeline.commandBuffer renderCommandEncoderWithDescriptor:configuration];
	if (!encoder) {
		NSLog(@"Failed to create render command encoder");
		return;
	}
	encoder.label = @"Final render";
	
	for (id<MTLFence> fence in fences) {
		[encoder waitForFence:fence beforeEncoderStages:MTLStageVertex];
	}
	
	[encoder setRenderPipelineState:pipelineState];
	[encoder setViewport:[_view getViewportWithPixelScaling:YES]];

	id<MTLTexture> processedOutput = (_postProcessingType == NoPostProcessing) ? _rayTracingOutputTexture : _postProcessingOutputTexture;

	[fragmentArgumentTable setAddress:_uniformsBuffer.gpuAddress atIndex:FinalRenderFragmentShaderUniformsIndex];
	[fragmentArgumentTable setTexture:_diffuseAlbedoTexture.gpuResourceID atIndex:FinalRenderFragmentShaderAlbedoTextureIndex];
	[fragmentArgumentTable setTexture:processedOutput.gpuResourceID atIndex:FinalRenderFragmentShaderRayTracingTextureIndex];
	[fragmentArgumentTable setTexture:hudTexture.gpuResourceID atIndex:FinalRenderFragmentShaderHUDTextureIndex];
	[encoder setArgumentTable:fragmentArgumentTable atStages:MTLRenderStageFragment];
	[encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
	
	[encoder endEncoding];
}


@end
