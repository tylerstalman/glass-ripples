#include "GridDecoder.h"

#include <assert.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

enum {
    frameHeader = 31, sectionHeader = 22, gridHeader = 8,
    rows = 62, columns = 94, imageBytes = gridHeader + rows * columns * 2,
    stateBytes = 36, stateSection = frameHeader + sectionHeader + imageBytes,
    reportBytes = stateSection + sectionHeader + stateBytes
};

static const uint8_t imageID[] = {
    0xcc,0xd5,0x90,0x6e,0x42,0x68,0x0a,0x31,0x50,0x89,0x09,0x7d,0xda,0x71,0x28,0xcf
};
static const uint8_t stateID[] = {
    0xcc,0xd5,0x90,0x6e,0x42,0x68,0x0a,0x31,0x65,0xda,0x7d,0x2a,0x77,0x91,0x01,0x6c
};
static uint8_t report[reportBytes];
static GRGridDecoder decoder;
static GRGridPoint events[GRMaxTouches];
static int eventCount;

static void put16(uint8_t *out, unsigned value) {
    out[0] = (uint8_t)value;
    out[1] = (uint8_t)(value >> 8);
}

static void section(uint8_t *p, const uint8_t *id, unsigned type, unsigned bytes) {
    p[0] = 1;
    memcpy(p + 1, id, 16);
    p[17] = 1;
    put16(p + 18, type);
    put16(p + 20, bytes);
}

static void buildFrame(void) {
    const uint8_t header[] = {0x5a,1,2,0,0x20,24,0};
    const uint8_t shape[] = {5,0x50,0,0,2,rows,columns,0};
    memcpy(report, header, sizeof(header));
    section(report + frameHeader, imageID, 0x9a00, imageBytes);
    memcpy(report + frameHeader + sectionHeader, shape, sizeof(shape));
    section(report + stateSection, stateID, 0x5200, stateBytes);
    uint8_t *state = report + stateSection + sectionHeader;
    state[8] = 2;
    state[22] = 1;
    state[23] = 1;
}

static void drawGrid(int fingerColumn, int fingerRow, int background) {
    uint8_t *pixels = report + frameHeader + sectionHeader + gridHeader;
    for (int row = 0; row < rows; row++) {
        for (int column = 0; column < columns; column++) {
            int dx = column - fingerColumn, dy = row - fingerRow;
            int radiusSquared = dx * dx + dy * dy;
            int sample = background + (row + column) % 7;
            if (radiusSquared <= 2) sample -= 650 - 150 * radiusSquared;
            put16(pixels + 2 * (row * columns + column), (unsigned)sample);
        }
    }
}

static void addFinger(int column, int row) {
    uint8_t *pixels = report + frameHeader + sectionHeader + gridHeader;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            uint8_t *p = pixels + 2 * ((row + dy) * columns + column + dx);
            int sample = p[0] | ((unsigned)p[1] << 8);
            put16(p, (unsigned)(sample - (650 - 150 * (dx * dx + dy * dy))));
        }
    }
}

static unsigned ticks;

static int observeScan(uint8_t mode, uint8_t marker, size_t length, float *x, float *y) {
    ticks += 8000;
    uint8_t *state = report + stateSection + sectionHeader;
    for (unsigned i = 0; i < 4; i++) {
        report[7+i] = state[i] = (uint8_t)(ticks >> (8*i));
        report[15+i] = state[12+i] = (uint8_t)((ticks / 8000) >> (8*i));
    }
    state[24] = mode;
    state[27] = marker;
    eventCount = GRGridTouches(&decoder, report, length, events);
    if (!eventCount) return GRGridNone;
    *x = events[0].x;
    *y = events[0].y;
    return events[0].phase;
}

static int observe(bool pressed, size_t length, float *x, float *y) {
    return observeScan(pressed ? 1 : 0, pressed ? 0 : 0xfe, length, x, y);
}

static void expectPress(int column, int row) {
    drawGrid(column, row, 4096);
    float x = -1, y = -1;
    assert(observe(true, sizeof(report), &x, &y) == GRGridBegan);
    assert(fabsf(x - (column + 0.5f) / columns) < 0.01f);
    assert(fabsf(y - (row + 0.5f) / rows) < 0.01f);
    for (int i = 0; i < 15; i++) assert(!observe(true, sizeof(report), &x, &y));
}

int main(void) {
    float x, y;
    buildFrame();
    GRGridReset(&decoder);

    // An active scan during startup cannot become the untouched reference.
    drawGrid(24, 30, 4096);
    assert(!observe(true, sizeof(report), &x, &y));
    drawGrid(71, 42, 4096);
    assert(!observe(true, sizeof(report), &x, &y));
    drawGrid(-10, -10, 4096);
    for (int i = 0; i < 15; i++) assert(!observe(false, sizeof(report), &x, &y));
    drawGrid(-10, -10, 3900);
    assert(!observe(false, sizeof(report), &x, &y));

    // Calibration plans recur every two seconds and change the top-edge
    // baseline across many electrodes. They must never generate a contact.
    drawGrid(-10, -10, 4096);
    uint8_t *pixels = report + frameHeader + sectionHeader + gridHeader;
    for (int row = rows - 3; row < rows; row++) {
        for (int column = 0; column < columns; column++) {
            put16(pixels + 2 * (row * columns + column), 3300);
        }
    }
    for (int i = 0; i < 30; i++) {
        ticks += 2000000;
        assert(!observeScan(2, 0xfe, sizeof(report), &x, &y));
        assert(!observeScan(4, 0xfe, sizeof(report), &x, &y));
        assert(!observeScan(1, 0xff, sizeof(report), &x, &y));
    }

    // Use the same localized deficit in irrelevant and truncated frames.
    drawGrid(7, 53, 4096);
    report[0] = 0;
    assert(!observe(true, sizeof(report), &x, &y));
    report[0] = 0x5a;
    report[frameHeader + 1] ^= 0xff;
    assert(!observe(true, sizeof(report), &x, &y));
    report[frameHeader + 1] ^= 0xff;
    assert(!observe(true, stateSection - 1, &x, &y));
    assert(!observe(true, stateSection, &x, &y));  // Missing scanner state.
    assert(!observe(true, sizeof(report) - 1, &x, &y));
    report[frameHeader + sectionHeader + 5]--;
    assert(!observe(true, sizeof(report), &x, &y));
    report[frameHeader + sectionHeader + 5]++;

    expectPress(7, 53);
    drawGrid(-10, -10, 4096);
    for (int i = 0; i < 10; i++) assert(!observe(false, sizeof(report), &x, &y));
    expectPress(85, 5);

    // Sleep between taps can suppress the release packet.
    ticks += 300000;
    expectPress(30, 18);

    // A continuous hold across the 32-bit timestamp wrap stays one contact.
    ticks = UINT32_MAX - 60000;
    drawGrid(-10, -10, 4096);
    assert(!observe(false, sizeof(report), &x, &y));
    expectPress(50, 20);
    // Movement follows the contact, remains rate limited, and never generates
    // repeated tap impulses. A fresh contact after lift starts a separate wake.
    int movements = 0;
    for (int column = 51; column <= 62; column++) {
        drawGrid(column, 20, 4096);
        int phase = observe(true, sizeof(report), &x, &y);
        assert(phase == GRGridNone || phase == GRGridMoved);
        if (phase == GRGridMoved) movements++;
    }
    assert(movements >= 2 && movements <= 3);
    drawGrid(62, 20, 4096);
    ticks += 40000;
    (void)observe(true, sizeof(report), &x, &y);
    for (int i = 0; i < 20; i++) assert(!observe(true, sizeof(report), &x, &y));
    drawGrid(-10, -10, 4096);
    assert(!observe(false, sizeof(report), &x, &y));
    expectPress(85, 5);
    // Three simultaneous contacts retain separate IDs while moving. Lifting
    // one does not restart the remaining fingers or join their trails.
    drawGrid(-10, -10, 4096);
    assert(!observe(false, sizeof(report), &x, &y));
    addFinger(10, 10); addFinger(40, 30); addFinger(75, 50);
    (void)observeScan(2, 0, sizeof(report), &x, &y);
    assert(eventCount == 3);
    int ids[3];
    for (int i = 0; i < 3; i++) {
        assert(events[i].phase == GRGridBegan);
        ids[i] = events[i].identifier;
    }
    ticks += 40000;
    drawGrid(-10, -10, 4096);
    addFinger(12, 10); addFinger(42, 30); addFinger(77, 50);
    (void)observeScan(4, 0, sizeof(report), &x, &y);
    assert(eventCount == 3);
    for (int i = 0; i < 3; i++) {
        assert(events[i].phase == GRGridMoved);
        assert(events[i].identifier == ids[i]);
    }
    ticks += 40000;
    drawGrid(-10, -10, 4096);
    addFinger(44, 30); addFinger(79, 50);
    (void)observe(true, sizeof(report), &x, &y);
    assert(eventCount == 2);
    assert(events[0].identifier == ids[1] && events[1].identifier == ids[2]);
    assert(events[0].phase == GRGridMoved && events[1].phase == GRGridMoved);
    ticks += 40000;
    drawGrid(-10, -10, 4096);
    addFinger(15, 10); addFinger(46, 30); addFinger(81, 50);
    (void)observe(true, sizeof(report), &x, &y);
    assert(eventCount == 3);
    assert(events[0].phase == GRGridBegan);
    assert(events[1].phase == GRGridMoved && events[2].phase == GRGridMoved);
    puts("Touch decoder tests passed");
}
