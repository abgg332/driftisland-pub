#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <CoreFoundation/CoreFoundation.h>
#import <notify.h>
#import "../DIExtraSpectrum.h"

/* Static thumbnails only: no CADisplayLink, NSTimer, audio input or live canvas. */
@interface DISpectrumStaticController : PSListController
@end
static UIImage *diStaticShape(NSInteger style){
    CGSize size=CGSizeMake(132,54);
    UIGraphicsBeginImageContextWithOptions(size,NO,0);
    CGContextRef ctx=UIGraphicsGetCurrentContext();
    if(!ctx){UIGraphicsEndImageContext();return nil;}
    CGFloat v[24];for(int i=0;i<24;i++)v[i]=.15+.78*fabs(sin(i*.61))*MAX(.3,1-fabs(i-11.5)/16);
    [[UIColor colorWithRed:.61 green:.47 blue:.95 alpha:1] setFill];
    CGRect b=CGRectMake(3,4,126,46);
    if(style>=9){CGPathRef p=diExtraSpectrumPath((int)style,v,24,b);CGContextAddPath(ctx,p);CGContextFillPath(ctx);CGPathRelease(p);}
    else {
        CGFloat dx=b.size.width/24;
        if(style==3){CGContextMoveToPoint(ctx,3,38);for(int i=0;i<24;i++){CGFloat x=3+i*dx,y=38-v[i]*30;CGContextAddLineToPoint(ctx,x,y);CGContextAddLineToPoint(ctx,x+dx,y);}CGContextAddLineToPoint(ctx,85,38);CGContextClosePath(ctx);CGContextFillPath(ctx);}
        else if(style==7){[[UIColor systemPurpleColor]setStroke];for(int i=0;i<24;i++){CGFloat x=3+i*dx,y=38-v[i]*30;if(i)CGContextAddLineToPoint(ctx,x,y);else CGContextMoveToPoint(ctx,x,y);}CGContextSetLineWidth(ctx,1.5);CGContextStrokePath(ctx);}
        else for(int i=0;i<24;i++){
            CGFloat x=3+i*dx,h=v[i]*30,y=38-h,w=2;
            if(style==1){for(int j=0;j<(int)(h/4);j++)CGContextFillRect(ctx,CGRectMake(x,35-j*4,w,2));}
            else if(style==2)CGContextFillRect(ctx,CGRectMake(x,21-h/2,w,h));
            else if(style==5){CGContextMoveToPoint(ctx,x,38);CGContextAddLineToPoint(ctx,x+w/2,y);CGContextAddLineToPoint(ctx,x+w,38);CGContextClosePath(ctx);CGContextFillPath(ctx);}
            else if(style==6){CGContextMoveToPoint(ctx,x,38);CGContextAddLineToPoint(ctx,x+h*.14,y);CGContextAddLineToPoint(ctx,x+h*.14+w,y);CGContextAddLineToPoint(ctx,x+w,38);CGContextClosePath(ctx);CGContextFillPath(ctx);}
            else {CGContextFillRect(ctx,CGRectMake(x,y,w,h));if(style==4)CGContextFillRect(ctx,CGRectMake(x,y-4,w,1));if(style==8)CGContextFillEllipseInRect(ctx,CGRectMake(x,y-6,2,2));}
        }
    }
    UIImage *image=UIGraphicsGetImageFromCurrentImageContext();UIGraphicsEndImageContext();return image;
}
@implementation DISpectrumStaticController
- (NSArray *)specifiers {
    if(!_specifiers){
        NSArray *names=@[@"柱状",@"点阵",@"镜像",@"阶梯",@"峰值",@"尖刺",@"斜切",@"电波",@"气泡",@"流体声带",@"平滑山峦",@"镜像丝带",@"悬浮星阵",@"放射光环",@"不对称声纹",@"层叠流体",@"干涉波带",@"轨道星环",@"双向喷流",@"等高线波纹"];
        NSMutableArray *rows=[NSMutableArray array];
        PSSpecifier *group=[PSSpecifier preferenceSpecifierNamed:@"静态形状图 · 点选应用" target:nil set:NULL get:NULL detail:nil cell:PSGroupCell edit:nil];
        [group setProperty:@"图示为固定信号下的形状示意，不播放动画、不采集音频。选中后到播放器查看实际音乐效果。" forKey:@"footerText"];[rows addObject:group];
        id saved=CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("SpectrumStyle"),CFSTR("com.abgg332.driftisland")));
        NSInteger selected=saved?[saved integerValue]:0;
        for(NSUInteger i=0;i<names.count;i++){
            NSString *title=[NSString stringWithFormat:@"%@%@",i==selected?@"✓  ":@"",names[i]];
            PSSpecifier *sp=[PSSpecifier preferenceSpecifierNamed:title target:self set:NULL get:NULL detail:nil cell:PSButtonCell edit:nil];
            [sp setProperty:@(i) forKey:@"diStyle"];
            UIImage *icon=diStaticShape(i);if(icon)[sp setProperty:icon forKey:@"iconImage"];
            [sp setButtonAction:@selector(selectStyle:)];[rows addObject:sp];
        }
        _specifiers=rows;
    }return _specifiers;
}
- (void)selectStyle:(PSSpecifier *)sp {
    NSNumber *n=[sp propertyForKey:@"diStyle"];
    if(!n || n.integerValue<0 || n.integerValue>19)return;
    CFPreferencesSetAppValue(CFSTR("SpectrumStyle"),(__bridge CFPropertyListRef)n,CFSTR("com.abgg332.driftisland"));
    CFPreferencesAppSynchronize(CFSTR("com.abgg332.driftisland"));notify_post("com.abgg332.driftisland.fxtune");
    _specifiers=nil;[self reloadSpecifiers];
}
@end
