# MetricsKit

Clean Objective-C SDK for [Count.ly](http://count.ly).

- Built for the modern Objective-C runtime
- Aware of network reachability
- Simple public API
- Compiles with ARC

## Application Launch

    [MetricsKit startWithAppKey:@"API_KEY" host:@"API_HOST"];

## Log an Event

    [MetricsKit logEvent:@"Event Name" count:1];