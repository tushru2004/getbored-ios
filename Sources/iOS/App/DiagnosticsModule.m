#import <React/RCTBridgeModule.h>

@interface RCT_EXTERN_MODULE(Diagnostics, NSObject)

RCT_EXTERN_METHOD(reportRecentLogs:(NSString *)reason
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

@end
