// list-modes.m — enumerate every mode CoreGraphics sees from userspace.
// Compiled on the host with `clang -framework CoreGraphics -framework Foundation`
// then scp'd into the VM to bypass the missing developer tools there.
// One line per mode: "WxH@Hz pixel=PWxPH".
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        uint32_t count = 0;
        CGGetOnlineDisplayList(16, NULL, &count);
        CGDirectDisplayID ids[16];
        CGGetOnlineDisplayList(count, ids, &count);
        printf("displays: %u\n", count);
        for (uint32_t i = 0; i < count; i++) {
            CFArrayRef modes = CGDisplayCopyAllDisplayModes(ids[i], NULL);
            if (!modes) continue;
            CFIndex n = CFArrayGetCount(modes);
            printf("display %u: %ld modes\n", ids[i], n);
            for (CFIndex j = 0; j < n; j++) {
                CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, j);
                printf("  %zux%zu @ %dHz pixel=%zux%zu\n",
                       CGDisplayModeGetWidth(m),
                       CGDisplayModeGetHeight(m),
                       (int)CGDisplayModeGetRefreshRate(m),
                       CGDisplayModeGetPixelWidth(m),
                       CGDisplayModeGetPixelHeight(m));
            }
            CFRelease(modes);
        }
    }
    return 0;
}
