// metal-clear-screen.m — M4 scaffold. Submits a single Metal render pass
// with loadAction=clear, clearColor=red to an off-screen texture, and
// commits. When Phase 3 lands, this pixel should appear red through
// noVNC. Today, with no pixel path yet, this program exists so the user
// can run it on the VM once M3 passes and watch the command buffer
// round-trip cleanly. verify-m4.sh then captures the screenshot and
// diffs against tests/screenshots/reference/clear-color-red.png.
//
// STATUS: STUB. This file sets up an MTLRenderPassDescriptor with a
// single color attachment whose loadAction is clear. It does NOT attach
// a CAMetalLayer drawable (that requires a window/session which this CLI
// program doesn't have) — instead it renders into a plain 1920x1080
// BGRA8 MTLTexture and blits onto the main screen's framebuffer using
// CoreGraphics. That last step is the part most likely to need adjustment
// once we know how our stack wants to be driven; it's isolated in
// main()'s trailing block so it can be revised in place.
//
// Build on a Mac host (SDK present):
//   clang -framework Foundation -framework Metal -framework QuartzCore \
//         -framework CoreGraphics \
//         metal-clear-screen.m -o metal-clear-screen
//
// Run on the VM:
//   scp metal-clear-screen <vm-user>@<vm-ip>:/tmp/
//   ssh <vm-user>@<vm-ip> 'sudo -n launchctl asuser 501 /tmp/metal-clear-screen'
//
// Exit codes:
//   0 — cmdbuf committed + completed; clear-color texture was produced
//   1 — MTLCreateSystemDefaultDevice returned null
//   2 — newCommandQueue failed
//   3 — texture creation failed
//   4 — commandBuffer / renderCommandEncoder creation failed
//   5 — waitUntilCompleted timed out or ended in Error
//
// The one thing this program does NOT do is assert anything visual —
// verify-m4.sh owns the screenshot + diff. This program's job is to
// submit the draw and exit cleanly.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

static const NSTimeInterval kCompletionTimeoutSec = 5.0;
static const NSUInteger kWidth = 1920;
static const NSUInteger kHeight = 1080;

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        printf("=== M4 stub: metal-clear-screen ===\n");

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) {
            printf("FAIL: MTLCreateSystemDefaultDevice returned null\n");
            return 1;
        }
        printf("device: %s\n", [[device name] UTF8String]);

        id<MTLCommandQueue> queue = [device newCommandQueue];
        if (!queue) {
            printf("FAIL: newCommandQueue returned null\n");
            return 2;
        }

        MTLTextureDescriptor *td = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                         width:kWidth
                                        height:kHeight
                                     mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModeManaged;
        id<MTLTexture> tex = [device newTextureWithDescriptor:td];
        if (!tex) {
            printf("FAIL: texture creation failed\n");
            return 3;
        }

        MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
        rpd.colorAttachments[0].texture = tex;
        rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
        rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
        // Red. If EXPECTED_RGB in verify-m4.sh changes, update both.
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(1.0, 0.0, 0.0, 1.0);

        id<MTLCommandBuffer> cmdbuf = [queue commandBuffer];
        if (!cmdbuf) {
            printf("FAIL: commandBuffer returned null\n");
            return 4;
        }
        cmdbuf.label = @"m4-clear-color-red";

        id<MTLRenderCommandEncoder> enc = [cmdbuf renderCommandEncoderWithDescriptor:rpd];
        if (!enc) {
            printf("FAIL: renderCommandEncoderWithDescriptor returned null\n");
            return 4;
        }
        [enc endEncoding];

        __block BOOL completed = NO;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [cmdbuf addCompletedHandler:^(id<MTLCommandBuffer> cb) {
            completed = YES;
            dispatch_semaphore_signal(sem);
        }];

        printf("committing clear-color render pass...\n");
        [cmdbuf commit];

        long waited = dispatch_semaphore_wait(sem,
            dispatch_time(DISPATCH_TIME_NOW,
                          (int64_t)(kCompletionTimeoutSec * NSEC_PER_SEC)));
        if (waited != 0) {
            printf("FAIL: waitUntilCompleted timed out after %.1fs\n",
                   kCompletionTimeoutSec);
            return 5;
        }
        if (cmdbuf.status != MTLCommandBufferStatusCompleted) {
            printf("FAIL: cmdbuf ended in status %ld (error: %s)\n",
                   (long)cmdbuf.status,
                   cmdbuf.error ? [[cmdbuf.error localizedDescription] UTF8String] : "(none)");
            return 5;
        }

        printf("OK: clear-color cmdbuf completed in %.3fs\n",
               (cmdbuf.GPUEndTime - cmdbuf.GPUStartTime));
        printf("NOTE: this program does not blit to the screen; verify-m4.sh\n");
        printf("      captures the framebuffer via noVNC to assert the pixel.\n");
        printf("      Until Phase 3 wires a CAMetalLayer drawable path through\n");
        printf("      our stack, the on-screen presentation side is a stub.\n");
        return 0;
    }
}
