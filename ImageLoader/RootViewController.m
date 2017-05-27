//
//  RootViewController.m
//  ImageLoader
//
//  Created by Sreekumar on 27/05/17.
//  Copyright © 2017 Sreekumar. All rights reserved.
//

#import "RootViewController.h"
#import "AppRecord.h"
#import "SKNetworkManager.h"
#import "AppConfig.h"
#import "ParseOperation.h"

#define kCustomRowCount 7

static NSString *CellIdentifier = @"LazyTableCell";
static NSString *PlaceholderCellIdentifier = @"PlaceholderCell";


#pragma mark -

@interface RootViewController () <UIScrollViewDelegate>

// the queue to run our "ParseOperation"
@property (nonatomic, strong) NSOperationQueue *queue;

// the NSOperation driving the parsing of the RSS feed
@property (nonatomic, strong) ParseOperation *parser;

@end


#pragma mark -

@implementation RootViewController

// -------------------------------------------------------------------------------
//	viewDidLoad
// -------------------------------------------------------------------------------
- (void)viewDidLoad
{
    [super viewDidLoad];
}

- (void)viewDidAppear:(BOOL)animated
{
    [self loadData];
}

// -------------------------------------------------------------------------------
//	dealloc
//  If this view controller is going away, we need to cancel all outstanding downloads.
// -------------------------------------------------------------------------------
- (void)dealloc
{
    // terminate all pending download connections
    [[SKNetworkManager defaultManager] cancelAllRequests];
}

// -------------------------------------------------------------------------------
//	didReceiveMemoryWarning
// -------------------------------------------------------------------------------
- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    
    // terminate all pending download connections
    [[SKNetworkManager defaultManager] cancelAllRequests];
}


#pragma mark - UITableViewDataSource

// -------------------------------------------------------------------------------
//	tableView:numberOfRowsInSection:
//  Customize the number of rows in the table view.
// -------------------------------------------------------------------------------
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    NSUInteger count = self.entries.count;
    
    // if there's no data yet, return enough rows to fill the screen
    if (count == 0)
    {
        return kCustomRowCount;
    }
    return count;
}

// -------------------------------------------------------------------------------
//	tableView:cellForRowAtIndexPath:
// -------------------------------------------------------------------------------
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = nil;
    
    NSUInteger nodeCount = self.entries.count;
    
    if (nodeCount == 0 && indexPath.row == 0)
    {
        // add a placeholder cell while waiting on table data
        cell = [tableView dequeueReusableCellWithIdentifier:PlaceholderCellIdentifier forIndexPath:indexPath];
    }
    else
    {
        cell = [tableView dequeueReusableCellWithIdentifier:CellIdentifier forIndexPath:indexPath];
        
        // Leave cells empty if there's no data yet
        if (nodeCount > 0)
        {
            // Set up the cell representing the app
            AppRecord *appRecord = (self.entries)[indexPath.row];
            
            cell.textLabel.text = appRecord.appName;
            cell.detailTextLabel.text = appRecord.artist;
            
            // Only load cached images; defer new downloads until scrolling ends
            if (!appRecord.appIcon)
            {
                if (self.tableView.dragging == NO && self.tableView.decelerating == NO)
                {
                    [self startIconDownload:appRecord forIndexPath:indexPath];
                }
                // if a download is deferred or in progress, return a placeholder image
                cell.imageView.image = [UIImage imageNamed:@"Placeholder.png"];
            }
            else
            {
                cell.imageView.image = appRecord.appIcon;
            }
        }
    }
    
    return cell;
}


#pragma mark - Table cell image support

// -------------------------------------------------------------------------------
//	startIconDownload:forIndexPath:
// -------------------------------------------------------------------------------
- (void)startIconDownload:(AppRecord *)appRecord forIndexPath:(NSIndexPath *)indexPath
{
    NSURL *url = [NSURL URLWithString:appRecord.imageURLString];
    [[SKNetworkManager defaultManager] imageAtURL:url
                                       completion:^(UIImage *image, NSString *localFilepath, BOOL isFromCache, NSError *error) {
         
         UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
         
         // Display the newly loaded image
         cell.imageView.image = image;
     }];
}

// -------------------------------------------------------------------------------
//	loadImagesForOnscreenRows
//  This method is used in case the user scrolled into a set of cells that don't
//  have their app icons yet.
// -------------------------------------------------------------------------------
- (void)loadImagesForOnscreenRows
{
    if (self.entries.count > 0)
    {
        NSArray *visiblePaths = [self.tableView indexPathsForVisibleRows];
        for (NSIndexPath *indexPath in visiblePaths)
        {
            AppRecord *appRecord = (self.entries)[indexPath.row];
            
            if (!appRecord.appIcon)
                // Avoid the app icon download if the app already has an icon
            {
                [self startIconDownload:appRecord forIndexPath:indexPath];
            }
        }
    }
}


#pragma mark - UIScrollViewDelegate

// -------------------------------------------------------------------------------
//	scrollViewDidEndDragging:willDecelerate:
//  Load images for all onscreen rows when scrolling is finished.
// -------------------------------------------------------------------------------
- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate
{
    if (!decelerate)
    {
        [self loadImagesForOnscreenRows];
    }
}

// -------------------------------------------------------------------------------
//	scrollViewDidEndDecelerating:scrollView
//  When scrolling stops, proceed to load the app icons that are on screen.
// -------------------------------------------------------------------------------
- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView
{
    [self loadImagesForOnscreenRows];
}

- (void) loadData
{
    NSURL *url = [NSURL URLWithString:TopPaidAppsFeed];
    
    [[SKNetworkManager defaultManager] requestURL:url
                                             type:SKNetworkHTTPMethodGET
                                       completion:^(NSData *data, NSString *localFilepath, BOOL isFromCache, NSError *error){
     
                                           if (error != nil)
                                           {
                                               [[NSOperationQueue mainQueue] addOperationWithBlock: ^{
                                                   [UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
     
                                                   if ([error code] == NSURLErrorAppTransportSecurityRequiresSecureConnection)
                                                   {
                                                       // if you get error NSURLErrorAppTransportSecurityRequiresSecureConnection (-1022),
                                                       // then your Info.plist has not been properly configured to match the target server.
                                                       //
                                                       abort();
                                                   }
                                                   else
                                                   {
                                                       [self handleError:error];
                                                   }
                                               }];
                                           }
                                           else
                                           {
                                               // create the queue to run our ParseOperation
                                               self.queue = [[NSOperationQueue alloc] init];
     
                                               // create an ParseOperation (NSOperation subclass) to parse the RSS feed data so that the UI is not blocked
                                               _parser = [[ParseOperation alloc] initWithData:data];
     
     
                                               __weak typeof(self) weakSelf = self;
                                               
                                               self.parser.errorHandler = ^(NSError *parseError) {
                                                   dispatch_async(dispatch_get_main_queue(), ^{
                                                       [UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
                                                       [weakSelf handleError:parseError];
                                                   });
                                               };
                                               
                                               // referencing parser from within its completionBlock would create a retain cycle
                                               __weak ParseOperation *weakParser = self.parser;
                                               
                                               self.parser.completionBlock = ^(void) {
                                                   [UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
                                                   if (weakParser.appRecordList != nil)
                                                   {
                                                       // The completion block may execute on any thread.  Because operations
                                                       // involving the UI are about to be performed, make sure they execute on the main thread.
                                                       //
                                                       dispatch_async(dispatch_get_main_queue(), ^{
                                                           // The root rootViewController is the only child of the navigation
                                                           // controller, which is the window's rootViewController.
                                                           //
     
                                                           
                                                           weakSelf.entries = weakParser.appRecordList;
                                                           
                                                           // tell our table view to reload its data, now that parsing has completed
                                                           [weakSelf.tableView reloadData];
                                                       });
                                                   }
                                                   
                                                   // we are finished with the queue and our ParseOperation
                                                   weakSelf.queue = nil;
                                               };
                                               
                                               [self.queue addOperation:self.parser]; // this will start the "ParseOperation"
                                           }
                                           
                                       }];
    
    // show in the status bar that network activity is starting
    [UIApplication sharedApplication].networkActivityIndicatorVisible = YES;
}

// -------------------------------------------------------------------------------
//	handleError:error
//  Reports any error with an alert which was received from connection or loading failures.
// -------------------------------------------------------------------------------
- (void)handleError:(NSError *)error
{
    NSString *errorMessage = [error localizedDescription];
    
    // alert user that our current record was deleted, and then we leave this view controller
    //
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Cannot Show Top Paid Apps"
                                                                   message:errorMessage
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    UIAlertAction *OKAction = [UIAlertAction actionWithTitle:@"OK"
                                                       style:UIAlertActionStyleDefault
                                                     handler:^(UIAlertAction *action) {
                                                         // dissmissal of alert completed
                                                     }];
    
    [alert addAction:OKAction];
    [self presentViewController:alert animated:YES completion:nil];
}



@end
