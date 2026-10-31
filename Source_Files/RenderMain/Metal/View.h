//
//  View.h
//  AlephOne
//
//  Created by Aanand Prasad on 31/10/2026.
//

#import <Foundation/Foundation.h>
#import <simd/simd.h>

#include "Shaders/ShaderTypes.h"

NS_ASSUME_NONNULL_BEGIN

@interface View : NSObject

@property (nonatomic, assign) float fov, pitch, yaw;
@property (nonatomic, assign) simd_int3 origin;
@property (nonatomic, assign) float weaponFlare;
@property (nonatomic, assign) float flashlight;
@property (nonatomic, assign) bool isInMedium;

@end

NS_ASSUME_NONNULL_END
