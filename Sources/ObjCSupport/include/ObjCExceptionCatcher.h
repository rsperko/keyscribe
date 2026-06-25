#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Runs `block` inside an @try/@catch, converting a raised NSException into an NSError (Swift can't catch
// them). Returns YES on clean completion, NO if an exception was caught (with `error` populated).
BOOL KSRunCatchingNSException(void (NS_NOESCAPE ^block)(void), NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
