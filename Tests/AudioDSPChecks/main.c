#include "AudioDSP.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

#define FRAMES 4096
#define GUARD 123.456f
#define NEAR(actual, expected) assert(fabsf((actual) - (expected)) < 0.00001f)

typedef struct { AudioBufferList *list; float *samples[4]; } Buffers;
static Buffers buffers(UInt32 count, const UInt32 *channels, UInt32 frames) {
    Buffers result = {0};
    result.list = calloc(1, sizeof(AudioBufferList) + (count - 1) * sizeof(AudioBuffer));
    result.list->mNumberBuffers = count;
    for (UInt32 b = 0; b < count; b++) {
        result.samples[b] = calloc(frames * channels[b] + 1, sizeof(float));
        result.samples[b][frames * channels[b]] = GUARD;
        result.list->mBuffers[b] = (AudioBuffer){channels[b], frames * channels[b] * sizeof(float), result.samples[b]};
    }
    return result;
}
static void fill(Buffers *b, UInt32 buffer, UInt32 channel, float value) {
    AudioBuffer *ab = &b->list->mBuffers[buffer];
    for (UInt32 i = channel; i < ab->mDataByteSize / sizeof(float); i += ab->mNumberChannels) b->samples[buffer][i] = value;
}
static float last(Buffers *b, UInt32 buffer, UInt32 channel) {
    AudioBuffer *ab = &b->list->mBuffers[buffer];
    return b->samples[buffer][ab->mDataByteSize / sizeof(float) - ab->mNumberChannels + channel];
}
static void release(Buffers b) {
    for (UInt32 i = 0; i < b.list->mNumberBuffers; i++) {
        assert(b.samples[i][b.list->mBuffers[i].mDataByteSize / sizeof(float)] == GUARD);
        free(b.samples[i]);
    }
    free(b.list);
}
static void interleavedAndDisabledMic(void) {
    FSAudioDSP *dsp = FSAudioDSPCreate(); assert(dsp);
    Buffers in = buffers(2, (UInt32[]){1, 2}, FRAMES);
    in.list->mBuffers[0].mData = NULL;
    fill(&in, 1, 0, 0.8f); fill(&in, 1, 1, -0.4f);
    Buffers out = buffers(1, (UInt32[]){6}, FRAMES);
    for (UInt32 c = 0; c < 6; c++) fill(&out, 0, c, 0.99f);
    FSAudioDSPConfigure(dsp, 1, 2, 2, 3, false, 48000);
    FSAudioDSPSetGain(dsp, 0.5f);
    FSAudioDSPRender(dsp, in.list, out.list);
    NEAR(last(&out, 0, 2), 0.4f); NEAR(last(&out, 0, 3), -0.2f);
    for (UInt32 c = 0; c < 6; c++) if (c != 2 && c != 3) assert(last(&out, 0, c) == 0);
    NEAR(FSAudioDSPGetPeak(dsp), 0.4f); assert(FSAudioDSPGetCallbackCount(dsp) == 1);
    release(in); release(out); FSAudioDSPDestroy(dsp);
    puts("PASS: interleaved routing skips disabled microphone and uses selected output channels");
}
static void planarBalance(void) {
    FSAudioDSP *dsp = FSAudioDSPCreate(); assert(dsp);
    Buffers in = buffers(2, (UInt32[]){1, 1}, FRAMES), out = buffers(2, (UInt32[]){1, 1}, FRAMES);
    fill(&in, 0, 0, 0.6f); fill(&in, 1, 0, -0.8f);
    FSAudioDSPConfigure(dsp, 0, 1, 0, 1, false, 48000);
    FSAudioDSPSetBalance(dsp, -0.75f);
    FSAudioDSPRender(dsp, in.list, out.list);
    NEAR(last(&out, 0, 0), 0.6f); NEAR(last(&out, 1, 0), -0.2f);
    release(in); release(out); FSAudioDSPDestroy(dsp);
    puts("PASS: planar stereo channels and balance");
}
static void monoAndMute(void) {
    FSAudioDSP *dsp = FSAudioDSPCreate(); assert(dsp);
    Buffers in = buffers(1, (UInt32[]){2}, FRAMES), out = buffers(1, (UInt32[]){1}, FRAMES);
    fill(&in, 0, 0, 0.8f); fill(&in, 0, 1, -0.4f);
    FSAudioDSPConfigure(dsp, 0, 1, 0, 0, true, 48000);
    FSAudioDSPRender(dsp, in.list, out.list); NEAR(last(&out, 0, 0), 0.2f);
    NEAR(FSAudioDSPGetPeak(dsp), 0.2f);
    FSAudioDSPSetMuted(dsp, true);
    FSAudioDSPRender(dsp, in.list, out.list); NEAR(last(&out, 0, 0), 0);
    FSAudioDSPRender(dsp, in.list, out.list); assert(last(&out, 0, 0) == 0);
    release(in); release(out); FSAudioDSPDestroy(dsp);
    puts("PASS: mono downmix, output metering and click-free mute");
}
static void shortInput(void) {
    FSAudioDSP *dsp = FSAudioDSPCreate(); assert(dsp);
    Buffers in = buffers(1, (UInt32[]){2}, 3), out = buffers(1, (UInt32[]){2}, 64);
    fill(&in, 0, 0, 0.5f); fill(&in, 0, 1, 0.5f);
    fill(&out, 0, 0, 0.99f); fill(&out, 0, 1, 0.99f);
    FSAudioDSPConfigure(dsp, 0, 1, 0, 1, false, 48000);
    FSAudioDSPRender(dsp, in.list, out.list);
    assert(out.samples[0][4] > 0);
    for (UInt32 i = 6; i < 128; i++) assert(out.samples[0][i] == 0);
    release(in); release(out); FSAudioDSPDestroy(dsp);
    puts("PASS: mismatched buffer lengths zero-fill without overruns");
}
static void clippingAndNonfiniteSamples(void) {
    FSAudioDSP *dsp = FSAudioDSPCreate(); assert(dsp);
    Buffers in = buffers(1, (UInt32[]){2}, FRAMES), out = buffers(1, (UInt32[]){2}, FRAMES);
    fill(&in, 0, 0, 0.9f); fill(&in, 0, 1, -INFINITY);
    FSAudioDSPConfigure(dsp, 0, 1, 0, 1, false, 48000);
    FSAudioDSPSetGain(dsp, 4);
    FSAudioDSPRender(dsp, in.list, out.list);
    assert(last(&out, 0, 0) == 1); assert(last(&out, 0, 1) == 0);
    assert(FSAudioDSPGetPeak(dsp) == 1);
    FSAudioDSPSetGain(dsp, NAN); FSAudioDSPSetBalance(dsp, INFINITY);
    FSAudioDSPRender(dsp, in.list, out.list); NEAR(last(&out, 0, 0), 0.9f);
    release(in); release(out); FSAudioDSPDestroy(dsp);
    puts("PASS: amplification is bounded and nonfinite samples/controls are sanitized");
}
int main(void) {
    interleavedAndDisabledMic(); planarBalance(); monoAndMute(); shortInput(); clippingAndNonfiniteSamples();
    puts("All audio DSP checks passed.");
    return 0;
}
