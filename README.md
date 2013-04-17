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

# License

Copyright (c) 2012-2013 Caleb Davenport.

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
