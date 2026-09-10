#pragma once

#import <Cocoa/Cocoa.h>

@class WKProcessPool;
@class WKWebView;
@class WKWebsiteDataStore;

typedef void (^AutomationPageEventHandler)(NSString *, NSDictionary *);

@interface AutomationPage : NSObject

@property (nonatomic, readonly) NSWindow *window;
@property (nonatomic, readonly) WKWebView *webView;

- (instancetype)initWithDataStore:(WKWebsiteDataStore *)dataStore processPool:(WKProcessPool *)processPool size:(NSSize)size headless:(BOOL)headless eventHandler:(AutomationPageEventHandler)eventHandler;
- (void)loadURLString:(NSString *)urlString;
- (void)close;
- (BOOL)handleJavaScriptDialogWithAccept:(BOOL)accept promptText:(NSString *)promptText;
- (NSString *)addDocumentScript:(NSString *)source;
- (BOOL)removeDocumentScript:(NSString *)identifier;

@end
