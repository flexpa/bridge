#import <HealthKit/HealthKit.h>
#include "clibproc.h"

void *hb_unit_from_string(const char *utf8) {
    if (!utf8) return NULL;
    @try {
        HKUnit *unit = [HKUnit unitFromString:[NSString stringWithUTF8String:utf8]];
        return (__bridge_retained void *)unit;
    } @catch (NSException *exception) {
        return NULL;
    }
}
