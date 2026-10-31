//
//  GeometryManager.m
//  AlephOne
//
//  Created by Aanand Prasad on 31/10/2026.
//

#import "GeometryManager.h"

@implementation GeometryManager

-(void)startUpdatingAllGeometry {
	_staticTriangles = [NSMutableArray array];
	_dynamicTriangles = [NSMutableArray array];
}

-(void)finishUpdatingAllGeometry {}

-(void)startUpdatingDynamicGeometry {
	_dynamicTriangles = [NSMutableArray array];
}

-(void)finishUpdatingDynamicGeometry {}

-(void)shutdown {
	_staticTriangles = nil;
	_dynamicTriangles = nil;
}

@end
