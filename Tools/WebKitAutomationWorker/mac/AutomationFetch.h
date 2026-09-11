#pragma once

#import <Foundation/Foundation.h>

@class _WKAutomationSession;
@class WKWebView;

typedef void (^AutomationFetchReply)(NSDictionary *, NSString *);

@interface AutomationFetch : NSObject
- (instancetype)initWithSession:(_WKAutomationSession *)session webView:(WKWebView *)webView eventHandler:(void (^)(NSString *, NSDictionary *))eventHandler;
@property (nonatomic, readonly) NSString *browsingContextHandle;
- (void)receiveMessage:(NSDictionary *)message;
- (void)receiveTransportResponse:(NSDictionary *)message;
- (void)handleCommand:(NSString *)method parameters:(NSDictionary *)parameters reply:(AutomationFetchReply)reply;
- (BOOL)handleAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler;
- (void)close;
@end
