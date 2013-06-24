//
//  MasterViewController.m
//  iOS UI Test
//
//  Created by Jonathan Willing on 4/8/13.
//  Copyright (c) 2013 AppJon. All rights reserved.
//

#import "MasterViewController.h"
#import <MailCore/MailCore.h>
#import "FXKeychain.h"
#import "MCTMsgViewController.h"

typedef void (^CompletionBlock)(NSString * body, NSError *error);

@interface MasterViewController () <MCOHTMLRendererIMAPDelegate>
{
    dispatch_queue_t   _bodyFetchqueue;
}
@property (nonatomic, strong) NSArray *messages;

@property (nonatomic, strong) MCOIMAPOperation *imapCheckOp;
@property (nonatomic, strong) MCOIMAPSession *imapSession;
@property (nonatomic, strong) MCOIMAPFetchMessagesOperation *imapMessagesFetchOp;

@property (nonatomic, strong) NSMutableDictionary *contentFetchOperations;

@end

@implementation MasterViewController

- (void)viewDidLoad {
	[super viewDidLoad];
	
	[[NSUserDefaults standardUserDefaults] registerDefaults:@{ HostnameKey: @"imap.gmail.com" }];
	
	NSString *username = [[NSUserDefaults standardUserDefaults] objectForKey:UsernameKey];
	NSString *password = [[FXKeychain defaultKeychain] objectForKey:PasswordKey];
	NSString *hostname = [[NSUserDefaults standardUserDefaults] objectForKey:HostnameKey];
	_contentFetchOperations = [[NSMutableDictionary alloc]init];
    _bodyFetchqueue = dispatch_queue_create("com.test.bodyqueue", 0);
	[self loadAccountWithUsername:username password:password hostname:hostname];
}

- (void)loadAccountWithUsername:(NSString *)username password:(NSString *)password hostname:(NSString *)hostname {
	if (!username.length || !password.length) {
		[self performSelector:@selector(showSettingsViewController:) withObject:nil afterDelay:0.5];
		return;
	}
	
	self.imapSession = [[MCOIMAPSession alloc] init];
	self.imapSession.hostname = hostname;
	self.imapSession.port = 993;
	self.imapSession.username = username;
	self.imapSession.password = password;
	self.imapSession.connectionType = MCOConnectionTypeTLS;
	
	NSLog(@"checking account");
	__weak MasterViewController *weakSelf = self;
	self.imapCheckOp = [self.imapSession checkAccountOperation];
	[self.imapCheckOp start:^(NSError *error) {
		MasterViewController *strongSelf = weakSelf;
		NSLog(@"finished checking account.");
		if (error == nil) {
			[strongSelf loadEmails];
		} else {
			NSLog(@"error loading account: %@", error);
		}
		
		strongSelf.imapCheckOp = nil;
	}];
}
- (void) bodyForMessage:(int ) uuid forFolder:(NSString *) folder onCompletion:(CompletionBlock) returnBlock
{
    
     MCOIMAPFetchContentOperation *fetchMessageBodyOperation = [self.imapSession fetchMessageByUIDOperationWithFolder:folder uid:uuid urgent:YES];
    
    [self.contentFetchOperations setObject:fetchMessageBodyOperation forKey:[NSNumber numberWithInt:uuid]];
    
    __weak MasterViewController *weakSelf = self;
    
    [fetchMessageBodyOperation start:^(NSError * error, NSData * messageData) {
        
        MasterViewController *strongSelf = weakSelf;
        
        if ( error == nil) {
            MCOMessageParser * parser = [MCOMessageParser messageParserWithData:messageData];
            
            NSString *htmlBody = [parser htmlRenderingWithDelegate:strongSelf];
            NSString *messageText = nil;
            if (htmlBody != nil && [htmlBody length] != 0) {
                
                messageText = [[htmlBody mco_flattenHTML]stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            }
            returnBlock(messageText,nil);
        } else {
            returnBlock(nil,error);
        }
    }];
    
}

/**
 * Strip off the div wrappers in the default parser
 *
 */
- (NSString *)MCOAbstractMessage_templateForMessage:(MCOAbstractMessage *)message {
    return @"{{BODY}}";
}


/**
 * We use the default html parser but don't want the header so just return an empty string
 *
 */
- (NSString *)MCOAbstractMessage:(MCOAbstractMessage *)msg templateForMainHeader:(MCOMessageHeader *)header {
    
    return @"";
}


- (void)loadEmails {
    
	MCOIMAPMessagesRequestKind requestKind = (MCOIMAPMessagesRequestKind)
	(MCOIMAPMessagesRequestKindHeaders | MCOIMAPMessagesRequestKindStructure |
	 MCOIMAPMessagesRequestKindInternalDate | MCOIMAPMessagesRequestKindHeaderSubject |
	 MCOIMAPMessagesRequestKindFlags);
	self.imapMessagesFetchOp = [self.imapSession fetchMessagesByUIDOperationWithFolder:@"INBOX"
																		   requestKind:requestKind
																				  uids:[MCOIndexSet indexSetWithRange:MCORangeMake(1, UINT64_MAX)]];
	[self.imapMessagesFetchOp setProgress:^(unsigned int progress) {
		//NSLog(@"progress: %u", progress);
	}];
	
	__weak MasterViewController *weakSelf = self;
	[self.imapMessagesFetchOp start:^(NSError *error, NSArray *messages, MCOIndexSet *vanishedMessages) {
		MasterViewController *strongSelf = weakSelf;
		NSLog(@"fetched all messages.");
		
		NSSortDescriptor *sort = [NSSortDescriptor sortDescriptorWithKey:@"header.date" ascending:NO];
		strongSelf.messages = [messages sortedArrayUsingDescriptors:@[sort]];
		[strongSelf.tableView reloadData];
         [strongSelf loadVisibleCells];
	}];
}

- (void)didReceiveMemoryWarning {
	[super didReceiveMemoryWarning];
	NSLog(@"%s",__PRETTY_FUNCTION__);
}

#pragma mark - Table View

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
	return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	return self.messages.count;
}

-(void) scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate
{
    [self loadVisibleCells];
    
}

-(void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView
{
    [self loadVisibleCells];
}
-(void) loadVisibleCells
{
    NSArray *visibleCells = [self.tableView visibleCells];
    __weak MasterViewController *weakSelf = self;
    [visibleCells enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        __weak UITableViewCell *cellRef = (UITableViewCell *) obj;
        MasterViewController *strongSelf = weakSelf;
         NSIndexPath *cellIndexPath = [strongSelf.tableView indexPathForCell:cellRef];
        MCOIMAPMessage *message = strongSelf.messages[cellIndexPath.row];
            
            dispatch_async(_bodyFetchqueue, ^{
                UITableViewCell *sCellRef = cellRef;
                [strongSelf bodyForMessage:message.uid forFolder:@"INBOX" onCompletion:^(NSString *body, NSError *error) {
                    dispatch_async(dispatch_get_main_queue(),^{
                        sCellRef.detailTextLabel.text = body;
                    });
                }];
            });
        //[weakSelf.contentFetchOperations removeObjectForKey:[NSNumber numberWithInt:message.uid]];
    }];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell" forIndexPath:indexPath];
	
	MCOIMAPMessage *message = self.messages[indexPath.row];
	cell.textLabel.text = message.header.subject;
    cell.detailTextLabel.text = @"Loading...";
	return cell;
}

- (void)showSettingsViewController:(id)sender {
	[self.imapMessagesFetchOp cancel];
	
	SettingsViewController *settingsViewController = [[SettingsViewController alloc] initWithNibName:nil bundle:nil];
	settingsViewController.delegate = self;
	[self presentViewController:settingsViewController animated:YES completion:nil];
}

- (void)settingsViewControllerFinished:(SettingsViewController *)viewController {
	[self dismissViewControllerAnimated:YES completion:nil];
	
	NSString *username = [[NSUserDefaults standardUserDefaults] stringForKey:UsernameKey];
	NSString *password = [[FXKeychain defaultKeychain] objectForKey:PasswordKey];
	NSString *hostname = [[NSUserDefaults standardUserDefaults] objectForKey:HostnameKey];
	
	if (![username isEqualToString:self.imapSession.username] ||
		![password isEqualToString:self.imapSession.password] ||
		![hostname isEqualToString:self.imapSession.hostname]) {
		self.imapSession = nil;
		[self loadAccountWithUsername:username password:password hostname:hostname];
	}
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	MCOIMAPMessage *msg = self.messages[indexPath.row];
	MCTMsgViewController *vc = [[MCTMsgViewController alloc] init];
	vc.folder = @"INBOX";
	vc.message = msg;
	vc.session = self.imapSession;
	[self.navigationController pushViewController:vc animated:YES];
}

@end
