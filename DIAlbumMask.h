// DIAlbumMask.h —— 专辑光晕遮罩(按规范实现)
// 素材目录固定: /var/mobile/灵动岛/遮罩素材/  (可直接放 png, 也可一层子文件夹)
// 关键: 遮罩 png 只能作为 maskView 使用(靠 alpha 通道), 绝不能用 addSubview 叠上去。
#import <UIKit/UIKit.h>

// 光晕视图识别 tag —— 清理旧光晕时用
static const NSInteger DIAlbumHaloTag = 0x0A10A;

// 偏好键: 选中的遮罩素材("文件夹/文件名" 形式, 空 = 关闭遮罩)
static NSString *const kDIAlbumMaskKey = @"diAlbumMaskAsset";

// 扫描素材目录(递归一层, 只要 .png), 返回 "文件夹/文件名" 或 "文件名"
NSArray<NSString *> *DIMaskListAssets(void);

// 当前选中的遮罩图片: 先读偏好键, 读不到用目录里第一个 png; 目录里没有 png 就返回 nil(不兜底!)
UIImage *DIMaskCurrentImage(void);

// 给卡片里的专辑封面加光晕: 封面本体 + 遮罩当 maskView, 垫在专辑下面
void DIApplyAlbumHalo(UIView *card, UIView *albumView, CGFloat haloDiameter);

// 清掉卡片里所有旧光晕(换歌/刷新时调)
void DIClearAlbumHalo(UIView *card);

// 让素材缓存失效(设置页选完素材后调, 立刻换图)
void DIMaskInvalidateCache(void);

// 素材失效代数: 每次 Invalidate 自增, 外部拿来做"素材是否换过"的缓存键
NSInteger DIMaskGeneration(void);
