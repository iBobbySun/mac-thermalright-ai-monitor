// ThermalSensor.m — IOHIDEventSystemClient-based temperature reader
//
// Reads CPU and GPU temperature on Apple Silicon without sudo.
// Based on fermion-star/apple_sensors (BSD 3-Clause License).
// Uses private IOKit HID API: IOHIDEventSystemClient.
//
// IMPORTANT: IOHIDEventSystemClient is created ONCE and reused
// to prevent memory leak (~4GB over hours of 0.5s polling).

#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <Foundation/Foundation.h>
#include <stdbool.h>
#include "ThermalSensor.h"

// Private IOKit declarations (not in public headers)
typedef struct __IOHIDEvent *IOHIDEventRef;
#ifdef __LP64__
typedef double IOHIDFloat;
#else
typedef float IOHIDFloat;
#endif

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef, int64_t, int32_t, int64_t);
extern IOHIDFloat IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef);

#define IOHIDEventFieldBase(type) (type << 16)
#define kIOHIDEventTypeTemperature 15

// Persistent state — created once, reused across calls
static IOHIDEventSystemClientRef _system = NULL;
static CFDictionaryRef _match = NULL;
static bool _servicesCached = false;

// Service names are stable for the lifetime of the machine. Keep one preferred
// representative plus two fallbacks per device class instead of issuing an HID
// event/property IPC round-trip to every temperature service on every poll.
static IOHIDServiceClientRef _cpuPrimary = NULL;
static IOHIDServiceClientRef _cpuFallbacks[2] = { NULL, NULL };
static int _cpuFallbackCount = 0;
static IOHIDServiceClientRef _gpuPrimary = NULL;
static IOHIDServiceClientRef _gpuFallbacks[2] = { NULL, NULL };
static int _gpuFallbackCount = 0;

static void ensureInitialized(void) {
    if (_system) return;

    int page = 0xff00;
    int usage = 0x0005;
    CFNumberRef nums[2];
    CFStringRef keys[2];
    keys[0] = CFStringCreateWithCString(0, "PrimaryUsagePage", 0);
    keys[1] = CFStringCreateWithCString(0, "PrimaryUsage", 0);
    nums[0] = CFNumberCreate(0, kCFNumberSInt32Type, &page);
    nums[1] = CFNumberCreate(0, kCFNumberSInt32Type, &usage);
    _match = CFDictionaryCreate(0, (const void**)keys, (const void**)nums, 2,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(keys[0]); CFRelease(keys[1]);
    CFRelease(nums[0]); CFRelease(nums[1]);

    _system = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    IOHIDEventSystemClientSetMatching(_system, _match);
}

static void retainService(IOHIDServiceClientRef service, IOHIDServiceClientRef *slot) {
    if (*slot || !service) return;
    *slot = (IOHIDServiceClientRef)CFRetain((CFTypeRef)service);
}

static void appendFallback(IOHIDServiceClientRef service,
                           IOHIDServiceClientRef slots[2], int *count) {
    if (!service || *count >= 2) return;
    slots[*count] = (IOHIDServiceClientRef)CFRetain((CFTypeRef)service);
    *count += 1;
}

static void cacheRepresentativeServices(void) {
    if (_servicesCached || !_system) return;

    CFArrayRef services = IOHIDEventSystemClientCopyServices(_system);
    if (!services) return;
    _servicesCached = true;

    long count = CFArrayGetCount(services);
    for (int i = 0; i < count; i++) {
        IOHIDServiceClientRef service =
            (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        CFStringRef name = IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
        if (!name) continue;

        NSString *sensorName = (__bridge NSString *)name;
        if ([sensorName containsString:@"PMU tdie"]) {
            retainService(service, &_cpuPrimary);
        } else if ([sensorName containsString:@"CPU"] ||
                   [sensorName containsString:@"pACC"] ||
                   [sensorName containsString:@"eACC"]) {
            appendFallback(service, _cpuFallbacks, &_cpuFallbackCount);
        }

        if ([sensorName containsString:@"GPU"]) {
            retainService(service, &_gpuPrimary);
        } else if ([sensorName hasPrefix:@"PMU TP"] && [sensorName hasSuffix:@"g"]) {
            appendFallback(service, _gpuFallbacks, &_gpuFallbackCount);
        }
        CFRelease(name);
    }
    CFRelease(services);
}

static bool readServiceTemperature(IOHIDServiceClientRef service, double *temperature) {
    if (!service) return false;
    IOHIDEventRef event = IOHIDServiceClientCopyEvent(
        service, kIOHIDEventTypeTemperature, 0, 0);
    if (!event) return false;
    double value = IOHIDEventGetFloatValue(
        event, IOHIDEventFieldBase(kIOHIDEventTypeTemperature));
    CFRelease(event);
    if (value <= 0 || value > 150) return false;
    *temperature = value;
    return true;
}

void readThermalSensors(double *cpuTemp, double *gpuTemp) {
    *cpuTemp = -1;
    *gpuTemp = -1;

    ensureInitialized();
    if (!_system) return;
    cacheRepresentativeServices();

    double value = 0;
    if (readServiceTemperature(_cpuPrimary, &value)) {
        *cpuTemp = value;
    } else {
        double maximum = 0;
        for (int i = 0; i < _cpuFallbackCount; i++) {
            if (readServiceTemperature(_cpuFallbacks[i], &value) && value > maximum) {
                maximum = value;
            }
        }
        if (maximum > 0) *cpuTemp = maximum;
    }

    if (readServiceTemperature(_gpuPrimary, &value)) {
        *gpuTemp = value;
    } else {
        double maximum = 0;
        for (int i = 0; i < _gpuFallbackCount; i++) {
            if (readServiceTemperature(_gpuFallbacks[i], &value) && value > maximum) {
                maximum = value;
            }
        }
        if (maximum > 0) *gpuTemp = maximum;
    }
}
