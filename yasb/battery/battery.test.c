/*
 * Tests for battery.c's logic (no real battery needed). Run by
 * scripts\Test-Windots.ps1, or by hand:
 *   gcc -Wall -o battery.test.exe battery.test.c -lpowrprof && battery.test.exe
 */
#define main battery_main
#include "battery.c"
#undef main

static int failures;

#define CHECK_STR(actual, expected) check_str(__LINE__, actual, expected)
static void check_str(int line, const char *actual, const char *expected) {
    if (strcmp(actual, expected) == 0) return;
    printf("battery.test.c:%d: got  %s\n                  want %s\n", line, actual, expected);
    failures++;
}

#define CHECK(condition) do { if (!(condition)) { printf("battery.test.c:%d: failed: %s\n", __LINE__, #condition); failures++; } } while (0)

static SYSTEM_POWER_STATUS power(int plugged, int percent, DWORD life_seconds) {
    SYSTEM_POWER_STATUS p = {0};
    p.ACLineStatus = (BYTE)plugged;
    p.BatteryLifePercent = (BYTE)percent;
    p.BatteryLifeTime = life_seconds;
    return p;
}

static SYSTEM_BATTERY_STATE state(int charging, DWORD remaining_mwh, DWORD max_mwh, LONG rate_mw) {
    SYSTEM_BATTERY_STATE s = {0};
    s.AcOnLine = charging;
    s.Charging = (BOOLEAN)charging;
    s.Discharging = (BOOLEAN)(rate_mw < 0);
    s.RemainingCapacity = remaining_mwh;
    s.MaxCapacity = max_mwh;
    s.Rate = (DWORD)rate_mw;
    return s;
}

static const char *run(SYSTEM_POWER_STATUS p, SYSTEM_BATTERY_STATE s, Rates r) {
    static char json[128];
    describe(&p, &s, &r, json, sizeof json);
    return json;
}

static void test_format_duration(void) {
    char out[32];
    format_duration(out, sizeof out, 0), CHECK_STR(out, "1m");
    format_duration(out, sizeof out, 59 * 60), CHECK_STR(out, "59m");
    format_duration(out, sizeof out, 60 * 60), CHECK_STR(out, "1h 0m");
    format_duration(out, sizeof out, 3 * 3600 + 11 * 60 + 59), CHECK_STR(out, "3h 11m");
}

static void test_smoothing(void) {
    Rates r = {0};
    SYSTEM_BATTERY_STATE s = state(1, 50000, 90000, 40000);
    CHECK(update_rates(&r, &s));
    CHECK(r.charge_mw == 40000); /* First sample is taken as is. */
    /* A trickle right after plugging in barely moves the average. */
    s.Rate = 1500;
    update_rates(&r, &s);
    CHECK(r.charge_mw > 35000);
    /* Rate 0 (unknown, right after a change) is not a sample. */
    s.Rate = 0;
    CHECK(!update_rates(&r, &s));
    SYSTEM_BATTERY_STATE discharging = state(0, 50000, 90000, -12000);
    CHECK(update_rates(&r, &discharging));
    CHECK(r.discharge_mw == 12000);
}

static void test_describe(void) {
    /* Charging: missing capacity over the smoothed rate, 45 Wh at 45 W. */
    CHECK_STR(run(power(1, 50, (DWORD)-1), state(1, 45000, 90000, 45000), (Rates){45000, 0}),
        "{\"icon\": \"\xEE\xAE\xB0\", \"percent\": 50, \"time\": \"1h 0m\"}");
    /* The smoothed rate wins over a momentary trickle. */
    CHECK_STR(run(power(1, 50, (DWORD)-1), state(1, 45000, 90000, 1500), (Rates){45000, 0}),
        "{\"icon\": \"\xEE\xAE\xB0\", \"percent\": 50, \"time\": \"1h 0m\"}");
    /* Plugged in, not charging. */
    CHECK_STR(run(power(1, 100, (DWORD)-1), state(0, 90000, 90000, 0), (Rates){0}),
        "{\"icon\": \"\xEE\xAE\xB5\", \"percent\": 100, \"time\": \"full\"}");
    CHECK_STR(run(power(1, 80, (DWORD)-1), state(0, 72000, 90000, 0), (Rates){0}),
        "{\"icon\": \"\xEE\xAE\xB3\", \"percent\": 80, \"time\": \"not charging\"}");
    /* On battery: Windows' estimate, as on the taskbar. */
    CHECK_STR(run(power(0, 58, 2 * 3600 + 5 * 60), state(0, 52000, 90000, -20000), (Rates){0, 10000}),
        "{\"icon\": \"\xEE\xAE\xA6\", \"percent\": 58, \"time\": \"2h 5m\"}");
    /* Windows has no estimate yet: fall back to the smoothed discharge rate. */
    CHECK_STR(run(power(0, 58, (DWORD)-1), state(0, 52000, 90000, 0), (Rates){0, 13000}),
        "{\"icon\": \"\xEE\xAE\xA6\", \"percent\": 58, \"time\": \"4h 0m\"}");
    /* No estimate and no rate seen yet: no time rather than a wrong one. */
    CHECK_STR(run(power(0, 58, (DWORD)-1), state(0, 52000, 90000, 0), (Rates){0}),
        "{\"icon\": \"\xEE\xAE\xA6\", \"percent\": 58, \"time\": \"\"}");
}

static void test_icon_levels(void) {
    /* Eleven levels, rounded: 0-4% empty, 95-100% full. */
    int cases[][2] = {{0, 0xA0}, {4, 0xA0}, {5, 0xA1}, {14, 0xA1}, {15, 0xA2}, {50, 0xA5}, {94, 0xA9}, {95, 0xAA}, {100, 0xAA}};
    for (size_t i = 0; i < sizeof cases / sizeof *cases; i++) {
        const char *json = run(power(0, cases[i][0], 3600), state(0, 1, 1, -1), (Rates){0});
        if ((unsigned char)json[12] != cases[i][1]) {
            printf("battery.test.c: %d%% on battery: glyph EE AE %02X, want %02X\n", cases[i][0], (unsigned char)json[12], cases[i][1]);
            failures++;
        }
        /* On AC, the charging set: same level, 0xAB up. */
        json = run(power(1, cases[i][0], (DWORD)-1), state(0, 1, 1, 0), (Rates){0});
        CHECK((unsigned char)json[12] == cases[i][1] + 0x0B);
    }
}

int main(void) {
    test_format_duration();
    test_smoothing();
    test_describe();
    test_icon_levels();
    if (failures) printf("%d battery test(s) failed\n", failures);
    else printf("battery tests passed\n");
    return failures != 0;
}
