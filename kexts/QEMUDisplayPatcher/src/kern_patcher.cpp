//
//  kern_patcher.cpp
//  QEMUDisplayPatcher
//
//  onPatcherLoad (consistent) + loadKinfo + routeMultiple on kext idx.
//

#include <Headers/kern_api.hpp>
#include <Headers/kern_util.hpp>
#include <Headers/kern_patcher.hpp>

#include <IOKit/IOLib.h>

#include "qdp_patcher.hpp"

// iMac EDID
static const unsigned char edid[128] = {
    0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x06, 0x10, 0xc3, 0x9c, 0x00, 0x00, 0x00, 0x00,
    0x01, 0x22, 0x01, 0x03, 0x80, 0x3c, 0x22, 0x78, 0x0a, 0xee, 0x91, 0xa3, 0x54, 0x4c, 0x99, 0x26,
    0x0f, 0x50, 0x54, 0x21, 0x08, 0x00, 0xd1, 0xc0, 0x81, 0xc0, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
    0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x02, 0x3a, 0x80, 0x18, 0x71, 0x38, 0x2d, 0x40, 0x58, 0x2c,
    0x45, 0x00, 0x06, 0x44, 0x21, 0x00, 0x00, 0x1e, 0x00, 0x00, 0x00, 0xfc, 0x00, 0x69, 0x4d, 0x61,
    0x63, 0x0a, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x00, 0x00, 0x00, 0xfd, 0x00, 0x38,
    0x4c, 0x1e, 0x51, 0x11, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff,
    0x00, 0x4d, 0x4f, 0x53, 0x31, 0x35, 0x56, 0x4d, 0x0a, 0x20, 0x20, 0x20, 0x20, 0x20, 0x00, 0x71,
};

// Originals
static IOReturn (*orgEnableController)(void *) = nullptr;
static bool (*orgHasDDCConnect)(void *, int32_t) = nullptr;
static IOReturn (*orgGetDDCBlock)(void *, int32_t, uint32_t, uint32_t, uint32_t, uint8_t *, uint64_t *) = nullptr;
static IOReturn (*orgSetGammaTable)(void *, uint32_t, uint32_t, uint32_t, void *) = nullptr;

static IOReturn patchedEnableController(void *that) {
    IOLog("QDP: enableController\n");
    return orgEnableController ? orgEnableController(that) : 0;
}

static bool patchedHasDDCConnect(void *that, int32_t idx) {
    return true;
}

static IOReturn patchedGetDDCBlock(void *that, int32_t ci, uint32_t bn,
    uint32_t bt, uint32_t opts, uint8_t *data, uint64_t *length) {
    if (bn != 1 || !data || !length)
        return orgGetDDCBlock ? orgGetDDCBlock(that, ci, bn, bt, opts, data, length) : 0xE00002BC;
    uint64_t len = (*length < 128) ? *length : 128;
    memcpy(data, edid, (size_t)len);
    *length = len;
    return 0;
}

static IOReturn patchedSetGammaTable(void *that, uint32_t cc, uint32_t dc, uint32_t dw, void *d) {
    return 0;
}

static const char *kextPath[] {
    "/System/Library/Extensions/IONDRVSupport.kext/IONDRVSupport"
};

static void onPatcherLoad(void *user, KernelPatcher &patcher) {
    IOLog("QDP: onPatcherLoad\n");

    // Load IONDRVSupport kext info
    size_t idx = patcher.loadKinfo(
        "com.apple.iokit.IONDRVSupport",
        kextPath, arrsize(kextPath),
        false, false, true  // not kernel, not fsonly, fsfallback=true
    );

    IOLog("QDP: loadKinfo=%lu err=%d\n", (unsigned long)idx, patcher.getError());
    patcher.clearError();

    if (idx == 0 || idx == (size_t)-1) {
        IOLog("QDP: kinfo load failed\n");
        return;
    }

    // Update running info
    patcher.updateRunningInfo(idx, 0, 0);
    patcher.clearError();

    // Route
    KernelPatcher::RouteRequest reqs[] = {
        {"__ZN17IONDRVFramebuffer16enableControllerEv",
         patchedEnableController, orgEnableController},
        {"__ZN17IONDRVFramebuffer13hasDDCConnectEi",
         patchedHasDDCConnect, orgHasDDCConnect},
        {"__ZN17IONDRVFramebuffer11getDDCBlockEijjjPhPy",
         patchedGetDDCBlock, orgGetDDCBlock},
        {"__ZN17IONDRVFramebuffer13setGammaTableEjjjPv",
         patchedSetGammaTable, orgSetGammaTable},
    };

    patcher.routeMultiple(idx, reqs, arrsize(reqs));
    IOLog("QDP: routeMultiple err=%d\n", patcher.getError());
    patcher.clearError();

    // Check what actually got routed
    IOLog("QDP: orgEnable=%p orgDDC=%p orgGamma=%p\n",
          orgEnableController, orgHasDDCConnect, orgSetGammaTable);
}

void pluginStart() {
    IOLog("QDP: pluginStart\n");
    lilu.onPatcherLoadForce(onPatcherLoad);
}
