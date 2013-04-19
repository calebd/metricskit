//
//  MetricsKitSession.h
//  MetricsKit
//
//  Created by Caleb Davenport on 4/15/13.
//  Copyright (c) 2013 Caleb Davenport. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface MetricsKitSession : NSObject

- (id)initWithAppKey:(NSString *)key host:(NSString *)host;

- (void)addEvent:(NSString *)key segmentation:(NSDictionary *)segmentation count:(NSNumber *)count sum:(NSNumber *)sum;

@end
