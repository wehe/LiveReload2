
#import "Action.h"


@implementation Action {
    NSMutableDictionary *_memento;
}

+ (NSString *)typeIdentifier {
    abort();
}

- (NSString *)typeIdentifier {
    return [[self class] typeIdentifier];
}

- (id)initWithMemento:(NSDictionary *)memento {
    self = [super init];
    if (self) {
        [self setMemento:memento];
    }
    return self;
}

- (NSDictionary *)memento {
    [self updateMemento:_memento];
    return _memento;
}

- (void)setMemento:(NSDictionary *)memento {
    _memento = [(memento ?: @{}) mutableCopy];
    [self loadFromMemento:_memento];
}

- (void)loadFromMemento:(NSDictionary *)memento {
    self.enabled = [(memento[@"enabled"] ?: @YES) boolValue];
}

- (void)updateMemento:(NSMutableDictionary *)memento {
    memento[@"action"] = self.typeIdentifier;
    memento[@"enabled"] = (self.enabled ? @1 : @0);
}

- (void)setEnabled:(BOOL)enabled {
    if (_enabled != enabled) {
        _enabled = enabled;
        [[NSNotificationCenter defaultCenter] postNotificationName:@"SomethingChanged" object:self];
    }
}

- (BOOL)isNonEmpty {
    return YES;
}

- (void)invokeForProjectAtPath:(NSString *)projectPath withModifiedFiles:(NSSet *)paths completionHandler:(UserScriptCompletionHandler)completionHandler {
    abort();
}

@end
