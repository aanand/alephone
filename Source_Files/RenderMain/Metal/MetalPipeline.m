//
//  MetalPipeline.m
//  AlephOne
//
//  Created by Aanand Prasad on 07/09/2026.
//

#import "MetalPipeline.h"

@implementation MetalPipeline

- (id<MTLRenderPipelineState>) renderPipelineStateWithVertexFunction:(NSString*)vertexFunctionName
													fragmentFunction:(NSString*)fragmentFunctionName
															   label:(NSString*)label
														 pixelFormat:(MTLPixelFormat)pixelFormat
{
	NSError *error;
	id<MTL4Compiler> compiler = [_device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
															error:&error];
	
	if (error) {
		NSLog(@"%@", error);
		return nil;
	}

	MTL4LibraryFunctionDescriptor *vertexFunction = [MTL4LibraryFunctionDescriptor new];
	vertexFunction.library = _defaultLibrary;
	vertexFunction.name = vertexFunctionName;
	
	MTL4LibraryFunctionDescriptor *fragmentFunction = [MTL4LibraryFunctionDescriptor new];
	fragmentFunction.library = _defaultLibrary;
	fragmentFunction.name = fragmentFunctionName;
	
	MTL4RenderPipelineDescriptor *descriptor = [MTL4RenderPipelineDescriptor new];
	descriptor.label = label;
	descriptor.vertexFunctionDescriptor = vertexFunction;
	descriptor.fragmentFunctionDescriptor = fragmentFunction;
	
	MTL4RenderPipelineColorAttachmentDescriptor *colorAttachment = descriptor.colorAttachments[0];
	colorAttachment.pixelFormat = pixelFormat;
	
	id<MTLRenderPipelineState> state = [compiler newRenderPipelineStateWithDescriptor:descriptor
																  compilerTaskOptions:nil
																				error:&error];
	if (error) {
		NSLog(@"%@", error);
		return nil;
	}
	
	return state;
}

@end
