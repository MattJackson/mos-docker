// metal-triangle.m — M5 scaffold. Submits a minimal shader-backed draw:
// three vertices, a vertex shader that passes position through, a fragment
// shader that writes a solid color. The shader is embedded as MSL source
// and compiled at runtime via newLibraryWithSource:. When Phase 3 lands,
// this exercises the AIR → LLVM → SPIR-V → lavapipe pipeline end-to-end.
//
// STATUS: STUB. Same caveat as metal-clear-screen.m — this program
// renders into an offscreen BGRA8 texture (no drawable). verify-m5.sh
// captures the resulting frame via the VNC path and diffs against
// tests/screenshots/reference/triangle.png.
//
// Build on a Mac host:
//   clang -framework Foundation -framework Metal -framework QuartzCore \
//         metal-triangle.m -o metal-triangle
//
// Run on the VM:
//   scp metal-triangle <vm-user>@<vm-ip>:/tmp/
//   ssh <vm-user>@<vm-ip> 'sudo -n launchctl asuser 501 /tmp/metal-triangle'
//
// Exit codes:
//   0 — cmdbuf completed; triangle was drawn into the offscreen texture
//   1 — MTLCreateSystemDefaultDevice returned null
//   2 — newCommandQueue / library / pipeline creation failed
//   3 — texture / buffer creation failed
//   4 — renderCommandEncoder or drawPrimitives failed
//   5 — waitUntilCompleted timed out or cmdbuf ended in Error
//
// The MSL below compiles any time on a Mac host SDK. It will NOT compile
// to AIR-then-run until Phase 3.B (shader translation) is in place; this
// is the whole point of the M5 gate — exercising that path.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

static const NSTimeInterval kCompletionTimeoutSec = 10.0;
static const NSUInteger kWidth = 1920;
static const NSUInteger kHeight = 1080;

// Minimal vertex+fragment shader pair. Vertex shader takes a float2 and
// emits a clip-space position; fragment shader writes solid green. The
// triangle covers the center ~30% of the viewport so the diff tolerance
// has something easy to latch onto.
static NSString * const kShaderSource = @
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"\n"
"struct VSIn { float2 pos; };\n"
"struct VSOut { float4 pos [[position]]; };\n"
"\n"
"vertex VSOut vs_main(uint vid [[vertex_id]],\n"
"                     const device VSIn *verts [[buffer(0)]]) {\n"
"    VSOut o;\n"
"    o.pos = float4(verts[vid].pos, 0.0, 1.0);\n"
"    return o;\n"
"}\n"
"\n"
"fragment float4 fs_main(VSOut in [[stage_in]]) {\n"
"    return float4(0.0, 1.0, 0.0, 1.0); // green\n"
"}\n";

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        printf("=== M5 stub: metal-triangle ===\n");

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) { printf("FAIL: no device\n"); return 1; }
        printf("device: %s\n", [[device name] UTF8String]);

        id<MTLCommandQueue> queue = [device newCommandQueue];
        if (!queue) { printf("FAIL: no queue\n"); return 2; }

        NSError *err = nil;
        id<MTLLibrary> lib = [device newLibraryWithSource:kShaderSource
                                                  options:nil
                                                    error:&err];
        if (!lib) {
            printf("FAIL: newLibraryWithSource: %s\n",
                   err ? [[err localizedDescription] UTF8String] : "(nil err)");
            return 2;
        }
        id<MTLFunction> vs = [lib newFunctionWithName:@"vs_main"];
        id<MTLFunction> fs = [lib newFunctionWithName:@"fs_main"];
        if (!vs || !fs) { printf("FAIL: function lookup\n"); return 2; }

        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = vs;
        pd.fragmentFunction = fs;
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        id<MTLRenderPipelineState> pso =
            [device newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!pso) {
            printf("FAIL: PSO: %s\n",
                   err ? [[err localizedDescription] UTF8String] : "(nil err)");
            return 2;
        }

        // Triangle: center 30% of clip space.
        const float verts[6] = {
             0.0f,  0.3f,
            -0.3f, -0.3f,
             0.3f, -0.3f,
        };
        id<MTLBuffer> vbuf = [device newBufferWithBytes:verts
                                                 length:sizeof(verts)
                                                options:MTLResourceStorageModeManaged];
        if (!vbuf) { printf("FAIL: vertex buffer\n"); return 3; }

        MTLTextureDescriptor *td = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                         width:kWidth
                                        height:kHeight
                                     mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModeManaged;
        id<MTLTexture> tex = [device newTextureWithDescriptor:td];
        if (!tex) { printf("FAIL: texture\n"); return 3; }

        MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
        rpd.colorAttachments[0].texture = tex;
        rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
        rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
        // Clear to dark grey so the green triangle is obvious.
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0.1, 0.1, 0.1, 1.0);

        id<MTLCommandBuffer> cmdbuf = [queue commandBuffer];
        if (!cmdbuf) { printf("FAIL: cmdbuf\n"); return 4; }
        cmdbuf.label = @"m5-triangle";

        id<MTLRenderCommandEncoder> enc =
            [cmdbuf renderCommandEncoderWithDescriptor:rpd];
        if (!enc) { printf("FAIL: encoder\n"); return 4; }
        [enc setRenderPipelineState:pso];
        [enc setVertexBuffer:vbuf offset:0 atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [enc endEncoding];

        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [cmdbuf addCompletedHandler:^(id<MTLCommandBuffer> cb) {
            dispatch_semaphore_signal(sem);
        }];

        printf("committing triangle draw...\n");
        [cmdbuf commit];

        long waited = dispatch_semaphore_wait(sem,
            dispatch_time(DISPATCH_TIME_NOW,
                          (int64_t)(kCompletionTimeoutSec * NSEC_PER_SEC)));
        if (waited != 0) {
            printf("FAIL: wait timed out after %.1fs\n", kCompletionTimeoutSec);
            return 5;
        }
        if (cmdbuf.status != MTLCommandBufferStatusCompleted) {
            printf("FAIL: cmdbuf status=%ld error=%s\n",
                   (long)cmdbuf.status,
                   cmdbuf.error ? [[cmdbuf.error localizedDescription] UTF8String] : "(none)");
            return 5;
        }

        printf("OK: triangle cmdbuf completed in %.3fs\n",
               (cmdbuf.GPUEndTime - cmdbuf.GPUStartTime));
        printf("NOTE: verify-m5.sh captures via noVNC and diffs against\n");
        printf("      tests/screenshots/reference/triangle.png once Phase 3 wires\n");
        printf("      presentation. Until then, exit 0 means the shader path did\n");
        printf("      not panic the guest — that is the useful M5 signal today.\n");
        return 0;
    }
}
