// Adapted from ungive/mediaremote-adapter v0.7.6, used by OpenWhispr.
// Copyright (c) 2025, Jonas van den Berg and contributors.
// Licensed under the BSD 3-Clause License in this directory.

#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <unistd.h>

typedef void (^PlayingCallback)(bool isPlaying);
typedef void (^ProcessIdentifierCallback)(int processIdentifier);
typedef void (*GetPlayingFunction)(
    dispatch_queue_t queue,
    PlayingCallback callback
);
typedef void (*GetProcessIdentifierFunction)(
    dispatch_queue_t queue,
    ProcessIdentifierCallback callback
);
typedef bool (*SendCommandFunction)(NSInteger command, id userInfo);

typedef NS_ENUM(NSInteger, WhisprLocalPlaybackState) {
    WhisprLocalPlaybackStateUnavailable = 0,
    WhisprLocalPlaybackStatePaused = 1,
    WhisprLocalPlaybackStatePlaying = 2,
};

static void *mediaRemoteHandle;
static GetPlayingFunction getPlaying;
static GetProcessIdentifierFunction getProcessIdentifier;
static SendCommandFunction sendCommand;
static dispatch_queue_t mediaRemoteQueue;

static const NSInteger kMediaRemotePlay = 0;
static const NSInteger kMediaRemotePause = 1;
static const int64_t kStateTimeoutNanoseconds = 180 * NSEC_PER_MSEC;
static const int64_t kCommandFlushNanoseconds = 100 * NSEC_PER_MSEC;

__attribute__((constructor))
static void initializeMediaRemoteAdapter(void) {
    mediaRemoteQueue = dispatch_queue_create(
        "com.jasenguerra.whisprlocal.mediaremote",
        DISPATCH_QUEUE_SERIAL
    );
    mediaRemoteHandle = dlopen(
        "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
        RTLD_NOW
    );
    if (mediaRemoteHandle == NULL) {
        return;
    }

    getPlaying = (GetPlayingFunction)dlsym(
        mediaRemoteHandle,
        "MRMediaRemoteGetNowPlayingApplicationIsPlaying"
    );
    getProcessIdentifier = (GetProcessIdentifierFunction)dlsym(
        mediaRemoteHandle,
        "MRMediaRemoteGetNowPlayingApplicationPID"
    );
    sendCommand = (SendCommandFunction)dlsym(
        mediaRemoteHandle,
        "MRMediaRemoteSendCommand"
    );
}

static void printResult(NSString *result) {
    fprintf(stdout, "%s\n", result.UTF8String);
    fflush(stdout);
}

static WhisprLocalPlaybackState currentPlaybackState(void) {
    if (getPlaying == NULL) {
        return WhisprLocalPlaybackStateUnavailable;
    }

    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block bool callbackReceived = false;
    __block bool isPlaying = false;

    getPlaying(mediaRemoteQueue, ^(bool reportedPlaying) {
        isPlaying = reportedPlaying;
        callbackReceived = true;
        dispatch_semaphore_signal(semaphore);
    });

    long waitResult = dispatch_semaphore_wait(
        semaphore,
        dispatch_time(
            DISPATCH_TIME_NOW,
            kStateTimeoutNanoseconds
        )
    );
    if (waitResult != 0 || !callbackReceived) {
        return WhisprLocalPlaybackStateUnavailable;
    }
    return isPlaying
        ? WhisprLocalPlaybackStatePlaying
        : WhisprLocalPlaybackStatePaused;
}

static bool sendMediaCommand(NSInteger command) {
    if (sendCommand == NULL || !sendCommand(command, nil)) {
        return false;
    }

    if (getProcessIdentifier == NULL) {
        usleep(50 * 1000);
        return true;
    }

    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    getProcessIdentifier(mediaRemoteQueue, ^(int processIdentifier) {
        (void)processIdentifier;
        dispatch_semaphore_signal(semaphore);
    });
    dispatch_semaphore_wait(
        semaphore,
        dispatch_time(
            DISPATCH_TIME_NOW,
            kCommandFlushNanoseconds
        )
    );
    return true;
}

void whisprlocal_media_state(void) {
    @autoreleasepool {
        switch (currentPlaybackState()) {
        case WhisprLocalPlaybackStatePlaying:
            printResult(@"PLAYING");
            break;
        case WhisprLocalPlaybackStatePaused:
            printResult(@"PAUSED");
            break;
        case WhisprLocalPlaybackStateUnavailable:
            printResult(@"UNAVAILABLE");
            break;
        }
    }
}

void whisprlocal_media_pause_if_playing(void) {
    @autoreleasepool {
        switch (currentPlaybackState()) {
        case WhisprLocalPlaybackStatePlaying:
            printResult(
                sendMediaCommand(kMediaRemotePause)
                    ? @"PAUSED"
                    : @"FAILED"
            );
            break;
        case WhisprLocalPlaybackStatePaused:
            printResult(@"ALREADY_PAUSED");
            break;
        case WhisprLocalPlaybackStateUnavailable:
            printResult(@"UNAVAILABLE");
            break;
        }
    }
}

void whisprlocal_media_play(void) {
    @autoreleasepool {
        printResult(
            sendMediaCommand(kMediaRemotePlay)
                ? @"PLAYED"
                : @"FAILED"
        );
    }
}
