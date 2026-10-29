/*
 * SPDX-FileCopyrightText: The LineageOS Project
 * SPDX-License-Identifier: Apache-2.0
 */

/*
 * Health HAL for PCs: the AOSP default implementation, which reads the battery and chargers
 * from /sys/class/power_supply (ACPI batteries and AC adapters on laptops), plus:
 *
 * - Desktops (no battery) report a full battery on AC power, as the virtual battery did
 *   before, instead of an absent battery at 0%, which shows an empty / unknown battery
 *   and fails recovery's battery check before installing.
 * - Desktops never suspend: the service holds a wakelock for them. Not every USB keyboard
 *   or mouse can wake a desktop, and they have no lid. Laptops suspend as usual (screen
 *   off, lid closed).
 */

#define LOG_TAG "android.hardware.health-service.pc"

#include <atomic>
#include <memory>
#include <optional>

#include <android-base/logging.h>
#include <android/binder_interface_utils.h>
#include <health-impl/Health.h>
#include <health/utils.h>

#ifndef __ANDROID_RECOVERY__
#include <wakelock/wakelock.h>
#endif

using aidl::android::hardware::health::BatteryCapacityLevel;
using aidl::android::hardware::health::BatteryHealth;
using aidl::android::hardware::health::BatteryStatus;
using aidl::android::hardware::health::HalHealthLoop;
using aidl::android::hardware::health::Health;
using aidl::android::hardware::health::HealthInfo;

namespace {

class PcHealth : public Health {
  public:
    using Health::Health;

    // Whether the kernel reported a battery the last time health info was read
    bool HasBattery() const { return has_battery_; }

  protected:
    void UpdateHealthInfo(HealthInfo* info) override {
        has_battery_ = info->batteryPresent;
        if (info->batteryPresent) return;

        info->batteryPresent = true;
        info->chargerAcOnline = true;
        info->batteryLevel = 100;
        info->batteryStatus = BatteryStatus::FULL;
        info->batteryHealth = BatteryHealth::GOOD;
        info->batteryCapacityLevel = BatteryCapacityLevel::FULL;
        info->batteryTemperatureTenthsCelsius = 250;
        info->batteryVoltageMillivolts = 5000;
        info->batteryTechnology = "";
    }

  private:
    std::atomic<bool> has_battery_ = false;
};

}  // namespace

int main(int, char** argv) {
#ifdef __ANDROID_RECOVERY__
    android::base::InitLogging(argv, android::base::KernelLogger);
#else
    (void)argv;
#endif

    auto config = std::make_unique<healthd_config>();
    ::android::hardware::health::InitHealthdConfig(config.get());
    auto binder = ndk::SharedRefBase::make<PcHealth>("default", std::move(config));

#ifndef __ANDROID_RECOVERY__
    // No battery: a desktop, which stays awake (see above). WakeLock can't be assigned, so the
    // optional is initialized directly.
    HealthInfo info;
    const bool desktop = binder->getHealthInfo(&info).isOk() && !binder->HasBattery();
    LOG(INFO) << (desktop ? "No battery: a desktop, keeping it awake"
                          : "Battery found: suspend allowed");
    const std::optional<android::wakelock::WakeLock> desktop_wakelock =
            desktop ? android::wakelock::WakeLock::tryGet("pc_desktop")
                    : std::optional<android::wakelock::WakeLock>();
    if (desktop && !desktop_wakelock) LOG(ERROR) << "Failed to take the wakelock";
#endif

    auto hal_health_loop = std::make_shared<HalHealthLoop>(binder, binder);
    return hal_health_loop->StartLoop();
}
