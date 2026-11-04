#pragma once
typedef void (*GRTouchCallback)(float x, float y, int identifier, int moving, void *context);
int GRStartTouchInput(GRTouchCallback callback, void *context);
void GRStopTouchInput(void);
const char *GRLastTouchError(void);
