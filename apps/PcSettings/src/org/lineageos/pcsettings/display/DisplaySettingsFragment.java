/*
 * SPDX-FileCopyrightText: The LineageOS Project
 * SPDX-License-Identifier: Apache-2.0
 */

package org.lineageos.pcsettings.display;

import android.app.AlertDialog;
import android.hardware.display.DisplayManager;
import android.os.Bundle;
import android.os.PowerManager;
import android.os.RemoteException;
import android.os.SystemProperties;
import android.util.Log;
import android.view.Display;
import android.view.Surface;
import android.view.WindowManagerGlobal;

import androidx.preference.ListPreference;
import androidx.preference.Preference;

import com.android.settingslib.widget.SettingsBasePreferenceFragment;

import org.lineageos.pcsettings.R;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Screen rotation, resolution and refresh rate.
 *
 * With a GPU driver, the display reports its modes, and the choice is applied right away as
 * the user preferred display mode. With the firmware framebuffer (simpledrm, for GPUs without
 * a driver yet), the mode is set by GRUB when booting: the resolution is then saved
 * for GRUB (persist.sys.pc.boot_resolution, see init.pc.rc) and used after a restart.
 */
public class DisplaySettingsFragment extends SettingsBasePreferenceFragment
        implements Preference.OnPreferenceChangeListener {

    private static final String TAG = "PcDisplaySettings";

    private static final String KEY_ROTATION = "rotation";
    private static final String KEY_RESOLUTION = "resolution";
    private static final String KEY_REFRESH_RATE = "refresh_rate";

    private static final String AUTOMATIC = "auto";

    // init.pc.rc saves it to GRUB's environment, and GRUB sets this mode before booting
    private static final String PROP_BOOT_RESOLUTION = "persist.sys.pc.boot_resolution";

    // Common modes for the firmware framebuffer. GRUB falls back to the automatic (native)
    // mode when the firmware doesn't have the chosen one.
    private static final String[] BOOT_RESOLUTIONS = {
        "3840x2160", "2560x1600", "2560x1440", "1920x1200", "1920x1080", "1680x1050",
        "1600x900", "1440x900", "1366x768", "1280x1024", "1280x800", "1280x720", "1024x768",
    };

    private DisplayManager mDisplayManager;
    private Display mDisplay;
    private ListPreference mRotation;
    private ListPreference mResolution;
    private ListPreference mRefreshRate;

    @Override
    public void onCreatePreferences(Bundle savedInstanceState, String rootKey) {
        setPreferencesFromResource(R.xml.display_settings, rootKey);

        mDisplayManager = requireContext().getSystemService(DisplayManager.class);
        mDisplay = mDisplayManager.getDisplay(Display.DEFAULT_DISPLAY);

        mRotation = findPreference(KEY_ROTATION);
        mResolution = findPreference(KEY_RESOLUTION);
        mRefreshRate = findPreference(KEY_REFRESH_RATE);
        mRotation.setOnPreferenceChangeListener(this);
        mResolution.setOnPreferenceChangeListener(this);
        mRefreshRate.setOnPreferenceChangeListener(this);

        setUpRotation();
        if (isFirmwareFramebuffer()) {
            setUpBootResolution();
        } else {
            mResolution.setSummaryProvider(ListPreference.SimpleSummaryProvider.getInstance());
            mRefreshRate.setSummaryProvider(ListPreference.SimpleSummaryProvider.getInstance());
            updateModes();
        }
    }

    @Override
    public boolean onPreferenceChange(Preference preference, Object newValue) {
        final String value = (String) newValue;
        if (preference == mRotation) {
            setRotation(Integer.parseInt(value));
        } else if (preference == mResolution && isFirmwareFramebuffer()) {
            setBootResolution(value);
        } else if (preference == mResolution) {
            mResolution.setValue(value);
            // Keep the refresh rate only if the new resolution has it
            String refreshRate = mRefreshRate.getValue();
            if (!AUTOMATIC.equals(refreshRate)
                    && findMode(value, Float.parseFloat(refreshRate)) == null) {
                refreshRate = AUTOMATIC;
            }
            setMode(value, refreshRate);
            updateModes();
            return false;
        } else if (preference == mRefreshRate) {
            setMode(mResolution.getValue(), value);
        }
        return true;
    }

    // Without a driver for the GPU (pc_gpu_detect), the display is the firmware framebuffer,
    // whose mode can't change at runtime, and graphics are software rendered (ANGLE).
    // virt-common's init sets ro.hardware.egl to mesa only with a GPU driver. The number of
    // modes doesn't tell: built-in panels often have a single one with a driver too.
    private boolean isFirmwareFramebuffer() {
        return !"mesa".equals(SystemProperties.get("ro.hardware.egl"));
    }

    // Rotation

    private void setUpRotation() {
        mRotation.setEntries(new CharSequence[] {
            getString(R.string.rotation_0), getString(R.string.rotation_90),
            getString(R.string.rotation_180), getString(R.string.rotation_270),
        });
        mRotation.setEntryValues(new CharSequence[] {
            String.valueOf(Surface.ROTATION_0), String.valueOf(Surface.ROTATION_90),
            String.valueOf(Surface.ROTATION_180), String.valueOf(Surface.ROTATION_270),
        });
        mRotation.setValue(String.valueOf(mDisplay.getRotation()));
        mRotation.setSummaryProvider(ListPreference.SimpleSummaryProvider.getInstance());
    }

    private void setRotation(int rotation) {
        try {
            // Locks the display to this rotation; it's kept across restarts
            WindowManagerGlobal.getWindowManagerService().freezeDisplayRotation(
                    Display.DEFAULT_DISPLAY, rotation, TAG);
        } catch (RemoteException e) {
            Log.e(TAG, "Failed to set the rotation", e);
        }
    }

    // Display modes (GPU driver)

    private void updateModes() {
        final Display.Mode current = mDisplay.getMode();
        final Display.Mode preferred = mDisplayManager.getGlobalUserPreferredDisplayMode();
        final String resolution = preferred != null && preferred.getPhysicalWidth() > 0
                ? resolutionValue(preferred.getPhysicalWidth(), preferred.getPhysicalHeight())
                : AUTOMATIC;
        final String refreshRate = preferred != null && preferred.getRefreshRate() > 0
                ? String.valueOf(preferred.getRefreshRate())
                : AUTOMATIC;

        // Resolutions, largest first
        final Map<String, CharSequence> resolutions = new LinkedHashMap<>();
        resolutions.put(AUTOMATIC, getString(R.string.automatic_with_current,
                resolutionEntry(current.getPhysicalWidth(), current.getPhysicalHeight())));
        final List<Display.Mode> modes = new ArrayList<>(List.of(mDisplay.getSupportedModes()));
        modes.sort((a, b) -> Integer.compare(b.getPhysicalWidth() * b.getPhysicalHeight(),
                a.getPhysicalWidth() * a.getPhysicalHeight()));
        for (Display.Mode mode : modes) {
            resolutions.putIfAbsent(resolutionValue(mode.getPhysicalWidth(),
                    mode.getPhysicalHeight()),
                    resolutionEntry(mode.getPhysicalWidth(), mode.getPhysicalHeight()));
        }
        setEntries(mResolution, resolutions, resolution);

        // Refresh rates of the chosen (or, when automatic, current) resolution, highest first
        final String ratesFor = AUTOMATIC.equals(resolution)
                ? resolutionValue(current.getPhysicalWidth(), current.getPhysicalHeight())
                : resolution;
        final Map<String, CharSequence> refreshRates = new LinkedHashMap<>();
        refreshRates.put(AUTOMATIC, getString(R.string.automatic_with_current,
                refreshRateEntry(current.getRefreshRate())));
        modes.sort((a, b) -> Float.compare(b.getRefreshRate(), a.getRefreshRate()));
        for (Display.Mode mode : modes) {
            if (ratesFor.equals(resolutionValue(mode.getPhysicalWidth(),
                    mode.getPhysicalHeight()))) {
                refreshRates.putIfAbsent(String.valueOf(mode.getRefreshRate()),
                        refreshRateEntry(mode.getRefreshRate()));
            }
        }
        setEntries(mRefreshRate, refreshRates, refreshRate);
    }

    private void setMode(String resolution, String refreshRate) {
        if (AUTOMATIC.equals(resolution) && AUTOMATIC.equals(refreshRate)) {
            mDisplayManager.clearGlobalUserPreferredDisplayMode();
            return;
        }
        final Display.Mode.Builder builder = new Display.Mode.Builder();
        if (!AUTOMATIC.equals(resolution)) {
            final String[] size = resolution.split("x");
            builder.setResolution(Integer.parseInt(size[0]), Integer.parseInt(size[1]));
        }
        if (!AUTOMATIC.equals(refreshRate)) {
            builder.setRefreshRate(Float.parseFloat(refreshRate));
        }
        mDisplayManager.setGlobalUserPreferredDisplayMode(builder.build());
    }

    private Display.Mode findMode(String resolution, float refreshRate) {
        for (Display.Mode mode : mDisplay.getSupportedModes()) {
            if ((AUTOMATIC.equals(resolution) || resolution.equals(
                    resolutionValue(mode.getPhysicalWidth(), mode.getPhysicalHeight())))
                    && Math.abs(mode.getRefreshRate() - refreshRate) < 0.01f) {
                return mode;
            }
        }
        return null;
    }

    // Boot resolution (firmware framebuffer)

    private void setUpBootResolution() {
        final Display.Mode current = mDisplay.getMode();
        final Map<String, CharSequence> resolutions = new LinkedHashMap<>();
        resolutions.put(AUTOMATIC, getString(R.string.automatic));
        for (String resolution : BOOT_RESOLUTIONS) {
            final String[] size = resolution.split("x");
            resolutions.put(resolution, resolutionEntry(Integer.parseInt(size[0]),
                    Integer.parseInt(size[1])));
        }
        setEntries(mResolution, resolutions,
                SystemProperties.get(PROP_BOOT_RESOLUTION, AUTOMATIC));
        mResolution.setTitle(R.string.boot_resolution_title);
        mResolution.setSummary(getString(R.string.boot_resolution_summary,
                resolutionEntry(current.getPhysicalWidth(), current.getPhysicalHeight())));

        mRefreshRate.setEnabled(false);
        mRefreshRate.setSummary(R.string.refresh_rate_unavailable);
    }

    private void setBootResolution(String resolution) {
        SystemProperties.set(PROP_BOOT_RESOLUTION, resolution);
        new AlertDialog.Builder(requireContext())
                .setTitle(R.string.restart_title)
                .setMessage(R.string.restart_message)
                .setPositiveButton(R.string.restart_now, (dialog, which) ->
                        requireContext().getSystemService(PowerManager.class).reboot(null))
                .setNegativeButton(R.string.restart_later, null)
                .show();
    }

    // Helpers

    private static void setEntries(ListPreference preference, Map<String, CharSequence> entries,
            String value) {
        preference.setEntries(entries.values().toArray(new CharSequence[0]));
        preference.setEntryValues(entries.keySet().toArray(new CharSequence[0]));
        preference.setValue(entries.containsKey(value) ? value : AUTOMATIC);
    }

    private static String resolutionValue(int width, int height) {
        return width + "x" + height;
    }

    private String resolutionEntry(int width, int height) {
        return getString(R.string.resolution_entry, width, height);
    }

    private String refreshRateEntry(float refreshRate) {
        // 60, 59.94, 143.86, ...
        final String rate = Math.abs(refreshRate - Math.round(refreshRate)) < 0.005f
                ? String.valueOf(Math.round(refreshRate))
                : String.format("%.2f", refreshRate);
        return getString(R.string.refresh_rate_entry, rate);
    }
}
