//
//  RayTracer.m
//  AlephOne
//
//  Created by Aanand Prasad on 01/11/2026.
//

#import "RayTracer.h"
#import "Common.h"

@implementation RayTracer
{
	id<MTLComputePipelineState> pipelineState;
	id<MTL4ArgumentTable> argumentTable;
	id<MTLIntersectionFunctionTable> intersectionFunctionTable;

	id<MTLArgumentEncoder> albedoTextureArgumentEncoder;
	id<MTLArgumentEncoder> normalMapArgumentEncoder;
	id<MTLArgumentEncoder> emissionMapArgumentEncoder;

	id<MTLBuffer> albedoTextureArgumentBuffer;
	id<MTLBuffer> normalMapArgumentBuffer;
	id<MTLBuffer> emissionMapArgumentBuffer;

	id<MTLBuffer> reservoirBufferA;
	id<MTLBuffer> reservoirBufferB;

	id<MTLBuffer> lightSourcesBuffer;
	NSUInteger lightSourceCount;
}

-(void)dealloc {
	if (_pipeline && _residencySet) {
		[_pipeline.commandQueue removeResidencySet:_residencySet];
	}
}

-(bool)compile {
	NSError *error;
	
	MTLResidencySetDescriptor *rsDesc = [MTLResidencySetDescriptor new];
	rsDesc.label = @"[RayTracer] residencySet";
	_residencySet = [_pipeline.device newResidencySetWithDescriptor:rsDesc error:&error];
	if (error) {
		NSLog(@"%@", error);
		return false;
	}
	[_pipeline.commandQueue addResidencySet:_residencySet];

	if (![self compilePipeline]) {
		return false;
	}
	
	NSAssert(_uniformsBuffer != nil, @"uniformsBuffer is not set");
	[_residencySet addAllocation:_uniformsBuffer];

	NSAssert(_geometryManager.perInstanceDataBuffer != nil, @"perInstanceDataBuffer is not set");
	NSAssert(_geometryManager.topLevelIAS != nil, @"topLevelIAS is not set");
	[_residencySet addAllocation:_geometryManager.perInstanceDataBuffer];
	[_residencySet addAllocation:_geometryManager.topLevelIAS];

	NSUInteger numPixels = _view.viewportSize.x * _view.viewportSize.y;
	reservoirBufferA = [_pipeline.device newBufferWithLength:sizeof(Reservoir) * numPixels options:MTLResourceStorageModeShared];
	reservoirBufferA.label = @"Reservoir buffer A";
	reservoirBufferB = [_pipeline.device newBufferWithLength:sizeof(Reservoir) * numPixels options:MTLResourceStorageModeShared];
	reservoirBufferB.label = @"Reservoir buffer B";
	[_residencySet addAllocation:reservoirBufferA];
	[_residencySet addAllocation:reservoirBufferB];
	Reservoir *aContents = (Reservoir*)reservoirBufferA.contents;
	Reservoir *bContents = (Reservoir*)reservoirBufferB.contents;
	for (NSUInteger i = 0; i < numPixels; i++) {
		aContents[i] = (Reservoir){};
		bContents[i] = (Reservoir){};
	}

	MTLTextureDescriptor *tDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:RayTracingPixelFormat
																						width:_view.viewportSize.x
																					   height:_view.viewportSize.y
																					mipmapped:NO];
	tDesc.storageMode = MTLStorageModePrivate;
	tDesc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
	_outputTexture = [_pipeline.device newTextureWithDescriptor:tDesc];
	_outputTexture.label = @"Ray-tracing output";
	[_residencySet addAllocation:_outputTexture];

	[_residencySet commit];
	
	return true;
}

- (bool) compilePipeline {
	NSError *error;
	id<MTLFunction> function = [_pipeline.defaultLibrary newFunctionWithName:@"reSTIR"];
	
	albedoTextureArgumentEncoder = [function newArgumentEncoderWithBufferIndex:RayTracingKernelAlbedoTexturesIndex];
	albedoTextureArgumentEncoder.label = @"[RayTracer] albedoTextureArgumentEncoder";
	albedoTextureArgumentBuffer = [_pipeline.device newBufferWithLength:albedoTextureArgumentEncoder.encodedLength
															   options:MTLResourceStorageModeShared];
	albedoTextureArgumentBuffer.label = @"[RayTracer] albedoTextureArgumentBuffer";
	[albedoTextureArgumentEncoder setArgumentBuffer:albedoTextureArgumentBuffer offset:0];
	[_residencySet addAllocation:albedoTextureArgumentBuffer];

	normalMapArgumentEncoder = [function newArgumentEncoderWithBufferIndex:RayTracingKernelNormalMapsIndex];
	normalMapArgumentEncoder.label = @"[RayTracer] normalMapArgumentEncoder";
	normalMapArgumentBuffer = [_pipeline.device newBufferWithLength:normalMapArgumentEncoder.encodedLength
														   options:MTLResourceStorageModeShared];
	normalMapArgumentBuffer.label = @"[RayTracer] normalMapArgumentBuffer";
	[normalMapArgumentEncoder setArgumentBuffer:normalMapArgumentBuffer offset:0];
	[_residencySet addAllocation:normalMapArgumentBuffer];

	emissionMapArgumentEncoder = [function newArgumentEncoderWithBufferIndex:RayTracingKernelEmissionMapsIndex];
	emissionMapArgumentEncoder.label = @"[RayTracer] emissionMapArgumentEncoder";
	emissionMapArgumentBuffer = [_pipeline.device newBufferWithLength:emissionMapArgumentEncoder.encodedLength
														   options:MTLResourceStorageModeShared];
	emissionMapArgumentBuffer.label = @"[RayTracer] emissionMapArgumentBuffer";
	[emissionMapArgumentEncoder setArgumentBuffer:emissionMapArgumentBuffer offset:0];
	[_residencySet addAllocation:emissionMapArgumentBuffer];

	MTLIntersectionFunctionDescriptor *intersectionFuncDesc = [MTLIntersectionFunctionDescriptor new];
	intersectionFuncDesc.name = @"alphaTestIntersection";
	
	id<MTLFunction> intersectionFunction = [_pipeline.defaultLibrary newIntersectionFunctionWithDescriptor:intersectionFuncDesc
																					error:&error];
	
	if (error) {
		NSLog(@"%@", error);
		return false;
	}
	
	MTLLinkedFunctions *linkedFunctions = [MTLLinkedFunctions new];
	linkedFunctions.functions = @[ intersectionFunction ];

	MTLComputePipelineDescriptor *pipelineDesc = [MTLComputePipelineDescriptor new];
	pipelineDesc.computeFunction = function;
	pipelineDesc.linkedFunctions = linkedFunctions;
	pipelineDesc.maxCallStackDepth = 4;
	
	pipelineState = [_pipeline.device newComputePipelineStateWithDescriptor:pipelineDesc
																	options:MTLPipelineOptionNone
																 reflection:nil
																	  error:&error];
	
	if (error) {
		NSLog(@"%@", error);
		return false;
	}

	MTL4ArgumentTableDescriptor *atDesc = [MTL4ArgumentTableDescriptor new];
	atDesc.maxBufferBindCount = RayTracingKernel_NumBuffers;
	atDesc.maxTextureBindCount = RayTracingKernel_NumTextures;
	atDesc.label = @"[RayTracer] argumentTable";
	argumentTable = [_pipeline.device newArgumentTableWithDescriptor:atDesc error:&error];
	
	if (error) {
		NSLog(@"%@", error);
		return false;
	}
	
	MTLIntersectionFunctionTableDescriptor *intersectionFuncTableDesc = [MTLIntersectionFunctionTableDescriptor intersectionFunctionTableDescriptor];
	intersectionFuncTableDesc.functionCount = 1;
	
	intersectionFunctionTable = [pipelineState newIntersectionFunctionTableWithDescriptor:intersectionFuncTableDesc];
	if (!intersectionFunctionTable) {
		NSLog(@"Failed to create intersection function table");
		return nil;
	}
	[_residencySet addAllocation:intersectionFunctionTable];

	id<MTLFunctionHandle> intersectionFunctionHandle = [pipelineState functionHandleWithFunction:intersectionFunction];
	if (!intersectionFunctionHandle) {
		NSLog(@"Failed to get function handle");
		return nil;
	}
	
	[intersectionFunctionTable setFunction:intersectionFunctionHandle atIndex:0];
	
	return true;
}

-(void)updateLightSourceCount:(NSUInteger)count {
	lightSourceCount = count;

	if (lightSourcesBuffer) {
		[_residencySet removeAllocation:lightSourcesBuffer];
	}
	
	lightSourcesBuffer = [_pipeline.device newBufferWithLength:sizeof(LightSource) * lightSourceCount
													   options:MTLResourceStorageModeShared];
	lightSourcesBuffer.label = @"lightSourcesBuffer";
	
	[_residencySet addAllocation:lightSourcesBuffer];
	[_residencySet commit];
}

- (void)updateLightSourceIntensities:(float *)intensities {
	LightSource *target = (LightSource*)lightSourcesBuffer.contents;
	
	for (NSUInteger i = 0; i < lightSourceCount; i++) {
		target[i].intensity = intensities[i];
	}
}

- (void) populateTextureArgumentBuffers {
	[albedoTextureArgumentEncoder setArgumentBuffer:albedoTextureArgumentBuffer offset:0];
	[normalMapArgumentEncoder setArgumentBuffer:normalMapArgumentBuffer offset:0];
	[emissionMapArgumentEncoder setArgumentBuffer:emissionMapArgumentBuffer offset:0];

	for (NSUInteger i = 0; i < _textureManager.textureIDs.count; i++) {
		NSString *textureID = _textureManager.textureIDs[i];
		id<MTLTexture> albedoTexture = _textureManager.albedoTextures[textureID];
		id<MTLTexture> normalMap = _textureManager.normalMaps[textureID];
		id<MTLTexture> emissionMap = _textureManager.emissionMaps[textureID];

		[albedoTextureArgumentEncoder setTexture:albedoTexture atIndex:i];
		[normalMapArgumentEncoder setTexture:normalMap atIndex:i];
		[emissionMapArgumentEncoder setTexture:emissionMap atIndex:i];

		[_residencySet addAllocation:albedoTexture];
		[_residencySet addAllocation:normalMap];
		[_residencySet addAllocation:emissionMap];
	}

	[_residencySet commit];
}

-(void) encode
{
	[self populateTextureArgumentBuffers];

	id<MTL4ComputeCommandEncoder> encoder = [_pipeline.commandBuffer computeCommandEncoder];
	if (!encoder) {
		NSLog(@"Failed to create compute command encoder");
		return;
	}
	encoder.label = @"Ray tracing";
	
	[encoder setComputePipelineState:pipelineState];
	[encoder waitForFence:_fenceToAwait beforeEncoderStages:MTLStageDispatch];

	[argumentTable setResource:_geometryManager.topLevelIAS.gpuResourceID atBufferIndex:RayTracingKernelAccelerationStructureIndex];
	
	[intersectionFunctionTable setBuffer:_geometryManager.perInstanceDataBuffer offset:0 atIndex:AlphaTestPerInstanceDataIndex];
	[intersectionFunctionTable setBuffer:albedoTextureArgumentBuffer offset:0 atIndex:AlphaTestAlbedoTexturesIndex];
	[argumentTable setResource:intersectionFunctionTable.gpuResourceID atBufferIndex:RayTracingKernelIntersectionFunctionTableIndex];

	[argumentTable setAddress:_uniformsBuffer.gpuAddress atIndex:RayTracingKernelUniformsIndex];
	[argumentTable setAddress:_geometryManager.perInstanceDataBuffer.gpuAddress atIndex:RayTracingKernelPerInstanceDataIndex];
	[argumentTable setAddress:albedoTextureArgumentBuffer.gpuAddress atIndex:RayTracingKernelAlbedoTexturesIndex];
	[argumentTable setAddress:normalMapArgumentBuffer.gpuAddress atIndex:RayTracingKernelNormalMapsIndex];
	[argumentTable setAddress:emissionMapArgumentBuffer.gpuAddress atIndex:RayTracingKernelEmissionMapsIndex];
	[argumentTable setAddress:lightSourcesBuffer.gpuAddress atIndex:RayTracingKernelLightSourcesIndex];

	if (_view.frameNumber % 2 == 0) {
		[argumentTable setAddress:reservoirBufferA.gpuAddress atIndex:RayTracingKernelPreviousReservoirIndex];
		[argumentTable setAddress:reservoirBufferB.gpuAddress atIndex:RayTracingKernelCurrentReservoirIndex];
	} else {
		[argumentTable setAddress:reservoirBufferB.gpuAddress atIndex:RayTracingKernelPreviousReservoirIndex];
		[argumentTable setAddress:reservoirBufferA.gpuAddress atIndex:RayTracingKernelCurrentReservoirIndex];
	}

	[argumentTable setTexture:_depthTexture.gpuResourceID atIndex:RayTracingKernelDepthTextureIndex];
	[argumentTable setTexture:_motionTexture.gpuResourceID atIndex:RayTracingKernelMotionTextureIndex];
	[argumentTable setTexture:_outputTexture.gpuResourceID atIndex:RayTracingKernelOutImageIndex];
	[encoder setArgumentTable:argumentTable];
	
	NSUInteger w = pipelineState.threadExecutionWidth;
	NSUInteger h = pipelineState.maxTotalThreadsPerThreadgroup / w;
	MTLSize threadsPerThreadgroup = MTLSizeMake( w, h, 1 );
	MTLSize threadsPerGrid = MTLSizeMake(_outputTexture.width, _outputTexture.height, 1);
	[encoder dispatchThreads:threadsPerGrid threadsPerThreadgroup:threadsPerThreadgroup];
	
	[encoder updateFence:_fenceToUpdate afterEncoderStages:MTLStageDispatch];
	[encoder endEncoding];
}

@end
