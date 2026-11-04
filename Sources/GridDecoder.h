#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

enum { GRGridRows = 62, GRGridColumns = 94, GRGridCount = GRGridRows * GRGridColumns, GRMaxTouches = 10 };
enum { GRGridNone, GRGridBegan, GRGridMoved };
typedef struct {
    float x, y, emittedX, emittedY;
    uint32_t emittedUS;
    bool active;
} GRFinger;
typedef struct {
    int16_t baseline[GRGridCount];
    uint32_t lastFrameUS;
    bool hasBaseline;
    GRFinger fingers[GRMaxTouches];
} GRGridDecoder;
typedef struct {
    float x, y;
    int identifier, phase;
} GRGridPoint;

void GRGridReset(GRGridDecoder *decoder);
// At most GRMaxTouches events in normalized bottom-left screen coordinates.
int GRGridTouches(GRGridDecoder *decoder, const uint8_t *report, size_t length, GRGridPoint *points);
