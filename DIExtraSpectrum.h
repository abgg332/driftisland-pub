#ifndef DI_EXTRA_SPECTRUM_H
#define DI_EXTRA_SPECTRUM_H
#import <UIKit/UIKit.h>
#include <math.h>
/* Original lightweight geometry inspired by public waveform/radial/reflective
   visualizer designs, not third-party shaders. Fixed cost <=64 samples. */
static inline CGFloat diSpectrumValue(CGFloat v){return isfinite(v)?MAX(0,MIN(1,v)):0;}
static inline void diSpectrumRound(CGMutablePathRef p,CGRect r,CGFloat radius){
 if(!isfinite(r.origin.x)||!isfinite(r.origin.y)||!isfinite(r.size.width)||!isfinite(r.size.height)||r.size.width<=0||r.size.height<=0)return;
 radius=MAX(0,MIN(radius,MIN(r.size.width,r.size.height)*.5));
 CGPathAddRoundedRect(p,NULL,r,radius,radius);
}
static inline CGPathRef diExtraSpectrumPath(int style,const CGFloat *v,int n,CGRect box){
 CGMutablePathRef p=CGPathCreateMutable();
 if(!v||n<2||n>64||!isfinite(box.origin.x)||!isfinite(box.origin.y)||!isfinite(box.size.width)||!isfinite(box.size.height)||box.size.width<1||box.size.height<1)return p;
 CGFloat w=box.size.width,h=box.size.height,x=box.origin.x,y=box.origin.y,mid=y+h*.5;
 CGFloat values[64];for(int i=0;i<n;i++)values[i]=diSpectrumValue(v[i]);
 if(style==9||style==10||style==11||style==14||style==15||style==16){
  /* Smooth cubic ribbons: endpoints share tangent, no jagged triangle chain. */
  for(int layer=0;layer<(style==15?3:1);layer++){
   CGFloat dx=w/(n-1),height=(style==10?.86:.43)*h,center=style==10?y+h:mid;
   CGFloat inset=layer*.11*h;
   CGFloat up[64],down[64];
   for(int i=0;i<n;i++){
    CGFloat e=values[i];if(style==9)e=pow(e,.7);
    if(style==16)e*=.55+.45*cos((CGFloat)i/(n-1)*M_PI*4);
    CGFloat extent=MAX(h*.015,e*height-inset);
    up[i]=center-extent;
    down[i]=style==10?y+h:(style==14?center+extent*.25:center+extent);
   }
   CGPathMoveToPoint(p,NULL,x,up[0]);
   for(int i=1;i<n;i++){CGFloat a=x+(i-1)*dx,b=x+i*dx;CGPathAddCurveToPoint(p,NULL,a+dx*.5,up[i-1],b-dx*.5,up[i],b,up[i]);}
   for(int i=n-1;i>0;i--){CGFloat a=x+i*dx,b=x+(i-1)*dx;CGPathAddCurveToPoint(p,NULL,a-dx*.5,down[i],b+dx*.5,down[i-1],b,down[i-1]);}
   CGPathCloseSubpath(p);
  }return p;
 }
 if(style==13||style==17){
  CGFloat cx=x+w*.5,cy=mid,r=MIN(w,h)*.23;
  for(int i=0;i<n;i++){
   CGFloat a=2*M_PI*i/n,extent=values[i]*MIN(w,h)*.22;
   if(style==17){CGFloat rr=r+extent;CGFloat dot=MAX(.4,MIN(w,h)*.018);CGPathAddEllipseInRect(p,NULL,CGRectMake(cx+cos(a)*rr-dot,cy+sin(a)*rr-dot,dot*2,dot*2));}
   else{CGFloat r1=r,r2=r+MAX(.7,extent),t=MIN(w,h)*.014,px=-sin(a)*t,py=cos(a)*t;
    CGPathMoveToPoint(p,NULL,cx+cos(a)*r1+px,cy+sin(a)*r1+py);CGPathAddLineToPoint(p,NULL,cx+cos(a)*r2+px,cy+sin(a)*r2+py);CGPathAddLineToPoint(p,NULL,cx+cos(a)*r2-px,cy+sin(a)*r2-py);CGPathAddLineToPoint(p,NULL,cx+cos(a)*r1-px,cy+sin(a)*r1-py);CGPathCloseSubpath(p);}
  }return p;
 }
 if(style==18){
  /* Bilateral fluid jets, center gap stays open. */
  for(int side=0;side<2;side++){
   CGFloat cx=x+w*.5,dir=side?1:-1;CGPathMoveToPoint(p,NULL,cx+dir*w*.025,mid);
   for(int i=0;i<n;i++){CGFloat t=(CGFloat)i/(n-1),xx=cx+dir*(w*.025+t*w*.475);CGPathAddLineToPoint(p,NULL,xx,mid-values[i]*h*.46*sin(M_PI*t));}
   for(int i=n-1;i>=0;i--){CGFloat t=(CGFloat)i/(n-1),xx=cx+dir*(w*.025+t*w*.475);CGPathAddLineToPoint(p,NULL,xx,mid+values[i]*h*.46*sin(M_PI*t));}CGPathCloseSubpath(p);
  }return p;
 }
 if(style==19){
  /* Open contour ribbons rather than solid mountains. */
  for(int band=0;band<3;band++){
   CGFloat gap=(band+1)*h*.11,dx=w/(n-1);
   CGPathMoveToPoint(p,NULL,x,mid-gap);
   for(int i=0;i<n;i++)CGPathAddLineToPoint(p,NULL,x+i*dx,mid-gap-values[i]*h*.22);
   for(int i=n-1;i>=0;i--)CGPathAddLineToPoint(p,NULL,x+i*dx,mid-gap-values[i]*h*.22+MAX(.6,h*.025));CGPathCloseSubpath(p);
   CGPathMoveToPoint(p,NULL,x,mid+gap);
   for(int i=0;i<n;i++)CGPathAddLineToPoint(p,NULL,x+i*dx,mid+gap+values[i]*h*.22);
   for(int i=n-1;i>=0;i--)CGPathAddLineToPoint(p,NULL,x+i*dx,mid+gap+values[i]*h*.22-MAX(.6,h*.025));CGPathCloseSubpath(p);
  }return p;
 }
 CGFloat dx=w/n;
 for(int i=0;i<n;i++){CGFloat val=values[i],xx=x+(i+.5)*dx,r=MIN(dx*.28,h*.045);
  if(style==12){int count=1+(int)(val*6);for(int j=0;j<count;j++)CGPathAddEllipseInRect(p,NULL,CGRectMake(xx-r,mid+(j-(count-1)*.5)*h/7-r,r*2,r*2));}
  else {CGFloat hh=MAX(.5,val*h*.9);diSpectrumRound(p,CGRectMake(xx-dx*.28,mid-hh/2,dx*.56,hh),dx*.28);}
 }return p;
}
#endif
