#import "WebviewCefPlugin.h"
#import "CefWrapper.h"

@implementation WebviewCefPlugin{
    CefWrapper *_cefWrapper;
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {

    FlutterMethodChannel* channel = [FlutterMethodChannel
                                     methodChannelWithName:@"webview_cef"
                                     binaryMessenger:[registrar messenger]];
    
    WebviewCefPlugin *instance = [[WebviewCefPlugin alloc] init];
    
    [registrar addMethodCallDelegate:instance channel:channel];
    instance->_cefWrapper = [[CefWrapper alloc] init];
    instance->_cefWrapper.channel = channel;
    instance->_cefWrapper.textureRegistry = registrar.textures;
    // Key on the Flutter view itself. Where it sits in the window differs
    // between engine versions, so the key router resolves the wrapper by
    // window rather than by an exact view identity (see wrapperForEvent:).
    if (registrar.view != nil) {
        [webviewPlugins setObject:instance->_cefWrapper forKey:registrar.view];
    }
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
    [self->_cefWrapper handleMethodCallWrapper:call result:result];
}
@end
