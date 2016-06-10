//
//  GBAEmulatorBridge.m
//  GBADeltaCore
//
//  Created by Riley Testut on 6/3/16.
//  Copyright © 2016 Riley Testut. All rights reserved.
//

#import "GBAEmulatorBridge.h"
#import "GBASoundDriver.h"

// VBA-M
#include "../VBA-M/System.h"
#include "../VBA-M/gba/Sound.h"
#include "../VBA-M/gba/GBA.h"
#include "../VBA-M/gba/Cheats.h"
#include "../VBA-M/gba/RTC.h"
#include "../VBA-M/Util.h"

#include <sys/time.h>

// Required vars, used by the emulator core
//
int  systemRedShift = 19;
int  systemGreenShift = 11;
int  systemBlueShift = 3;
int  systemColorDepth = 32;
int  systemVerbose;
int  systemSaveUpdateCounter = 0;
int  systemFrameSkip;
u32  systemColorMap32[0x10000];
u16  systemColorMap16[0x10000];
u16  systemGbPalette[24];

int  emulating;
int  RGB_LOW_BITS_MASK;

@interface GBAEmulatorBridge ()

@property (assign, nonatomic, getter=isFrameReady) BOOL frameReady;

@property (strong, nonatomic, nonnull, readonly) NSMutableSet<NSNumber *> *activatedInputs;
@property (strong, nonatomic, nonnull, readonly) NSMutableDictionary<NSString *, NSNumber *> *cheatCodes;

@end

@implementation GBAEmulatorBridge

- (instancetype)init
{
    self = [super init];
    if (self)
    {
        _activatedInputs = [NSMutableSet set];
        _cheatCodes = [NSMutableDictionary dictionary];
    }
    
    return self;
}

#pragma mark - Emulation -

- (void)startWithGameURL:(NSURL *)URL
{
    [super startWithGameURL:URL];
    
    [self.cheatCodes removeAllObjects];
    
    NSData *data = [NSData dataWithContentsOfURL:URL];
    
    if (!CPULoadRomData((const char *)data.bytes, (int)data.length))
    {
        return;
    }
    
    [self updateGameSettings];
    
    [self loadGameSaveFromURL:[self defaultGameSaveURL]];
    
    utilUpdateSystemColorMaps(NO);
    
    soundInit();
    soundSetSampleRate(32768); // 44100 chirps
    
    soundReset();
    
    emulating = 1;
    
    CPUInit(0, false);
    
    GBASystem.emuReset();
}

- (void)stop
{
    [super stop];
    
    [self saveGameSaveToURL:[self defaultGameSaveURL]];
    
    GBASystem.emuCleanUp();
    soundShutdown();
    
    emulating = 0;
}

- (void)pause
{
    [super pause];
    
    [self saveGameSaveToURL:[self defaultGameSaveURL]];
    
    emulating = 0;
}

- (void)resume
{
    [super resume];
    
    emulating = 1;
}

- (void)runFrame
{
    self.frameReady = NO;
    
    while (![self isFrameReady])
    {
        GBASystem.emuMain(GBASystem.emuCount);
    }
}

#pragma mark - Settings -

- (void)updateGameSettings
{
    NSString *gameID = [NSString stringWithFormat:@"%c%c%c%c", rom[0xac], rom[0xad], rom[0xae], rom[0xaf]];
    
    NSLog(@"VBA-M: GameID in ROM is: %@", gameID);
    
    // Set defaults
    // Use underscores to prevent shadowing of global variables
    BOOL _enableRTC       = NO;
    BOOL _enableMirroring = NO;
    BOOL _useBIOS         = NO;
    int  _cpuSaveType     = 0;
    int  _flashSize       = 0x10000;
    
    // Read in vba-over.ini and break it into an array of strings
    NSString *iniPath = [[NSBundle bundleForClass:[self class]] pathForResource:@"vba-over" ofType:@"ini"];
    NSString *iniString = [NSString stringWithContentsOfFile:iniPath encoding:NSUTF8StringEncoding error:NULL];
    NSArray *settings = [iniString componentsSeparatedByString:@"\n"];
    
    BOOL matchFound = NO;
    NSMutableDictionary *overridesFound = [[NSMutableDictionary alloc] init];
    NSString *temp;
    
    // Check if vba-over.ini has per-game settings for our gameID
    for (NSString *s in settings)
    {
        temp = nil;
        
        if ([s hasPrefix:@"["])
        {
            NSScanner *scanner = [NSScanner scannerWithString:s];
            [scanner scanString:@"[" intoString:nil];
            [scanner scanUpToString:@"]" intoString:&temp];
            
            if ([temp caseInsensitiveCompare:gameID] == NSOrderedSame)
            {
                matchFound = YES;
            }
            
            continue;
        }
        
        else if (matchFound && [s hasPrefix:@"saveType="])
        {
            NSScanner *scanner = [NSScanner scannerWithString:s];
            [scanner scanString:@"saveType=" intoString:nil];
            [scanner scanUpToString:@"\n" intoString:&temp];
            _cpuSaveType = [temp intValue];
            [overridesFound setObject:temp forKey:@"CPU saveType"];
            
            continue;
        }
        
        else if (matchFound && [s hasPrefix:@"rtcEnabled="])
        {
            NSScanner *scanner = [NSScanner scannerWithString:s];
            [scanner scanString:@"rtcEnabled=" intoString:nil];
            [scanner scanUpToString:@"\n" intoString:&temp];
            _enableRTC = [temp boolValue];
            [overridesFound setObject:temp forKey:@"rtcEnabled"];
            
            continue;
        }
        
        else if (matchFound && [s hasPrefix:@"flashSize="])
        {
            NSScanner *scanner = [NSScanner scannerWithString:s];
            [scanner scanString:@"flashSize=" intoString:nil];
            [scanner scanUpToString:@"\n" intoString:&temp];
            _flashSize = [temp intValue];
            [overridesFound setObject:temp forKey:@"flashSize"];
            
            continue;
        }
        
        else if (matchFound && [s hasPrefix:@"mirroringEnabled="])
        {
            NSScanner *scanner = [NSScanner scannerWithString:s];
            [scanner scanString:@"mirroringEnabled=" intoString:nil];
            [scanner scanUpToString:@"\n" intoString:&temp];
            _enableMirroring = [temp boolValue];
            [overridesFound setObject:temp forKey:@"mirroringEnabled"];
            
            continue;
        }
        
        else if (matchFound && [s hasPrefix:@"useBios="])
        {
            NSScanner *scanner = [NSScanner scannerWithString:s];
            [scanner scanString:@"useBios=" intoString:nil];
            [scanner scanUpToString:@"\n" intoString:&temp];
            _useBIOS = [temp boolValue];
            [overridesFound setObject:temp forKey:@"useBios"];
            
            continue;
        }
        
        else if (matchFound)
            break;
    }
    
    if (matchFound)
    {
        NSLog(@"VBA: overrides found: %@", overridesFound);
    }
    
    // Apply settings
    rtcEnable(_enableRTC);
    mirroringEnable = _enableMirroring;
    doMirroring(mirroringEnable);
    cpuSaveType = _cpuSaveType;
    
    if (_flashSize == 0x10000 || _flashSize == 0x20000)
    {
        flashSetSize(_flashSize);
    }
    
}

#pragma mark - Inputs -

- (void)activateInput:(GBAGameInput)gameInput
{
    [self.activatedInputs addObject:@(gameInput)];
}

- (void)deactivateInput:(GBAGameInput)gameInput
{
    [self.activatedInputs removeObject:@(gameInput)];
}

#pragma mark - Game Saves -

- (void)saveGameSaveToURL:(NSURL *)URL
{
    GBASystem.emuWriteBattery(URL.fileSystemRepresentation);
}

- (void)loadGameSaveFromURL:(NSURL *)URL
{
    GBASystem.emuReadBattery(URL.fileSystemRepresentation);
}

- (NSURL *)defaultGameSaveURL
{
    NSURL *saveURL = [[self.gameURL URLByDeletingPathExtension] URLByAppendingPathExtension:@"sav"];
    return saveURL;
}

#pragma mark - Save States -

- (void)saveSaveStateToURL:(NSURL *)URL
{
    GBASystem.emuWriteState(URL.fileSystemRepresentation);
}

- (void)loadSaveStateFromURL:(NSURL *)URL
{
    GBASystem.emuReadState(URL.fileSystemRepresentation);
}

#pragma mark - Cheats -

- (BOOL)activateCheat:(NSString *)cheatCode type:(GBACheatType)type
{
    NSArray *codes = [cheatCode componentsSeparatedByString:@"\n"];
    for (NSString *code in codes)
    {
        BOOL success = YES;
        
        switch (type)
        {
            case GBACheatTypeActionReplay:
            case GBACheatTypeGameShark:
            {
                NSString *sanitizedCode = [code stringByReplacingOccurrencesOfString:@" " withString:@""];
                success = cheatsAddGSACode([sanitizedCode UTF8String], "code", true);
                break;
            }
                
            case GBACheatTypeCodeBreaker:
            {
                success = cheatsAddCBACode([code UTF8String], "code");
                break;
            }
        }
        
        if (!success)
        {
            return NO;
        }
    }
    
    self.cheatCodes[cheatCode] = @(type);
    
    [self updateCheats];
    
    return YES;
}

- (void)deactivateCheat:(NSString *)cheatCode
{
    if (self.cheatCodes[cheatCode] == nil)
    {
        return;
    }
    
    self.cheatCodes[cheatCode] = nil;
    
    [self updateCheats];
}

- (void)updateCheats
{
    cheatsDeleteAll(false);
    
    [self.cheatCodes.copy enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull cheatCode, NSNumber * _Nonnull type, BOOL * _Nonnull stop) {
        
        NSArray *codes = [cheatCode componentsSeparatedByString:@"\n"];
        for (NSString *code in codes)
        {
            switch ([type integerValue])
            {
                case GBACheatTypeActionReplay:
                case GBACheatTypeGameShark:
                {
                    NSString *sanitizedCode = [code stringByReplacingOccurrencesOfString:@" " withString:@""];
                    cheatsAddGSACode([sanitizedCode UTF8String], "code", true);
                    break;
                }
                    
                case GBACheatTypeCodeBreaker:
                {
                    cheatsAddCBACode([code UTF8String], "code");
                    break;
                }
            }
        }
        
    }];
}

@end

#pragma mark - VBA-M -

void systemMessage(int _iId, const char * _csFormat, ...)
{
    NSLog(@"VBA-M: %s", _csFormat);
}

void systemDrawScreen()
{
    for (int i = 0; i < 241 * 162 * 4; i++)
    {
        if ((i + 1) % 4 == 0)
        {
            pix[i] = 255;
        }
    }
    
    // Get rid of the first line and the last row
    dispatch_apply(160, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(size_t y){
        memcpy([GBAEmulatorBridge sharedBridge].videoRenderer.videoBuffer + y * 240 * 4, pix + (y + 1) * (240 + 1) * 4, 240 * 4);
    });
    
    [[GBAEmulatorBridge sharedBridge] setFrameReady:YES];
}

bool systemReadJoypads()
{
    return true;
}

u32 systemReadJoypad(int joy)
{
    u32 joypad = 0;
    
    for (NSNumber *input in [GBAEmulatorBridge sharedBridge].activatedInputs.copy)
    {
        joypad |= [input unsignedIntegerValue];
    }
    
    return joypad;
}

void systemShowSpeed(int _iSpeed)
{
    
}

void system10Frames(int _iRate)
{
    if (systemSaveUpdateCounter > 0)
    {
        systemSaveUpdateCounter--;
        
        if (systemSaveUpdateCounter <= SYSTEM_SAVE_NOT_UPDATED)
        {
            [[GBAEmulatorBridge sharedBridge] saveGameSaveToURL:[[GBAEmulatorBridge sharedBridge] defaultGameSaveURL]];
            
            systemSaveUpdateCounter = SYSTEM_SAVE_NOT_UPDATED;
        }
    }
}

void systemFrame()
{
    
}

void systemSetTitle(const char * _csTitle)
{

}

void systemScreenCapture(int _iNum)
{

}

u32 systemGetClock()
{
    timeval time;
    
    gettimeofday(&time, NULL);
    
    double milliseconds = (time.tv_sec * 1000.0) + (time.tv_usec / 1000.0);
    return milliseconds;
}

SoundDriver *systemSoundInit()
{
    soundShutdown();
    
    auto driver = new GBASoundDriver;
    return driver;
}

void systemUpdateMotionSensor()
{
}

u8 systemGetSensorDarkness()
{
    return 0;
}

int systemGetSensorX()
{
    return 0;
}

int systemGetSensorY()
{
    return 0;
}

int systemGetSensorZ()
{
    return 0;
}

void systemCartridgeRumble(bool)
{
}

void systemGbPrint(u8 * _puiData,
                   int  _iLen,
                   int  _iPages,
                   int  _iFeed,
                   int  _iPalette,
                   int  _iContrast)
{
}

void systemScreenMessage(const char * _csMsg)
{
}

bool systemCanChangeSoundQuality()
{
    return true;
}

bool systemPauseOnFrame()
{
    return false;
}

void systemGbBorderOn()
{
}

void systemOnSoundShutdown()
{
}

void systemOnWriteDataToSoundBuffer(const u16 * finalWave, int length)
{
}

void debuggerMain()
{
}

void debuggerSignal(int, int)
{
}

void log(const char *defaultMsg, ...)
{
    static FILE *out = NULL;
    
    if(out == NULL) {
        out = fopen("trace.log","w");
    }
    
    va_list valist;
    
    va_start(valist, defaultMsg);
    vfprintf(out, defaultMsg, valist);
    va_end(valist);
}