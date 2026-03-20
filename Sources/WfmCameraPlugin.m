#import "WfmCameraPlugin.h"

@implementation WfmCameraPlugin

// 暴露方法给 JS 端
UNI_EXPORT_METHOD(@selector(test:callback:))

/// 测试方法
- (void)test:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    NSLog(@"✅ test 方法被调用，参数: %@", options);
    
    if (callback) {
        // 返回结果给 JS
        callback(@{
            @"success": @YES,
            @"msg": @"插件工作正常！"
        }, NO);
    }
}

@end
