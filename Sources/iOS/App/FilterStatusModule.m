#import <React/RCTBridgeModule.h>

@interface RCT_EXTERN_MODULE(FilterStatus, NSObject)

RCT_EXTERN_METHOD(current:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

@end
