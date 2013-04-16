//
//  MetricsKit.h
//
//  Created by Caleb Davenport on 7/22/12.
//  Copyright (c) 2012 Caleb Davenport. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface MetricsKit : NSObject

/**
 
 Start a Countly session at the given host with the given app token.
 
 */
+ (void)startWithAppKey:(NSString *)key host:(NSString *)host;

/**
 
 Log events.
 
 */
+ (void)logEvent:(NSString *)key;
+ (void)logEvent:(NSString *)key count:(int)count;
+ (void)logEvent:(NSString *)key segmentation:(NSDictionary *)segmentation;
+ (void)logEvent:(NSString *)key segmentation:(NSDictionary *)segmentation count:(int)count;

@end
