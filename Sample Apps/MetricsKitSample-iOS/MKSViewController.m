//
//  MKSViewController.m
//  MetricsKitSample
//
//  Created by Caleb Davenport on 7/22/12.
//  Copyright (c) 2012 Caleb Davenport. All rights reserved.
//

#import "MKSViewController.h"

#import "MetricsKit.h"

@implementation MKSViewController

- (IBAction)someButtonPress:(id)sender {
    [MetricsKit logEvent:@"Button Press" count:1];
}

@end
