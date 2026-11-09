//
//  PostProcessor.m
//  AlephOne
//
//  Created by Aanand Prasad on 01/11/2026.
//

#import <MetalFX/MetalFX.h>

#import "PostProcessor.h"
#import "Common.h"

NSArray<NSNumber*> *waveletDenoisePasses = @[@8, @4, @2, @1];

@implementation PostProcessor
{
	id<MTLComputePipelineState> denoisePipeline;
	id<MTLComputePipelineState> taaPipeline;
	id<MTL4ArgumentTable> argumentTable;

	// Using a Metal 3 command queue for the MetalFX upscalers because they seem to be buggy when using Metal 4
	id<MTLCommandQueue> mtl3queue;
	id<MTLFXTemporalScaler> temporalScaler;
	id<MTLFXTemporalDenoisedScaler> temporalDenoisedScaler;
	
	id<MTLBuffer> denoiseConfigBuffer;
}

-(bool)compile {
	denoisePipeline = [self compileComputePipelineWithFunctionName:@"denoiseKernel"];
	if (!denoisePipeline) {
		return false;
	}
	
	taaPipeline = [self compileComputePipelineWithFunctionName:@"TAA"];
	if (!taaPipeline) {
		return false;
	}
	
	mtl3queue = [_pipeline.device newCommandQueue];
	if (![self setupTemporalScaler]) {
		return nil;
	}
	if (![self setupTemporalDenoisedScaler]) {
		return nil;
	}
	
	NSError *error;
	
	MTL4ArgumentTableDescriptor *atDesc = [MTL4ArgumentTableDescriptor new];
	atDesc.maxBufferBindCount = DenoisePass_NumBuffers;
	atDesc.maxTextureBindCount = DenoisePass_NumTextures;
	atDesc.label = @"[PostProcessor] argumentTable";
	argumentTable = [_pipeline.device newArgumentTableWithDescriptor:atDesc error:&error];
	if (error) {
		NSLog(@"%@", error);
		return false;
	}

	MTLResidencySetDescriptor *rsDesc = [MTLResidencySetDescriptor new];
	rsDesc.label = @"[PostProcessor] residencySet";
	_residencySet = [_pipeline.device newResidencySetWithDescriptor:rsDesc error:&error];
	if (error) {
		NSLog(@"%@", error);
		return false;
	}
	
	denoiseConfigBuffer = [_pipeline.device newBufferWithLength:sizeof(DenoiseConfig) * waveletDenoisePasses.count options:MTLResourceStorageModeShared];
	denoiseConfigBuffer.label = @"Denoise config";
	[_residencySet addAllocation:denoiseConfigBuffer];
	
	NSAssert(_uniformsBuffer != nil, @"uniformsBuffer is not set");
	[_residencySet addAllocation:_uniformsBuffer];

	MTLTextureDescriptor *tDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:RayTracingPixelFormat
																					 width:_view.viewportSize.x
																					height:_view.viewportSize.y
																				 mipmapped:NO];
	tDesc.storageMode = MTLStorageModePrivate;
	tDesc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
	_scratchTexture = [_pipeline.device newTextureWithDescriptor:tDesc];
	_scratchTexture.label = @"[PostProcessor] scratchTexture";
	_outputTexture = [_pipeline.device newTextureWithDescriptor:tDesc];
	_outputTexture.label = @"[PostProcessor] outputTexture";
	[_residencySet addAllocation:_scratchTexture];
	[_residencySet addAllocation:_outputTexture];

	for (id<MTLTexture> texture in _initialRender.textures) {
		[_residencySet addAllocation:texture];
	}
	
	[_residencySet commit];

	return true;
}

- (id<MTLComputePipelineState>) compileComputePipelineWithFunctionName:(NSString*)functionName {
	NSError *error;
	id<MTLFunction> function = [_pipeline.defaultLibrary newFunctionWithName:functionName];
	
	id<MTLComputePipelineState> state = [_pipeline.device newComputePipelineStateWithFunction:function
																					   error:&error];
	if (error) {
		NSLog(@"%@", error);
	}
	
	return state;
}

- (bool) setupTemporalScaler {
	if (![MTLFXTemporalScalerDescriptor supportsMetal4FX:_pipeline.device]) {
		NSLog(@"Temporal scaler is unsupported");
		return false;
	}
	
	MTLFXTemporalScalerDescriptor *descriptor = [MTLFXTemporalScalerDescriptor new];
	descriptor.inputWidth = _view.viewportSize.x;
	descriptor.inputHeight = _view.viewportSize.y;
	descriptor.outputWidth = _view.viewportSize.x;
	descriptor.outputHeight = _view.viewportSize.y;

	descriptor.colorTextureFormat = RayTracingPixelFormat;
	descriptor.outputTextureFormat = RayTracingPixelFormat;
	descriptor.depthTextureFormat = DepthPixelFormat;
	descriptor.motionTextureFormat = MotionPixelFormat;
	
	descriptor.requiresSynchronousInitialization = YES;
	
	temporalScaler = [descriptor newTemporalScalerWithDevice:_pipeline.device];
	
	if (temporalScaler == nil) {
		NSLog(@"Failed to create temporal scaler");
		return false;
	}
	
	return true;
}

- (bool) setupTemporalDenoisedScaler {
	if (![MTLFXTemporalDenoisedScalerDescriptor supportsMetal4FX:_pipeline.device]) {
		NSLog(@"Temporal denoised scaler is unsupported");
		return false;
	}

	MTLFXTemporalDenoisedScalerDescriptor *descriptor = [MTLFXTemporalDenoisedScalerDescriptor new];
	descriptor.inputWidth = _view.viewportSize.x;
	descriptor.inputHeight = _view.viewportSize.y;
	descriptor.outputWidth = _view.viewportSize.x;
	descriptor.outputHeight = _view.viewportSize.y;

	descriptor.colorTextureFormat = RayTracingPixelFormat;
	descriptor.outputTextureFormat = RayTracingPixelFormat;
	descriptor.diffuseAlbedoTextureFormat = DiffuseAlbedoPixelFormat;
	descriptor.specularAlbedoTextureFormat = SpecularAlbedoPixelFormat;
	descriptor.roughnessTextureFormat = RoughnessPixelFormat;
	descriptor.depthTextureFormat = DepthPixelFormat;
	descriptor.normalTextureFormat = NormalPixelFormat;
	descriptor.motionTextureFormat = MotionPixelFormat;
	
	descriptor.requiresSynchronousInitialization = YES;
	
	temporalDenoisedScaler = [descriptor newTemporalDenoisedScalerWithDevice:_pipeline.device];
	
	if (temporalDenoisedScaler == nil) {
		NSLog(@"Failed to create temporal denoised scaler");
		return false;
	}
	
	return true;
}

-(void) encodeWaveletDenoiseUpdatingFence:(id<MTLFence>)fence {
	id<MTL4ComputeCommandEncoder> encoder = [self createComputeCommandEncoderForPipeline:denoisePipeline label:@"Denoise"];

	MTLSize threadsPerGrid = MTLSizeMake(_rayTracingOutputTexture.width, _rayTracingOutputTexture.height, 1);
	
	DenoiseConfig *configs = (DenoiseConfig*)denoiseConfigBuffer.contents;
	for (int i = 0; i < waveletDenoisePasses.count; i++) {
		configs[i].step = waveletDenoisePasses[i].unsignedIntValue;
	}
	
	id<MTLTexture> currentInput = _rayTracingOutputTexture;
	id<MTLTexture> currentOutput = (waveletDenoisePasses.count % 2 == 1) ? _outputTexture : _scratchTexture;

	for (int i = 0; i < waveletDenoisePasses.count; i++) {
		MTLGPUAddress configAddress = denoiseConfigBuffer.gpuAddress + (i * sizeof(DenoiseConfig));

		[argumentTable setAddress:_uniformsBuffer.gpuAddress atIndex:DenoisePassUniformsIndex];
		[argumentTable setAddress:configAddress atIndex:DenoisePassConfigIndex];
		[argumentTable setTexture:_initialRender.normalTexture.gpuResourceID atIndex:DenoisePassNormalTextureIndex];
		[argumentTable setTexture:_initialRender.depthTexture.gpuResourceID atIndex:DenoisePassDepthTextureIndex];
		[argumentTable setTexture:currentInput.gpuResourceID atIndex:DenoisePassInputTextureIndex];
		[argumentTable setTexture:currentOutput.gpuResourceID atIndex:DenoisePassOutputTextureIndex];
		[encoder setArgumentTable:argumentTable];
		
		[encoder dispatchThreads:threadsPerGrid
		   threadsPerThreadgroup:[self getThreadsPerThreadgroupForPipeline:denoisePipeline]];
		
		if (i < waveletDenoisePasses.count - 1) {
			[encoder barrierAfterEncoderStages:MTLStageDispatch
						   beforeEncoderStages:MTLStageDispatch
							 visibilityOptions:MTL4VisibilityOptionDevice];
			
			currentInput = currentOutput;
			currentOutput = (currentInput == _outputTexture) ? _scratchTexture : _outputTexture;
		}
	}

	[encoder updateFence:fence afterEncoderStages:MTLStageDispatch];
	[encoder endEncoding];
}

-(void) encodeTAAUpdatingFence:(id<MTLFence>)fence {
	id<MTL4ComputeCommandEncoder> encoder = [self createComputeCommandEncoderForPipeline:taaPipeline label:@"TAA"];
	
	MTLSize threadsPerGrid = MTLSizeMake(_rayTracingOutputTexture.width, _rayTracingOutputTexture.height, 1);

	id<MTLTexture> previousOutput = (_view.frameNumber % 2 == 0) ? _scratchTexture : _outputTexture;
	id<MTLTexture> currentOutput  = (_view.frameNumber % 2 == 0) ? _outputTexture : _scratchTexture;
	
	[argumentTable setAddress:_uniformsBuffer.gpuAddress atIndex:TAAKernelUniformsIndex];
	[argumentTable setTexture:_rayTracingOutputTexture.gpuResourceID atIndex:TAAKernelInputTextureIndex];
	[argumentTable setTexture:_initialRender.motionTexture.gpuResourceID atIndex:TAAKernelMotionTextureIndex];
	[argumentTable setTexture:previousOutput.gpuResourceID atIndex:TAAKernelPreviousOutputTextureIndex];
	[argumentTable setTexture:currentOutput.gpuResourceID atIndex:TAAKernelOutputTextureIndex];
	[encoder setArgumentTable:argumentTable];
	
	[encoder dispatchThreads:threadsPerGrid
	   threadsPerThreadgroup:[self getThreadsPerThreadgroupForPipeline:taaPipeline]];
	
	[encoder updateFence:fence afterEncoderStages:MTLStageDispatch];
	[encoder endEncoding];
}

-(id<MTL4ComputeCommandEncoder>) createComputeCommandEncoderForPipeline:(id<MTLComputePipelineState>)pipelineState
																  label:(NSString*)label
{
	id<MTL4ComputeCommandEncoder> encoder = [_pipeline.commandBuffer computeCommandEncoder];
	if (!encoder) {
		NSLog(@"Failed to create encoder for '%@'", label);
		return nil;
	}
	encoder.label = label;
	[encoder setComputePipelineState:pipelineState];
	return encoder;
}

-(MTLSize) getThreadsPerThreadgroupForPipeline:(id<MTLComputePipelineState>)pipelineState {
	NSUInteger w = pipelineState.threadExecutionWidth;
	NSUInteger h = pipelineState.maxTotalThreadsPerThreadgroup / w;
	return MTLSizeMake( w, h, 1 );
}

-(void) encodeTemporalUpscaleUpdatingFence:(id<MTLFence>)fence {
	id<MTLCommandBuffer> mtl3buffer = [mtl3queue commandBuffer];
	mtl3buffer.label = [NSString stringWithFormat:@"Frame %llu (denoise)", _view.frameNumber];
	
	temporalScaler.colorTexture = _rayTracingOutputTexture;
	temporalScaler.depthTexture = _initialRender.depthTexture;
	temporalScaler.motionTexture = _initialRender.motionTexture;
	temporalScaler.motionVectorScaleX = 1.0;
	temporalScaler.motionVectorScaleY = 1.0;
	temporalScaler.outputTexture = _outputTexture;
	temporalScaler.jitterOffsetX = _view.jitter.x;
	temporalScaler.jitterOffsetY = _view.jitter.y;
	temporalScaler.fence = fence;
	[temporalScaler encodeToCommandBuffer:mtl3buffer];
	[mtl3buffer commit];
	[mtl3buffer waitUntilCompleted];
}

-(void) encodeTemporalDenoisedUpscaleUpdatingFence:(id<MTLFence>)fence {
	id<MTLCommandBuffer> mtl3buffer = [mtl3queue commandBuffer];
	mtl3buffer.label = [NSString stringWithFormat:@"Frame %llu (denoise)", _view.frameNumber];
	
	temporalDenoisedScaler.colorTexture = _rayTracingOutputTexture;
	temporalDenoisedScaler.diffuseAlbedoTexture = _initialRender.diffuseAlbedoTexture;
	temporalDenoisedScaler.specularAlbedoTexture = _initialRender.specularAlbedoTexture;
	temporalDenoisedScaler.roughnessTexture = _initialRender.roughnessTexture;
	temporalDenoisedScaler.depthTexture = _initialRender.depthTexture;
	temporalDenoisedScaler.normalTexture = _initialRender.normalTexture;
	temporalDenoisedScaler.motionTexture = _initialRender.motionTexture;
	temporalDenoisedScaler.motionVectorScaleX = 1.0;
	temporalDenoisedScaler.motionVectorScaleY = 1.0;
	temporalDenoisedScaler.outputTexture = _outputTexture;
	temporalDenoisedScaler.jitterOffsetX = _view.jitter.x;
	temporalDenoisedScaler.jitterOffsetY = _view.jitter.y;
	temporalDenoisedScaler.fence = fence;
	[temporalDenoisedScaler encodeToCommandBuffer:mtl3buffer];
	[mtl3buffer commit];
	[mtl3buffer waitUntilCompleted];
}

@end
