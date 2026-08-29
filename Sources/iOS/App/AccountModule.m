#import <React/RCTBridgeModule.h>

@interface RCT_EXTERN_MODULE(Account, NSObject)

RCT_EXTERN_METHOD(signIn:(NSString *)username
																		password:(NSString *)password
																		resolver:(RCTPromiseResolveBlock)resolve
																		rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(signUp:(NSString *)username
																		password:(NSString *)password
																		resolver:(RCTPromiseResolveBlock)resolve
																		rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(signOut:(RCTPromiseResolveBlock)resolve
																		rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(currentAccount:(RCTPromiseResolveBlock)resolve
																		rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(redeemActivationCode:(NSString *)code
																		resolver:(RCTPromiseResolveBlock)resolve
																		rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(deleteAccount:(RCTPromiseResolveBlock)resolve
																		rejecter:(RCTPromiseRejectBlock)reject)

@end
