// Coucou Now Playing helper.
//
// Since macOS 15.4 only Apple-entitled processes may read MediaRemote (the system's
// "Now Playing": browsers, Spotify, Music, any app). /usr/bin/perl is one of them, so
// Coucou runs perl, which loads this library through DynaLoader and calls
// coucou_nowplaying_run(). From then on:
//   stdout: one JSON object per line, each time what's playing changes
//   stdin:  one command per line: toggle | play | pause | next | previous | seek <seconds>
// It exits as soon as stdin closes, so it never outlives Coucou.

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

typedef void (*MRGetInfo)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*MRGetBool)(dispatch_queue_t, void (^)(Boolean));
typedef void (*MRGetPid)(dispatch_queue_t, void (^)(int));
typedef void (*MRGetClient)(dispatch_queue_t, void (^)(id));
typedef CFStringRef (*MRClientString)(id);
typedef void (*MRRegister)(dispatch_queue_t);
typedef Boolean (*MRSendCommand)(int, CFDictionaryRef);
typedef void (*MRSetElapsed)(double);

static MRGetInfo getInfo;
static MRGetBool getIsPlaying;
static MRGetPid getPid;
static MRGetClient getClient;
static MRClientString clientBundle;
static MRClientString clientParentBundle;
static MRSendCommand sendCommand;
static MRSetElapsed setElapsed;

static NSUInteger lastArtworkHash = 0;
static NSUInteger generation = 0;

static void emit(NSDictionary *object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    if (!data) return;
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static NSString *stringFrom(CFStringRef s) {
    return s ? [(__bridge NSString *)s copy] : nil;
}

/// Reads everything about the current player, then emits one line (main queue).
static void readAndEmit(void) {
    dispatch_queue_t q = dispatch_get_main_queue();
    getInfo(q, ^(CFDictionaryRef raw) {
        NSDictionary *info = (__bridge NSDictionary *)raw;
        getIsPlaying(q, ^(Boolean playing) {
            getPid(q, ^(int pid) {
                void (^finish)(NSString *, NSString *) = ^(NSString *bundle, NSString *parent) {
                    NSString *title = info[@"kMRMediaRemoteNowPlayingInfoTitle"];
                    if (info.count == 0 || title.length == 0) {
                        lastArtworkHash = 0;
                        emit(@{ @"type": @"none" });
                        return;
                    }
                    NSMutableDictionary *out = [@{ @"type": @"state",
                                                   @"title": title,
                                                   @"playing": @(playing),
                                                   @"pid": @(pid) } mutableCopy];
                    NSString *artist = info[@"kMRMediaRemoteNowPlayingInfoArtist"];
                    NSString *album = info[@"kMRMediaRemoteNowPlayingInfoAlbum"];
                    NSNumber *duration = info[@"kMRMediaRemoteNowPlayingInfoDuration"];
                    NSNumber *elapsed = info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"];
                    NSNumber *rate = info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"];
                    NSDate *stamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
                    if ([artist isKindOfClass:NSString.class]) out[@"artist"] = artist;
                    if ([album isKindOfClass:NSString.class]) out[@"album"] = album;
                    if ([duration isKindOfClass:NSNumber.class]) out[@"duration"] = duration;
                    if ([elapsed isKindOfClass:NSNumber.class]) out[@"elapsed"] = elapsed;
                    if ([rate isKindOfClass:NSNumber.class]) out[@"rate"] = rate;
                    if ([stamp isKindOfClass:NSDate.class]) out[@"timestamp"] = @(stamp.timeIntervalSince1970);
                    if (bundle) out[@"bundle"] = bundle;
                    if (parent) out[@"parentBundle"] = parent;
                    // Artwork goes out only when it changes: it is the heavy part of a line.
                    NSData *art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                    if ([art isKindOfClass:NSData.class] && art.length > 0) {
                        NSUInteger h = art.hash ^ art.length;
                        if (h != lastArtworkHash) {
                            lastArtworkHash = h;
                            out[@"artwork"] = [art base64EncodedStringWithOptions:0];
                        }
                        out[@"artworkHash"] = @(h);
                    } else {
                        lastArtworkHash = 0;
                    }
                    emit(out);
                };
                if (getClient && clientBundle) {
                    getClient(q, ^(id client) {
                        NSString *b = client ? stringFrom(clientBundle(client)) : nil;
                        NSString *p = (client && clientParentBundle) ? stringFrom(clientParentBundle(client)) : nil;
                        finish(b, p);
                    });
                } else {
                    finish(nil, nil);
                }
            });
        });
    });
}

/// Players post several changes in a row: read once they settle.
static void scheduleRead(void) {
    NSUInteger mine = ++generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (mine == generation) readAndEmit();
    });
}

static void handleCommand(NSString *line) {
    NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
    NSString *cmd = parts.firstObject;
    // MRMediaRemoteCommand values
    if ([cmd isEqualToString:@"play"]) sendCommand(0, NULL);
    else if ([cmd isEqualToString:@"pause"]) sendCommand(1, NULL);
    else if ([cmd isEqualToString:@"toggle"]) sendCommand(2, NULL);
    else if ([cmd isEqualToString:@"next"]) sendCommand(4, NULL);
    else if ([cmd isEqualToString:@"previous"]) sendCommand(5, NULL);
    else if ([cmd isEqualToString:@"seek"] && parts.count > 1 && setElapsed) setElapsed(parts[1].doubleValue);
    else if ([cmd isEqualToString:@"refresh"]) readAndEmit();
}

__attribute__((visibility("default")))
void coucou_nowplaying_run(void) {
    void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!mr) { emit(@{ @"type": @"error", @"message": @"MediaRemote unavailable" }); exit(1); }
    getInfo = (MRGetInfo)dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
    getIsPlaying = (MRGetBool)dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    getPid = (MRGetPid)dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationPID");
    getClient = (MRGetClient)dlsym(mr, "MRMediaRemoteGetNowPlayingClient");
    clientBundle = (MRClientString)dlsym(mr, "MRNowPlayingClientGetBundleIdentifier");
    clientParentBundle = (MRClientString)dlsym(mr, "MRNowPlayingClientGetParentAppBundleIdentifier");
    sendCommand = (MRSendCommand)dlsym(mr, "MRMediaRemoteSendCommand");
    setElapsed = (MRSetElapsed)dlsym(mr, "MRMediaRemoteSetElapsedTime");
    MRRegister registerForNotifications = (MRRegister)dlsym(mr, "MRMediaRemoteRegisterForNowPlayingNotifications");
    if (!getInfo || !getIsPlaying || !getPid || !sendCommand || !registerForNotifications) {
        emit(@{ @"type": @"error", @"message": @"MediaRemote symbols missing" });
        exit(1);
    }

    registerForNotifications(dispatch_get_main_queue());
    for (NSString *name in @[ @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                              @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                              @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
                              @"kMRMediaRemoteNowPlayingApplicationClientStateDidChange" ]) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil
                                                    usingBlock:^(NSNotification *n) { scheduleRead(); }];
    }

    // Commands from Coucou; EOF means Coucou is gone.
    [NSThread detachNewThreadWithBlock:^{
        char *buf = NULL;
        size_t cap = 0;
        ssize_t len;
        while ((len = getline(&buf, &cap, stdin)) > 0) {
            NSString *line = [[[NSString alloc] initWithBytes:buf length:(NSUInteger)len encoding:NSUTF8StringEncoding]
                              stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (line.length == 0) continue;
            dispatch_async(dispatch_get_main_queue(), ^{ handleCommand(line); });
        }
        exit(0);
    }];

    readAndEmit();
    CFRunLoopRun();
}
