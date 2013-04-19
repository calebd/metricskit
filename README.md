# MetricsKit

Clean Objective-C SDK for [Count.ly](http://count.ly).

- Built for the modern Objective-C runtime
- Aware of network reachability
- Simple public API
- Compiles with ARC
- Saves event payloads on disk until they are successfully posted
- Can be installed directly from source or as a static library

## Requirements

- ARC
- `CoreTelephony.framework`
- `SystemConfiguration.framework`
- `UIKit.framework`

## Application Launch

    [MetricsKit startWithAppKey:@"API_KEY" host:@"API_HOST"];

## Log an Event

    [MetricsKit logEvent:@"Event Name"];
