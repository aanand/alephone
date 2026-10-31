//
//  View.m
//  AlephOne
//
//  Created by Aanand Prasad on 31/10/2026.
//

#import "View.h"
#import "Metal/Utils.h"

simd_float4x4 rotationMatrix(float angle, simd_float3 axis) {
	simd_quatf quat = simd_quaternion(radians(angle), axis);
	return simd_matrix4x4(quat);
}

simd_float4x4 perspectiveProjection(float horizontalFOV, float width, float height) {
	float xs = 1.0 / tanf(radians(horizontalFOV) * 0.5);
	float ys = xs * width / height;
	float nz = 0.01;
	
	return simd_matrix((simd_float4){  xs, 0.0, 0.0, 0.0 },
					   (simd_float4){ 0.0,  ys, 0.0, 0.0 },
					   (simd_float4){ 0.0, 0.0, 1.0, 1.0 },
					   (simd_float4){ 0.0, 0.0, -nz, 0.0 });
}

@implementation View

- (Camera)camera {
	return (Camera){
		.fov = _fov,
		.origin = _origin,
		.pitchMat = rotationMatrix(_pitch, simd_make_float3(1.0, 0.0, 0.0)),
		.yawMat = rotationMatrix(-_yaw, simd_make_float3(0.0, 1.0, 0.0)),
		.rotateDirectionMat = simd_mul(rotationMatrix(_yaw, simd_make_float3(0.0, 1.0, 0.0)), rotationMatrix(-_pitch, simd_make_float3(1.0, 0.0, 0.0))),
		.perspectiveMat = perspectiveProjection(_fov, _viewportSize.x, _viewportSize.y),
		.jitter = _jitter,
	};
}

@end
