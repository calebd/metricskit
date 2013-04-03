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
static NSString * const MetricsKitVersion = @"1.0";

// static variables
static int MetricsKitOperationCountContext = 0;
static id __session = nil;

// reachability resources
enum {
    MetricsKitReachabilityStatusNotReachable = 0,
    MetricsKitReachabilityStatusReachableViaWiFi,
    MetricsKitReachabilityStatusReachableViaWWAN
};
typedef NSUInteger MetricsKitReachabilityStatus;
void MetricsKitReachabilityDidChange(SCNetworkReachabilityRef reachability, SCNetworkReachabilityFlags flags, void *info);

@interface NSString (MetricsKitAdditions)
- (NSString *)mk_percentEncodedString;
@end

@interface MetricsKitSession : NSObject
@property (atomic, assign) SCNetworkReachabilityFlags reachabilityFlags;
@property (nonatomic, readonly) MetricsKitReachabilityStatus reachabilityStatus;
@property (nonatomic, readonly, getter = isReachable) BOOL reachable;
- (id)initWithAppKey:(NSString *)key host:(NSString *)host;
- (void)logEvent:(NSString *)key segmentation:(NSDictionary *)segmentation count:(NSNumber *)count sum:(NSNumber *)sum;
- (void)uploadItemAtURL:(NSURL *)itemURL;
@end

@implementation MetricsKit

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
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        static NSString * const key = @"me.dvnprt.caleb.metricskit.device-identifier";
        identifier = [defaults objectForKey:key];
        if (identifier == nil) {
            CFUUIDRef UUIDRef = CFUUIDCreate(kCFAllocatorDefault);
            identifier = (__bridge_transfer NSString *)CFUUIDCreateString(kCFAllocatorDefault, UUIDRef);
            CFRelease(UUIDRef);
            [defaults setObject:identifier forKey:key];
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

- (id)initWithAppKey:(NSString *)key host:(NSString *)host {
    NSParameterAssert(key != nil);
    NSParameterAssert(host != nil);
    if ((self = [super init])) {
        
        // save stuff
        _events = [NSMutableArray array];
        _appKey = [key copy];
        _host = [host copy];
        _task = UIBackgroundTaskInvalid;
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
        
        // kvo
        [[MetricsKit sharedOperationQueue]
         addObserver:self
         forKeyPath:@"operationCount"
         options:(NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld)
         context:&MetricsKitOperationCountContext];
        
        // reachability
        if ((_reachability = SCNetworkReachabilityCreateWithName(kCFAllocatorDefault, [_host UTF8String]))) {
            if (SCNetworkReachabilitySetCallback(_reachability, MetricsKitReachabilityDidChange, (__bridge void *)self)) {
                SCNetworkReachabilityScheduleWithRunLoop(_reachability, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
            }
        }
        
        // start
        [self startSession];
        
    }
    return self;
}


- (void)dealloc {
    
    // notifications
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    // kvo
    [[MetricsKit sharedOperationQueue]
     removeObserver:self
     forKeyPath:@"operationCount"
     context:&MetricsKitOperationCountContext];
    
    // reachability
    SCNetworkReachabilityUnscheduleFromRunLoop(_reachability, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    SCNetworkReachabilitySetCallback(_reachability, NULL, (__bridge void *)self);
    CFRelease(_reachability);
    
    // timer
    [_timer invalidate];
    
}


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


#pragma mark - Reachability

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


#pragma mark - Handle events

- (void)uploadAllItems {
    NSFileManager *manager = [NSFileManager defaultManager];
    NSURL *directoryURL = [MetricsKit URLForDataDirectory];
    NSArray *array = [manager
                      contentsOfDirectoryAtURL:directoryURL
                      includingPropertiesForKeys:nil
                      options:NSDirectoryEnumerationSkipsHiddenFiles
                      error:nil];
    [array enumerateObjectsUsingBlock:^(NSURL *URL, NSUInteger idx, BOOL *stop) {
        [self uploadItemAtURL:URL];
    }];
}


- (void)uploadItemAtURL:(NSURL *)itemURL {
    [[MetricsKit sharedOperationQueue] addOperationWithBlock:^{
        NSFileManager *manager = [NSFileManager defaultManager];
        if (self.reachable && [manager fileExistsAtPath:[itemURL path]]) {
            
            // get item
            NSString *item = [NSString stringWithContentsOfURL:itemURL encoding:NSUTF8StringEncoding error:nil];
            MKLog(@"Starting upload of item: %@", item);
            
            // build query parameters
            NSString *query = [NSString stringWithFormat:
                               @"app_key=%@&device_id=%@&%@",
                               _appKey,
                               [MetricsKit deviceIdentifier],
                               item];
            
            // get the request url
            NSString *requestURLString = [NSString stringWithFormat:
                                          @"http://%@/i?%@",
                                          _host,
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


/*
 
 Save a new event payload to disk. The `payload` parameter will be turned into
 query parameters in the URL. It can be `nil`. `attachments` should be a
 dictionary with string keys and JSON-encodable objects.
 
 */
- (void)logPayload:(NSDictionary *)payload withJSONAttachments:(NSDictionary *)attachments {
    
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
    NSString *queryString = [MetricsKit queryStringFromParameters:parameters];
    
    // write data to disk
    NSOperation *operation = [NSBlockOperation blockOperationWithBlock:^{
        NSString *uniqueString = [[NSProcessInfo processInfo] globallyUniqueString];
        NSURL *URL = [[MetricsKit URLForDataDirectory] URLByAppendingPathComponent:uniqueString];
        [queryString writeToURL:URL atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [__session uploadItemAtURL:URL];
    }];
    [operation setQueuePriority:NSOperationQueuePriorityHigh];
    [[MetricsKit sharedOperationQueue] addOperation:operation];
    
}


@end

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

#pragma mark - Reachability callback

void MetricsKitReachabilityDidChange(SCNetworkReachabilityRef reachability, SCNetworkReachabilityFlags flags, void *info) {
    MetricsKitSession *session = (__bridge id)info;
    session.reachabilityFlags = flags;
    [session uploadAllItems];
}
