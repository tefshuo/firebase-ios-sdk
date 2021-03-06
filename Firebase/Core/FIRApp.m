// Copyright 2017 Google
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include <sys/utsname.h>

#import "FIRApp.h"
#import "Private/FIRAppInternal.h"
#import "Private/FIRBundleUtil.h"
#import "FIRConfiguration.h"
#import "Private/FIRLogger.h"
#import "Private/FIROptionsInternal.h"

NSString *const kFIRServiceAdMob = @"AdMob";
NSString *const kFIRServiceAuth = @"Auth";
NSString *const kFIRServiceAuthUI = @"AuthUI";
NSString *const kFIRServiceCrash = @"Crash";
NSString *const kFIRServiceDatabase = @"Database";
NSString *const kFIRServiceDynamicLinks = @"DynamicLinks";
NSString *const kFIRServiceInstanceID = @"InstanceID";
NSString *const kFIRServiceInvites = @"Invites";
NSString *const kFIRServiceMessaging = @"Messaging";
NSString *const kFIRServiceMeasurement = @"Measurement";
NSString *const kFIRServiceRemoteConfig = @"RemoteConfig";
NSString *const kFIRServiceStorage = @"Storage";
NSString *const kGGLServiceAnalytics = @"Analytics";
NSString *const kGGLServiceSignIn = @"SignIn";

NSString *const kFIRDefaultAppName = @"__FIRAPP_DEFAULT";
NSString *const kFIRAppReadyToConfigureSDKNotification = @"FIRAppReadyToConfigureSDKNotification";
NSString *const kFIRAppDeleteNotification = @"FIRAppDeleteNotification";
NSString *const kFIRAppIsDefaultAppKey = @"FIRAppIsDefaultAppKey";
NSString *const kFIRAppNameKey = @"FIRAppNameKey";
NSString *const kFIRGoogleAppIDKey = @"FIRGoogleAppIDKey";

NSString *const kFIRAppDiagnosticsNotification = @"FIRAppDiagnosticsNotification";

NSString *const kFIRAppDiagnosticsConfigurationTypeKey = @"ConfigType";
NSString *const kFIRAppDiagnosticsErrorKey = @"Error";
NSString *const kFIRAppDiagnosticsFIRAppKey = @"FIRApp";
NSString *const kFIRAppDiagnosticsSDKNameKey = @"SDKName";
NSString *const kFIRAppDiagnosticsSDKVersionKey = @"SDKVersion";

/**
 * The URL to download plist files.
 */
static NSString *const kPlistURL = @"https://console.firebase.google.com/";

@interface FIRApp ()

@property(nonatomic) BOOL alreadySentConfigureNotification;

@property(nonatomic) BOOL alreadySentDeleteNotification;

@end

@implementation FIRApp

// This is necessary since our custom getter prevents `_options` from being created.
@synthesize options = _options;

static NSMutableDictionary *sAllApps;
static FIRApp *sDefaultApp;

+ (void)configure {
  FIROptions *options = [FIROptions defaultOptions];
  if (!options) {
    [[NSNotificationCenter defaultCenter]
        postNotificationName:kFIRAppDiagnosticsNotification
                      object:nil
                    userInfo:@{
                      kFIRAppDiagnosticsConfigurationTypeKey : @(FIRConfigTypeCore),
                      kFIRAppDiagnosticsErrorKey : [FIRApp errorForMissingOptions]
                    }];
    [NSException raise:kFirebaseCoreErrorDomain
                format:@"`[FIRApp configure];` (`FirebaseApp.configure()` in Swift) could not find "
                       @"a valid GoogleService-Info.plist in your project. Please download one "
                       @"from %@.",
                       kPlistURL];
  }
  [FIRApp configureDefaultAppWithOptions:options sendingNotifications:YES];
}

+ (void)configureWithOptions:(FIROptions *)options {
  if (!options) {
    [NSException raise:kFirebaseCoreErrorDomain
                format:@"Options is nil. Please pass a valid options."];
  }
  [FIRApp configureDefaultAppWithOptions:options sendingNotifications:YES];
}

+ (void)configureWithoutSendingNotification {
  FIROptions *options = [FIROptions defaultOptions];
  if (!options) {
    [[NSNotificationCenter defaultCenter]
        postNotificationName:kFIRAppDiagnosticsNotification
                      object:nil
                    userInfo:@{
                      kFIRAppDiagnosticsConfigurationTypeKey : @(FIRConfigTypeCore),
                      kFIRAppDiagnosticsErrorKey : [FIRApp errorForMissingOptions]
                    }];
    [NSException raise:kFirebaseCoreErrorDomain format:@"Please check there is a valid "
                                                       @"GoogleService-Info.plist in the project."];
  }
  [FIRApp configureDefaultAppWithOptions:options sendingNotifications:NO];
}

+ (void)configureDefaultAppWithOptions:(FIROptions *)options
                  sendingNotifications:(BOOL)sendNotifications {
  if (sDefaultApp) {
    // FIRApp sets up FirebaseAnalytics and does plist validation, but does not cause it
    // to fire notifications. So, if the default app already exists, but has not sent out
    // configuration notifications, then continue re-initializing it.
    if (!sendNotifications || sDefaultApp.alreadySentConfigureNotification) {
      [NSException raise:kFirebaseCoreErrorDomain
                  format:@"Default app has already been configured."];
    }
  }
  @synchronized(self) {
    FIRLogDebug(kFIRLoggerCore, @"I-COR000001", @"Configuring the default app.");
    sDefaultApp = [[FIRApp alloc] initInstanceWithName:kFIRDefaultAppName options:options];
    [FIRApp addAppToAppDictionary:sDefaultApp];
    if (!sDefaultApp.alreadySentConfigureNotification && sendNotifications) {
      [FIRApp sendNotificationsToSDKs:sDefaultApp];
      sDefaultApp.alreadySentConfigureNotification = YES;
    }
  }
}

+ (void)configureWithName:(NSString *)name options:(FIROptions *)options {
  if (!name || !options) {
    [NSException raise:kFirebaseCoreErrorDomain format:@"Neither name nor options can be nil."];
  }
  if (name.length == 0) {
    [NSException raise:kFirebaseCoreErrorDomain format:@"Name cannot be empty."];
  }
  if ([name isEqualToString:kFIRDefaultAppName]) {
    [NSException raise:kFirebaseCoreErrorDomain format:@"Name cannot be __FIRAPP_DEFAULT."];
  }
  NSString *lowerCaseName = [name lowercaseString];
  for (NSInteger charIndex = 0; charIndex < lowerCaseName.length; charIndex++) {
    char character = [lowerCaseName characterAtIndex:charIndex];
     if (!((character >= 'a' && character <= 'z')
           || (character >= '0' && character <= '9')
           || character == '_'
           || character == '-'))  {
       [NSException raise:kFirebaseCoreErrorDomain format:@"App name should only contain Letters, "
                                                      @"Numbers, Underscores, and Dashes."];
     }
  }

  if (sAllApps && sAllApps[name]) {
    [NSException raise:kFirebaseCoreErrorDomain
                format:@"App named %@ has already been configured.", name];
  }

  @synchronized(self) {
    FIRLogDebug(kFIRLoggerCore, @"I-COR000002", @"Configuring app named %@", name);
    FIRApp *app = [[FIRApp alloc] initInstanceWithName:name options:options];
    [FIRApp addAppToAppDictionary:app];
    if (!app.alreadySentConfigureNotification) {
      [FIRApp sendNotificationsToSDKs:app];
      app.alreadySentConfigureNotification = YES;
    }
  }
}

+ (FIRApp *)defaultApp {
  if (sDefaultApp) {
    return sDefaultApp;
  }
  FIRLogError(kFIRLoggerCore, @"I-COR000003", @"The default Firebase app has not yet been "
              @"configured. Add `[FIRApp configure];` (`FirebaseApp.configure()` in Swift) to your "
              @"application initialization. Read more: https://goo.gl/ctyzm8.");
  return nil;
}

+ (FIRApp *)appNamed:(NSString *)name {
  @synchronized(self) {
    if (sAllApps) {
      FIRApp *app = sAllApps[name];
      if (app) {
        return app;
      }
    }
    FIRLogError(kFIRLoggerCore, @"I-COR000004", @"App with name %@ does not exist.", name);
    return nil;
  }
}

+ (NSDictionary *)allApps {
  @synchronized(self) {
    if (!sAllApps) {
      FIRLogError(kFIRLoggerCore, @"I-COR000005", @"No app has been configured yet.");
    }
    NSDictionary *dict = [NSDictionary dictionaryWithDictionary:sAllApps];
    return dict;
  }
}

// Public only for tests
+ (void)resetApps {
  sDefaultApp = nil;
  [sAllApps removeAllObjects];
  sAllApps = nil;
}

- (void)deleteApp:(FIRAppVoidBoolCallback)completion {
  @synchronized([self class]) {
    if (sAllApps && sAllApps[self.name]) {
      FIRLogDebug(kFIRLoggerCore, @"I-COR000006", @"Deleting app named %@", self.name);
      [sAllApps removeObjectForKey:self.name];
      if ([self.name isEqualToString:kFIRDefaultAppName]) {
        sDefaultApp = nil;
      }
      if (!self.alreadySentDeleteNotification) {
        NSDictionary *appInfoDict = @ {
          kFIRAppNameKey : self.name
        };
        [[NSNotificationCenter defaultCenter] postNotificationName:kFIRAppDeleteNotification
                                                            object:[self class]
                                                          userInfo:appInfoDict];
        self.alreadySentDeleteNotification = YES;
      }
      completion(YES);
    } else {
      FIRLogError(kFIRLoggerCore, @"I-COR000007", @"App does not exist.");
      completion(NO);
    }
  }
}

+ (void)addAppToAppDictionary:(FIRApp *)app {
  if (!sAllApps) {
    sAllApps = [NSMutableDictionary dictionary];
  }
  if ([app configureCore]) {
    sAllApps[app.name] = app;
    [[NSNotificationCenter defaultCenter]
        postNotificationName:kFIRAppDiagnosticsNotification
                      object:nil
                    userInfo:@{
                      kFIRAppDiagnosticsConfigurationTypeKey : @(FIRConfigTypeCore),
                      kFIRAppDiagnosticsFIRAppKey : app
                    }];
  } else {
    [NSException raise:kFirebaseCoreErrorDomain
                format:@"Configuration fails. It may be caused by an invalid GOOGLE_APP_ID in "
                       @"GoogleService-Info.plist or set in the customized options."];
  }
}

- (instancetype)initInstanceWithName:(NSString *)name options:(FIROptions *)options {
  self = [super init];
  if (self) {
    _name = [name copy];
    _options = [options copy];
    _options.editingLocked = YES;

    FIRApp *app = sAllApps[name];
    _alreadySentConfigureNotification = app.alreadySentConfigureNotification;
    _alreadySentDeleteNotification = app.alreadySentDeleteNotification;
  }
  return self;
}

- (void)getTokenForcingRefresh:(BOOL)forceRefresh withCallback:(FIRTokenCallback)callback {
  if (!_getTokenImplementation) {
    callback(nil, nil);
    return;
  }

  _getTokenImplementation(forceRefresh, callback);
}

- (BOOL)configureCore {
  [self checkExpectedBundleID];
  if (![self isAppIDValid]) {
    if (_options.usingOptionsFromDefaultPlist) {
      [[NSNotificationCenter defaultCenter]
          postNotificationName:kFIRAppDiagnosticsNotification
                        object:nil
                      userInfo:@{
                        kFIRAppDiagnosticsConfigurationTypeKey : @(FIRConfigTypeCore),
                        kFIRAppDiagnosticsErrorKey : [FIRApp errorForInvalidAppID],
                      }];
    }
    return NO;
  }

  if (NSClassFromString(@"FIRAppIndexing") != nil) {
    FIRLogDebug(kFIRLoggerCore, @"I-COR000024", @"Firebase App Indexing on iOS is deprecated. "
                @"You don't need to take any action at this time. Learn more about Firebase App "
                @"Indexing at https://firebase.google.com/docs/app-indexing/.");
  }

  // Initialize the Analytics once there is a valid options under default app. Analytics should
  // always initialize first by itself before the other SDKs.
  if ([self.name isEqualToString:kFIRDefaultAppName]) {
    Class firAnalyticsClass = NSClassFromString(@"FIRAnalytics");
    if (!firAnalyticsClass) {
      FIRLogError(kFIRLoggerCore, @"I-COR000022", @"Firebase Analytics is not available.");
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"
      SEL startWithConfigurationSelector = @selector(startWithConfiguration:options:);
#pragma clang diagnostic pop
      if ([firAnalyticsClass respondsToSelector:startWithConfigurationSelector]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [firAnalyticsClass performSelector:startWithConfigurationSelector
                                withObject:[FIRConfiguration sharedInstance].analyticsConfiguration
                                withObject:_options];
#pragma clang diagnostic pop
      }
    }
  }
  return YES;
}

- (FIROptions *)options {
  return [_options copy];
}

#pragma mark - private

+ (void)sendNotificationsToSDKs:(FIRApp *)app {
  NSNumber *isDefaultApp = [NSNumber numberWithBool:(app == sDefaultApp)];
  NSDictionary *appInfoDict = @ {
    kFIRAppNameKey : app.name,
    kFIRAppIsDefaultAppKey : isDefaultApp,
    kFIRGoogleAppIDKey : app.options.googleAppID
  };
  [[NSNotificationCenter defaultCenter] postNotificationName:kFIRAppReadyToConfigureSDKNotification
                                                      object:self
                                                    userInfo:appInfoDict];
}

+ (NSError *)errorForMissingOptions {
  NSDictionary *errorDict = @{
    NSLocalizedDescriptionKey :
        @"Unable to parse GoogleService-Info.plist in order to configure services.",
    NSLocalizedRecoverySuggestionErrorKey :
        @"Check formatting and location of GoogleService-Info.plist."
  };
  return FIRCreateError(kFirebaseCoreErrorDomain, FIRErrorCodeInvalidPlistFile, errorDict);
}

+ (NSError *)errorForSubspecConfigurationFailureWithDomain:(NSString *)domain
                                                 errorCode:(FIRErrorCode)code
                                                   service:(NSString *)service
                                                    reason:(NSString *)reason {
  NSString *description =
      [NSString stringWithFormat:@"Configuration failed for service %@.", service];
  NSDictionary *errorDict = @{
    NSLocalizedDescriptionKey : description,
    NSLocalizedFailureReasonErrorKey : reason
  };
  return FIRCreateError(domain, code, errorDict);
}

+ (NSError *)errorForInvalidAppID {
  NSDictionary *errorDict = @{
      NSLocalizedDescriptionKey :
      @"Unable to validate Google App ID",
      NSLocalizedRecoverySuggestionErrorKey :
      @"Check formatting and location of GoogleService-Info.plist or GoogleAppID set in the "
      @"customized options."
  };
  return FIRCreateError(kFirebaseCoreErrorDomain, FIRErrorCodeInvalidAppID, errorDict);
}

+ (BOOL)isDefaultAppConfigured {
  return (sDefaultApp != nil);
}

- (void)checkExpectedBundleID {
  NSArray *bundles = [FIRBundleUtil relevantBundles];
  NSString *expectedBundleID = [self expectedBundleID];
  // The checking is only done when the bundle ID is provided in the serviceInfo dictionary for
  // backward compatibility.
  if (expectedBundleID != nil &&
      ![FIRBundleUtil hasBundleIdentifier:expectedBundleID inBundles:bundles]) {
    FIRLogInfo(kFIRLoggerCore, @"I-COR000008", @"The project's Bundle ID is inconsistent with "
                @"either the Bundle ID in '%@.%@', or the Bundle ID in the options if you are "
                @"using a customized options. To ensure that everything can be configured "
                @"correctly, you may need to make the Bundle IDs consistent. To continue with this "
                @"plist file, you may change your app's bundle identifier to '%@'. Or you can "
                @"download a new configuration file that matches your bundle identifier from %@ "
                @"and replace the current one.", kServiceInfoFileName, kServiceInfoFileType,
                expectedBundleID, kPlistURL);
  }
}

- (nullable NSString *)getUID {
  if (!_getUIDImplementation) {
    FIRLogWarning(kFIRLoggerCore, @"I-COR000025", @"FIRAuth getUID implementation wasn't set.");
    return nil;
  }
  return _getUIDImplementation();
}

#pragma mark - private - App ID Validation

/**
 * Validates the format and fingerprint of the app ID contained in GOOGLE_APP_ID in the plist file.
 * This is the main method for validating app ID.
 *
 * @return YES if the app ID fulfills the expected format and fingerprint, NO otherwise.
 */
- (BOOL)isAppIDValid {
  NSString *appID = _options.googleAppID;
  BOOL isValid = [FIRApp validateAppID:appID];
  if (!isValid){
    NSString *expectedBundleID = [self expectedBundleID];
    FIRLogError(kFIRLoggerCore, @"I-COR000009", @"The GOOGLE_APP_ID either in the plist file "
                @"'%@.%@' or the one set in the customized options is invalid. If you are using "
                @"the plist file, use the iOS version of bundle identifier to download the file, "
                @"and do not manually edit the GOOGLE_APP_ID. You may change your app's bundle "
                @"identifier to '%@'. Or you can download a new configuration file that matches "
                @"your bundle identifier from %@ and replace the current one.",
                kServiceInfoFileName, kServiceInfoFileType, expectedBundleID, kPlistURL);

  };
  return isValid;
}

+ (BOOL)validateAppID:(NSString *)appID {
  // Failing validation only occurs when we are sure we are looking at a V2 app ID and it does not
  // have a valid fingerprint, otherwise we just warn about the potential issue.
  if (!appID.length) {
    return NO;
  }

  // All app IDs must start with at least "<version number>:".
  NSString *const versionPattern = @"^\\d+:";
  NSRegularExpression *versionRegex =
      [NSRegularExpression regularExpressionWithPattern:versionPattern options:0 error:NULL];
  if (!versionRegex) {
    return NO;
  }

  NSRange appIDRange = NSMakeRange(0, appID.length);
  NSArray *versionMatches = [versionRegex matchesInString:appID options:0 range:appIDRange];
  if (versionMatches.count != 1) {
    return NO;
  }

  NSRange versionRange = [(NSTextCheckingResult *)versionMatches.firstObject range];
  NSString *appIDVersion = [appID substringWithRange:versionRange];
  NSArray *knownVersions = @[ @"1:" ];
  if (![knownVersions containsObject:appIDVersion]) {
    // Permit unknown yet properly formatted app ID versions.
    return YES;
  }

  if (![FIRApp validateAppIDFormat:appID withVersion:appIDVersion]) {
    return NO;
  }

  if (![FIRApp validateAppIDFingerprint:appID withVersion:appIDVersion]) {
    return NO;
  }

  return YES;
}

+ (NSString *)actualBundleID {
  return [[NSBundle mainBundle] bundleIdentifier];
}

/**
 * Validates that the format of the app ID string is what is expected based on the supplied version.
 * The version must end in ":".
 *
 * For v1 app ids the format is expected to be
 * '<version #>:<project number>:ios:<fingerprint of bundle id>'.
 *
 * This method does not verify that the contents of the app id are correct, just that they fulfill
 * the expected format.
 *
 * @param appID Contents of GOOGLE_APP_ID from the plist file.
 * @param version Indicates what version of the app id format this string should be.
 * @return YES if provided string fufills the expected format, NO otherwise.
 */
+ (BOOL)validateAppIDFormat:(NSString *)appID withVersion:(NSString *)version {
  if (!appID.length || !version.length) {
    return NO;
  }

  if (![version hasSuffix:@":"]) {
    return NO;
  }

  if (![appID hasPrefix:version]) {
    return NO;
  }

  NSString *const pattern = @"^\\d+:ios:[a-f0-9]+$";
  NSRegularExpression *regex =
      [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:NULL];
  if (!regex) {
    return NO;
  }

  NSRange localRange = NSMakeRange(version.length, appID.length - version.length);
  NSUInteger numberOfMatches = [regex numberOfMatchesInString:appID options:0 range:localRange];
  if (numberOfMatches != 1) {
    return NO;
  }
  return YES;
}

/**
 * Validates that the fingerprint of the app ID string is what is expected based on the supplied
 * version. The version must end in ":".
 *
 * Note that the v1 hash algorithm is not permitted on the client and cannot be fully validated.
 *
 * @param appID Contents of GOOGLE_APP_ID from the plist file.
 * @param version Indicates what version of the app id format this string should be.
 * @return YES if provided string fufills the expected fingerprint and the version is known, NO
 *         otherwise.
 */
+ (BOOL)validateAppIDFingerprint:(NSString *)appID withVersion:(NSString *)version {
  if (!appID.length || !version.length) {
    return NO;
  }

  if (![version hasSuffix:@":"]) {
    return NO;
  }

  if (![appID hasPrefix:version]) {
    return NO;
  }

  // Extract the supplied fingerprint from the supplied app ID.
  // This assumes the app ID format is the same for all known versions below. If the app ID format
  // changes in future versions, the tokenizing of the app ID format will need to take into account
  // the version of the app ID.
  NSArray *components = [appID componentsSeparatedByString:@":"];
  if (components.count != 4) {
    return NO;
  }

  NSString *suppliedFingerprintString = components[3];
  if (!suppliedFingerprintString.length) {
    return NO;
  }

  uint64_t suppliedFingerprint;
  NSScanner *scanner = [NSScanner scannerWithString:suppliedFingerprintString];
  if (![scanner scanHexLongLong:&suppliedFingerprint]) {
    return NO;
  }

  if ([version isEqual:@"1:"]) {
    // The v1 hash algorithm is not permitted on the client so the actual hash cannot be validated.
    return YES;
  }

  // Unknown version.
  return NO;
}

- (NSString *)expectedBundleID {
  return _options.bundleID;
}

// end App ID validation
#pragma mark

- (void)sendLogsWithServiceName:(NSString *)serviceName
                        version:(NSString *)version
                          error:(NSError *)error{
  NSMutableDictionary *userInfo = [[NSMutableDictionary alloc] initWithDictionary:@{
    kFIRAppDiagnosticsConfigurationTypeKey : @(FIRConfigTypeSDK),
    kFIRAppDiagnosticsSDKNameKey : serviceName,
    kFIRAppDiagnosticsSDKVersionKey : version,
    kFIRAppDiagnosticsFIRAppKey : self
  }];
  if (error) {
    userInfo[kFIRAppDiagnosticsErrorKey] = error;
  }
  [[NSNotificationCenter defaultCenter]
      postNotificationName:kFIRAppDiagnosticsNotification
                    object:nil
                  userInfo:userInfo];
}

@end
