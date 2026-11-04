#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>

/* 漂流岛 预览投递器
   这是一个带 bundle id(com.abgg332.driftisland.preview) 的极小程序,
   唯一作用: 用真实 App 身份投递一条本地通知。
   为什么必须在独立 App 里发: SpringBoard 进程自己没有 bundle 身份,
   调 UNUserNotificationCenter 会"返回成功但通知被丢弃"(日志已实证)。
   有了真实 bundle, 系统就走完整第三方通知链路 → 上岛 → 锁屏卡片。 */

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSString *body = @"文字颜色预览 ABC 123";
        NSString *title = @"漂流岛";
        /* 从设置页传参(可选): driftislandpreview <title> <body> */
        if (argc > 1 && argv[1]) title = [NSString stringWithUTF8String:argv[1]];
        if (argc > 2 && argv[2]) body = [NSString stringWithUTF8String:argv[2]];

        UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
        __block BOOL finished = NO;

        /* 先请求授权(通知/声音); 已授权时立即回调, 不会弹窗 */
        [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert |
                                                UNAuthorizationOptionSound |
                                                UNAuthorizationOptionBadge)
                              completionHandler:^(BOOL granted, NSError *err) {
            if (!granted) {
                NSLog(@"[DriftIslandPreview] 授权未通过: %@", err);
                finished = YES;
                return;
            }
            UNMutableNotificationContent *c = [UNMutableNotificationContent new];
            c.title = title;
            c.body = body;
            c.sound = nil; // 预览不响铃
            NSString *ident = [NSString stringWithFormat:@"di-preview-%u", arc4random() % 1000000];
            UNNotificationRequest *req = [UNNotificationRequest requestWithIdentifier:ident
                                                                             content:c
                                                                             trigger:nil]; // nil = 立即送达
            [center addNotificationRequest:req withCompletionHandler:^(NSError *e) {
                NSLog(@"[DriftIslandPreview] 投递%@ %@", e ? @"失败" : @"成功", e ?: @"");
                finished = YES;
            }];
        }];

        /* 等投递完成再退出(最多 3 秒), 否则进程被杀会丢掉通知 */
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3.0];
        while (!finished && [deadline timeIntervalSinceNow] > 0) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        }
        /* 再给系统 0.6 秒把通知推到界面 */
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.6]];
    }
    return 0;
}
