#import <React/RCTBridgeModule.h>

@interface RCT_EXTERN_MODULE(AppGroupDefaults, NSObject)

RCT_EXTERN_METHOD(snapshot:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

@end
