//
//  GeometryManager.h
//  AlephOne
//
//  Created by Aanand Prasad on 31/10/2026.
//

#import <Foundation/Foundation.h>

#import "MetalTypes.h"

NS_ASSUME_NONNULL_BEGIN

@interface GeometryManager : NSObject

@property (nonatomic) NSMutableArray<Triangle*> *staticTriangles;
@property (nonatomic) NSMutableArray<Triangle*> *dynamicTriangles;

- (void) startUpdatingAllGeometry;
- (void) finishUpdatingAllGeometry;
- (void) startUpdatingDynamicGeometry;
- (void) finishUpdatingDynamicGeometry;
- (void) shutdown;

@end

NS_ASSUME_NONNULL_END
