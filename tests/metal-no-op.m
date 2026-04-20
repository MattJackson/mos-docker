// metal-no-op.m — Phase 1 exit criterion: empty Metal command buffer round-trip.
//
// Distinct from metal-probe (which only enumerates). This one actually
// constructs a command queue, commits an empty command buffer, and
// waits for completion. Any non-null default device that can complete
// this without crashing means the device/queue/commit path through
// apple-gfx-pci-linux + libapplegfx-vulkan is functional.
//
// Build on host: clang -framework Foundation -framework Metal metal-no-op.m -o metal-no-op
// Run on VM   : sudo launchctl asuser 501 /tmp/metal-no-op
//
// Exit codes:
//   0 — device obtained, queue created, empty cmdbuf committed and completed
//   1 — MTLCreateSystemDefaultDevice returned null (Phase 1 not yet met)
//   2 — newCommandQueue failed
//   3 — commandBuffer creation failed
//   4 — waitUntilCompleted timed out (5s)
//   5 — command buffer returned error status

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

static const NSTimeInterval kCompletionTimeoutSec = 5.0;

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        printf("=== Phase 1 exit criterion: metal-no-op ===\n");

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) {
            printf("FAIL: MTLCreateSystemDefaultDevice() returned null\n");
            printf("      Phase 1 not yet met — libapplegfx-vulkan device\n");
            printf("      is not publishing as an IOAccelerator Metal can find.\n");
            return 1;
        }
        printf("device:        %s\n", [[device name] UTF8String]);
        printf("registryID:    0x%llx\n", [device registryID]);
        printf("lowPower:      %d\n", [device isLowPower]);
        printf("headless:      %d\n", [device isHeadless]);

        id<MTLCommandQueue> queue = [device newCommandQueue];
        if (!queue) {
            printf("FAIL: [device newCommandQueue] returned null\n");
            return 2;
        }
        printf("command queue: created\n");

        id<MTLCommandBuffer> cmdbuf = [queue commandBuffer];
        if (!cmdbuf) {
            printf("FAIL: [queue commandBuffer] returned null\n");
            return 3;
        }
        printf("command buf:   created (label=%s)\n",
               cmdbuf.label ? [cmdbuf.label UTF8String] : "(none)");

        __block BOOL completed = NO;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [cmdbuf addCompletedHandler:^(id<MTLCommandBuffer> cb) {
            completed = YES;
            dispatch_semaphore_signal(sem);
        }];

        printf("committing empty command buffer...\n");
        [cmdbuf commit];

        long waited = dispatch_semaphore_wait(sem,
            dispatch_time(DISPATCH_TIME_NOW,
                          (int64_t)(kCompletionTimeoutSec * NSEC_PER_SEC)));
        if (waited != 0) {
            printf("FAIL: waitUntilCompleted timed out after %.1fs\n",
                   kCompletionTimeoutSec);
            printf("      Command buffer never completed. Likely the device\n");
            printf("      didn't wire completion notifications yet.\n");
            return 4;
        }

        MTLCommandBufferStatus status = cmdbuf.status;
        NSError *err = cmdbuf.error;
        const char *statusStr =
            (status == MTLCommandBufferStatusCompleted) ? "Completed" :
            (status == MTLCommandBufferStatusError)     ? "Error"     :
            (status == MTLCommandBufferStatusEnqueued)  ? "Enqueued"  :
            (status == MTLCommandBufferStatusCommitted) ? "Committed" :
            (status == MTLCommandBufferStatusScheduled) ? "Scheduled" :
            (status == MTLCommandBufferStatusNotEnqueued) ? "NotEnqueued" :
                                                            "Unknown";
        printf("status:        %s\n", statusStr);
        if (err) {
            printf("error:         %s\n", [[err localizedDescription] UTF8String]);
        }
        if (status != MTLCommandBufferStatusCompleted) {
            printf("FAIL: command buffer did not reach Completed\n");
            return 5;
        }

        printf("\n=== PASS: Phase 1 exit criterion met ===\n");
        printf("device + queue + empty cmdbuf round-trip OK in %.3fs\n",
               (cmdbuf.GPUEndTime - cmdbuf.GPUStartTime));
        return 0;
    }
}
