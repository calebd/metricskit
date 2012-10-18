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

#import "MetricsKit.h"

#if DEBUG
#define MKLog(fmt, args...) NSLog(@"[MetricsKit] " fmt, ##args)
#else
#define MKLog(fmt, args...)
#endif

// constant strings
static NSString * const MetricsKitDeviceIdentifierFileName = @"device_identifier";
static NSString * const MetricsKitVersion = @"1.0";

// static variables
static NSString * MetricsKitURLHost = nil;
static NSString * MetricsKitAppToken = nil;
static int MetricsKitOperationCountContext = 0;

// reachability resources
enum {
    MetricsKitReachabilityStatusNotReachable = 0,
    MetricsKitReachabilityStatusReachableViaWiFi,
    MetricsKitReachabilityStatusReachableViaWWAN
};
typedef NSUInteger MetricsKitReachabilityStatus;
static SCNetworkReachabilityFlags _reachabilityFlags = 0;
void MetricsKitReachabilityDidChange(SCNetworkReachabilityRef reachability, SCNetworkReachabilityFlags flags, void *info);

#pragma mark - private interfaces

@interface NSString (MetricsKitAdditions)

- (NSString *)mk_percentEncodedString;

@end

@interface MetricsKitSession : NSObject

+ (MetricsKitSession *)sharedSession;

@end

@implementation MetricsKit

#pragma mark - class methods

+ (NSURL *)URLForDataDirectory {
    static NSURL *URL = nil;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        NSFileManager *manager = [NSFileManager defaultManager];
        NSURL *temporaryURL = [[manager
                                URLsForDirectory:NSApplicationSupportDirectory
                                inDomains:NSUserDomainMask]
                               objectAtIndex:0];
        temporaryURL = [temporaryURL URLByAppendingPathComponent:@"MetricsKit"];
        if ([manager
             createDirectoryAtURL:temporaryURL
             withIntermediateDirectories:YES
             attributes:nil
             error:nil]) {
            URL = temporaryURL;
        }
    });
    return URL;
}

+ (NSString *)deviceIdentifier {
    static NSString *identifier = nil;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        NSFileManager *manager = [NSFileManager defaultManager];
        NSURL *URL = [[self URLForDataDirectory] URLByAppendingPathComponent:MetricsKitDeviceIdentifierFileName];
        if ([manager fileExistsAtPath:[URL path]]) {
            identifier = [NSString stringWithContentsOfURL:URL encoding:NSUTF8StringEncoding error:nil];
        }
        else {
            CFUUIDRef UUIDRef = CFUUIDCreate(kCFAllocatorDefault);
            NSString *UUID = (__bridge NSString *)CFUUIDCreateString(kCFAllocatorDefault, UUIDRef);
            CFRelease(UUIDRef);
            [UUID writeToURL:URL atomically:YES encoding:NSUTF8StringEncoding error:nil];
            identifier = UUID;
        }
    });
    return identifier;
}

+ (NSString *)queryStringFromParameters:(NSDictionary *)parameters {
    NSMutableArray *array = [NSMutableArray arrayWithCapacity:[parameters count]];
    [parameters enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        NSString *entry = [NSString stringWithFormat:
                           @"%@=%@",
                           [key mk_percentEncodedString],
                           [obj mk_percentEncodedString]];
        [array addObject:entry];
    }];
    return [array componentsJoinedByString:@"&"];
}

+ (NSOperationQueue *)sharedOperationQueue {
    static NSOperationQueue *queue = nil;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        queue = [[NSOperationQueue alloc] init];
        [queue setName:@"com.guicocoa.MetricsKit.NetworkQueue"];
        [queue setMaxConcurrentOperationCount:1];
    });
    return queue;
}

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

+ (void)startWithAppKey:(NSString *)key host:(NSString *)host {
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        
        // save options
        MetricsKitURLHost = [host copy];
        MetricsKitAppToken = [key copy];
        NSAssert(MetricsKitURLHost, @"A MetricsKit host must be provided.");
        NSAssert(MetricsKitAppToken, @"A MetricsKit app token must be provided.");
        
        // get session
        [MetricsKitSession sharedSession];
        
        // reachability
        SCNetworkReachabilityRef reachability = NULL;
        if ((reachability = SCNetworkReachabilityCreateWithName(kCFAllocatorDefault, [MetricsKitURLHost UTF8String]))) {
            if (SCNetworkReachabilitySetCallback(reachability, MetricsKitReachabilityDidChange, NULL)) {
                SCNetworkReachabilityScheduleWithRunLoop(reachability, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
            }
        }
        
    });
}

#pragma mark - log data

+ (void)logEvent:(NSString *)key count:(int)count {
    [self logEvent:key segmentation:nil count:count];
}

+ (void)logEvent:(NSString *)key count:(int)count sum:(double)sum {
    [self logEvent:key segmentation:nil count:count sum:sum];
}

+ (void)logEvent:(NSString *)key segmentation:(NSDictionary *)segmentation count:(int)count {
    NSMutableDictionary *payload = [NSMutableDictionary dictionaryWithCapacity:3];
    [payload setObject:key forKey:@"key"];
    [payload setObject:@(count) forKey:@"count"];
    if (segmentation) { [payload setObject:segmentation forKey:@"segmentation"]; }
    [self logPayload:nil withJSONAttachments:@{
         @"events" : @[ payload ]
     }];
}

+ (void)logEvent:(NSString *)key segmentation:(NSDictionary *)segmentation count:(int)count sum:(double)sum {
    NSMutableDictionary *payload = [NSMutableDictionary dictionaryWithCapacity:3];
    [payload setObject:key forKey:@"key"];
    [payload setObject:@(count) forKey:@"count"];
    [payload setObject:@(sum) forKey:@"sum"];
    if (segmentation) { [payload setObject:segmentation forKey:@"segmentation"]; }
    [self logPayload:nil withJSONAttachments:@{
         @"events" : @[ payload ]
     }];
}

/*
 
 Save a new event payload to disk. The `payload` parameter will be turned into
 query parameters in the URL. It can be `nil`. `attachments` should be a
 dictionary with string keys and JSON-encodable objects.
 
 */
+ (void)logPayload:(NSDictionary *)payload withJSONAttachments:(NSDictionary *)attachments {
    
    // get timestamp
    time_t time = [[NSDate date] timeIntervalSince1970];
    NSString *timeString = [NSString stringWithFormat:@"%ld", time];
    
    // gather parameters
    NSMutableDictionary *parameters = ([payload mutableCopy] ?: [NSMutableDictionary dictionary]);
    [parameters setObject:timeString forKey:@"timestamp"];
    [attachments enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
        NSString *string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (data) { [parameters setObject:string forKey:key]; }
    }];
    
    // make sure we have something
    if ([parameters count] == 0) { return; }
    
    // get query string
    NSString *queryString = [self queryStringFromParameters:parameters];
    
    // write data to disk
    NSOperation *operation = [NSBlockOperation blockOperationWithBlock:^{
        NSString *uniqueString = [[NSProcessInfo processInfo] globallyUniqueString];
        NSURL *URL = [[self URLForDataDirectory] URLByAppendingPathComponent:uniqueString];
        [queryString writeToURL:URL atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [self uploadItemAtURL:URL];
    }];
    [operation setQueuePriority:NSOperationQueuePriorityHigh];
    [[self sharedOperationQueue] addOperation:operation];
    
}

#pragma mark - upload items

+ (void)uploadItemAtURL:(NSURL *)itemURL {
    [[self sharedOperationQueue] addOperationWithBlock:^{
        NSFileManager *manager = [NSFileManager defaultManager];
        if ([self isReachable] && [manager fileExistsAtPath:[itemURL path]]) {
            
            // get item
            NSString *item = [NSString stringWithContentsOfURL:itemURL encoding:NSUTF8StringEncoding error:nil];
            MKLog(@"Starting upload of item: %@", item);
            
            // build query parameters
            NSString *query = [NSString stringWithFormat:
                               @"app_key=%@&device_id=%@&%@",
                               MetricsKitAppToken,
                               [self deviceIdentifier],
                               item];
            
            // get the request url
            NSString *requestURLString = [NSString stringWithFormat:
                                          @"http://%@/i?%@",
                                          MetricsKitURLHost,
                                          query];
            NSURL *requestURL = [NSURL URLWithString:requestURLString];
            
            // run the request
            NSError *error = nil;
            NSHTTPURLResponse *response = nil;
            NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:requestURL];
            [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&error];
            
            // check status
            NSInteger status = [response statusCode];
            if (status == 200) {
                [[NSFileManager defaultManager] removeItemAtURL:itemURL error:nil];
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

+ (void)uploadAllItems {
    NSFileManager *manager = [NSFileManager defaultManager];
    NSURL *directoryURL = [self URLForDataDirectory];
    NSArray *array = [manager
                      contentsOfDirectoryAtURL:directoryURL
                      includingPropertiesForKeys:nil
                      options:NSDirectoryEnumerationSkipsHiddenFiles
                      error:nil];
    [array enumerateObjectsUsingBlock:^(NSURL *URL, NSUInteger idx, BOOL *stop) {
        if ([[URL lastPathComponent] isEqualToString:MetricsKitDeviceIdentifierFileName]) { return; }
        [self uploadItemAtURL:URL];
    }];
}

#pragma mark - reachability helpers

+ (void)setReachabilityFlags:(SCNetworkReachabilityFlags)flags {
    @synchronized(self) {
        _reachabilityFlags = flags;
    }
}

+ (MetricsKitReachabilityStatus)reachabilityStatus {
    
    // get flags
    SCNetworkReachabilityFlags flags = 0;
    @synchronized(self) {
        flags = _reachabilityFlags;
    }
    
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

+ (BOOL)isReachable {
    return ([self reachabilityStatus] != MetricsKitReachabilityStatusNotReachable);
}

@end

#pragma mark - category and private implementations

@implementation NSString (MetricsKitAdditions)

- (NSString *)mk_percentEncodedString {
    CFStringRef string = CFURLCreateStringByAddingPercentEscapes(NULL,
                                                                 (CFStringRef)self,
                                                                 NULL,
                                                                 CFSTR("!*'();:@&=+$,/?%#[]"),
                                                                 kCFStringEncodingUTF8);
    return (__bridge_transfer NSString *)string;
}

@end

@implementation MetricsKitSession {
    NSTimer *_timer;
    UIBackgroundTaskIdentifier _task;
}

+ (MetricsKitSession *)sharedSession {
    static MetricsKitSession *session = nil;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        session = [[MetricsKitSession alloc] init];
    });
    return session;
}

- (id)init {
    self = [super init];
    if (self) {
        
        // kvo
        [[MetricsKit sharedOperationQueue]
         addObserver:self
         forKeyPath:@"operationCount"
         options:(NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld)
         context:&MetricsKitOperationCountContext];
        
        // task
        _task = UIBackgroundTaskInvalid;
        
        // timer
        _timer = [NSTimer
                  scheduledTimerWithTimeInterval:30.0
                  target:self
                  selector:@selector(timerFired)
                  userInfo:nil
                  repeats:YES];
        
        // notifications
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center
         addObserver:self
         selector:@selector(endSession)
         name:UIApplicationDidEnterBackgroundNotification
         object:nil];
        [center
         addObserver:self
         selector:@selector(startSession)
         name:UIApplicationWillEnterForegroundNotification
         object:nil];
        
        // start
        [self startSession];
        
    }
    return self;
}

- (void)dealloc {
    
    // kvo
    [[MetricsKit sharedOperationQueue]
     removeObserver:self
     forKeyPath:@"operationCount"
     context:&MetricsKitOperationCountContext];
    
    // timer
    [_timer invalidate];
    _timer = nil;
    
    // notifications
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center
     removeObserver:self
     name:UIApplicationDidEnterBackgroundNotification
     object:nil];
    [center
     removeObserver:self
     name:UIApplicationWillEnterForegroundNotification
     object:nil];
    
}

- (void)timerFired {
    [MetricsKit
     logPayload:@{
         @"session_duration" : @"30"
     }
     withJSONAttachments:nil];
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
}

- (void)endSession {
    [MetricsKit
     logPayload:@{
         @"end_session" : @"1"
     }
     withJSONAttachments:nil];
}

- (void)startSession {
    [MetricsKit
     logPayload:@{
         @"sdk_version" : MetricsKitVersion,
         @"begin_session" : @"1",
     }
     withJSONAttachments:@{
         @"metrics" : [MetricsKit deviceMetrics]
     }];
}

@end

#pragma mark - reachability callback

void MetricsKitReachabilityDidChange(SCNetworkReachabilityRef reachability, SCNetworkReachabilityFlags flags, void *info) {
    [MetricsKit setReachabilityFlags:flags];
    [MetricsKit uploadAllItems];
}
