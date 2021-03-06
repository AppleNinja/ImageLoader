//
//  SKNetworkManager.m
//  ImageLoader
//
//  Created by Sreekumar on 27/05/17.
//  Copyright © 2017 Sreekumar. All rights reserved.
//

#import "SKNetworkManager.h"
#import <CommonCrypto/CommonHMAC.h>

static NSString *const kDownloadCachePathname = @"SKDownloadCache";
const char *const kETAGExtAttributeName  = "etag";
const char *const kLastModifiedExtAttributeName  = "lastmodified";
static const double kDownloadTimeout = 20.0;
static const double kETagValidationTimeout = 1.0;
static NSCache *kImageCache = nil;
static dispatch_queue_t kDownloadGCDQueue = nil;

@interface SKNetworkManager ()

@property (nonatomic, readonly) NSURLSession *urlSession;
@property (nonatomic, readonly) NSSet *runningURLRequests;

@end

@implementation SKNetworkManager
{
    NSURLSession *_urlSession;
    NSSet *_runningURLRequests;
}

static NSUInteger networkFetchingCount = 0;
static void SKBeginNetworkActivity()
{
    networkFetchingCount++;
    [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:YES];
}

static void SKEndNetworkActivity()
{
    if (networkFetchingCount > 0) {
        networkFetchingCount--;
        
        if (networkFetchingCount == 0) {
            [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:NO];
        }
    }
}

#pragma mark - Init & Dealloc

+ (instancetype)defaultManager
{
    static dispatch_once_t onceToken;
    static SKNetworkManager *shared = nil;
    dispatch_once(&onceToken, ^{
        shared = [[[self class] alloc] init];
    });
    
    return shared;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        if (!kImageCache) {
            kImageCache = [[NSCache alloc] init];
            [kImageCache setTotalCostLimit:1000];
        }
        if (!kDownloadGCDQueue) {
            kDownloadGCDQueue = dispatch_queue_create("com.sreekumar.download_gcd_queue", NULL);
        }
    }
    return self;
}

#pragma mark - Public methods

- (void)requestURL:(NSURL*)url
              type:(SKNetworkHTTPMethod)method
        completion:(void(^)(NSData *data,
                            NSString *localFilepath,
                            BOOL isFromCache,
                            NSError *error))completion
{
    NSMutableURLRequest *request = [[NSMutableURLRequest alloc]
                                    initWithURL:url
                                    cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                    timeoutInterval:kDownloadTimeout];
    switch (method) {
        case SKNetworkHTTPMethodGET:
            [request setHTTPMethod:@"GET"];
            break;
        case SKNetworkHTTPMethodPOST:
            [request setHTTPMethod:@"POST"];
            break;
        case SKNetworkHTTPMethodDELETE:
            [request setHTTPMethod:@"DELETE"];
            break;
        case SKNetworkHTTPMethodPUT:
            [request setHTTPMethod:@"PUT"];
            break;
        default:
            [request setHTTPMethod:@"GET"];
            break;
    }
    
    [self sendRequest:request completion:completion];
}

- (void)request:(NSURLRequest*)request
     completion:(void(^)(NSData *data,
                         NSError *error))completion
{
    [self sendRequest:request
           completion:^(NSData *data,
                        NSString *localFilepath,
                        BOOL isFromCache,
                        NSError *error) {
               completion(data,error);
           }];
}

- (UIImage*)imageAtURL:(NSURL*)url
            completion:(void(^)(UIImage *image,
                                NSString *localFilepath,
                                BOOL isFromCache,
                                NSError *error))completion
{
    if (!url) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, nil, YES, [self errorForNilURL]);
            });
        }
        
        return nil;
    }
    if ([url isKindOfClass:[NSURL class]] &&
        [[[self class] imageCache] objectForKey:url]) {
        // there is already an image in our cache so return this image
        // Download not necessary
        // we also call the completion block
        UIImage * image = [[[self class] imageCache] objectForKey:url];
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(image,nil,YES,nil);
            });
        }
        return image;
    }
    
    if ([self hasCachedFileForURL:url]) {
        dispatch_async(kDownloadGCDQueue, ^{
            NSString *filepath = [self cachedFilePathForURL:url];
            NSError *error = nil;
            NSData *data = [NSData dataWithContentsOfFile:filepath options:NSDataReadingMappedIfSafe error:&error];
            UIImage *image = [UIImage imageWithData:data];
            if (image) {
                [[[self class] imageCache] setObject:image forKey:url];
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) {
                    completion(image, filepath, YES, error);
                    [self isDownloadNecessaryForURL:url completion:^(BOOL needsDownload) {
                        if (needsDownload) {
                            [self requestImageAtURL:url completion:completion];
                        }
                    }];
                }
            });
        });
    } else {
        [self requestImageAtURL:url completion:completion];
    }
    
    return nil;
}

- (void)downloadURL:(NSURL*)url
         completion:(void(^)(NSData *data, NSString *localFilepath, BOOL isFromCache, NSError *error))completion
{
    if (!url) {
        if (completion) {
            completion(nil,nil,NO,[self errorForNilURL]);
        }
        ///  URL is nil
        ///  stop here
        return;
    }
    [self isDownloadNecessaryForURL:url
                         completion: ^(BOOL needsDownload) {
                             
                             if (!needsDownload) {
                                 //
                                 // we can grab the data from the cache
                                 // there is no newer version
                                 
                                 NSString *filepath = [self cachedFilePathForURL:url];
                                 NSError *error = nil;
                                 NSData *data = [NSData dataWithContentsOfFile:filepath options:NSDataReadingMappedIfSafe error:&error];
                                 
                                 if (completion) {
                                     dispatch_async(dispatch_get_main_queue(), ^{
                                         completion(data,filepath,YES,error);
                                     });
                                 }
                             } else {
                                 [self requestURL:url
                                             type:SKNetworkHTTPMethodGET
                                       completion:completion];
                             }
                         }];
}

- (void)cancelAllRequests
{
    [_urlSession invalidateAndCancel];
    _urlSession = nil;
    _runningURLRequests = nil;
}

- (void)cancelAllRequestForURL:(NSURL*)url
{
    [_urlSession getTasksWithCompletionHandler:^(NSArray *dataTasks, NSArray *uploadTasks, NSArray *downloadTasks) {
        
        NSInteger capacity = [dataTasks count] + [uploadTasks count] + [downloadTasks count];
        NSMutableArray *tasks = [NSMutableArray arrayWithCapacity:capacity];
        [tasks addObjectsFromArray:dataTasks];
        [tasks addObjectsFromArray:uploadTasks];
        [tasks addObjectsFromArray:downloadTasks];
        NSPredicate *predicate = [NSPredicate predicateWithFormat:@"originalRequest.URL = %@", url];
        [tasks filterUsingPredicate:predicate];
        for (NSURLSessionTask *task in tasks) {
            [task cancel];
        }
    }];
}

- (BOOL)reset
{
    [[[self class] imageCache] removeAllObjects];
    NSString *cachePath = [self localCachePath];
    NSFileManager *fileManager = [[NSFileManager alloc] init];
    NSError *error = nil;
    return [fileManager removeItemAtPath:cachePath error:&error];
}

#pragma mark - Getter

- (NSURLSession *)urlSession
{
    if (_urlSession) {
        return _urlSession;
    }
    
    _urlSession = [NSURLSession sessionWithConfiguration:
                   [NSURLSessionConfiguration defaultSessionConfiguration]];
    _urlSession.sessionDescription = @"net.tapwork.sknetworkmanager.nsurlsession";
    
    return _urlSession;
}

- (BOOL)isProcessingURL:(NSURL*)url
{
    return ([self.runningURLRequests containsObject:url]);
}

- (void)isDownloadNecessaryForURL:(NSURL*)url completion:(void(^)(BOOL needsDownload))completion
{
    NSString *cachedFile = [self cachedFilePathForURL:url];
    NSString *eTag = [self eTagAtCachedFilepath:cachedFile];
    NSString *lastModified = [self lastModifiedAtCachedFilepath:cachedFile];
    
    if (![self isNetworkReachable] &&
        [self hasCachedFileForURL:url]) {
        if (completion) {
            completion(NO);
        }
    } else if (![self hasCachedFileForURL:url] ||
               ![self isNetworkReachable] ||
               (!eTag && !lastModified)) {
        if (completion) {
            completion(YES);
        }
    } else {
        NSMutableURLRequest *request = [[NSMutableURLRequest alloc] initWithURL:url
                                                                    cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                                timeoutInterval:kETagValidationTimeout];
        if ([eTag length] > 0) {
            [request setValue:eTag forHTTPHeaderField:@"If-None-Match"];
        }
        if ([lastModified length] > 0) {
            [request setValue:lastModified forHTTPHeaderField:@"If-Modified-Since"];
        }
        [request setHTTPMethod:@"HEAD"];
        
        NSURLSession *session = self.urlSession;
        [[session dataTaskWithRequest:request
                    completionHandler:^(NSData *data,
                                        NSURLResponse *response,
                                        NSError *error) {
                        
                        if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
                            NSInteger statusCode = [(NSHTTPURLResponse*)response statusCode];
                            NSDictionary *header = [(NSHTTPURLResponse*)response allHeaderFields];
                            
                            if (statusCode == 304) {  // Not Modified - our cached stuff is fresh enough
                                completion(NO);
                            } else if (statusCode == 301) { // Moved Permanently HTTP Forward
                                NSURL *forwardURL = [NSURL URLWithString:header[@"Location"]];
                                [self isDownloadNecessaryForURL:forwardURL
                                                     completion:completion];
                            } else if (statusCode == 200) {
                                completion(YES);
                            } else {
                                completion(NO);
                            }
                        } else {
                            completion(NO);
                        }
                        
                    }] resume];
    }
}

- (BOOL)hasCachedFileForURL:(NSURL*)url
{
    NSFileManager *fileManager = [[NSFileManager alloc] init];
    return [fileManager fileExistsAtPath:[self cachedFilePathForURL:url]];
}

- (NSString *)cachedFilePathForURL:(NSURL*)url
{
    NSString *md5Filename = [self md5HashForString:[url absoluteString]];
    NSString *fullpath = [[self localCachePath] stringByAppendingPathComponent:md5Filename];
    
    return fullpath;
}

- (NSString *)localCachePath
{
    NSURL *libcache = [[[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask] lastObject];
    libcache = [libcache URLByAppendingPathComponent:kDownloadCachePathname];
    
    NSFileManager *filemanager = [[NSFileManager alloc] init];
    NSError *error = nil;
    BOOL isDir;
    if (![filemanager fileExistsAtPath:[libcache path] isDirectory:&isDir] ||
        !isDir) {
        [filemanager createDirectoryAtURL:libcache withIntermediateDirectories:YES attributes:nil error:&error];
    }
    
    return [libcache path];
}

- (BOOL)isNetworkReachable
{
    Reachability *reach = [Reachability reachabilityForInternetConnection];
    
    return ([reach currentReachabilityStatus] != NotReachable);
}

- (BOOL)isReachableViaWiFi
{
    Reachability *reach = [Reachability reachabilityForInternetConnection];
    
    return ([reach currentReachabilityStatus] == ReachableViaWiFi);
}

+ (NSCache*)imageCache
{
    return kImageCache;
}

- (NSError*)errorForNilURL
{
    return [NSError errorWithDomain:NSURLErrorDomain
                               code:-1
                           userInfo:@{NSLocalizedFailureReasonErrorKey : @"URL must not be nil"}];
}

#pragma mark - Private

- (void)requestImageAtURL:(NSURL*)url
               completion:(void(^)(UIImage *image,
                                   NSString *localFilepath,
                                   BOOL isFromCache,
                                   NSError *error))completion
{
    [self requestURL:url
                type:SKNetworkHTTPMethodGET
          completion:^(NSData *data, NSString *localFilepath, BOOL isFromCache, NSError *error) {
              dispatch_async(kDownloadGCDQueue, ^{
                  UIImage *image = nil;
                  if (url && data) {
                      image = [UIImage imageWithData:data];
                      if (image.size.width < 2 || image.size.height < 2) {
                          image = nil;
                      }
                      if (image) {
                          [[[self class] imageCache] setObject:image forKey:url];
                      }
                  }
                  dispatch_async(dispatch_get_main_queue(), ^{
                      if (completion) {
                          completion(image, localFilepath, isFromCache, error);
                      }
                  });
              });
          }];
}

- (void)sendRequest:(NSURLRequest*)request
         completion:(void(^)(NSData *data,
                             NSString *localFilepath,
                             BOOL isFromCache,
                             NSError *error))completion
{
    NSURL *url = [request URL];
    if (!url) {
        NSAssert(url, @"url must not be nil here");
        if (completion) {
            completion(nil, nil, NO, [self errorForNilURL]);
        }
        
        return;
    }
    
    [self addRequestedURL:url];
    
    SKBeginNetworkActivity();
    
    NSURLSession *session = self.urlSession;
    [[session dataTaskWithRequest:request
                completionHandler:^(NSData *data,
                                    NSURLResponse *response,
                                    NSError *connectionError) {
                    
                    SKEndNetworkActivity();
                    
                    NSError *resError = connectionError;
                    NSInteger statusCode = 0;
                    if ([response respondsToSelector:@selector(statusCode)]) {
                        statusCode = [(NSHTTPURLResponse*)response statusCode];
                    }
                    if (statusCode >= 400) {
                        NSMutableDictionary *errorUserInfo = [NSMutableDictionary dictionary];
                        errorUserInfo[@"HTTP statuscode"] = @(statusCode);
                        if (connectionError) {
                            errorUserInfo[@"underlying error"] = connectionError;
                        }
                        resError = [NSError errorWithDomain:NSURLErrorDomain
                                                       code:statusCode
                                                   userInfo:errorUserInfo];
                    }
                    
                    NSString *filepath = [self cachedFilePathForURL:url];
                    if (data) {
                        // for some strange reasons,NSDataWritingAtomic does not override in some cases
                        NSFileManager* filemanager = [[NSFileManager alloc] init];
                        [filemanager removeItemAtPath:filepath error:nil];
                        [data writeToFile:filepath options:NSDataWritingAtomic error:nil];
                        
                        NSError *readError = nil;
                        data = [NSData dataWithContentsOfFile:filepath options:NSDataReadingMappedIfSafe error:&readError];
                        
                        if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
                            NSDictionary *header = [(NSHTTPURLResponse*)response allHeaderFields];
                            NSString *etag = header[@"Etag"];
                            NSString *lastmodified = header[@"Last-Modified"];
                            if (etag) {
                                // store the eTag - we use it to check later if the content has been modified
                                [self setETag:etag forCachedFilepath:filepath];
                            } else if (lastmodified) {
                                [self setLastModified:lastmodified forCachedFilepath:filepath];
                            }
                        }
                    }
                    
                    dispatch_async(dispatch_get_main_queue(), ^{
                        
                        if (completion) {
                            completion(data,filepath,NO,resError);
                        }
                        [self removeRequestedURL:url];
                    });
                }] resume];
}

#pragma mark - Private Getter

- (void)addRequestedURL:(NSURL*)url
{
    @synchronized(self) {
        NSMutableSet *requests = [self.runningURLRequests mutableCopy];
        if (url) {
            [requests addObject:url];
            _runningURLRequests = requests;
        }
    }
}

- (void)removeRequestedURL:(NSURL*)url
{
    @synchronized(self ) {
        NSMutableSet *requests = [self.runningURLRequests mutableCopy];
        if (url && [requests containsObject:url]) {
            [requests removeObject:url];
            _runningURLRequests = requests;
        }
    }
}

- (NSString *)md5HashForString:(NSString *)string
{
    const char *cStr = [string UTF8String];
    unsigned char digest[16];
    CC_MD5( cStr, (CC_LONG)strlen(cStr), digest );
    
    NSMutableString *output = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) {
        [output appendFormat:@"%02x", digest[i]];
    }
    
    return  output;
}

- (NSSet *)runningURLRequests
{
    if (!_runningURLRequests) {
        _runningURLRequests = [[NSSet alloc] init];
    }
    return _runningURLRequests;
}

#pragma mark - Extended File Attributes (eTag & Last Modified)

- (BOOL)setETag:(NSString *)eTag forCachedFilepath:(NSString *)filepath
{
    return [self setExtendedFileAttribute:kETAGExtAttributeName withValue:eTag forCachedFilepath:filepath];
}

- (NSString *)eTagAtCachedFilepath:(NSString *)filepath
{
    return [self extendedFileAttribute:kETAGExtAttributeName cachedFilepath:filepath];
}

- (BOOL)setLastModified:(NSString *)lastModified forCachedFilepath:(NSString *)filepath
{
    return [self setExtendedFileAttribute:kLastModifiedExtAttributeName withValue:lastModified forCachedFilepath:filepath];
}

- (NSString *)lastModifiedAtCachedFilepath:(NSString *)filepath
{
    return [self extendedFileAttribute:kLastModifiedExtAttributeName cachedFilepath:filepath];
}

- (BOOL)setExtendedFileAttribute:(const char *)attribute withValue:(NSString *)value forCachedFilepath:(NSString *)filepath
{
    const char *cfilePath = [filepath fileSystemRepresentation];
    const char *cETag = [value UTF8String];
    
    if (0 != setxattr(cfilePath, attribute, cETag, strlen(cETag), 0, XATTR_NOFOLLOW)) {
        NSLog(@"could not create Extended File Attributes to file %@",filepath);
        return NO;
    }
    
    return YES;
}

- (NSString *)extendedFileAttribute:(const char *)attribute cachedFilepath:(NSString *)filepath
{
    const char *cfilePath = [filepath fileSystemRepresentation];
    NSString *etagString = nil;
    
    // get size of needed buffer
    ssize_t bufferLength = getxattr(cfilePath, attribute, NULL, 0, 0, 0);
    
    if (bufferLength > 0) {
        // make a buffer of sufficient length
        char *buffer = malloc(bufferLength);
        
        getxattr(cfilePath,
                 attribute,
                 buffer,
                 255,
                 0, 0);
        
        etagString = [[NSString alloc] initWithBytes:buffer length:bufferLength encoding:NSUTF8StringEncoding];
        
        // release buffer
        free(buffer);
    }
    
    return etagString;
}

@end


////////////////////////////////////////////////////////////////////////////////////////////////////////////////
//////////////////////////////////////////////////////////////////////////////////////////////////////////////
//          SKNetworkRequest Class
//////////////////////////////////////////////////////////////////////////////////////////////////////////////
//////////////////////////////////////////////////////////////////////////////////////////////////////////////
@implementation SKNetworkRequest
@end
