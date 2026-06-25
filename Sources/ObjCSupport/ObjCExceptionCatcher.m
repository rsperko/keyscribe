#import "include/ObjCExceptionCatcher.h"

BOOL KSRunCatchingNSException(void (NS_NOESCAPE ^block)(void), NSError *_Nullable *_Nullable error) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            if (exception.name) { info[@"KSExceptionName"] = exception.name; }
            if (exception.reason) { info[NSLocalizedDescriptionKey] = exception.reason; }
            *error = [NSError errorWithDomain:@"com.keyscribe.ObjCException" code:0 userInfo:info];
        }
        return NO;
    }
}
