#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <CoreFoundation/CoreFoundation.h>
#import <notify.h>
#include <math.h>


/* Static thumbnails only: no CADisplayLink, NSTimer, audio input or live canvas. */
@interface DISpectrumStaticController : PSListController
@end

/* 3.0.112: 8 种 —— 原有 柱状/点阵/镜像/峰值/尖刺/斜切 + 萤火 + 星轨。
   3.0.111 新增的 绸带/山峦/脉冲/阶梯 已按用户要求删除。 */
static const NSInteger diStyleIDs[8] = { 0, 1, 2, 4, 5, 6, 10, 14 };

static BOOL diStyleKnown(NSInteger s) {
    for (int i = 0; i < 8; i++) if (diStyleIDs[i] == s) return YES;
    return NO;
}

/* 固定信号下的静态示意 —— 和播放器里那 8 种画法一一对应, 只画形状不跑动画。 */
static UIImage *diStaticShape(NSInteger style){
    CGSize size=CGSizeMake(132,54);
    UIGraphicsBeginImageContextWithOptions(size,NO,0);
    CGContextRef ctx=UIGraphicsGetCurrentContext();
    if(!ctx){UIGraphicsEndImageContext();return nil;}
    CGFloat v[24];for(int i=0;i<24;i++)v[i]=.15+.78*fabs(sin(i*.61))*MAX(.3,1-fabs(i-11.5)/16);
    UIColor *ink=[UIColor colorWithRed:.61 green:.47 blue:.95 alpha:1];
    CGContextSetFillColorWithColor(ctx, ink.CGColor);
    CGContextSetStrokeColorWithColor(ctx, ink.CGColor);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextSetLineJoin(ctx, kCGLineJoinRound);
    CGRect b=CGRectMake(3,4,126,46);
    {
        CGFloat dx=b.size.width/24;
        for(int i=0;i<24;i++){
            CGFloat x=3+i*dx,h=v[i]*30,y=38-h,w=2;
            CGFloat cx = x + w*0.5f;
            if(style==1){for(int j=0;j<(int)(h/4);j++)CGContextFillRect(ctx,CGRectMake(x,35-j*4,w,2));}
            else if(style==2)CGContextFillRect(ctx,CGRectMake(x,21-h/2,w,h));
            else if(style==4){CGContextFillRect(ctx,CGRectMake(x,y,w,h));CGContextFillRect(ctx,CGRectMake(x,y-4,w,1));}
            else if(style==5){CGContextMoveToPoint(ctx,x,38);CGContextAddLineToPoint(ctx,x+w/2,y);CGContextAddLineToPoint(ctx,x+w,38);CGContextClosePath(ctx);CGContextFillPath(ctx);}
            else if(style==6){CGContextMoveToPoint(ctx,x,38);CGContextAddLineToPoint(ctx,x+h*.14,y);CGContextAddLineToPoint(ctx,x+h*.14+w,y);CGContextAddLineToPoint(ctx,x+w,38);CGContextClosePath(ctx);CGContextFillPath(ctx);}
            else if(style==10){                  /* 萤火: 细光柱 + 顶部光点 */
                CGContextFillRect(ctx,CGRectMake(cx-0.3f,y,0.6f,h));
                CGFloat r=0.8f+2.2f*v[i];
                CGContextFillEllipseInRect(ctx,CGRectMake(cx-r,y-r,r*2,r*2));
            }
            else if(style==14){                  /* 星轨: 光柱 + 十字星 */
                CGContextFillRect(ctx,CGRectMake(cx-0.35f,y,0.7f,h));
                CGFloat r=1.0f+2.6f*v[i];
                CGContextFillRect(ctx,CGRectMake(cx-0.45f,y-r,0.9f,r*2));
                CGContextFillRect(ctx,CGRectMake(cx-r,y-0.45f,r*2,0.9f));
            }
            else {CGContextFillRect(ctx,CGRectMake(x,y,w,h));}
        }
    }
    UIImage *image=UIGraphicsGetImageFromCurrentImageContext();UIGraphicsEndImageContext();return image;
}
@implementation DISpectrumStaticController
- (NSArray *)specifiers {
    if(!_specifiers){
        NSArray *names=@[@"柱状",@"点阵",@"镜像",@"峰值",@"尖刺",@"斜切",
                         @"萤火",@"星轨"];
        NSMutableArray *rows=[NSMutableArray array];
        PSSpecifier *group=[PSSpecifier preferenceSpecifierNamed:@"静态形状图 · 点选应用" target:nil set:NULL get:NULL detail:nil cell:PSGroupCell edit:nil];
        [group setProperty:@"图示为固定信号下的形状示意，不播放动画、不采集音频。选中后到播放器查看实际音乐效果。" forKey:@"footerText"];[rows addObject:group];
        id saved=CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("SpectrumStyle"),CFSTR("com.abgg332.driftisland")));
        NSInteger selected=saved?[saved integerValue]:0;
        if(!diStyleKnown(selected))selected=0;
        for(NSUInteger i=0;i<names.count;i++){
            NSInteger sid = diStyleIDs[i];
            NSString *title=[NSString stringWithFormat:@"%@%@",sid==selected?@"✓  ":@"",names[i]];
            PSSpecifier *sp=[PSSpecifier preferenceSpecifierNamed:title target:self set:NULL get:NULL detail:nil cell:PSButtonCell edit:nil];
            [sp setProperty:@(sid) forKey:@"diStyle"];
            UIImage *icon=diStaticShape(sid);if(icon)[sp setProperty:icon forKey:@"iconImage"];
            [sp setButtonAction:@selector(selectStyle:)];[rows addObject:sp];
        }
        _specifiers=rows;
    }return _specifiers;
}
- (void)selectStyle:(PSSpecifier *)sp {
    NSNumber *n=[sp propertyForKey:@"diStyle"];
    if(![n isKindOfClass:NSNumber.class] || !diStyleKnown(n.integerValue))return;
    CFPreferencesSetAppValue(CFSTR("SpectrumStyle"),(__bridge CFPropertyListRef)n,CFSTR("com.abgg332.driftisland"));
    CFPreferencesAppSynchronize(CFSTR("com.abgg332.driftisland"));notify_post("com.abgg332.driftisland.fxtune");
    _specifiers=nil;[self reloadSpecifiers];
}
@end
