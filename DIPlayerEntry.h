//
//  DIPlayerEntry.h
//  3.0: 播放器入口 —— 全局悬浮球(PNG/GIF) + 点击呼出播放面板 + 接系统播放器
//

#import <UIKit/UIKit.h>

/* 读偏好并创建/移除悬浮球。主线程安全(内部会切主队列)。 */
void diPlayerEntryReload(void);
