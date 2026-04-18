#include <IOKit/IOLib.h>
#include <IOKit/IOService.h>
#include <IOKit/IOTimerEventSource.h>
#include <mach/mach_types.h>

// iMac 27" Retina display EDID — Apple vendor, 1920x1080@60Hz, P3 color
static const uint8_t iMacEDID[] = {
    0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x06, 0x10, 0x34, 0xA0, 0x00, 0x00, 0x00, 0x00,
    0x30, 0x1E, 0x01, 0x04, 0xB5, 0x3C, 0x22, 0x78, 0x3A, 0xD6, 0x65, 0xA6, 0x56, 0x51, 0xA0, 0x26,
    0x0D, 0x50, 0x54, 0x00, 0x00, 0x00, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
    0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x02, 0x3A, 0x80, 0x18, 0x71, 0x38, 0x2D, 0x40, 0x58, 0x2C,
    0x45, 0x00, 0xC0, 0x58, 0x21, 0x00, 0x00, 0x1E, 0x00, 0x00, 0x00, 0xFC, 0x00, 0x69, 0x4D, 0x61,
    0x63, 0x0A, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x00, 0x00, 0x00, 0xFD, 0x00, 0x30,
    0x3E, 0x1E, 0x64, 0x16, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x68,
};

static IOService *gFramebuffer = nullptr;

class QEMUHelper : public IOService {
    OSDeclareDefaultStructors(QEMUHelper)

    IOTimerEventSource *timer;
    IOWorkLoop *workLoop;
    int patchAttempts;

    static void patchDisplay(IOService *fb) {
        // VRAM: 256MB
        OSNumber *vramSize = OSNumber::withNumber((uint64_t)268435456, 64);
        if (vramSize) {
            fb->setProperty("IOFBMemorySize", vramSize);
            vramSize->release();
        }

        // EDID: iMac 27" identity
        OSData *edidData = OSData::withBytes(iMacEDID, sizeof(iMacEDID));
        if (edidData) {
            fb->setProperty("IODisplayEDID", edidData);
            edidData->release();
        }

        // Display identity: Apple iMac
        OSNumber *vendorID = OSNumber::withNumber((uint32_t)0x610, 32);
        OSNumber *productID = OSNumber::withNumber((uint32_t)0xA034, 32);
        if (vendorID && productID) {
            fb->setProperty("DisplayVendorID", vendorID);
            fb->setProperty("DisplayProductID", productID);
            vendorID->release();
            productID->release();
        }
    }

public:
    static bool framebufferMatched(void *target, void *refCon, IOService *newService, IONotifier *notifier) {
        IOLog("QEMUHelper: framebuffer appeared! class=%s\n", newService->getMetaClass()->getClassName());
        newService->retain();
        gFramebuffer = newService;
        QEMUHelper *self = (QEMUHelper *)target;
        if (self->timer) {
            self->timer->setTimeoutMS(5000);
            IOLog("QEMUHelper: timer armed\n");
        }
        return true;
    }

    static void timerFired(OSObject *owner, IOTimerEventSource *sender) {
        if (!gFramebuffer) return;

        QEMUHelper *self = (QEMUHelper *)owner;
        self->patchAttempts++;

        patchDisplay(gFramebuffer);
        IOLog("QEMUHelper: display patched (attempt %d) — VRAM=256MB, EDID=iMac, Vendor=Apple\n", self->patchAttempts);

        if (self->patchAttempts < 5) {
            sender->setTimeoutMS(10000);
        } else {
            IOLog("QEMUHelper: patching complete\n");
        }
    }

    bool start(IOService *provider) override {
        IOLog("QEMUHelper::start\n");
        if (!IOService::start(provider)) return false;

        patchAttempts = 0;
        workLoop = getWorkLoop();
        if (workLoop) {
            timer = IOTimerEventSource::timerEventSource(this, timerFired);
            if (timer) workLoop->addEventSource(timer);
        }

        OSDictionary *matching = IOService::serviceMatching("IOFramebuffer");
        if (matching) {
            addMatchingNotification(gIOPublishNotification, matching,
                &QEMUHelper::framebufferMatched, this);
            IOLog("QEMUHelper: watching for framebuffer\n");
        }
        return true;
    }

    void stop(IOService *provider) override {
        if (timer) {
            timer->cancelTimeout();
            if (workLoop) workLoop->removeEventSource(timer);
            timer->release();
            timer = nullptr;
        }
        if (gFramebuffer) {
            gFramebuffer->release();
            gFramebuffer = nullptr;
        }
        IOService::stop(provider);
    }
};

OSDefineMetaClassAndStructors(QEMUHelper, IOService)
