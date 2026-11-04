#include "GridDecoder.h"
#include <string.h>

// Kiwi's mutual-capacitance image, as distinct from its noise-reference image.
static const uint8_t imageID[16] = {
    0xcc,0xd5,0x90,0x6e,0x42,0x68,0x0a,0x31,0x50,0x89,0x09,0x7d,0xda,0x71,0x28,0xcf
};
static uint16_t little16(const uint8_t *p) {
    return (uint16_t)(p[0] | ((unsigned)p[1] << 8));
}
static int value(const uint8_t *grid, int index) {
    return (int16_t)little16(grid + 2 * index);
}
typedef struct {
    const uint8_t *image;
    uint32_t micros;
    bool idle;
    bool contact;
} Scan;

static bool readScan(const uint8_t *p, size_t length, Scan *scan) {
    const uint8_t gridHeader[] = {0x05,0x50,0,0,2,GRGridRows,GRGridColumns,0};
    if (!p || length < 31 || length > 65536 ||
        memcmp(p, (uint8_t[]){0x5a,1,2,0,0x20,24,0}, 7) != 0) return false;
    scan->micros = little16(p+7) | ((uint32_t)little16(p+9) << 16);
    bool hasScanMode = false;
    for (size_t pos = 31; pos < length;) {
        if (length - pos < 22) return false;
        const uint8_t *node = p + pos;
        if (node[0] != 1 && node[0] != 2) return false;
        size_t bytes = little16(node + 20);
        pos += 22;
        if (bytes > length - pos) return false;
        uint16_t type = little16(node+18);
        if (bytes == 8 + 2 * GRGridCount && type == 0x9a00 &&
            memcmp(node+1, imageID, sizeof(imageID)) == 0 &&
            memcmp(p+pos, gridHeader, sizeof(gridHeader)) == 0)
            scan->image = p + pos + 8;
        if (bytes == 36 && type == 0x5200) {
            hasScanMode = true;
            scan->idle = p[pos+24] == 0 && p[pos+27] == 0xfe;
            scan->contact = p[pos+24] == 1 && p[pos+27] == 0;
        }
        pos += bytes;
    }
    return hasScanMode;
}
void GRGridReset(GRGridDecoder *decoder) {
    memset(decoder, 0, sizeof(*decoder));
}
int GRGridTouches(GRGridDecoder *d, const uint8_t *report, size_t length, GRGridPoint *points) {
    Scan scan = {0};
    if (!readScan(report, length, &scan)) return 0;
    // Calibration sweeps change the grid gain and must never become contacts.
    if (!scan.idle && !scan.contact) return 0;
    if (scan.micros - d->lastFrameUS > 250000u || scan.idle)
        memset(d->fingers, 0, sizeof(d->fingers));
    d->lastFrameUS = scan.micros;
    const uint8_t *grid = scan.image;
    if (!grid) return 0;
    if (scan.idle) {
        for (int i = 0; i < GRGridCount; i++) d->baseline[i] = value(grid, i);
        d->hasBaseline = true;
        return 0;
    }
    if (!d->hasBaseline) return 0;
    int signal = 0, reference = 0;
    for (int i = 0; i < GRGridCount; i += 17) {
        signal += value(grid, i);
        reference += d->baseline[i];
    }
    if (signal <= 0 || reference <= 0) return 0;
    const float gain = (float)signal / (float)reference;
    if (gain < 0.50f || gain > 1.60f) return 0;

    float deficit[GRGridCount];
    uint8_t visited[GRGridCount] = {0};
    uint16_t queue[GRGridCount];
    for (int i = 0; i < GRGridCount; i++)
        deficit[i] = gain * d->baseline[i] - value(grid, i);
    GRGridPoint candidates[GRMaxTouches];
    int count = 0;
    // Each connected patch is a fingertip. Weighted centers retain sub-cell
    // precision, while isolated noise and broad palm patches are discarded.
    for (int seed = 0; seed < GRGridCount; seed++) {
        if (visited[seed] || deficit[seed] < 65) continue;
        int head = 0, tail = 1;
        queue[0] = seed;
        visited[seed] = 1;
        float total = 0, sumX = 0, sumY = 0, peak = 0;
        while (head < tail) {
            int index = queue[head++];
            int row = index / GRGridColumns, col = index % GRGridColumns;
            float weight = deficit[index] - 40;
            total += weight;
            sumX += col * weight;
            sumY += row * weight;
            if (deficit[index] > peak) peak = deficit[index];
            for (int dy = -1; dy <= 1; dy++) {
                int r = row + dy;
                if (r < 0 || r >= GRGridRows) continue;
                for (int dx = -1; dx <= 1; dx++) {
                    int c = col + dx;
                    if (c < 0 || c >= GRGridColumns) continue;
                    int next = r * GRGridColumns + c;
                    if (!visited[next] && deficit[next] >= 65) {
                        visited[next] = 1;
                        queue[tail++] = next;
                    }
                }
            }
        }
        if (tail < 2 || tail > 100 || peak < 100 || total < 95 || count == GRMaxTouches) continue;
        candidates[count++] = (GRGridPoint){
            .x = (sumX / total + 0.5f) / GRGridColumns,
            .y = (sumY / total + 0.5f) / GRGridRows
        };
    }

    int matches[GRMaxTouches];
    bool used[GRMaxTouches] = {0};
    for (int i = 0; i < count; i++) matches[i] = -1;
    // Match nearest pairs globally so one finger lifting doesn't steal another
    // finger's wake. Slots are reused only as new contacts.
    for (int pass = 0; pass < count; pass++) {
        float best = 0.0256f;
        int candidate = -1, finger = -1;
        for (int i = 0; i < count; i++) {
            if (matches[i] >= 0) continue;
            for (int j = 0; j < GRMaxTouches; j++) {
                if (used[j] || !d->fingers[j].active) continue;
                float dx = candidates[i].x - d->fingers[j].x;
                float dy = candidates[i].y - d->fingers[j].y;
                float distance = dx * dx + dy * dy;
                if (distance < best) { best = distance; candidate = i; finger = j; }
            }
        }
        if (candidate < 0) break;
        matches[candidate] = finger;
        used[finger] = true;
    }
    for (int j = 0; j < GRMaxTouches; j++)
        if (!used[j]) d->fingers[j].active = false;
    int events = 0;
    for (int i = 0; i < count; i++) {
        int slot = matches[i];
        bool moving = slot >= 0;
        if (!moving) {
            for (slot = 0; slot < GRMaxTouches; slot++)
                if (!d->fingers[slot].active) break;
        }
        GRFinger *finger = &d->fingers[slot];
        finger->x = candidates[i].x;
        finger->y = candidates[i].y;
        finger->active = true;
        float dx = finger->x - finger->emittedX, dy = finger->y - finger->emittedY;
        if (moving && (dx * dx + dy * dy < 0.000016f ||
                       scan.micros - finger->emittedUS < 33333u)) continue;
        finger->emittedX = finger->x;
        finger->emittedY = finger->y;
        finger->emittedUS = scan.micros;
        points[events++] = (GRGridPoint){finger->x, finger->y, slot, moving ? GRGridMoved : GRGridBegan};
    }
    return events;
}
