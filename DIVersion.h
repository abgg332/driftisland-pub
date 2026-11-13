/* ===== 3.0.28: 版本号唯一来源 =====
   以前 prefs 里的 DI_VERSION_STR 和 Tweak.mm 的 DI_BUILD_VER 各写一份,
   改了主版本忘了改 prefs, 设置页/日志底下就一直显示旧版本(用户反馈 v2.9.60)。
   以后只改这里, 两个目标都包含它。 */
#ifndef DI_VERSION_H
#define DI_VERSION_H
#define DI_VERSION @"3.0.56"
#endif
