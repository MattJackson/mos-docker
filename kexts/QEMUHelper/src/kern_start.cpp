#include <IOKit/IOLib.h>
#include <IOKit/IOService.h>
#include <IOKit/IOTimerEventSource.h>
#include <mach/mach_types.h>

static IOService *gFramebuffer = nullptr;

class QEMUHelper : public IOService {
    OSDeclareDefaultStructors(QEMUHelper)

    IOTimerEventSource *timer;
    IOWorkLoop *workLoop;
    int patchAttempts;

public:
    static bool framebufferMatched(void *target, void *refCon, IOService *newService, IONotifier *notifier) {
        IOLog("QEMUHelper: framebuffer appeared! class=%s\n", newService->getMetaClass()->getClassName());
        newService->retain();
        gFramebuffer = newService;
        // Start timer to patch after IONDRVFramebuffer finishes init
        QEMUHelper *self = (QEMUHelper *)target;
        if (self->timer) {
            self->timer->setTimeoutMS(5000); // 5 seconds
            IOLog("QEMUHelper: timer armed, will patch in 5 seconds\n");
        }
        return true;
    }

    static void timerFired(OSObject *owner, IOTimerEventSource *sender) {
        if (!gFramebuffer) return;

        QEMUHelper *self = (QEMUHelper *)owner;
        self->patchAttempts++;

        OSNumber *vramSize = OSNumber::withNumber((uint64_t)268435456, 64);
        if (vramSize) {
            gFramebuffer->setProperty("IOFBMemorySize", vramSize);
            vramSize->release();
            IOLog("QEMUHelper: IOFBMemorySize set to 256MB (attempt %d)\n", self->patchAttempts);
        }

        // Keep re-patching every 10 seconds for 5 attempts in case it gets overwritten
        if (self->patchAttempts < 5) {
            sender->setTimeoutMS(10000);
        } else {
            IOLog("QEMUHelper: patching complete after %d attempts\n", self->patchAttempts);
        }
    }

    bool start(IOService *provider) override {
        IOLog("QEMUHelper::start called!\n");
        if (!IOService::start(provider)) return false;

        patchAttempts = 0;

        // Create timer
        workLoop = getWorkLoop();
        if (workLoop) {
            timer = IOTimerEventSource::timerEventSource(this, timerFired);
            if (timer) {
                workLoop->addEventSource(timer);
            }
        }

        // Register notification for IOFramebuffer
        OSDictionary *matching = IOService::serviceMatching("IOFramebuffer");
        if (matching) {
            addMatchingNotification(gIOPublishNotification, matching,
                &QEMUHelper::framebufferMatched, this);
            IOLog("QEMUHelper: notification registered\n");
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
