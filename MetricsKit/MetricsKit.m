//
//  MetricsKit.m
//
//  Created by Caleb Davenport on 7/22/12.
//  Copyright (c) 2012 Caleb Davenport. All rights reserved.
//

#import <TargetConditionals.h>
#import <sys/sysctl.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <CoreTelephony/CTCarrier.h>
#import <UIKit/UIKit.h>

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












+ (void)logEvent:(NSString *)key count:(int)count {
    [self logEvent:key segmentation:nil count:count];
}


+ (void)logEvent:(NSString *)key count:(int)count sum:(double)sum {
    [self logEvent:key segmentation:nil count:count sum:sum];
}


+ (void)logEvent:(NSString *)key segmentation:(NSDictionary *)segmentation count:(int)count {
    [__session logEvent:key segmentation:nil count:@(count) sum:nil];
}


+ (void)logEvent:(NSString *)key segmentation:(NSDictionary *)segmentation count:(int)count sum:(double)sum {
    [__session logEvent:key segmentation:nil count:@(count) sum:@(sum)];
}


@end

@implementation MetricsKitSession {
    NSString *_host;
    NSString *_appKey;
    NSTimer *_timer;
    UIBackgroundTaskIdentifier _task;
    SCNetworkReachabilityRef _reachability;
    NSMutableArray *_events;
}

#pragma mark - Instance methods




- (void)timerFired {
    [self
     logPayload:@{
         @"session_duration" : @"30"
     }
     withJSONAttachments:nil];
    [self logEvents];
}


- (void)startSession {
    [self
     logPayload:@{
         @"sdk_version" : MetricsKitVersion,
         @"begin_session" : @"1",
     }
     withJSONAttachments:@{
         @"metrics" : [MetricsKit deviceMetrics]
     }];
}


- (void)endSession {
    [self
     logPayload:@{
         @"end_session" : @"1"
     }
     withJSONAttachments:nil];
    [self logEvents];
}


#pragma mark - KVO

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context == &MetricsKitOperationCountContext) {
        NSUInteger old = [[change objectForKey:NSKeyValueChangeOldKey] unsignedIntegerValue];
        NSUInteger new = [[change objectForKey:NSKeyValueChangeNewKey] unsignedIntegerValue];
        dispatch_async(dispatch_get_main_queue(), ^{
            UIApplication *application = [UIApplication sharedApplication];
            void (^endTask) (void) = ^{
                UIBackgroundTaskIdentifier task = _task;
                [application endBackgroundTask:task];
                _task = UIBackgroundTaskInvalid;
            };
            if (old == 0 && new > 0 && _task == UIBackgroundTaskInvalid) {
                [application beginBackgroundTaskWithExpirationHandler:endTask];
            }
            else if (old > 0 && new == 0 && _task != UIBackgroundTaskInvalid) {
                endTask();
            }
        });
    }
}



#pragma mark - Handle events







- (void)logEvent:(NSString *)key segmentation:(NSDictionary *)segmentation count:(NSNumber *)count sum:(NSNumber *)sum {
    NSMutableDictionary *payload = [NSMutableDictionary dictionaryWithCapacity:3];
    [payload setObject:key forKey:@"key"];
    if (count) { [payload setObject:count forKey:@"count"]; }
    if (sum) { [payload setObject:sum forKey:@"sum"]; }
    if (segmentation) { [payload setObject:segmentation forKey:@"segmentation"]; }
    [_events addObject:payload];
}


- (void)logEvents {
    [self logPayload:nil withJSONAttachments:@{
         @"events" : _events
     }];
    [_events removeAllObjects];
}





@end

