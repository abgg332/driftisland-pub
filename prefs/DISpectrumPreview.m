#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <notify.h>
#import "../DIExtraSpectrum.h"
static NSArray *diPreviewNames(void){return @[@"柱状",@"点阵",@"镜像",@"阶梯",@"峰值",@"尖刺",@"斜切",@"电波",@"气泡",@"居中胶囊",@"流动山峦",@"对称声纹",@"星点矩阵",@"环形能量",@"双轨脉冲"];}
@interface DISpectrumPreviewCanvas:UIView
@property(nonatomic) NSInteger style;
@property(nonatomic) CGFloat phase;
@end
@implementation DISpectrumPreviewCanvas
- (void)drawRect:(CGRect)rect {
 CGContextRef ctx=UIGraphicsGetCurrentContext();if(!ctx)return;
 CGRect b=CGRectInset(self.bounds,10,9);CGFloat values[32];
 for(int i=0;i<32;i++)values[i]=.08+.92*fabs(sin(self.phase*1.5+i*.36))*pow(MAX(.1,1-fabs(i-15.5)/19),.7);
 UIColor *color=[UIColor colorWithRed:.64 green:.55 blue:1 alpha:1];[color setFill];[color setStroke];
 if(self.style>=9){CGPathRef path=diExtraSpectrumPath((int)self.style,values,32,b);CGContextAddPath(ctx,path);CGContextDrawPath(ctx,self.style==13?kCGPathFillStroke:kCGPathFill);CGPathRelease(path);return;}
 CGFloat dx=b.size.width/32;
 for(int i=0;i<32;i++){
  CGFloat h=values[i]*b.size.height,w=MAX(1,dx*.6),x=b.origin.x+i*dx,y=CGRectGetMaxY(b)-h;
  if(self.style==1){for(int j=0;j<h/5;j++)CGContextFillRect(ctx,CGRectMake(x,CGRectGetMaxY(b)-j*5-3,w,3));}
  else if(self.style==2)CGContextFillRect(ctx,CGRectMake(x,CGRectGetMidY(b)-h/2,w,h));
  else if(self.style==5){CGContextMoveToPoint(ctx,x,CGRectGetMaxY(b));CGContextAddLineToPoint(ctx,x+w/2,y);CGContextAddLineToPoint(ctx,x+w,CGRectGetMaxY(b));CGContextFillPath(ctx);}
  else if(self.style==7){if(i==0)CGContextMoveToPoint(ctx,x,y);else CGContextAddLineToPoint(ctx,x,y);}
  else {CGFloat skew=self.style==6?h*.12:0;CGContextFillRect(ctx,CGRectMake(x+skew,y,w,h));if(self.style==4)CGContextFillRect(ctx,CGRectMake(x,y-5,w,2));if(self.style==8)CGContextFillEllipseInRect(ctx,CGRectMake(x,y-8-fmod(self.phase*10+i,14),3,3));}
 }
 if(self.style==7){CGContextSetLineWidth(ctx,1.5);CGContextStrokePath(ctx);}
}
@end
@interface DISpectrumStylePreviewController:UITableViewController
@property(nonatomic,strong) CADisplayLink *displayLink;
@property(nonatomic,assign) NSInteger selected;
@property(nonatomic,assign) CFTimeInterval previous;
@end
@implementation DISpectrumStylePreviewController
- (instancetype)init {return [super initWithStyle:UITableViewStyleInsetGrouped];}
- (void)viewDidLoad{[super viewDidLoad];self.title=@"频谱样式预览";self.tableView.rowHeight=110;self.tableView.backgroundColor=UIColor.systemGroupedBackgroundColor;[self readSelected];}
- (void)readSelected {id n=CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("SpectrumStyle"),CFSTR("com.abgg332.driftisland")));self.selected=n?[n integerValue]:0;}
- (void)viewDidAppear:(BOOL)animated{[super viewDidAppear:animated];self.displayLink=[CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];self.displayLink.preferredFramesPerSecond=20;[self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];}
- (void)viewWillDisappear:(BOOL)animated{[super viewWillDisappear:animated];[self.displayLink invalidate];self.displayLink=nil;self.previous=0;}
- (void)dealloc{[_displayLink invalidate];}
- (void)tick:(CADisplayLink *)link {CGFloat delta=self.previous?MIN(.1,link.timestamp-self.previous):.05;self.previous=link.timestamp;for(UITableViewCell *c in self.tableView.visibleCells){DISpectrumPreviewCanvas *v=(DISpectrumPreviewCanvas *)[c.contentView viewWithTag:1071];v.phase+=delta;[v setNeedsDisplay];}}
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section{(void)table;(void)section;return diPreviewNames().count;}
- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section{(void)table;(void)section;return @"点选即应用 · 模拟音频动画预览";}
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section{(void)table;(void)section;return @"预览使用模拟信号，不读取麦克风。旧样式为示意预览；新增样式与实播共用路径算法。实际效果受歌曲频谱、颜色和高度设置影响，并非特定音乐 App 的官方复刻。";}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)index {
 UITableViewCell *c=[table dequeueReusableCellWithIdentifier:@"spectrum"];
 if(!c){c=[[UITableViewCell alloc]initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"spectrum"];UILabel *title=[[UILabel alloc]initWithFrame:CGRectZero];title.tag=1070;title.font=[UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];title.textColor=UIColor.labelColor;[c.contentView addSubview:title];DISpectrumPreviewCanvas *v=[DISpectrumPreviewCanvas new];v.tag=1071;v.backgroundColor=UIColor.clearColor;[c.contentView addSubview:v];}
 UILabel *label=(UILabel *)[c.contentView viewWithTag:1070];label.text=diPreviewNames()[index.row];label.frame=CGRectMake(16,6,240,25);label.autoresizingMask=UIViewAutoresizingFlexibleWidth;
 DISpectrumPreviewCanvas *v=(DISpectrumPreviewCanvas *)[c.contentView viewWithTag:1071];v.style=index.row;v.frame=CGRectMake(12,33,MAX(100,table.bounds.size.width-90),68);v.autoresizingMask=UIViewAutoresizingFlexibleWidth;[v setNeedsDisplay];
 c.accessoryType=self.selected==index.row?UITableViewCellAccessoryCheckmark:UITableViewCellAccessoryNone;return c;
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)index {
 self.selected=index.row;NSNumber *value=@(index.row);CFPreferencesSetAppValue(CFSTR("SpectrumStyle"),(__bridge CFPropertyListRef)value,CFSTR("com.abgg332.driftisland"));CFPreferencesAppSynchronize(CFSTR("com.abgg332.driftisland"));notify_post("com.abgg332.driftisland.fxtune");[table deselectRowAtIndexPath:index animated:YES];[table reloadData];
}
@end
