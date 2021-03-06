
#import "ATChildTask.h"
#import "ATGlobals.h"



////////////////////////////////////////////////////////////////////////////////

static id ATPipeOrFileHandleForWriting(id task, NSPipe *pipe) {
    if ([task isKindOfClass:[NSTask class]])
        return pipe;
    else
        return pipe.fileHandleForWriting;
}

id ATLaunchUnixTaskAndCaptureOutput(NSURL *scriptURL, NSArray *arguments, ATLaunchUnixTaskAndCaptureOutputOptions options, ATLaunchUnixTaskAndCaptureOutputCompletionHandler handler) {
    NSError *error = nil;
    id task;
    if ((options & ATLaunchUnixTaskAndCaptureOutputOptionsIgnoreSandbox) == ATLaunchUnixTaskAndCaptureOutputOptionsIgnoreSandbox) {
        task = [[ATPlainUnixTask alloc] initWithURL:scriptURL error:&error];
    } else {
        task = ATCreateUserUnixTask(scriptURL, &error);
    }
    if (!task) {
        handler(nil, nil, error);
        return nil;
    }

    BOOL merge = !!(options & ATLaunchUnixTaskAndCaptureOutputOptionsMergeStdoutAndStderr);

    ATTaskOutputReader *outputReader = [[ATTaskOutputReader alloc] init];
    [task setStandardOutput:ATPipeOrFileHandleForWriting(task, outputReader.standardOutputPipe)];
    if (merge) {
        [task setStandardError:ATPipeOrFileHandleForWriting(task, outputReader.standardOutputPipe)];
        [outputReader.standardErrorPipe.fileHandleForWriting closeFile];
    } else {
        [task setStandardError:ATPipeOrFileHandleForWriting(task, outputReader.standardErrorPipe)];
    }
    [outputReader startReading];

    [task executeWithArguments:arguments completionHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
//            [outputReader waitForCompletion:^{
            NSString *outputText = outputReader.standardOutputText;
            NSString *stderrText = (merge ? outputText : outputReader.standardErrorText);
            handler(outputText, stderrText, error);
//            }];
        });
    }];
    [outputReader launched];
    return task;
}



////////////////////////////////////////////////////////////////////////////////
#pragma mark -

NSString *ATPlainUnixTaskErrorDomain = @"PlainUnixTask";


id ATCreateUserUnixTask(NSURL *scriptURL, NSError **error) {
    if (ATIsSandboxed()) {
        if (ATIsUserScriptsFolderSupported()) {
            return [[NSUserUnixTask alloc] initWithURL:scriptURL error:error];
        } else {
            if (error)
                *error = [NSError errorWithDomain:ATPlainUnixTaskErrorDomain code:PlainUnixTaskErrSandboxedTasksNotSupportedBefore10_8 userInfo:@{NSURLErrorKey:scriptURL}];
            return nil; // TODO
        }
    } else {
        return [[ATPlainUnixTask alloc] initWithURL:scriptURL error:error];
    }
}


@interface ATPlainUnixTask ()

@property(strong) NSURL *url;

@end


@implementation ATPlainUnixTask

@synthesize url;
@synthesize standardInput;
@synthesize standardOutput;
@synthesize standardError;

- (id)initWithURL:(NSURL *)aUrl error:(NSError **)error {
    self = [super init];
    if (self) {
        self.url = aUrl;
        *error = nil;
    }
    return self;
}

- (void)executeWithArguments:(NSArray *)arguments completionHandler:(PlainUnixTaskCompletionHandler)handler {
    NSTask *task = [[NSTask alloc] init];

    [task setLaunchPath:[url path]];
    [task setArguments:arguments];

    // standard input is required, otherwise everything just hangs
    if (!self.standardInput) {
        NSPipe *fakeInputPipe = [NSPipe pipe];
        [task setStandardInput:fakeInputPipe];
        [fakeInputPipe.fileHandleForWriting closeFile];
    } else {
        [task setStandardInput:self.standardInput];
    }

    [task setStandardOutput:self.standardOutput ?: [NSFileHandle fileHandleWithNullDevice]];
    [task setStandardError:self.standardError ?: [NSFileHandle fileHandleWithNullDevice]];

    task.terminationHandler = ^(NSTask *task) {
        NSError *error = nil;
        if ([task terminationStatus] != 0) {
            error = [NSError errorWithDomain:ATPlainUnixTaskErrorDomain code:PlainUnixTaskErrNonZeroExit userInfo:nil];
        }
        handler(error);
    };

    [task launch];
}

@end



////////////////////////////////////////////////////////////////////////////////
#pragma mark -

@implementation ATTaskOutputReader {
    NSPipe *_standardOutputPipe;
    NSPipe *_standardErrorPipe;

    NSMutableData *_standardOutputData;
    NSMutableData *_standardErrorData;

    BOOL _outputClosed;
    BOOL _errorClosed;

    void (^_completionBlock)();
}

@synthesize standardOutputPipe=_standardOutputPipe;
@synthesize standardOutputData=_standardOutputData;
@synthesize standardErrorPipe=_standardErrorPipe;
@synthesize standardErrorData=_standardErrorData;

- (id)init {
    self = [super init];
    if (self) {
        _standardOutputPipe = [NSPipe pipe];
        _standardErrorPipe = [NSPipe pipe];

        _standardOutputData = [[NSMutableData alloc] init];
        _standardErrorData = [[NSMutableData alloc] init];
    }
    return self;
}

- (id)initWithTask:(id)task {
    self = [self init];
    if (self) {
        Class _NSUserUnixTask = NSClassFromString(@"NSUserUnixTask");
        if (_NSUserUnixTask && [task isKindOfClass:_NSUserUnixTask]) {
            [task setStandardOutput:self.standardOutputPipe.fileHandleForWriting];
            [task setStandardError:self.standardErrorPipe.fileHandleForWriting];
        } else {
            [task setStandardOutput:self.standardOutputPipe];
            [task setStandardError:self.standardErrorPipe];
        }
        [self startReading];
    }
    return self;
}

- (void)launched {
    [_standardOutputPipe.fileHandleForWriting closeFile];
    [_standardErrorPipe.fileHandleForWriting closeFile];
}

- (void)startReading {
    _standardOutputPipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *file) {
        NSData *availableData = [file availableData];
        [_standardOutputData appendData:availableData];
        if ([availableData length] == 0 || _completionBlock != nil) {
            _outputClosed = YES;
            _standardOutputPipe.fileHandleForReading.readabilityHandler = nil;
            [self executeCompletionBlockIfBothChannelsClosed];
        }
    };
    _standardErrorPipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *file) {
        NSData *availableData = [file availableData];
        [_standardErrorData appendData:availableData];
        if ([availableData length] == 0 || _completionBlock != nil) {
            _errorClosed = YES;
            _standardErrorPipe.fileHandleForReading.readabilityHandler = nil;
            [self executeCompletionBlockIfBothChannelsClosed];
        }
    };
//    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(standardOutputNotification:) name:NSFileHandleDataAvailableNotification object:_standardOutputPipe.fileHandleForReading];
//    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(standardErrorNotification:)  name:NSFileHandleDataAvailableNotification object:_standardErrorPipe.fileHandleForReading];
//
//    [_standardOutputPipe.fileHandleForReading waitForDataInBackgroundAndNotify];
//    [_standardErrorPipe.fileHandleForReading waitForDataInBackgroundAndNotify];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)waitForCompletion:(void (^)())completionBlock {
    if (_outputClosed && _errorClosed)
        dispatch_async(dispatch_get_main_queue(), completionBlock);
    else
        _completionBlock = completionBlock;
}

- (void)executeCompletionBlockIfBothChannelsClosed {
    if (_outputClosed && _errorClosed && _completionBlock) {
        dispatch_async(dispatch_get_main_queue(), _completionBlock);
        _completionBlock = nil;
    }
}

- (void)processPendingOutputData {
    if (_outputClosed)
        return;
    NSData *availableData = [_standardOutputPipe.fileHandleForReading availableData];
    [_standardOutputData appendData:availableData];
    if ([availableData length] == 0 || _completionBlock != nil) {
        _outputClosed = YES;
        [self executeCompletionBlockIfBothChannelsClosed];
    }
}

- (void)processPendingErrorData {
    if (_errorClosed)
        return;
    NSData *availableData = [_standardErrorPipe.fileHandleForReading availableData];
    [_standardErrorData appendData:availableData];
    if ([availableData length] == 0 || _completionBlock != nil) {
        _errorClosed = YES;
        [self executeCompletionBlockIfBothChannelsClosed];
    }
}

- (void)processPendingDataAndClosePipes {
    if (_standardOutputPipe) {
//        [self processPendingOutputData];
        _standardOutputPipe = nil;
    }
    if (_standardErrorPipe) {
//        [self processPendingErrorData];
        _standardErrorPipe = nil;
    }
}

-(void)standardOutputNotification:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self processPendingOutputData];

        if (!_outputClosed)
            [_standardOutputPipe.fileHandleForReading waitForDataInBackgroundAndNotify];
    });
}

-(void)standardErrorNotification:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self processPendingErrorData];

        if (!_errorClosed)
            [_standardErrorPipe.fileHandleForReading waitForDataInBackgroundAndNotify];
    });
}

- (NSString *)standardOutputText {
    [self processPendingDataAndClosePipes];
    return [[NSString alloc] initWithData:_standardOutputData encoding:NSUTF8StringEncoding];
}

- (NSString *)standardErrorText {
    [self processPendingDataAndClosePipes];
    return [[NSString alloc] initWithData:_standardErrorData encoding:NSUTF8StringEncoding];
}

- (NSString *)combinedOutputText {
    return [[self standardOutputText] stringByAppendingString:[self standardErrorText]];
}

@end
