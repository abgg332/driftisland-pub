#ifndef DI_EXTRA_SPECTRUM_H
#define DI_EXTRA_SPECTRUM_H
#import <UIKit/UIKit.h>
#include <math.h>
static inline CGPathRef diExtraSpectrumPath(int style,const CGFloat *v,int n,CGRect box){
 CGMutablePathRef p=CGPathCreateMutable(); if(n<2)return p;
 CGFloat w=box.size.width,h=box.size.height,x=box.origin.x,y=box.origin.y,mid=y+h/2,dx=w/n;
 if(style==13){
  CGFloat r=MIN(w,h)*.22;CGPoint c=CGPointMake(x+w/2,mid);
  for(int i=0;i<n;i++){CGFloat a=i*2*M_PI/n,r2=r+v[i]*MIN(w,h)*.25;
   CGPoint a0=CGPointMake(c.x+cos(a)*r,c.y+sin(a)*r),b=CGPointMake(c.x+cos(a)*r2,c.y+sin(a)*r2);
   CGFloat t=MAX(.7,MIN(w,h)*.018);CGPathAddRoundedRect(p,NULL,CGRectMake(b.x-t,b.y-t,2*t,2*t),t,t);
   CGFloat px=-sin(a)*t*.5,py=cos(a)*t*.5;
   CGPathMoveToPoint(p,NULL,a0.x+px,a0.y+py);CGPathAddLineToPoint(p,NULL,b.x+px,b.y+py);
   CGPathAddLineToPoint(p,NULL,b.x-px,b.y-py);CGPathAddLineToPoint(p,NULL,a0.x-px,a0.y-py);CGPathCloseSubpath(p);
  } return p;
 }
 if(style==10||style==11){
  CGPathMoveToPoint(p,NULL,x,style==11?mid:y+h);
  for(int i=0;i<n;i++)CGPathAddLineToPoint(p,NULL,x+(i+.5)*dx,(style==11?mid:y+h)-v[i]*h*(style==11?.48:1));
  for(int i=n-1;i>=0;i--)CGPathAddLineToPoint(p,NULL,x+(i+.5)*dx,style==11?mid+v[i]*h*.48:y+h);
  CGPathCloseSubpath(p);return p;
 }
 for(int i=0;i<n;i++){
  CGFloat value=MAX(.03,MIN(1,v[i])),bw=MAX(.6,dx*.58),xx=x+(i+.5)*dx-bw/2;
  if(style==12){int count=(int)(value*8)+1;CGFloat r=MIN(dx*.28,h/20);
   for(int j=0;j<count;j++)CGPathAddEllipseInRect(p,NULL,CGRectMake(xx,mid-r+(j-count*.5)*h/9,2*r,2*r));
  }else if(style==14){CGFloat hh=value*h*.43;
   CGPathAddRoundedRect(p,NULL,CGRectMake(xx,mid-h*.06-hh,bw,hh),bw/2,bw/2);
   CGPathAddRoundedRect(p,NULL,CGRectMake(xx,mid+h*.06,bw,hh),bw/2,bw/2);
  }else{CGFloat hh=MAX(bw,value*h);CGPathAddRoundedRect(p,NULL,CGRectMake(xx,mid-hh/2,bw,hh),MIN(bw/2,hh/2),MIN(bw/2,hh/2));}
 }return p;
}
#endif
