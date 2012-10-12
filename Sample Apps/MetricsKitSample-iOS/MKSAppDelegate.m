//
//  MKSAppDelegate.m
//  MetricsKitSample
//
//  Created by Caleb Davenport on 7/22/12.
//  Copyright (c) 2012 Caleb Davenport. All rights reserved.
//

#import "MKSAppDelegate.h"

#import "MetricsKit.h"

@implementation MKSAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    [MetricsKit startWithAppKey:@"" host:@""];
    return YES;
}



@end
