//
//  AppRecord.h
//  ImageLoader
//
//  Created by Sreekumar on 27/05/17.
//  Copyright © 2017 Sreekumar. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface AppRecord : NSObject

@property (nonatomic, strong) NSString *appName;
@property (nonatomic, strong) UIImage *appIcon;
@property (nonatomic, strong) NSString *artist;
@property (nonatomic, strong) NSString *imageURLString;
@property (nonatomic, strong) NSString *appURLString;

@end
