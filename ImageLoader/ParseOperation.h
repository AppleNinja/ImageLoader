//
//  ParseOperation.h
//  ImageLoader
//
//  Created by Sreekumar on 27/05/17.
//  Copyright © 2017 Sreekumar. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface ParseOperation : NSOperation

// A block to call when an error is encountered during parsing.
@property (nonatomic, copy) void (^errorHandler)(NSError *error);

@property (nonatomic, strong, readonly) NSArray *appRecordList;

// The initializer for this NSOperation subclass.
- (instancetype)initWithData:(NSData *)data;

@end
