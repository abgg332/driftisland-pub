static BOOL pnp31KeyOn(void) {
    static NSString *cache = nil;
    static CFTimeInterval ts = 0;
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (cache && now - ts < 2.0) return [cache isEqualToString:@"3x1"];
    NSString *cur = nil;
    id sz = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("Size"),
                                                       CFSTR("com.local.playerexact")));
    if ([sz isKindOfClass:NSString.class] && [(NSString *)sz length]) cur = sz;
    if (!cur.length) {
        id d = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("ModuleSizes"),
                                                          CFSTR("com.local.playerexact")));
        if ([d isKindOfClass:NSDictionary.class]) {
            id s = ((NSDictionary *)d)[@"com.apple.mediaremote.controlcenter.nowplaying"];
            if ([s isKindOfClass:NSString.class]) cur = s;
        }
    }
    if (!cur.length) {
        id v = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("PlayerGridVariant"),
                                                          CFSTR("com.local.playerexact")));
        if ([v isKindOfClass:NSString.class] && [(NSString *)v length]) cur = v;
    }
    cache = cur ?: @"";
    ts = now;
    return [cache isEqualToString:@"3x1"];
}

/* 3.0.120: NP runtime verified at 0xa974/0xa99c/0xa9c4 (arm64).
   Layout is allocated as three columns, not a late setFrame visual crop. */
typedef struct { NSUInteger width,height; } PNP31LayoutSize;
static id (*pnp31SettingsOrig)(id,SEL,NSString *,PNP31LayoutSize);
static id (*pnp31SizesOrig)(id,SEL,id,id,NSInteger);
static id (*pnp31InstanceOrig)(id,SEL,id,id,PNP31LayoutSize);
static BOOL pnp31SettingsInstalled=NO,pnp31SizesInstalled=NO,pnp31InstanceInstalled=NO;
static NSString *const pnp31ModuleID=@"com.apple.mediaremote.controlcenter.nowplaying";
static BOOL pnp31SizeABI(Method m,unsigned argument) {
    if(!m)return NO;
    char *type=method_copyArgumentType(m,argument);
    BOOL ok=NO;
    if(type && type[0]=='{' && strstr(type,"=QQ}")){
        NSUInteger size=0;NSGetSizeAndAlignment(type,&size,NULL);ok=size==sizeof(PNP31LayoutSize);
    }
    if(type)free(type);return ok;
}
static id pnp31Settings(id self,SEL cmd,NSString *identifier,PNP31LayoutSize prototype){
    if(!pnp31KeyOn() || ![identifier isEqualToString:pnp31ModuleID])return pnp31SettingsOrig(self,cmd,identifier,prototype);
    Class cls=NSClassFromString(@"CCUIModuleSettings");SEL init=NSSelectorFromString(@"initWithPortraitLayoutSize:landscapeLayoutSize:");
    Method method=class_getInstanceMethod(cls,init);
    if(pnp31SizeABI(method,2)&&pnp31SizeABI(method,3)){
        PNP31LayoutSize size={3,1};
        id value=((id(*)(id,SEL,PNP31LayoutSize,PNP31LayoutSize))objc_msgSend)([cls alloc],init,size,size);
        if(value){static int logs=0;if(logs++<4)PNPLog(@"[3x1][真实占位] settings portrait=3x1 landscape=3x1");return value;}
    }
    PNPLog(@"[3x1][真实占位] settings ABI不匹配，保留系统返回");
    return pnp31SettingsOrig(self,cmd,identifier,prototype);
}
static id pnp31Sizes(id self,SEL cmd,id identifiers,id instances,NSInteger orientation){
    id original=pnp31SizesOrig(self,cmd,identifiers,instances,orientation);
    if(!pnp31KeyOn() || ![identifiers isKindOfClass:NSArray.class] || ![original isKindOfClass:NSArray.class])return original;
    NSUInteger index=[identifiers indexOfObject:pnp31ModuleID];
    if(index==NSNotFound || index>=[original count])return original;
    SEL factory=NSSelectorFromString(@"ccui_valueWithLayoutSize:");
    Method method=class_getClassMethod(NSValue.class,factory);
    if(!pnp31SizeABI(method,2))return original;
    PNP31LayoutSize size={3,1};
    id value=((id(*)(id,SEL,PNP31LayoutSize))objc_msgSend)(NSValue.class,factory,size);
    if(!value)return original;
    NSMutableArray *result=[original mutableCopy];result[index]=value;
    static int logs=0;if(logs++<8)PNPLog(@"[3x1][真实占位] collection index=%lu orientation=%ld →3x1",(unsigned long)index,(long)orientation);
    return result;
}
static id pnp31Instance(id self,SEL cmd,id metadata,id module,PNP31LayoutSize prototype){
    SEL selector=NSSelectorFromString(@"moduleIdentifier");
    id identifier=[metadata respondsToSelector:selector]?((id(*)(id,SEL))objc_msgSend)(metadata,selector):nil;
    if(pnp31KeyOn() && [identifier isEqual:pnp31ModuleID])prototype=(PNP31LayoutSize){3,1};
    return pnp31InstanceOrig(self,cmd,metadata,module,prototype);
}
static void pnp31Install(void){
    Class manager=NSClassFromString(@"CCUIModuleSettingsManager");
    SEL settings=NSSelectorFromString(@"moduleSettingsForModuleIdentifier:prototypeSize:");
    if(!pnp31SettingsInstalled && pnp31SizeABI(class_getInstanceMethod(manager,settings),3)){
        MSHookMessageEx(manager,settings,(IMP)pnp31Settings,(IMP *)&pnp31SettingsOrig);pnp31SettingsInstalled=YES;
    }
    Class collection=NSClassFromString(@"CCUIModuleCollectionViewController");
    SEL sizes=NSSelectorFromString(@"_sizesForModuleIdentifiers:moduleInstanceByIdentifier:interfaceOrientation:");
    Method method=class_getInstanceMethod(collection,sizes);
    if(!pnp31SizesInstalled && method && method_getNumberOfArguments(method)==5){
        char ret[64]={},orient[64]={};method_getReturnType(method,ret,sizeof(ret));method_getArgumentType(method,4,orient,sizeof(orient));
        if(ret[0]=='@' && (orient[0]=='q'||orient[0]=='Q')){
            MSHookMessageEx(collection,sizes,(IMP)pnp31Sizes,(IMP *)&pnp31SizesOrig);pnp31SizesInstalled=YES;
        }
    }
    Class instance=NSClassFromString(@"CCUIModuleInstance");
    SEL init=NSSelectorFromString(@"initWithMetadata:module:prototypeModuleSize:");
    if(!pnp31InstanceInstalled && pnp31SizeABI(class_getInstanceMethod(instance,init),4)){
        MSHookMessageEx(instance,init,(IMP)pnp31Instance,(IMP *)&pnp31InstanceOrig);pnp31InstanceInstalled=YES;
    }
    static int logs=0;if(logs++<5)PNPLog(@"[3x1][真实占位] hooks settings=%d collection=%d instance=%d；无setFrame裁窄",pnp31SettingsInstalled,pnp31SizesInstalled,pnp31InstanceInstalled);
}

