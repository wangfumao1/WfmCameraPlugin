#import "WfmCameraPlugin.h"
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

@interface WfmCameraPlugin () <AVCaptureVideoDataOutputSampleBufferDelegate>

@property (nonatomic, strong) AVCaptureMultiCamSession *multiCamSession;
@property (nonatomic, strong) AVCaptureDeviceInput *backInput;
@property (nonatomic, strong) AVCaptureDeviceInput *frontInput;
@property (nonatomic, strong) AVCaptureVideoDataOutput *backOutput;
@property (nonatomic, strong) AVCaptureVideoDataOutput *frontOutput;
@property (nonatomic, strong) UIView *backPreviewView;
@property (nonatomic, strong) UIView *frontPreviewView;
@property (nonatomic, strong) UIImageView *backImageView;
@property (nonatomic, strong) UIImageView *frontImageView;
@property (nonatomic, strong) dispatch_queue_t videoQueue;
@property (nonatomic, assign) CGColorSpaceRef colorSpace;
@property (nonatomic, strong) NSMutableArray *logs;

@end

@implementation WfmCameraPlugin

// 暴露方法
UNI_EXPORT_METHOD(@selector(test:callback:))
UNI_EXPORT_METHOD(@selector(openDualCamera:callback:))
UNI_EXPORT_METHOD(@selector(closeDualCamera:callback:))
UNI_EXPORT_METHOD(@selector(log:callback:))

- (instancetype)init {
    self = [super init];
    if (self) {
        // 创建视频处理队列
        _videoQueue = dispatch_queue_create("com.wfm.camera.queue", DISPATCH_QUEUE_SERIAL);
        // 初始化日志数组
        _logs = [NSMutableArray array];
    }
    return self;
}

// 日志辅助方法
- (void)log:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    NSString *message = options[@"message"] ?: @"";
    NSLog(@"[WfmCameraPlugin] %@", message);
    if (callback) {
        callback(@{@"success": @YES, @"log": message}, NO);
    }
}

- (void)logMessage:(NSString *)message callback:(UniModuleKeepAliveCallback)callback {
    NSLog(@"[WfmCameraPlugin] %@", message);
    [self.logs addObject:message];
}

- (void)logError:(NSString *)message error:(NSError *)error callback:(UniModuleKeepAliveCallback)callback {
    NSString *fullMsg = [NSString stringWithFormat:@"❌ %@: %@", message, error.localizedDescription];
    NSLog(@"[WfmCameraPlugin] %@", fullMsg);
    [self.logs addObject:fullMsg];
}

// 发送最终结果
- (void)sendResult:(BOOL)success message:(NSString *)message callback:(UniModuleKeepAliveCallback)callback {
    if (callback) {
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        result[@"success"] = @(success);
        if (message) {
            result[@"msg"] = message;
        }
        if (self.logs.count > 0) {
            result[@"logs"] = self.logs;
        }
        callback(result, NO);
    }
    // 清空日志
    [self.logs removeAllObjects];
}

// test 方法
- (void)test:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    [self logMessage:@"test 方法开始" callback:callback];
    [self logMessage:@"测试第一条日志" callback:callback];
    [self logMessage:@"测试第二条日志" callback:callback];
    [self logMessage:@"测试第三条日志" callback:callback];
    [self logMessage:@"test 方法结束" callback:callback];
    [self sendResult:YES message:@"插件工作正常！" callback:callback];
}

// 打开双摄
- (void)openDualCamera:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    [self logMessage:@"========== 打开双摄 ==========" callback:callback];
    
    @try {
        // 检查 iOS 版本
        if (@available(iOS 13.0, *)) {
            [self logMessage:@"iOS 13+ 检查通过" callback:callback];
        } else {
            [self logMessage:@"需要 iOS 13 或更高版本" callback:callback];
            [self sendResult:NO message:@"需要 iOS 13 或更高版本" callback:callback];
            return;
        }
        
        // 检查权限
        AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
        [self logMessage:[NSString stringWithFormat:@"相机权限状态: %ld", (long)status] callback:callback];
        
        if (status != AVAuthorizationStatusAuthorized) {
            if (status == AVAuthorizationStatusNotDetermined) {
                [self logMessage:@"请求相机权限..." callback:callback];
                [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
                    dispatch_async(dispatch_get_main_queue(), ^{ 
                        if (granted) {
                            [self logMessage:@"权限已授权，开始打开双摄" callback:callback];
                            [self setupDualCamera:callback];
                        } else {
                            [self logMessage:@"用户拒绝相机权限" callback:callback];
                            [self sendResult:NO message:@"需要相机权限" callback:callback];
                        }
                    });
                }];
            } else {
                [self logMessage:@"相机权限未授权" callback:callback];
                [self sendResult:NO message:@"请先在设置中开启相机权限" callback:callback];
            }
            return;
        }
        
        // 已有权限，直接打开
        [self setupDualCamera:callback];
    } @catch (NSException *exception) {
        [self logMessage:[NSString stringWithFormat:@"异常: %@", exception.reason] callback:callback];
        [self sendResult:NO message:exception.reason callback:callback];
    }
}

// 关闭双摄
- (void)closeDualCamera:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    [self logMessage:@"========== 关闭双摄 ==========" callback:callback];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.multiCamSession) {
            [self.multiCamSession stopRunning];
            [self logMessage:@"会话已停止" callback:callback];
            
            // 移除输出代理
            if (self.backOutput) {
                [self.backOutput setSampleBufferDelegate:nil queue:NULL];
            }
            if (self.frontOutput) {
                [self.frontOutput setSampleBufferDelegate:nil queue:NULL];
            }
            
            if (self.backPreviewView) {
                [self.backPreviewView removeFromSuperview];
                self.backPreviewView = nil;
                [self logMessage:@"后置预览视图已移除" callback:callback];
            }
            if (self.frontPreviewView) {
                [self.frontPreviewView removeFromSuperview];
                self.frontPreviewView = nil;
                [self logMessage:@"前置预览视图已移除" callback:callback];
            }
            
            self.multiCamSession = nil;
            self.backInput = nil;
            self.frontInput = nil;
            self.backOutput = nil;
            self.frontOutput = nil;
            self.backImageView = nil;
            self.frontImageView = nil;
            
            [self logMessage:@"双摄已关闭" callback:callback];
            [self sendResult:YES message:@"双摄已关闭" callback:callback];
        } else {
            [self logMessage:@"双摄未开启" callback:callback];
            [self sendResult:YES message:@"双摄未开启" callback:callback];
        }
    });
}

// 设置双摄预览
- (void)setupDualCamera:(UniModuleKeepAliveCallback)callback API_AVAILABLE(ios(13.0)) {
    [self logMessage:@"开始设置双摄..." callback:callback];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            // 1. 创建多摄会话
            [self logMessage:@"步骤1: 创建多摄会话..." callback:callback];
            self.multiCamSession = [[AVCaptureMultiCamSession alloc] init];
            self.multiCamSession.sessionPreset = AVCaptureSessionPresetHigh;
            [self logMessage:@"步骤1: 多摄会话创建成功" callback:callback];
            
            // 2. 获取后置摄像头
            [self logMessage:@"步骤2: 获取后置摄像头..." callback:callback];
            AVCaptureDevice *backCamera = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
                                                                              mediaType:AVMediaTypeVideo
                                                                               position:AVCaptureDevicePositionBack];
            if (!backCamera) {
                [self logMessage:@"步骤2: 找不到后置摄像头" callback:callback];
                [self sendResult:NO message:@"找不到后置摄像头" callback:callback];
                return;
            }
            [self logMessage:[NSString stringWithFormat:@"步骤2: 找到后置摄像头: %@", backCamera.localizedName] callback:callback];
            
            // 3. 获取前置摄像头
            [self logMessage:@"步骤3: 获取前置摄像头..." callback:callback];
            AVCaptureDevice *frontCamera = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
                                                                               mediaType:AVMediaTypeVideo
                                                                                position:AVCaptureDevicePositionFront];
            if (!frontCamera) {
                [self logMessage:@"步骤3: 找不到前置摄像头" callback:callback];
                [self sendResult:NO message:@"找不到前置摄像头" callback:callback];
                return;
            }
            [self logMessage:[NSString stringWithFormat:@"步骤3: 找到前置摄像头: %@", frontCamera.localizedName] callback:callback];
            
            // 4. 添加后置输入
            [self logMessage:@"步骤4: 添加后置输入..." callback:callback];
            NSError *error = nil;
            self.backInput = [AVCaptureDeviceInput deviceInputWithDevice:backCamera error:&error];
            if (error) {
                [self logMessage:[NSString stringWithFormat:@"步骤4: 后置输入创建失败: %@", error.localizedDescription] callback:callback];
                [self sendResult:NO message:@"后置摄像头初始化失败" callback:callback];
                return;
            }
            
            if ([self.multiCamSession canAddInput:self.backInput]) {
                [self.multiCamSession addInput:self.backInput];
                [self logMessage:@"步骤4: 后置输入添加成功" callback:callback];
            } else {
                [self logMessage:@"步骤4: 无法添加后置输入" callback:callback];
                [self sendResult:NO message:@"无法添加后置摄像头" callback:callback];
                return;
            }
            
            // 5. 添加前置输入
            [self logMessage:@"步骤5: 添加前置输入..." callback:callback];
            self.frontInput = [AVCaptureDeviceInput deviceInputWithDevice:frontCamera error:&error];
            if (error) {
                [self logMessage:[NSString stringWithFormat:@"步骤5: 前置输入创建失败: %@", error.localizedDescription] callback:callback];
                [self sendResult:NO message:@"前置摄像头初始化失败" callback:callback];
                return;
            }
            
            if ([self.multiCamSession canAddInput:self.frontInput]) {
                [self.multiCamSession addInput:self.frontInput];
                [self logMessage:@"步骤5: 前置输入添加成功" callback:callback];
            } else {
                [self logMessage:@"步骤5: 无法添加前置输入" callback:callback];
                [self sendResult:NO message:@"无法添加前置摄像头" callback:callback];
                return;
            }
            
            // 6. 添加后置视频输出
            [self logMessage:@"步骤6: 添加后置视频输出..." callback:callback];
            self.backOutput = [[AVCaptureVideoDataOutput alloc] init];
            self.backOutput.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
            [self.backOutput setSampleBufferDelegate:self queue:self.videoQueue];
            
            if ([self.multiCamSession canAddOutput:self.backOutput]) {
                [self.multiCamSession addOutputWithNoConnections:self.backOutput];
                
                // 创建后置输出连接
                if (self.backInput.ports.count > 0) {
                    AVCaptureConnection *backConnection = [AVCaptureConnection connectionWithInputPorts:self.backInput.ports output:self.backOutput];
                    if (backConnection) {
                        if ([self.multiCamSession canAddConnection:backConnection]) {
                            [self.multiCamSession addConnection:backConnection];
                            [self logMessage:@"步骤6: 后置视频输出添加成功" callback:callback];
                        } else {
                            [self logMessage:@"步骤6: 无法添加后置输出连接" callback:callback];
                            [self sendResult:NO message:@"无法添加后置摄像头连接" callback:callback];
                            return;
                        }
                    } else {
                        [self logMessage:@"步骤6: 无法创建后置输出连接" callback:callback];
                        [self sendResult:NO message:@"无法创建后置摄像头连接" callback:callback];
                        return;
                    }
                } else {
                    [self logMessage:@"步骤6: 后置输入端口为空" callback:callback];
                    [self sendResult:NO message:@"后置摄像头端口为空" callback:callback];
                    return;
                }
            } else {
                [self logMessage:@"步骤6: 无法添加后置视频输出" callback:callback];
                [self sendResult:NO message:@"无法添加后置视频输出" callback:callback];
                return;
            }
            
            // 7. 添加前置视频输出
            [self logMessage:@"步骤7: 添加前置视频输出..." callback:callback];
            self.frontOutput = [[AVCaptureVideoDataOutput alloc] init];
            self.frontOutput.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
            [self.frontOutput setSampleBufferDelegate:self queue:self.videoQueue];
            
            if ([self.multiCamSession canAddOutput:self.frontOutput]) {
                [self.multiCamSession addOutputWithNoConnections:self.frontOutput];
                
                // 创建前置输出连接
                if (self.frontInput.ports.count > 0) {
                    AVCaptureConnection *frontConnection = [AVCaptureConnection connectionWithInputPorts:self.frontInput.ports output:self.frontOutput];
                    if (frontConnection) {
                        if (frontConnection.isVideoMirroringSupported) {
                            frontConnection.videoMirrored = YES;
                        }
                        if ([self.multiCamSession canAddConnection:frontConnection]) {
                            [self.multiCamSession addConnection:frontConnection];
                            [self logMessage:@"步骤7: 前置视频输出添加成功" callback:callback];
                        } else {
                            [self logMessage:@"步骤7: 无法添加前置输出连接" callback:callback];
                            [self sendResult:NO message:@"无法添加前置摄像头连接" callback:callback];
                            return;
                        }
                    } else {
                        [self logMessage:@"步骤7: 无法创建前置输出连接" callback:callback];
                        [self sendResult:NO message:@"无法创建前置摄像头连接" callback:callback];
                        return;
                    }
                } else {
                    [self logMessage:@"步骤7: 前置输入端口为空" callback:callback];
                    [self sendResult:NO message:@"前置摄像头端口为空" callback:callback];
                    return;
                }
            } else {
                [self logMessage:@"步骤7: 无法添加前置视频输出" callback:callback];
                [self sendResult:NO message:@"无法添加前置视频输出" callback:callback];
                return;
            }
            
            // 8. 获取当前视图并创建预览
            [self logMessage:@"步骤8: 获取当前视图..." callback:callback];
            UIViewController *topVC = [self getTopViewController];
            if (!topVC) {
                [self logMessage:@"步骤8: 无法获取当前视图" callback:callback];
                [self sendResult:NO message:@"无法获取当前视图" callback:callback];
                return;
            }
            [self logMessage:[NSString stringWithFormat:@"步骤8: 当前视图: %@", NSStringFromClass([topVC class])] callback:callback];
            
            // 9. 创建后置预览视图（全屏）
            [self logMessage:@"步骤9: 创建后置预览..." callback:callback];
            self.backPreviewView = [[UIView alloc] initWithFrame:topVC.view.bounds];
            self.backPreviewView.backgroundColor = [UIColor blackColor];
            [topVC.view addSubview:self.backPreviewView];
            
            self.backImageView = [[UIImageView alloc] initWithFrame:self.backPreviewView.bounds];
            self.backImageView.contentMode = UIViewContentModeScaleAspectFill;
            [self.backPreviewView addSubview:self.backImageView];
            [self logMessage:@"步骤10: 后置预览已创建" callback:callback];
            
            // 11. 创建前置预览视图（小窗）
            [self logMessage:@"步骤11: 创建前置预览..." callback:callback];
            CGFloat smallWidth = 120;
            CGFloat smallHeight = 160;
            CGFloat margin = 16;
            CGFloat topOffset = 100;
            
            self.frontPreviewView = [[UIView alloc] initWithFrame:CGRectMake(
                topVC.view.bounds.size.width - smallWidth - margin,
                topOffset,
                smallWidth,
                smallHeight
            )];
            self.frontPreviewView.backgroundColor = [UIColor blackColor];
            self.frontPreviewView.layer.cornerRadius = 8;
            self.frontPreviewView.layer.masksToBounds = YES;
            self.frontPreviewView.layer.borderWidth = 2;
            self.frontPreviewView.layer.borderColor = [UIColor whiteColor].CGColor;
            [topVC.view addSubview:self.frontPreviewView];
            
            self.frontImageView = [[UIImageView alloc] initWithFrame:self.frontPreviewView.bounds];
            self.frontImageView.contentMode = UIViewContentModeScaleAspectFill;
            [self.frontPreviewView addSubview:self.frontImageView];
            [self logMessage:@"步骤10: 前置预览已创建" callback:callback];
            
            // 11. 启动会话
            [self logMessage:@"步骤11: 启动会话..." callback:callback];
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{ 
                [self.multiCamSession startRunning];
                dispatch_async(dispatch_get_main_queue(), ^{ 
                    [self logMessage:@"步骤11: 会话已启动" callback:callback];
                    [self logMessage:@"✅ 双摄预览已开启！" callback:callback];
                    [self sendResult:YES message:@"双摄预览已开启" callback:callback];
                });
            });
            
        } @catch (NSException *exception) {
            [self logMessage:[NSString stringWithFormat:@"设置双摄时崩溃: %@", exception.reason] callback:callback];
            [self sendResult:NO message:exception.reason callback:callback];
        }
    });
}

#pragma mark - AVCaptureVideoDataOutputSampleBufferDelegate

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    if (!sampleBuffer) return;
    
    // 判断是哪个摄像头的数据
    UIImageView *targetImageView = nil;
    if (output == self.backOutput) {
        targetImageView = self.backImageView;
    } else if (output == self.frontOutput) {
        targetImageView = self.frontImageView;
    }
    
    if (!targetImageView) return;
    
    // 将 sample buffer 转换为 UIImage
    UIImage *image = [self imageFromSampleBuffer:sampleBuffer];
    
    if (image) {
        dispatch_async(dispatch_get_main_queue(), ^{ 
            // 确保视图仍然存在
            if (targetImageView.superview) {
                targetImageView.image = image;
            }
        });
    }
}

- (void)captureOutput:(AVCaptureOutput *)output didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    // 处理丢帧情况
}

// 将 CMSampleBufferRef 转换为 UIImage
- (UIImage *)imageFromSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!imageBuffer) return nil;
    
    CVPixelBufferLockBaseAddress(imageBuffer, 0);
    
    void *baseAddress = CVPixelBufferGetBaseAddress(imageBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer);
    size_t width = CVPixelBufferGetWidth(imageBuffer);
    size_t height = CVPixelBufferGetHeight(imageBuffer);
    
    // 重用颜色空间
    if (!self.colorSpace) {
        self.colorSpace = CGColorSpaceCreateDeviceRGB();
    }
    
    // 创建上下文
    CGContextRef context = CGBitmapContextCreate(baseAddress, width, height, 8, bytesPerRow, self.colorSpace, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    
    CGImageRef cgImage = CGBitmapContextCreateImage(context);
    UIImage *image = [UIImage imageWithCGImage:cgImage];
    
    CGImageRelease(cgImage);
    CGContextRelease(context);
    
    CVPixelBufferUnlockBaseAddress(imageBuffer, 0);
    
    return image;
}

- (void)dealloc {
    if (self.colorSpace) {
        CGColorSpaceRelease(self.colorSpace);
    }
}

// 获取当前视图控制器
- (UIViewController *)getTopViewController {
    UIViewController *topVC = nil;
    
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *windowScene in [UIApplication sharedApplication].connectedScenes) {
            if (windowScene.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *window in windowScene.windows) {
                    if (window.isKeyWindow) {
                        topVC = window.rootViewController;
                        break;
                    }
                }
            }
        }
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        topVC = [UIApplication sharedApplication].keyWindow.rootViewController;
#pragma clang diagnostic pop
    }
    
    while (topVC.presentedViewController) {
        topVC = topVC.presentedViewController;
    }
    if ([topVC isKindOfClass:[UINavigationController class]]) {
        topVC = [(UINavigationController *)topVC visibleViewController];
    }
    return topVC;
}

@end
