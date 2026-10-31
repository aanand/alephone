//
//  InitialRender.m
//  AlephOne
//
//  Created by Aanand Prasad on 31/10/2026.
//

#import "InitialRender.h"

#import <Metal/Metal.h>
#import "MetalTypes.h"

const NSString *vertexFunctionName = @"initialRenderVertexShader";
const NSString *fragmentFunctionName = @"initialRenderFragmentShader";

@implementation InitialRender
{
	MetalPipeline *_pipeline;
	View *_view;
	PostProcessingType _postProcessingType;

	id<MTLRenderPipelineState> pipelineState;
	id<MTL4ArgumentTable> vertexArgumentTable;
	id<MTL4ArgumentTable> fragmentArgumentTable;
	id<MTLArgumentEncoder> albedoTextureArgumentEncoder;
	id<MTLBuffer> albedoTextureArgumentBuffer;
	id<MTLBuffer> triangleBuffer;
}

-(instancetype)initWithPipeline:(MetalPipeline *)pipeline {
	_pipeline = pipeline;

	if (self = [super init]) {
		if (![self setupResidencySet]) {
			return nil;
		}
	}

	return self;
}

-(bool)compile {
	if (![self setupTextures]) {
		return false;
	}

	pipelineState = [self compilePipelineState];
	if (!pipelineState) {
		return false;
	}
	
	if (![self setupArgumentTables]) {
		return false;
	}

	NSAssert(_uniformsBuffer != nil, @"uniformsBuffer is not set");
	[_residencySet addAllocation:_uniformsBuffer];
	
	triangleBuffer = [_pipeline.device newBufferWithLength:(sizeof(WorldVertex) * MAX_TRIANGLES * 3) options:MTLResourceStorageModeShared];
	triangleBuffer.label = @"Triangle vertices";
	[_residencySet addAllocation:triangleBuffer];

	[_residencySet commit];
	
	return true;
}

-(void)shutdown {
	[_residencySet removeAllAllocations];
	_staticTriangles = nil;
	_dynamicTriangles = nil;
}

-(bool)setupResidencySet {
	NSError *error;

	MTLResidencySetDescriptor *residencySetDescriptor = [MTLResidencySetDescriptor new];
	residencySetDescriptor.label = @"[InitialRender] residencySet";
	_residencySet = [_pipeline.device newResidencySetWithDescriptor:residencySetDescriptor
															  error:&error];
	if (error) {
		NSLog(@"%@", error);
		return false;
	}

	return true;
}

-(bool)setupTextures {
	MTLTextureDescriptor *initial = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:DiffuseAlbedoPixelFormat
																					   width:_view.viewportSize.x
																					  height:_view.viewportSize.y
																				   mipmapped:NO];
	initial.storageMode = MTLStorageModePrivate;
	initial.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
	_diffuseAlbedoTexture = [_pipeline.device newTextureWithDescriptor:initial];
	_diffuseAlbedoTexture.label = @"Diffuse Albedo";
	
	initial.pixelFormat = SpecularAlbedoPixelFormat;
	_specularAlbedoTexture = [_pipeline.device newTextureWithDescriptor:initial];
	_specularAlbedoTexture.label = @"Specular Albedo";
	
	initial.pixelFormat = RoughnessPixelFormat;
	_roughnessTexture = [_pipeline.device newTextureWithDescriptor:initial];
	_roughnessTexture.label = @"Roughness";
	
	initial.pixelFormat = DepthPixelFormat;
	_depthTexture = [_pipeline.device newTextureWithDescriptor:initial];
	_depthTexture.label = @"Depth";
	
	initial.pixelFormat = NormalPixelFormat;
	_normalTexture = [_pipeline.device newTextureWithDescriptor:initial];
	_normalTexture.label = @"Normal";
	
	initial.pixelFormat = MotionPixelFormat;
	_motionTexture = [_pipeline.device newTextureWithDescriptor:initial];
	_motionTexture.label = @"Motion";

	switch (_postProcessingType) {
		case NoPostProcessing:
			_textures = [NSSet setWithArray:@[
				_diffuseAlbedoTexture,
				_depthTexture,
				_motionTexture,
			]];
			break;

		case WaveletDenoise:
			_textures = [NSSet setWithArray:@[
				_diffuseAlbedoTexture,
				_depthTexture,
				_normalTexture,
			]];
			break;
			
		case TAA:
			_textures = [NSSet setWithArray:@[
				_diffuseAlbedoTexture,
				_motionTexture,
			]];
			break;

		case TemporalUpscale:
			_textures = [NSSet setWithArray:@[
				_diffuseAlbedoTexture,
				_depthTexture,
				_motionTexture,
			]];
			break;

		case TemporalDenoisedUpscale:
			_textures = [NSSet setWithArray:@[
				_diffuseAlbedoTexture,
				_depthTexture,
				_normalTexture,
				_specularAlbedoTexture,
				_roughnessTexture,
				_motionTexture,
			]];
			break;
	}
	
	for (id<MTLTexture> texture in _textures) {
		[_residencySet addAllocation:texture];
	}
	
	return true;
}

-(id<MTLRenderPipelineState>) compilePipelineState {
	NSError *error;
	id<MTL4Compiler> compiler = [_pipeline.device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
															error:&error];

	if (error) {
		NSLog(@"%@", error);
		return nil;
	}

	MTL4LibraryFunctionDescriptor *vertexFunction = [MTL4LibraryFunctionDescriptor new];
	vertexFunction.library = _pipeline.defaultLibrary;
	vertexFunction.name = [vertexFunctionName copy];
	
	MTL4LibraryFunctionDescriptor *fragmentFunction = [MTL4LibraryFunctionDescriptor new];
	fragmentFunction.library = _pipeline.defaultLibrary;
	fragmentFunction.name = [fragmentFunctionName copy];

	MTL4RenderPipelineDescriptor *descriptor = [MTL4RenderPipelineDescriptor new];
	descriptor.label = @"Initial Render";
	descriptor.vertexFunctionDescriptor = vertexFunction;
	descriptor.fragmentFunctionDescriptor = fragmentFunction;
	
	if ([_textures containsObject:_diffuseAlbedoTexture]) {
		MTL4RenderPipelineColorAttachmentDescriptor *albedoAttachment = descriptor.colorAttachments[InitialRenderAttachmentDiffuseAlbedo];
		albedoAttachment.pixelFormat = DiffuseAlbedoPixelFormat;
		albedoAttachment.blendingState = MTL4BlendStateEnabled;
		albedoAttachment.sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
		albedoAttachment.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
		albedoAttachment.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
		albedoAttachment.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
	}
	
	if ([_textures containsObject:_depthTexture]) {
		MTL4RenderPipelineColorAttachmentDescriptor *depthAttachment = descriptor.colorAttachments[InitialRenderAttachmentDepth];
		depthAttachment.pixelFormat = DepthPixelFormat;
	}
	
	if ([_textures containsObject:_normalTexture]) {
		MTL4RenderPipelineColorAttachmentDescriptor *normalAttachment = descriptor.colorAttachments[InitialRenderAttachmentNormal];
		normalAttachment.pixelFormat = NormalPixelFormat;
	}
	
	if ([_textures containsObject:_specularAlbedoTexture]) {
		MTL4RenderPipelineColorAttachmentDescriptor *specularAlbedoAttachment = descriptor.colorAttachments[InitialRenderAttachmentSpecularAlbedo];
		specularAlbedoAttachment.pixelFormat = SpecularAlbedoPixelFormat;
	}
	
	if ([_textures containsObject:_roughnessTexture]) {
		MTL4RenderPipelineColorAttachmentDescriptor *roughnessAttachment = descriptor.colorAttachments[InitialRenderAttachmentRoughness];
		roughnessAttachment.pixelFormat = RoughnessPixelFormat;
	}
	
	if ([_textures containsObject:_motionTexture]) {
		MTL4RenderPipelineColorAttachmentDescriptor *motionAttachment = descriptor.colorAttachments[InitialRenderAttachmentMotion];
		motionAttachment.pixelFormat = MotionPixelFormat;
	}

	id<MTLRenderPipelineState> state = [compiler newRenderPipelineStateWithDescriptor:descriptor
																  compilerTaskOptions:nil
																				error:&error];
	
	if (error) {
		NSLog(@"%@", error);
	}
	
	return state;
}

-(bool)setupArgumentTables {
	NSError *error;

	MTL4ArgumentTableDescriptor *vertexArgumentTableDescriptor = [MTL4ArgumentTableDescriptor new];
	vertexArgumentTableDescriptor.maxBufferBindCount = MAX(InitialRenderVertexShader_NumBuffers, FinalRenderVertexShader_NumBuffers);
	vertexArgumentTableDescriptor.label = @"Vertex argument table";
	vertexArgumentTable = [_pipeline.device newArgumentTableWithDescriptor:vertexArgumentTableDescriptor error:&error];
	if (error) {
		NSLog(@"%@", error);
		return false;
	}
	
	MTL4ArgumentTableDescriptor *fragmentArgumentTableDescriptor = [MTL4ArgumentTableDescriptor new];
	fragmentArgumentTableDescriptor.maxTextureBindCount = FinalRenderFragmentShader_NumTextures;
	fragmentArgumentTableDescriptor.maxBufferBindCount = MAX(InitialRenderFragmentShader_NumBuffers, FinalRenderFragmentShader_NumBuffers);
	fragmentArgumentTableDescriptor.label = @"Fragment argument table";
	fragmentArgumentTable = [_pipeline.device newArgumentTableWithDescriptor:fragmentArgumentTableDescriptor error:&error];
	if (error) {
		NSLog(@"%@", error);
		return false;
	}
	
	id<MTLFunction> fragmentFunction = [_pipeline.defaultLibrary newFunctionWithName:[fragmentFunctionName copy]];
	albedoTextureArgumentEncoder = [fragmentFunction newArgumentEncoderWithBufferIndex:InitialRenderFragmentShaderAlbedoTexturesIndex];
	albedoTextureArgumentEncoder.label = @"albedoTextureArgumentEncoder";
	albedoTextureArgumentBuffer = [_pipeline.device newBufferWithLength:albedoTextureArgumentEncoder.encodedLength
																options:MTLResourceStorageModeShared];
	[albedoTextureArgumentEncoder setArgumentBuffer:albedoTextureArgumentBuffer offset:0];
	[_residencySet addAllocation:albedoTextureArgumentBuffer];

	return true;
}

- (void) populateTextureArgumentBuffer:(NSDictionary<NSString *,id<MTLTexture>> *)albedoTextures {
	for (NSUInteger i = 0; i < _textureIDs.count; i++) {
		id<MTLTexture> albedoTexture = albedoTextures[_textureIDs[i]];
		[albedoTextureArgumentEncoder setTexture:albedoTexture atIndex:i];
		[_residencySet addAllocation:albedoTexture];
	}
}

- (void) encodeAndUpdateFence:(id<MTLFence>)fence
{
	// Commit any textures that were added
	[_residencySet commit];

	MTL4RenderPassDescriptor *configuration = [MTL4RenderPassDescriptor new];

	if ([_textures containsObject:_diffuseAlbedoTexture]) {
		MTLRenderPassColorAttachmentDescriptor *diffuseAlbedo = configuration.colorAttachments[InitialRenderAttachmentDiffuseAlbedo];
		diffuseAlbedo.texture = _diffuseAlbedoTexture;
		diffuseAlbedo.loadAction = MTLLoadActionClear;
		// Render a white sky, which the raytracing pass will multiply down
		diffuseAlbedo.clearColor = MTLClearColorMake(1.0, 1.0, 1.0, 1.0);
		diffuseAlbedo.storeAction = MTLStoreActionStore;
	}

	if ([_textures containsObject:_depthTexture]) {
		MTLRenderPassColorAttachmentDescriptor *depth = configuration.colorAttachments[InitialRenderAttachmentDepth];
		depth.texture = _depthTexture;
		depth.loadAction = MTLLoadActionClear;
		depth.clearColor = MTLClearColorMake(1.0, 1.0, 1.0, 1.0);
		depth.storeAction = MTLStoreActionStore;
	}
	
	if ([_textures containsObject:_normalTexture]) {
		MTLRenderPassColorAttachmentDescriptor *normal = configuration.colorAttachments[InitialRenderAttachmentNormal];
		normal.texture = _normalTexture;
		normal.loadAction = MTLLoadActionClear;
		normal.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
		normal.storeAction = MTLStoreActionStore;
	}
	
	if ([_textures containsObject:_specularAlbedoTexture]) {
		MTLRenderPassColorAttachmentDescriptor *specularAlbedo = configuration.colorAttachments[InitialRenderAttachmentSpecularAlbedo];
		specularAlbedo.texture = _specularAlbedoTexture;
		specularAlbedo.loadAction = MTLLoadActionClear;
		specularAlbedo.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
		specularAlbedo.storeAction = MTLStoreActionStore;
	}
	
	if ([_textures containsObject:_roughnessTexture]) {
		MTLRenderPassColorAttachmentDescriptor *roughness = configuration.colorAttachments[InitialRenderAttachmentRoughness];
		roughness.texture = _roughnessTexture;
		roughness.loadAction = MTLLoadActionClear;
		roughness.clearColor = MTLClearColorMake(1.0, 1.0, 1.0, 1.0);
		roughness.storeAction = MTLStoreActionStore;
	}
	
	if ([_textures containsObject:_motionTexture]) {
		MTLRenderPassColorAttachmentDescriptor *motion = configuration.colorAttachments[InitialRenderAttachmentMotion];
		motion.texture = _motionTexture;
		motion.loadAction = MTLLoadActionClear;
		motion.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
		motion.storeAction = MTLStoreActionStore;
	}
	
	id<MTL4RenderCommandEncoder> renderPassEncoder = [_pipeline.commandBuffer renderCommandEncoderWithDescriptor:configuration];
	if (!renderPassEncoder) {
		NSLog(@"Failed to create render command encoder");
		return;
	}
	renderPassEncoder.label = @"Initial render";
	
	[renderPassEncoder setRenderPipelineState:pipelineState];

	NSAssert(_depthState != nil, @"depthState is not set");
	[renderPassEncoder setDepthStencilState:_depthState];
	[renderPassEncoder setViewport:[_view getViewportWithPixelScaling:NO]];
	
	[vertexArgumentTable setAddress:_uniformsBuffer.gpuAddress atIndex:InitialRenderVertexShaderUniformsIndex];
	[vertexArgumentTable setAddress:triangleBuffer.gpuAddress atIndex:InitialRenderVertexShaderVertexDataIndex];

	[fragmentArgumentTable setAddress:_uniformsBuffer.gpuAddress atIndex:InitialRenderFragmentShaderUniformsIndex];
	[fragmentArgumentTable setAddress:albedoTextureArgumentBuffer.gpuAddress atIndex:InitialRenderFragmentShaderAlbedoTexturesIndex];

	WorldVertex *target = (WorldVertex*)triangleBuffer.contents;
	NSUInteger __block numVertices = 0;

	NSAssert(_textureIDs != nil, @"textureIDs is not set");

	void (^drawTriangle)(Triangle*) = ^(Triangle *triangle){
		NSAssert(numVertices/3 < MAX_TRIANGLES, @"Exceeded triangle buffer size");

		NSUInteger textureIndex = [self->_textureIDs indexOfObject:triangle.surface.textureID];
		NSAssert(textureIndex != NSNotFound, @"Missing triangle texture ID");

		target[numVertices] = triangle.v0;
		target[numVertices].textureIndex = (uint32_t)textureIndex;
		target[numVertices].material = triangle.surface.material;
		target[numVertices+1] = triangle.v1;
		target[numVertices+1].textureIndex = (uint32_t)textureIndex;
		target[numVertices+1].material = triangle.surface.material;
		target[numVertices+2] = triangle.v2;
		target[numVertices+2].textureIndex = (uint32_t)textureIndex;
		target[numVertices+2].material = triangle.surface.material;

		numVertices += 3;
	};
	
	for (Triangle *triangle in _staticTriangles) drawTriangle(triangle);
	for (Triangle *triangle in _dynamicTriangles) drawTriangle(triangle);

	[renderPassEncoder setArgumentTable:vertexArgumentTable atStages:MTLRenderStageVertex];
	[renderPassEncoder setArgumentTable:fragmentArgumentTable atStages:MTLRenderStageFragment];
	[renderPassEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:numVertices];

	[renderPassEncoder updateFence:fence afterEncoderStages:MTLStageFragment];
	[renderPassEncoder endEncoding];
}

@end
