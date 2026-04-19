//
//  kern_start.cpp
//  QEMUDisplayPatcher
//
//  Lilu plugin that patches IONDRVFramebuffer to behave as QEMUDisplay.
//  Runs from Boot KC — no System KC dependency.
//

#include <Headers/plugin_start.hpp>
#include <Headers/kern_api.hpp>
#include <Headers/kern_util.hpp>

#include "qdp_patcher.hpp"

static const char *bootargOff[] { "-qdpoff" };       // disable QDP plugin entirely
static const char *bootargDbg[] { "-qdpdbg" };       // verbose debug
static const char *bootargBeta[] { "-qdpbeta" };     // (Lilu beta mode)
// -qdpbasic: parsed inside pluginStart() — when set, every hook becomes pure
//            passthrough to original (no SMC writes, no setProperty, no EDID
//            substitution). Lets us toggle the fancy QDP behaviour off at
//            runtime without rebuilding, leaving Lilu + the routed surface
//            in place. Layered with BASELINE=1 build (which omits Lilu/QDP
//            entirely) for graduated recovery.

PluginConfiguration ADDPR(config) {
    xStringify(PRODUCT_NAME),
    parseModuleVersion(xStringify(MODULE_VERSION)),
    LiluAPI::AllowNormal | LiluAPI::AllowInstallerRecovery,
    bootargOff, arrsize(bootargOff),
    bootargDbg, arrsize(bootargDbg),
    bootargBeta, arrsize(bootargBeta),
    KernelVersion::Sequoia,   // min
    KernelVersion::Sequoia,   // max
    pluginStart
};
