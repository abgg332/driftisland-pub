#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <CoreFoundation/CoreFoundation.h>
#import <notify.h>
#include <math.h>


/* Static thumbnails only: no CADisplayLink, NSTimer, audio input or live canvas. */
@interface DISpectrumStaticController : PSListController
@end

/* 3.0.114: 14 种 —— 原有六种 + 萤火/星轨/胶囊/霓虹/双子 + 声呐/波浪/雨帘。
   3.0.111 新增的 绸带/山峦/脉冲/阶梯 已按用户要求删除。 */
static const NSInteger diStyleIDs[14] = { 0, 1, 2, 4, 5, 6, 10, 14, 15, 16, 17, 18, 19, 20 };

static BOOL diStyleKnown(NSInteger s) {
    for (int i = 0; i < 14; i++) if (diStyleIDs[i] == s) return YES;
    return NO;
}

/* 缩略图用的圆角矩形填充 */
static void diPrevRound(CGContextRef ctx, CGRect r, CGFloat rr) {
    CGPathRef p = CGPathCreateWithRoundedRect(r, rr, rr, NULL);
    CGContextAddPath(ctx, p);
    CGContextFillPath(ctx);
    CGPathRelease(p);
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
            else if(style==15){                  /* 胶囊: 圆头竖条 */
                CGFloat cw=w*1.30f, cx2=x+w*0.5f, hh=MAX(2.0f,h);
                diPrevRound(ctx,CGRectMake(cx2-cw*0.5f,38-hh,cw,hh),MIN(cw*0.5f,hh*0.5f));
            }
            else if(style==16){                  /* 霓虹: 空心管 + 亮芯 */
                CGFloat cw=w*1.15f, cx2=x+w*0.5f, hh=MAX(5.0f,h);
                CGFloat t=MAX(0.9f,cw*0.26f), xl=cx2-cw*0.5f, yt=38-hh;
                diPrevRound(ctx,CGRectMake(xl,yt,cw,t),0.6f);
                diPrevRound(ctx,CGRectMake(xl,38-t,cw,t),0.6f);
                diPrevRound(ctx,CGRectMake(xl,yt,t,hh),0.6f);
                diPrevRound(ctx,CGRectMake(xl+cw-t,yt,t,hh),0.6f);
                CGFloat ch=hh*0.42f;
                diPrevRound(ctx,CGRectMake(cx2-t*0.32f,38-ch,t*0.64f,ch),0.4f);
            }
            else if(style==17){                  /* 双子: 主副两根 */
                CGFloat cw=MAX(0.9f,w*0.44f), cx2=x+w*0.5f, hh=MAX(2.0f,h);
                diPrevRound(ctx,CGRectMake(cx2-cw-0.35f,38-hh,cw,hh),MIN(cw*0.5f,1.2f));
                diPrevRound(ctx,CGRectMake(cx2+0.35f,38-hh*0.55f,cw,MAX(1.4f,hh*0.55f)),MIN(cw*0.5f,1.0f));
            }
            else if(style==18){                  /* 声呐: 绕圈扇段 */
                CGFloat cx2=x+w*0.5f, cy=27, baseR=16.0f;
                CGFloat stepA=(CGFloat)(M_PI*2.0)/24.0f;
                CGFloat a0=(CGFloat)(-M_PI_2)+i*stepA+stepA*0.10f;
                CGFloat a1=a0+stepA*0.78f;
                CGFloat r1=baseR*(1.10f+0.80f*v[i]);
                const int seg=4;
                CGContextMoveToPoint(ctx,cx2+cosf(a0)*baseR,cy+sinf(a0)*baseR);
                for(int k=1;k<=seg;k++){CGFloat a=a0+(a1-a0)*k/seg;CGContextAddLineToPoint(ctx,cx2+cosf(a)*baseR,cy+sinf(a)*baseR);}
                for(int k=seg;k>=0;k--){CGFloat a=a0+(a1-a0)*k/seg;CGContextAddLineToPoint(ctx,cx2+cosf(a)*r1,cy+sinf(a)*r1);}
                CGContextClosePath(ctx);CGContextFillPath(ctx);
            }
            else if(style==19){ /* 波浪: 循环后整条画, 这里跳过 */ }
            else if(style==20){                  /* 雨帘: 从顶垂下 */
                diPrevRound(ctx,CGRectMake(x,4,w,MAX(3.0f,h)),w*0.5f);
            }
            else {CGContextFillRect(ctx,CGRectMake(x,y,w,h));}
        }
        if(style==19){                       /* 波浪: 整条平滑波带 */
            CGFloat thick=6.0f, amp=22.0f, baseY=32.0f;
            CGFloat px=3.0f, py=baseY-v[0]*amp;
            CGContextMoveToPoint(ctx,px,py);
            for(int i=1;i<24;i++){
                CGFloat x2=3+i*dx, y2=baseY-v[i]*amp;
                CGFloat mx2=(px+x2)*0.5f, my2=(py+y2)*0.5f;
                CGContextAddQuadCurveToPoint(ctx,px,py,mx2,my2);
                px=x2; py=y2;
            }
            CGContextAddLineToPoint(ctx,px,py);
            CGContextAddLineToPoint(ctx,px,py+thick);
            for(int i=23;i>=1;i--){
                CGFloat x1=3+(i-1)*dx, y1=baseY-v[i-1]*amp+thick;
                CGFloat mx2=(3+i*dx+x1)*0.5f, my2=(baseY-v[i]*amp+thick+y1)*0.5f;
                CGContextAddQuadCurveToPoint(ctx,3+i*dx+0.01f,baseY-v[i]*amp+thick,mx2,my2);
            }
            CGContextAddLineToPoint(ctx,3.0f,baseY-v[0]*amp+thick);
            CGContextClosePath(ctx);
            CGContextFillPath(ctx);
        }
    }
    UIImage *image=UIGraphicsGetImageFromCurrentImageContext();UIGraphicsEndImageContext();return image;
}
@implementation DISpectrumStaticController
- (NSArray *)specifiers {
    if(!_specifiers){
        NSArray *names=@[@"柱状",@"点阵",@"镜像",@"峰值",@"尖刺",@"斜切",
                         @"萤火",@"星轨",@"胶囊",@"霓虹",@"双子",
                         @"声呐",@"波浪",@"雨帘"];
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
