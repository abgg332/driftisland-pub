/* 3.1.27: mirror only geometric animations of the exact host container.
 * CA performs interpolation in the render server, not via delayed presentation
 * sampling on SpringBoard's main thread. No system layer hook or swizzling.
 */
static id diBGValue327(id value,NSString *key,NSInteger kind,CGFloat pixel){
    if(!value)return nil;
    if([key isEqualToString:@"bounds"]){
        if(![value isKindOfClass:NSValue.class] || strcmp([value objCType],@encode(CGRect)))return nil;
        CGRect b=[value CGRectValue];
        if(kind==2)return @(MIN(b.size.width,b.size.height)*.5);
        if(kind==1)b=CGRectMake(0,0,b.size.width+2*pixel,b.size.height+2*pixel);
        return [NSValue valueWithCGRect:b];
    }
    if([key isEqualToString:@"bounds.size"]){
        if(![value isKindOfClass:NSValue.class] || strcmp([value objCType],@encode(CGSize)))return nil;
        CGSize b=[value CGSizeValue];
        if(kind==2)return @(MIN(b.width,b.height)*.5);
        if(kind==1){b.width+=2*pixel;b.height+=2*pixel;}
        return [NSValue valueWithCGSize:b];
    }
    if([key isEqualToString:@"bounds.size.width"] || [key isEqualToString:@"bounds.size.height"]){
        if(![value isKindOfClass:NSNumber.class] || kind==2)return nil;
        return @([value doubleValue]+(kind==1?2*pixel:0));
    }
    if([key isEqualToString:@"cornerRadius"] && kind==0)return value;
    return nil;
}
static CAAnimation *diBGAnimation327(CAAnimation *source,NSInteger kind,CGFloat pixel,BOOL *hasBounds,int depth){
    if(!source || depth>6)return nil;
    if([source isKindOfClass:CAAnimationGroup.class]){
        NSMutableArray *parts=[NSMutableArray array];
        for(CAAnimation *child in ((CAAnimationGroup *)source).animations){CAAnimation *a=diBGAnimation327(child,kind,pixel,hasBounds,depth+1);if(a)[parts addObject:a];}
        if(!parts.count)return nil;
        CAAnimationGroup *group=[source copy];group.animations=parts;group.delegate=nil;return group;
    }
    if(![source isKindOfClass:CAPropertyAnimation.class])return nil;
    CAPropertyAnimation *prop=(CAPropertyAnimation *)source;
    NSString *key=prop.keyPath;
    if(prop.additive || prop.cumulative)return nil;
    if(![key isEqualToString:@"bounds"] && ![key hasPrefix:@"bounds.size"] && ![key isEqualToString:@"cornerRadius"])return nil;
    if(kind!=0 && [key isEqualToString:@"cornerRadius"])return nil;
    if(kind==2 && ![key isEqualToString:@"bounds"] && ![key isEqualToString:@"bounds.size"])return nil;
    CAPropertyAnimation *copy=[prop copy];copy.delegate=nil;
    if([source isKindOfClass:CABasicAnimation.class]){
        CABasicAnimation *a=(CABasicAnimation *)source,*b=(CABasicAnimation *)copy;
        // Require explicit endpoints; never invent a curve or guess an additive delta.
        id from=diBGValue327(a.fromValue,key,kind,pixel),to=diBGValue327(a.toValue,key,kind,pixel);
        if(!from || !to || a.byValue)return nil;
        b.fromValue=from;b.toValue=to;b.byValue=nil;
    }else if([source isKindOfClass:CAKeyframeAnimation.class]){
        CAKeyframeAnimation *a=(CAKeyframeAnimation *)source,*b=(CAKeyframeAnimation *)copy;
        if(a.path || !a.values.count)return nil;
        NSMutableArray *values=[NSMutableArray array];
        for(id v in a.values){id q=diBGValue327(v,key,kind,pixel);if(!q)return nil;[values addObject:q];}
        b.values=values;
    }else return nil;
    if(kind==2)copy.keyPath=@"cornerRadius";
    if([key hasPrefix:@"bounds"] && kind!=2)*hasBounds=YES;
    return copy;
}
static NSString *diBGSignature327(CAAnimation *a,int depth){
    if(depth>6)return @"depth";
    NSMutableString *s=[NSMutableString stringWithFormat:@"%@/%.9f/%.9f/%.6f/%.6f/%@/%d/%d/%@",NSStringFromClass(a.class),a.beginTime,a.duration,a.speed,a.timeOffset,a.timingFunction,a.autoreverses,a.removedOnCompletion,a.fillMode];
    if([a isKindOfClass:CAAnimationGroup.class])for(CAAnimation *child in ((CAAnimationGroup *)a).animations)[s appendString:diBGSignature327(child,depth+1)];
    if([a isKindOfClass:CAPropertyAnimation.class])[s appendString:((CAPropertyAnimation *)a).keyPath?:@""];
    if([a isKindOfClass:CABasicAnimation.class]){CABasicAnimation *b=(CABasicAnimation *)a;[s appendFormat:@"/%@/%@/%@",b.fromValue,b.toValue,b.byValue];}
    if([a isKindOfClass:CAKeyframeAnimation.class]){CAKeyframeAnimation *b=(CAKeyframeAnimation *)a;[s appendFormat:@"/%@/%@/%@",b.values,b.keyTimes,b.timingFunctions];}
    if([a isKindOfClass:CASpringAnimation.class]){CASpringAnimation *b=(CASpringAnimation *)a;[s appendFormat:@"/%.8f/%.8f/%.8f/%.8f",b.mass,b.stiffness,b.damping,b.initialVelocity];}
    return s;
}
