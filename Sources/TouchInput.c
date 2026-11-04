#include "TouchInput.h"
#include "GridDecoder.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hid/IOHIDManager.h>
#include <mach/mach_error.h>
#include <stdio.h>

// Lifecycle and reports are serialized on the main run loop. Only the built-in
// Apple touchscreen has this profile. In particular, the internal trackpad has
// a different HID usage and never enters the manager's device set.
static IOHIDManagerRef manager;
static GRGridDecoder grid;
static GRTouchCallback onTouch;
static void *touchContext;
static char lastError[256];

static CFDictionaryRef screenMatching(void) {
    const int digitizers = 13, touchscreen = 4;
    CFNumberRef page = CFNumberCreate(NULL, kCFNumberIntType, &digitizers);
    CFNumberRef usage = CFNumberCreate(NULL, kCFNumberIntType, &touchscreen);
    const void *keys[] = {CFSTR(kIOHIDPrimaryUsagePageKey), CFSTR(kIOHIDPrimaryUsageKey),
                          CFSTR(kIOHIDBuiltInKey), CFSTR(kIOHIDManufacturerKey),
                          CFSTR(kIOHIDProductKey), CFSTR(kIOHIDTransportKey)};
    const void *values[] = {page, usage, kCFBooleanTrue, CFSTR("Apple"), CFSTR("Kiwi"), CFSTR("FIFO")};
    CFDictionaryRef match = CFDictionaryCreate(NULL, keys, values, 6,
                                                &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(page);
    CFRelease(usage);
    return match;
}

static void deviceChanged(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    (void)result; (void)sender; (void)device;
    if (context == manager) GRGridReset(&grid);
}

static void reportReceived(void *context, IOReturn result, void *sender, IOHIDReportType type,
                           uint32_t reportID, uint8_t *bytes, CFIndex length) {
    (void)sender; (void)reportID;
    if (context != manager || !onTouch || result != kIOReturnSuccess || type != kIOHIDReportTypeInput || !bytes || length <= 0) return;
    GRGridPoint points[GRMaxTouches];
    int count = GRGridTouches(&grid, bytes, (size_t)length, points);
    for (int i = 0; i < count; i++)
        onTouch(points[i].x, points[i].y, points[i].identifier, points[i].phase == GRGridMoved, touchContext);
}

const char *GRLastTouchError(void) { return lastError; }

int GRStartTouchInput(GRTouchCallback callback, void *context) {
    GRStopTouchInput();
    manager = IOHIDManagerCreate(NULL, kIOHIDOptionsTypeNone);
    if (!manager) {
        snprintf(lastError, sizeof(lastError), "Could not create the touchscreen reader.");
        return 0;
    }
    CFDictionaryRef matching = screenMatching();
    IOHIDManagerSetDeviceMatching(manager, matching);
    CFRelease(matching);
    CFSetRef matches = IOHIDManagerCopyDevices(manager);
    CFIndex count = matches ? CFSetGetCount(matches) : 0;
    if (matches) CFRelease(matches);
    if (count != 1) {
        snprintf(lastError, sizeof(lastError), "Expected one supported built-in touchscreen, found %ld.", (long)count);
        CFRelease(manager);
        manager = NULL;
        return 0;
    }
    onTouch = callback;
    touchContext = context;
    IOHIDManagerRegisterDeviceMatchingCallback(manager, deviceChanged, manager);
    IOHIDManagerRegisterDeviceRemovalCallback(manager, deviceChanged, manager);
    IOHIDManagerRegisterInputReportCallback(manager, reportReceived, manager);
    IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), kCFRunLoopCommonModes);
    IOReturn result = IOHIDManagerOpen(manager, kIOHIDOptionsTypeNone);
    if (result != kIOReturnSuccess) {
        snprintf(lastError, sizeof(lastError), "Could not read the built-in touchscreen: %s (0x%08x).", mach_error_string(result), (unsigned)result);
        GRStopTouchInput();
        return 0;
    }
    lastError[0] = '\0';
    return 1;
}

void GRStopTouchInput(void) {
    IOHIDManagerRef previous = manager;
    manager = NULL;
    onTouch = NULL;
    touchContext = NULL;
    if (previous) {
        IOHIDManagerUnscheduleFromRunLoop(previous, CFRunLoopGetMain(), kCFRunLoopCommonModes);
        IOHIDManagerRegisterInputReportCallback(previous, NULL, NULL);
        IOHIDManagerRegisterDeviceMatchingCallback(previous, NULL, NULL);
        IOHIDManagerRegisterDeviceRemovalCallback(previous, NULL, NULL);
        IOHIDManagerClose(previous, kIOHIDOptionsTypeNone);
        CFRelease(previous);
    }
    GRGridReset(&grid);
}
