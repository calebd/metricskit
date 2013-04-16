//
//  MetricsKit.m
//
//  Created by Caleb Davenport on 7/22/12.
//  Copyright (c) 2012 Caleb Davenport. All rights reserved.
//

#import "MetricsKit.h"
#import "MetricsKitSession.h"

static MetricsKitSession *__session = nil;

@implementation MetricsKit

#pragma mark - Public

+ (void)startWithAppKey:(NSString *)key host:(NSString *)host {
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        __session = [[MetricsKitSession alloc] initWithAppKey:key host:host];
    });
}


+ (void)logEvent:(NSString *)key {
    [__session addEvent:key segmentation:nil count:@1 sum:nil];
}


+ (void)logEvent:(NSString *)key count:(int)count {
    [__session addEvent:key segmentation:nil count:@(count) sum:nil];
}


+ (void)logEvent:(NSString *)key segmentation:(NSDictionary *)segmentation {
    [__session addEvent:key segmentation:segmentation count:@1 sum:nil];
}


+ (void)logEvent:(NSString *)key segmentation:(NSDictionary *)segmentation count:(int)count {
    [__session addEvent:key segmentation:segmentation count:@(count) sum:nil];
}


@end
