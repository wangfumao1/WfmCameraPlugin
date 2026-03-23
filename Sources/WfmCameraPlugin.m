#import "WfmCameraPlugin.h"

@implementation WfmCameraPlugin

// 暴露 test 方法给 JS
UNI_EXPORT_METHOD(@selector(test:callback:))

// 暴露日志方法
UNI_EXPORT_METHOD(@selector(log:callback:))

- (void)test:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    // 准备返回结果
    NSDictionary *result = @{
        @"success": @YES,
        @"msg": @"插件工作正常！",
        @"params": options ?: @{}
    };
    
    if (callback) {
        callback(result, NO);
    }
}

// 日志方法 - 通过回调返回日志信息
- (void)log:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    NSString *message = options[@"message"] ?: @"";
    NSLog(@"[WfmCameraPlugin] %@", message);
    
    if (callback) {
        callback(@{
            @"success": @YES,
            @"log": message
        }, NO);
    }
}

@end
