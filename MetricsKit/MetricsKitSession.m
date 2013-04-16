//
//  MetricsKitSession.m
//  MetricsKit
//
//  Created by Caleb Davenport on 4/15/13.
//  Copyright (c) 2013 Caleb Davenport. All rights reserved.
//

#import <SystemConfiguration/SystemConfiguration.h>
#import <UIKit/UIKit.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <CoreTelephony/CTCarrier.h>
#import <sys/sysctl.h>

#import "MetricsKitSession.h"

#if DEBUG
    #define MKLog(fmt, args...) NSLog(@"[MetricsKit] " fmt, ##args)
#else
    #define MKLog(fmt, args...)
#endif

static int MetricsKitOperationCountContext = 0;
static NSString * const MetricsKitVersion = @"1.0";

typedef NS_ENUM(NSUInteger, MetricsKitReachabilityStatus) {
    MetricsKitReachabilityStatusNotReachable,
    MetricsKitReachabilityStatusReachableViaWiFi,
    MetricsKitReachabilityStatusReachableViaWWAN
};

@interface MetricsKitSession () {
    NSString *_host;
    NSString *_appKey;
    NSTimer *_timer;
    UIBackgroundTaskIdentifier _task;
    SCNetworkReachabilityRef _reachability;
    NSMutableArray *_events;
    NSOperationQueue *_queue;
}

@property (atomic, assign) SCNetworkReachabilityFlags reachabilityFlags;
@property (nonatomic, readonly) MetricsKitReachabilityStatus reachabilityStatus;
@property (nonatomic, readonly, getter = isReachable) BOOL reachable;

- (void)uploadAllItems;

@end

void MetricsKitReachabilityDidChange(SCNetworkReachabilityRef reachability, SCNetworkReachabilityFlags flags, void *info) {
    MetricsKitSession *session = (__bridge id)info;
    session.reachabilityFlags = flags;
    [session uploadAllItems];
}

@implementation MetricsKitSession

#pragma mark - Class methods

+ (NSDictionary *)deviceMetrics {
    static NSDictionary *metrics = nil;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
        [dictionary setObject:@"iOS" forKey:@"_os"];
        
        // device type
        {
            const char *type = "hw.machine";
            size_t length;
            sysctlbyname(type, NULL, &length, NULL, 0);
            char *machine = malloc(length);
            sysctlbyname(type, machine, &length, NULL, 0);
            NSString *platform = [NSString stringWithUTF8String:machine];
            [dictionary setObject:platform forKey:@"_device"];
            free(machine);
        }
        
        // app version
        {
            NSDictionary *infoDictionary = [[NSBundle mainBundle] infoDictionary];
            NSString *versionString = [infoDictionary objectForKey:@"CFBundleShortVersionString"];
            NSString *version = [infoDictionary objectForKey:@"CFBundleVersion"];
            if (versionString) { [dictionary setObject:versionString forKey:@"_app_version"]; }
            else { [dictionary setObject:version forKey:@"_app_version"]; }
        }
        
        // operating system version
        {
            NSString *version = [[UIDevice currentDevice] systemVersion];
            [dictionary setObject:version forKey:@"_os_version"];
        }
        
        // locale
        {
            NSString *locale = [[NSLocale currentLocale] localeIdentifier];
            [dictionary setObject:locale forKey:@"_locale"];
        }
        
        // carrier
        {
            CTTelephonyNetworkInfo *info = [[CTTelephonyNetworkInfo alloc] init];
            CTCarrier *carrier = info.subscriberCellularProvider;
            NSString *name = carrier.carrierName;
            if ([name length]) {
                [dictionary setObject:name forKey:@"_carrier"];
            }
        }
        
        // resolution
        {
            CGRect bounds = [[UIScreen mainScreen] bounds];
            NSString *resolution = [NSString stringWithFormat:@"%gx%g", bounds.size.width, bounds.size.height];
            [dictionary setObject:resolution forKey:@"_resolution"];
        }
        
        metrics = dictionary;
    });
    return metrics;
}


+ (NSString *)deviceIdentifier {
    static NSString *identifier = nil;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
        static NSString * const key = @"me.calebd.MetricsKit.DeviceIdentifier";
        identifier = [userDefaults objectForKey:key];
        if (identifier == nil) {
            NSString *identifier = [[NSProcessInfo processInfo] globallyUniqueString];
            [userDefaults setObject:identifier forKey:key];
        }
    });
    return identifier;
}


+ (NSURL *)URLForDataDirectory {
    static NSURL *URL = nil;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSURL *temporaryURL = [[fileManager
                                URLsForDirectory:NSApplicationSupportDirectory
                                inDomains:NSUserDomainMask]
                               objectAtIndex:0];
        temporaryURL = [temporaryURL URLByAppendingPathComponent:@"MetricsKit"];
        if ([fileManager
             createDirectoryAtURL:temporaryURL
             withIntermediateDirectories:YES
             attributes:nil
             error:nil]) {
            URL = temporaryURL;
        }
    });
    return URL;
}


+ (NSString *)percentEncodedStringWithString:(NSString *)string {
    CFStringRef encodedString = CFURLCreateStringByAddingPercentEscapes(NULL,
                                                                        (CFStringRef)string,
                                                                        NULL,
                                                                        CFSTR("!*'();:@&=+$,/?%#[]"),
                                                                        kCFStringEncodingUTF8);
    return (__bridge_transfer NSString *)encodedString;
}


+ (NSString *)queryStringWithParameters:(NSDictionary *)parameters {
    NSMutableArray *array = [NSMutableArray arrayWithCapacity:[parameters count]];
    [parameters enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        NSString *entry = [NSString stringWithFormat:
                           @"%@=%@",
                           [[self class] percentEncodedStringWithString:key],
                           [[self class] percentEncodedStringWithString:obj]];
        [array addObject:entry];
    }];
    return [array componentsJoinedByString:@"&"];
}


#pragma mark - NSObject

- (id)initWithAppKey:(NSString *)key host:(NSString *)host {
    NSParameterAssert(key != nil);
    NSParameterAssert(host != nil);
    if ((self = [super init])) {
        
        // save stuff
        _events = [NSMutableArray array];
        _appKey = [key copy];
        _host = [host copy];
        _task = UIBackgroundTaskInvalid;
        
        // operation queue
        _queue = [[NSOperationQueue alloc] init];
        [_queue setName:[NSString stringWithFormat:
                         @"me.calebd.MetricsKit.Session.%p",
                         self]];
        
        // notifications
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center
         addObserver:self
         selector:@selector(startSession)
         name:UIApplicationDidBecomeActiveNotification
         object:nil];
        [center
         addObserver:self
         selector:@selector(endSession)
         name:UIApplicationWillResignActiveNotification
         object:nil];
        
        // kvo
        [_queue
         addObserver:self
         forKeyPath:@"operationCount"
         options:(NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld)
         context:&MetricsKitOperationCountContext];
        
        // reachability
        if ((_reachability = SCNetworkReachabilityCreateWithName(NULL, [_host UTF8String]))) {
            SCNetworkReachabilityContext context = {0, (__bridge void *)self, NULL, NULL, NULL};
            if (SCNetworkReachabilitySetCallback(_reachability, MetricsKitReachabilityDidChange, &context)) {
                SCNetworkReachabilitySetDispatchQueue(_reachability, dispatch_get_main_queue());
            }
        }
        
    }
    return self;
}


- (void)dealloc {
    
    // notifications
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    // kvo
    [_queue
     removeObserver:self
     forKeyPath:@"operationCount"
     context:&MetricsKitOperationCountContext];
    
    // reachability
    if (_reachability) {
        SCNetworkReachabilitySetDispatchQueue(_reachability, NULL);
        SCNetworkReachabilitySetCallback(_reachability, NULL, NULL);
        CFRelease(_reachability);
    }
    
    // timer
    [_timer invalidate];
    
}


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
    else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}


#pragma mark - Public

- (void)addEvent:(NSString *)key segmentation:(NSDictionary *)segmentation count:(NSNumber *)count sum:(NSNumber *)sum {
    NSMutableDictionary *payload = [NSMutableDictionary dictionaryWithCapacity:3];
    payload[@"key"] = key;
    if (count) { payload[@"count"] = count; }
    if (sum) { payload[@"sum"] = sum; }
    if (segmentation) { payload[@"segmentation"] = segmentation; }
    [_events addObject:payload];
    if (_timer == nil) {
        [self persistAllEvents];
    }
}


#pragma mark - Private

- (void)persistAllEvents {
    [self logPayload:nil withJSONAttachments:@{ @"events" : [_events copy] }];
    [_events removeAllObjects];
}


- (void)timerFired {
    [self logPayload:@{ @"session_duration" : @"30" } withJSONAttachments:nil];
    [self persistAllEvents];
    [self uploadAllItems];
}


- (void)startSession {
    if (_timer) { return; }
    [self
     logPayload:@{
         @"sdk_version" : MetricsKitVersion,
         @"begin_session" : @"1",
     }
     withJSONAttachments:@{
         @"metrics" : [[self class] deviceMetrics]
     }];
    [self uploadAllItems];
    _timer = [NSTimer
              scheduledTimerWithTimeInterval:30.0
              target:self
              selector:@selector(timerFired)
              userInfo:nil
              repeats:YES];
}


- (void)endSession {
    if (_timer == nil) { return; }
    [self logPayload:@{ @"end_session" : @"1" } withJSONAttachments:nil];
    [self persistAllEvents];
    [_timer invalidate];
    _timer = nil;
}


- (void)logPayload:(NSDictionary *)payload withJSONAttachments:(NSDictionary *)attachments {
    
    // get timestamp
    time_t time = [[NSDate date] timeIntervalSince1970];
    NSString *timeString = [NSString stringWithFormat:@"%ld", time];
    
    // build payload and write to disk
    NSOperation *operation = [NSBlockOperation blockOperationWithBlock:^{
        
        // gather all parameters
        NSMutableDictionary *parameters = ([payload mutableCopy] ?: [NSMutableDictionary dictionary]);
        parameters[@"timestamp"] = timeString;
        parameters[@"app_key"] = _appKey;
        parameters[@"device_id"] = [[self class] deviceIdentifier];
        [attachments enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
            NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
            NSString *string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if (data) { parameters[key] = string; }
        }];
        
        // make sure we have something
        if ([parameters count] == 0) { return; }
        NSString *queryString = [[self class] queryStringWithParameters:parameters];
        
        // write to file
        NSString *fileName = [[NSProcessInfo processInfo] globallyUniqueString];
        NSURL *URL = [[[self class] URLForDataDirectory] URLByAppendingPathComponent:fileName];
        [queryString writeToURL:URL atomically:NO encoding:NSUTF8StringEncoding error:nil];
        [self uploadItemAtURL:URL];
        
    }];
    [operation setQueuePriority:NSOperationQueuePriorityHigh];
    [_queue addOperation:operation];
    
}


#pragma mark - - Post items

- (void)uploadItemAtURL:(NSURL *)itemURL {
    [_queue addOperationWithBlock:^{
        NSFileManager *manager = [NSFileManager defaultManager];
        if ([self isReachable] && [manager fileExistsAtPath:[itemURL path]]) {
            
            // get item
            NSString *item = [NSString
                              stringWithContentsOfURL:itemURL
                              encoding:NSUTF8StringEncoding
                              error:nil];
            MKLog(@"Starting upload of item: %@", [itemURL lastPathComponent]);
            
            // get the request url
            NSString *requestURLString = [NSString stringWithFormat:
                                          @"http://%@/i?%@",
                                          _host,
                                          item];
            NSURL *requestURL = [NSURL URLWithString:requestURLString];
            
            // run the request
            NSError *error = nil;
            NSHTTPURLResponse *response = nil;
            NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:requestURL];
            [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&error];
            
            // check status
            NSInteger status = [response statusCode];
            if (status == 200) {
                [manager removeItemAtURL:itemURL error:nil];
                MKLog(@"-- Upload finished.");
            }
            else {
                MKLog(@"-- Upload failed.\nError: %@\nResponse:%@\nStatus code:%ld",
                      error,
                      response,
                      (long)[response statusCode]);
            }
            
        }
    }];
}


- (void)uploadAllItems {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSURL *directoryURL = [[self class] URLForDataDirectory];
    NSArray *array = [fileManager
                      contentsOfDirectoryAtURL:directoryURL
                      includingPropertiesForKeys:nil
                      options:NSDirectoryEnumerationSkipsHiddenFiles
                      error:nil];
    [array enumerateObjectsUsingBlock:^(NSURL *URL, NSUInteger idx, BOOL *stop) {
        [self uploadItemAtURL:URL];
    }];
}


#pragma mark - - Reachability

- (MetricsKitReachabilityStatus)reachabilityStatus {
    
    // get flags
    SCNetworkReachabilityFlags flags = self.reachabilityFlags;
    
    // return appropriate status
    MetricsKitReachabilityStatus status = MetricsKitReachabilityStatusNotReachable;
    if ((flags & kSCNetworkReachabilityFlagsReachable) == 0) {
        return status;
    }
    if ((flags & kSCNetworkReachabilityFlagsConnectionRequired) == 0) {
        status = MetricsKitReachabilityStatusReachableViaWiFi;
    }
    if (((flags & kSCNetworkReachabilityFlagsConnectionOnDemand) != 0) ||
        ((flags & kSCNetworkReachabilityFlagsConnectionOnTraffic) != 0)) {
        if ((flags & kSCNetworkReachabilityFlagsInterventionRequired) == 0) {
            status = MetricsKitReachabilityStatusReachableViaWiFi;
        }
    }
    if ((flags & kSCNetworkReachabilityFlagsIsWWAN) != 0) {
        status = MetricsKitReachabilityStatusReachableViaWWAN;
    }
    return status;
    
}


- (BOOL)isReachable {
    return (self.reachabilityStatus != MetricsKitReachabilityStatusNotReachable);
}


@end

