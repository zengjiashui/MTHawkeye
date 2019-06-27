//
// Copyright (c) 2008-present, Meitu, Inc.
// All rights reserved.
//
// This source code is licensed under the license found in the LICENSE file in
// the root directory of this source tree.
//
// Created on: 2019/6/14
// Created by: David.Dai
//

#import "MTHANRDetectThread.h"

#import <MTHawkeye/MTHawkeyeAppStat.h>
#import <MTHawkeye/MTHawkeyeDyldImagesUtils.h>
#import <MTHawkeye/MTHawkeyeLogMacros.h>
#import <MTHawkeye/mth_stack_backtrace.h>
#import <pthread.h>

#define MTHANRTRACE_MAXSTACKCOUNT 50

@interface MTHANRDetectThread ()
@property (nonatomic, assign) float perStackIntervalInMillSecond;
@property (nonatomic, assign) CFRunLoopObserverRef observerRef;
@property (atomic, assign) BOOL runloopWorking;
@property (atomic, assign) CFAbsoluteTime runloopCycleStartTime;
@property (atomic, assign) UIApplicationState appState;
@property (nonatomic, assign) CFAbsoluteTime anrStartTime;
@property (nonatomic, strong) NSMutableArray<MTHANRRecordRaw *> *threadStacks;
@end

@implementation MTHANRDetectThread

- (instancetype)init {
    (self = [super init]);
    if (self) {
        self.shouldCaptureBackTrace = YES;
        self.detectInterval = 0.1f;
        self.anrThreshold = 0.4f;
        self.perStackIntervalInMillSecond = 50;
        self.name = @"com.meitu.hawkeye.anr.observer";
        self.threadStacks = [NSMutableArray array];
    }
    return self;
}

- (void)startWithDetectInterval:(float)detectInterval anrThreshold:(float)anrThreshold handler:(MTHANRThreadResultBlock)threadResultBlock {
    self.threadResultBlock = threadResultBlock;
    self.detectInterval = detectInterval;
    self.anrThreshold = anrThreshold;
    self.runloopCycleStartTime = CFAbsoluteTimeGetCurrent();
    [self start];
}

#pragma mark - Thread Work
- (void)start {
    [self registerObserver];
    [self registerNotification];
    [super start];
}

- (void)cancel {
    [super cancel];
    [self unregisterObserver];
    [self unregisterNotification];
    [self.threadStacks removeAllObjects];
}

- (void)main {
    __block thread_t main_thread;
    dispatch_sync(dispatch_get_main_queue(), ^(void) {
        main_thread = mach_thread_self();
    });

    while (self.isCancelled == false) {
        CFAbsoluteTime current = CFAbsoluteTimeGetCurrent();
        CFAbsoluteTime runloopCycleStartTime = self.runloopCycleStartTime;
        float diff = current - runloopCycleStartTime;
        BOOL anrDetected = NO;
        if (diff >= self.anrThreshold && current > runloopCycleStartTime) {
            // may mistake when app enter background
            if (self.appState == UIApplicationStateBackground) {
                continue;
            }

            anrDetected = YES;
            [self.threadStacks addObject:[self recordThreadStack:main_thread]];
        }

        if (anrDetected || self.anrStartTime != 0) {
            self.anrStartTime = self.anrStartTime == 0 ? runloopCycleStartTime : self.anrStartTime;

            // ANR is happening, wait for next normal one to report
            if (self.anrStartTime == runloopCycleStartTime) {
                usleep(self.detectInterval * 1000 * 1000 + (self.threadStacks.count - 1) * self.perStackIntervalInMillSecond * 1000);
                continue;
            }

            if (self.shouldCaptureBackTrace && self.threadResultBlock) {
                MTHANRRecord *record = [[MTHANRRecord alloc] init];
                record.rawRecords = [NSArray arrayWithArray:self.threadStacks];
                record.duration = runloopCycleStartTime - self.anrStartTime;
                self.threadResultBlock(record);
            }

            MTHLogWarn(@"ANR recorded from:%@ to %@, duration:%.2fs",
                [NSDate dateWithTimeIntervalSinceReferenceDate:self.anrStartTime],
                [NSDate dateWithTimeIntervalSinceReferenceDate:runloopCycleStartTime],
                runloopCycleStartTime - self.anrStartTime);

            [self.threadStacks removeAllObjects];
            self.anrStartTime = 0;
        }

        usleep(self.detectInterval * 1000 * 1000);
    }
}

- (uintptr_t)titleFrameForStackframes:(uintptr_t *)frames size:(size_t)size {
    for (int fi = 0; fi < size; ++fi) {
        uintptr_t frame = frames[fi];
        if (!mtha_addr_is_in_sys_libraries(frame)) {
            return frame;
        }
    }

    if (size > 0) {
        uintptr_t frame = frames[0];
        return frame;
    }
    return 0;
}

- (MTHANRRecordRaw *)recordThreadStack:(thread_t)thread {
    MTHANRRecordRaw *threadStack = nil;
    threadStack = [[MTHANRRecordRaw alloc] init];
    threadStack.cpuUsed = MTHawkeyeAppStat.cpuUsedByAllThreads * 100.0f;
    threadStack.time = [[NSDate new] timeIntervalSince1970];
    mth_stack_backtrace *stackframes = mth_malloc_stack_backtrace();

    if (stackframes) {
        mth_stack_backtrace_of_thread(thread, stackframes, MTHANRTRACE_MAXSTACKCOUNT, 0);
        threadStack->stackframesSize = stackframes->frames_size;
        threadStack->stackframes = (uintptr_t *)malloc(sizeof(uintptr_t) * stackframes->frames_size);
        memcpy(threadStack->stackframes, stackframes->frames, sizeof(uintptr_t) * stackframes->frames_size);
        threadStack->titleFrame = [self titleFrameForStackframes:stackframes->frames size:stackframes->frames_size];
        mth_free_stack_backtrace(stackframes);
    }

    return threadStack;
}

#pragma mark - Notifications
- (void)registerNotification {
    NSArray *appNotice = @[ UIApplicationWillTerminateNotification,
        UIApplicationDidBecomeActiveNotification,
        UIApplicationDidEnterBackgroundNotification,
        UIApplicationWillResignActiveNotification ];
    for (NSString *noticeName in appNotice) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationNotification:) name:noticeName object:nil];
    }
}

- (void)unregisterNotification {
    NSArray *appNotice = @[ UIApplicationWillTerminateNotification,
        UIApplicationDidBecomeActiveNotification,
        UIApplicationDidEnterBackgroundNotification,
        UIApplicationWillResignActiveNotification ];
    for (NSString *noticeName in appNotice) {
        [[NSNotificationCenter defaultCenter] removeObserver:self name:noticeName object:nil];
    }
}

- (void)applicationNotification:(NSNotification *)notice {
    self.appState = [UIApplication sharedApplication].applicationState;
}

#pragma mark - Runloop Observer
static void mthanr_runLoopObserverCallBack(CFRunLoopObserverRef observer, CFRunLoopActivity activity, void *info) {
    MTHANRDetectThread *object = (__bridge MTHANRDetectThread *)info;
    switch (activity) {
        case kCFRunLoopBeforeTimers:
        case kCFRunLoopBeforeSources:
        case kCFRunLoopAfterWaiting: {
            if (object.runloopWorking == NO) {
                object.runloopCycleStartTime = CFAbsoluteTimeGetCurrent();
            }
            object.runloopWorking = YES;
            break;
        }
        case kCFRunLoopBeforeWaiting: {
            object.runloopWorking = NO;
            break;
        }
        default:
            break;
    }
}

- (void)registerObserver {
    if (!self.observerRef) {
        CFRunLoopObserverContext context = {0, (__bridge void *)self, NULL, NULL};
        CFRunLoopObserverRef observer = CFRunLoopObserverCreate(kCFAllocatorDefault, kCFRunLoopAllActivities, YES, 0, &mthanr_runLoopObserverCallBack, &context);
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, kCFRunLoopCommonModes);
        self.observerRef = observer;
    }
}

- (void)unregisterObserver {
    if (self.observerRef) {
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), self.observerRef, kCFRunLoopCommonModes);
        CFRelease(self.observerRef);
        self.observerRef = NULL;
    }
}
@end