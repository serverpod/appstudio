//
//  CefWrapper.h
//  Pods
//
//  Created by Hao Linwei on 2022/8/18.
//

#ifndef CefWrapper_h
#define CefWrapper_h
#import <FlutterMacOS/FlutterMacOS.h>

extern NSMapTable* webviewPlugins;

@interface CefWrapper : NSObject

@property(nonatomic) NSObject<FlutterTextureRegistry>* textureRegistry;
@property(nonatomic) FlutterMethodChannel* channel;

- (void)handleMethodCallWrapper: (FlutterMethodCall*)call result:(FlutterResult)result;

// Request one external BeginFrame for every live webview (drives the GPU
// frame-production clock). Called from the CVDisplayLink tick and, as a
// fallback, from the message-pump timer.
+ (void)beginFrameAllPlugins;
- (void)tickBeginFrame;

// Tear down the pump timer and the vblank clock. CefShutdown() is one-way and
// this class outlives it, so both have to stop the moment CEF is gone.
+ (void)stopDrivingCEF;

@end

#endif /* CefWrapper_h */
