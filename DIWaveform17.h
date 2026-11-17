/* iOS17 system waveform adapter. Hook ABI confirmed against reference runtime
   0x50fc (float samples*, NSUInteger count, float sampleRate, id settings),
   0x51c8 (NSArray amplitudes). Normalization/remap below is an adaptation,
   NOT a byte-for-byte reconstruction of reference 0x5440 or 0x2f3cc. */
#import <os/lock.h>
static os_unfair_lock diW17Lock=OS_UNFAIR_LOCK_INIT;
static float diW17Peak[64],diW17Previous=0;
static int diW17Tokens[8],diW17Meta=-1,diW17Demand=-1;
static uint64_t diW17Sequence=0,diW17ReadSeq=0;
static CFTimeInterval diW17Published=0,diW17ReadAt=0;
static BOOL diW17Ready=NO;
static float diW17Energy=0;
static BOOL diW17InitChannel(void){
 static dispatch_once_t once;
 dispatch_once(&once,^{
  BOOL ok=YES;
  for(int i=0;i<8;i++){NSString *n=[NSString stringWithFormat:@"com.abgg332.driftisland.wave17.b%d",i];if(notify_register_check(n.UTF8String,&diW17Tokens[i])!=NOTIFY_STATUS_OK)ok=NO;}
  if(notify_register_check("com.abgg332.driftisland.wave17.meta",&diW17Meta)!=NOTIFY_STATUS_OK)ok=NO;
  if(notify_register_check("com.abgg332.driftisland.wave17.demand",&diW17Demand)!=NOTIFY_STATUS_OK)ok=NO;
  diW17Ready=ok;
 });return diW17Ready;
}
static void diW17Publish(const float *samples,NSUInteger count){
 if(!samples || count<2 || !diW17InitChannel())return;
 uint64_t demand=0;notify_get_state(diW17Demand,&demand);
 uint64_t nowMS=(uint64_t)(CACurrentMediaTime()*1000);
 if(!demand || nowMS<demand || nowMS-demand>1500)return;
 os_unfair_lock_lock(&diW17Lock);
 CFTimeInterval now=CACurrentMediaTime();
 if(now-diW17Published<1.0/60){os_unfair_lock_unlock(&diW17Lock);return;}
 diW17Published=now;count=MIN(count,(NSUInteger)512);
 float bands[64]={},sum=0;
 for(int b=0;b<64;b++){
  NSUInteger lo=b*count/64,hi=MAX(lo+1,(b+1)*count/64);hi=MIN(hi,count);
  float pk=0;
  for(NSUInteger j=lo;j<hi;j++){float v=samples[j];if(isfinite(v))pk=fmaxf(pk,fabsf(v));}
  diW17Peak[b]=fmaxf(pk,diW17Peak[b]*0.985f);
  bands[b]=fminf(1,pk/fmaxf(.001f,diW17Peak[b]));sum+=bands[b];
 }
 // Separate source energy: maintain its own envelope; not the rendered 72-band mean.
 float e=sum/64;diW17Previous+= (e-diW17Previous)*(e>diW17Previous?.72f:.20f);
 for(int b=0;b<8;b++){
  uint64_t value=0;for(int j=0;j<8;j++)value|=(uint64_t)lrintf(bands[b*8+j]*255)<<(8*j);
  notify_set_state(diW17Tokens[b],value);
 }
 uint64_t meta=(++diW17Sequence & 0x00ffffffffffffffULL)|((uint64_t)lrintf(diW17Previous*255)<<56);
 notify_set_state(diW17Meta,meta);
 os_unfair_lock_unlock(&diW17Lock);
}
static id (*diW17InitOrig)(id,SEL,const float *,NSUInteger,float,id)=NULL;
static void (*diW17AmpOrig)(id,SEL,id)=NULL;
static id diW17Init(id self,SEL cmd,const float *data,NSUInteger count,float rate,id settings){
 diW17Publish(data,count);return diW17InitOrig(self,cmd,data,count,rate,settings);
}
static void diW17Amplitudes(id self,SEL cmd,id values){
 diW17AmpOrig(self,cmd,values);
 if(![values isKindOfClass:NSArray.class])return;
 float buffer[512];NSUInteger n=MIN((NSUInteger)512,[values count]);
 for(NSUInteger i=0;i<n;i++){id v=values[i];buffer[i]=[v respondsToSelector:@selector(floatValue)]?[v floatValue]:0;}
 diW17Publish(buffer,n);
}
static BOOL diW17Arg(Method m,unsigned i,const char *expected){
 char *t=method_copyArgumentType(m,i);BOOL ok=t && strcmp(t,expected)==0;if(t)free(t);return ok;
}
static void diW17Install(void){
 if(NSProcessInfo.processInfo.operatingSystemVersion.majorVersion<17)return;
 Class cls=NSClassFromString(@"MRUWaveformData");if(!cls)return;
 static BOOL initDone=NO,ampDone=NO;
 SEL init=NSSelectorFromString(@"initWithFFTSamples:count:sampleRate:settings:");Method m=class_getInstanceMethod(cls,init);
 if(!initDone && m && method_getNumberOfArguments(m)==6 && diW17Arg(m,2,"^f") && diW17Arg(m,3,"Q") && diW17Arg(m,4,"f") && diW17Arg(m,5,"@")){
  MSHookMessageEx(cls,init,(IMP)diW17Init,(IMP *)&diW17InitOrig);initDone=YES;
 }
 SEL amp=NSSelectorFromString(@"setAmplitudes:");m=class_getInstanceMethod(cls,amp);
 if(!ampDone && m && method_getNumberOfArguments(m)==3 && diW17Arg(m,2,"@")){
  MSHookMessageEx(cls,amp,(IMP)diW17Amplitudes,(IMP *)&diW17AmpOrig);ampDone=YES;
 }
}
static BOOL diW17Read(float *out,float *energy){
 if(NSProcessInfo.processInfo.operatingSystemVersion.majorVersion<17 || !diW17InitChannel())return NO;
 CFTimeInterval now=CACurrentMediaTime();
 notify_set_state(diW17Demand,(uint64_t)(now*1000));diW17Install();
 uint64_t a=0,b=0;notify_get_state(diW17Meta,&a);uint64_t seq=a&0x00ffffffffffffffULL;
 if(!seq)return NO;
 float raw[64];
 for(int i=0;i<8;i++){uint64_t v=0;notify_get_state(diW17Tokens[i],&v);for(int j=0;j<8;j++)raw[i*8+j]=((v>>(j*8))&255)/255.0f;}
 notify_get_state(diW17Meta,&b);if(a!=b)return NO;
 if(seq!=diW17ReadSeq){diW17ReadSeq=seq;diW17ReadAt=now;}
 if(now-diW17ReadAt>.8)return NO;
 for(int i=0;i<72;i++){
  float pos=i*63.0f/71;int lo=(int)pos,hi=MIN(63,lo+1);float t=pos-lo;
  out[i]=raw[lo]*(1-t)+raw[hi]*t;
 }
 *energy=(a>>56)/255.0f;return YES;
}
__attribute__((constructor)) static void diW17Start(void){
 if(NSProcessInfo.processInfo.operatingSystemVersion.majorVersion<17)return;
 dispatch_async(dispatch_get_main_queue(),^{diW17Install();
  const int retries[]={2,5,15,30,60}; for(int sec:retries)dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)sec*NSEC_PER_SEC),dispatch_get_main_queue(),^{diW17Install();});
 });
}
