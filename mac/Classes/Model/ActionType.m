
#import "ActionType.h"
#import "Action.h"

@implementation ActionType

- (id)initWithClass:(Class)klass {
    self = [super init];
    if (self) {
        _identifier = [[klass typeIdentifier] copy];
        _klass = klass;
    }
    return self;
}

@end
