#import "WfmCameraPlugin.h"

@implementation WfmCameraPlugin

UNI_EXPORT_METHOD(@selector(test:callback:))

- (void)test:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    NSLog(@"✅ test 方法被调用，参数: %@", options);
    
    if (callback) {
        callback(@{
            @"success": @YES,
            @"msg": @"插件工作正常！"
        }, NO);
    }
}

@end
