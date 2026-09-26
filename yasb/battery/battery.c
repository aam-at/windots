/*
 * Prints battery state as JSON for the YASB battery widget:
 * {"icon": "<glyph>", "percent": 56, "time": "53m"}. Native so the widget can
 * poll every second and follow the charger as quickly as the taskbar does.
 *
 * Values come from the same sources as the Windows taskbar: the percent and
 * the time left on battery from GetSystemPowerStatus. Windows has no time to
 * full, so while charging it is the missing capacity over the charge rate.
 * Plugged in but not charging, time says why. Prints nothing without a
 * battery, so the widget hides.
 *
 * Right after the charger is plugged or pulled, Windows' estimate is unknown
 * for a while and the rate reads 0, then a trickle, before it settles. So the
 * charge and discharge rates are smoothed across runs in %TEMP%, and the
 * last session's rate gives a time at once.
 *
 * Build: pwsh -File ../Build-Native.ps1 battery.c -Libs powrprof (setup runs it too).
 * Tests: battery.test.c (scripts/Test-Windots.ps1 runs them).
 */
#include <windows.h>
#include <powrprof.h>
#include <stdio.h>

/* Weight of each one-second sample: rates settle over about ten seconds. */
#define SMOOTHING 0.1

typedef struct {
    double charge_mw, discharge_mw;
} Rates;

static void rates_path(char *out, DWORD size) {
    DWORD length = GetTempPathA(size, out);
    snprintf(out + length, size - length, "yasb-battery-rates.bin");
}

static void smooth(double *average, double sample) {
    *average = *average > 0 ? *average + SMOOTHING * (sample - *average) : sample;
}

static void format_duration(char *out, size_t size, double seconds) {
    long minutes = (long)(seconds / 60);
    if (minutes < 1) minutes = 1;
    if (minutes >= 60) snprintf(out, size, "%ldh %ldm", minutes / 60, minutes % 60);
    else snprintf(out, size, "%ldm", minutes);
}

/* Folds the current rate into the smoothed ones; returns whether it did. */
static int update_rates(Rates *rates, const SYSTEM_BATTERY_STATE *battery) {
    /* Rate is signed in practice: positive charging, negative discharging. */
    LONG rate = (LONG)battery->Rate;
    if (battery->Charging && rate > 0) return smooth(&rates->charge_mw, rate), 1;
    if (battery->Discharging && rate < 0) return smooth(&rates->discharge_mw, -(double)rate), 1;
    return 0;
}

/* The widget's JSON line for this state. */
static void describe(const SYSTEM_POWER_STATUS *power, const SYSTEM_BATTERY_STATE *battery, const Rates *rates, char *out, size_t size) {
    int percent = power->BatteryLifePercent;
    int plugged = power->ACLineStatus == 1;
    char time[32] = "";
    if (plugged) {
        if (battery->Charging && rates->charge_mw > 0 && battery->RemainingCapacity < battery->MaxCapacity)
            format_duration(time, sizeof time, 3600.0 * (battery->MaxCapacity - battery->RemainingCapacity) / rates->charge_mw);
        else if (!battery->Charging)
            snprintf(time, sizeof time, percent >= 100 ? "full" : "not charging");
    }
    else if (power->BatteryLifeTime != (DWORD)-1)
        format_duration(time, sizeof time, power->BatteryLifeTime);
    else if (rates->discharge_mw > 0)
        format_duration(time, sizeof time, 3600.0 * battery->RemainingCapacity / rates->discharge_mw);

    /* Segoe Fluent Battery0..10 (U+EBA0) and BatteryCharging0..10 (U+EBAB):
       the taskbar's eleven levels, with the plug whenever on AC. UTF-8 is
       EE AE xx for the whole range. */
    int glyph = (plugged ? 0xAB : 0xA0) + (percent + 5) / 10;
    snprintf(out, size, "{\"icon\": \"\xEE\xAE%c\", \"percent\": %d, \"time\": \"%s\"}", glyph, percent, time);
}

int main(void) {
    SYSTEM_POWER_STATUS power;
    if (!GetSystemPowerStatus(&power) || power.BatteryFlag == 128 || power.BatteryLifePercent > 100) return 0;

    SYSTEM_BATTERY_STATE battery;
    if (CallNtPowerInformation(SystemBatteryState, NULL, 0, &battery, sizeof battery) != 0) return 0;

    char path[MAX_PATH];
    rates_path(path, sizeof path);
    Rates rates = {0};
    FILE *file = fopen(path, "rb");
    if (file) {
        if (fread(&rates, sizeof rates, 1, file) != 1) rates = (Rates){0};
        fclose(file);
    }
    if (update_rates(&rates, &battery) && (file = fopen(path, "wb"))) {
        fwrite(&rates, sizeof rates, 1, file);
        fclose(file);
    }

    char json[128];
    describe(&power, &battery, &rates, json, sizeof json);
    puts(json);
    return 0;
}
