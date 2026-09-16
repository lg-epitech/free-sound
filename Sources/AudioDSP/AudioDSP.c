#include "AudioDSP.h"
#include <math.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "Audio controls require lock-free atomics");
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "Audio meter requires lock-free atomics");

struct FSAudioDSP {
    _Atomic(UInt32) gainBits, balanceBits, peakBits, muted;
    _Atomic(UInt64) callbackCount;
    UInt32 inputLeft, inputRight, outputLeft, outputRight;
    bool monoOutput;
    double currentLeft, currentRight, smoothing;
};

static UInt32 floatBits(float value) { UInt32 bits; memcpy(&bits, &value, 4); return bits; }
static float bitsFloat(UInt32 bits) { float value; memcpy(&value, &bits, 4); return value; }
static float controlLoad(const _Atomic(UInt32) *value) {
    return bitsFloat(atomic_load_explicit(value, memory_order_relaxed));
}
static float clamp(float value, float low, float high) {
    return fminf(high, fmaxf(low, value));
}

FSAudioDSP *FSAudioDSPCreate(void) {
    FSAudioDSP *state = calloc(1, sizeof(FSAudioDSP));
    if (!state) return NULL;
    atomic_init(&state->gainBits, floatBits(1));
    atomic_init(&state->balanceBits, floatBits(0));
    atomic_init(&state->peakBits, floatBits(0));
    atomic_init(&state->muted, 0);
    atomic_init(&state->callbackCount, 0);
    state->smoothing = 1.0f / 240.0f;
    return state;
}

void FSAudioDSPDestroy(FSAudioDSP *state) { free(state); }
void FSAudioDSPConfigure(FSAudioDSP *state, UInt32 inputLeft, UInt32 inputRight,
                        UInt32 outputLeft, UInt32 outputRight, bool monoOutput,
                        double sampleRate) {
    state->inputLeft = inputLeft; state->inputRight = inputRight;
    state->outputLeft = outputLeft; state->outputRight = outputRight;
    state->monoOutput = monoOutput;
    state->smoothing = 1.0 - exp(-1.0 / (fmax(8000, sampleRate) * 0.005));
    state->currentLeft = state->currentRight = 0; // Short fade-in prevents a starting click.
    atomic_store_explicit(&state->peakBits, floatBits(0), memory_order_relaxed);
    atomic_store_explicit(&state->callbackCount, 0, memory_order_relaxed);
}
void FSAudioDSPSetGain(FSAudioDSP *state, float gain) {
    atomic_store_explicit(&state->gainBits, floatBits(isfinite(gain) ? clamp(gain, 0, 4) : 1), memory_order_relaxed);
}
void FSAudioDSPSetMuted(FSAudioDSP *state, bool muted) {
    atomic_store_explicit(&state->muted, muted, memory_order_relaxed);
}
void FSAudioDSPSetBalance(FSAudioDSP *state, float balance) {
    atomic_store_explicit(&state->balanceBits, floatBits(isfinite(balance) ? clamp(balance, -1, 1) : 0), memory_order_relaxed);
}
float FSAudioDSPGetPeak(const FSAudioDSP *state) { return controlLoad(&state->peakBits); }
UInt64 FSAudioDSPGetCallbackCount(const FSAudioDSP *state) {
    return atomic_load_explicit(&state->callbackCount, memory_order_relaxed);
}

typedef struct { float *data; UInt32 stride, frames; } Channel;
static Channel channelAt(const AudioBufferList *list, UInt32 index) {
    Channel empty = {0};
    if (!list) return empty;
    for (UInt32 i = 0; i < list->mNumberBuffers; i++) {
        const AudioBuffer *buffer = &list->mBuffers[i];
        if (index < buffer->mNumberChannels) {
            if (!buffer->mData || !buffer->mNumberChannels) return empty;
            Channel channel = {(float *)buffer->mData + index, buffer->mNumberChannels,
                               buffer->mDataByteSize / sizeof(float) / buffer->mNumberChannels};
            return channel;
        }
        index -= buffer->mNumberChannels;
    }
    return empty;
}
static float sampleAt(Channel channel, UInt32 frame) {
    if (!channel.data || frame >= channel.frames) return 0;
    float sample = channel.data[frame * channel.stride];
    return isfinite(sample) ? sample : 0;
}
void FSAudioDSPRender(FSAudioDSP *state, const AudioBufferList *input, AudioBufferList *output) {
    if (!state || !output) return;
    for (UInt32 i = 0; i < output->mNumberBuffers; i++) {
        if (output->mBuffers[i].mData) memset(output->mBuffers[i].mData, 0, output->mBuffers[i].mDataByteSize);
    }
    Channel leftIn = channelAt(input, state->inputLeft);
    Channel rightIn = channelAt(input, state->inputRight);
    Channel leftOut = channelAt(output, state->outputLeft);
    Channel rightOut = channelAt(output, state->outputRight);
    UInt32 frames = leftOut.frames > rightOut.frames ? leftOut.frames : rightOut.frames;
    float gain = atomic_load_explicit(&state->muted, memory_order_relaxed) ? 0 : controlLoad(&state->gainBits);
    float balance = controlLoad(&state->balanceBits);
    float targetLeft = gain * (balance > 0 ? 1 - balance : 1);
    float targetRight = gain * (balance < 0 ? 1 + balance : 1);
    float peak = 0;
    for (UInt32 frame = 0; frame < frames; frame++) {
        state->currentLeft += (targetLeft - state->currentLeft) * state->smoothing;
        state->currentRight += (targetRight - state->currentRight) * state->smoothing;
        float left = sampleAt(leftIn, frame) * state->currentLeft;
        float right = sampleAt(rightIn, frame) * state->currentRight;
        // Protect the device from out-of-range samples when amplification is enabled.
        left = clamp(left, -1, 1); right = clamp(right, -1, 1);
        if (state->monoOutput) left = (left + right) * 0.5f;
        peak = fmaxf(peak, state->monoOutput ? fabsf(left) : fmaxf(fabsf(left), fabsf(right)));
        if (leftOut.data && frame < leftOut.frames) leftOut.data[frame * leftOut.stride] = left;
        if (!state->monoOutput && rightOut.data && frame < rightOut.frames) rightOut.data[frame * rightOut.stride] = right;
    }
    if (fabs(targetLeft - state->currentLeft) < 1e-6) state->currentLeft = targetLeft;
    if (fabs(targetRight - state->currentRight) < 1e-6) state->currentRight = targetRight;
    atomic_store_explicit(&state->peakBits, floatBits(peak), memory_order_relaxed);
    atomic_fetch_add_explicit(&state->callbackCount, 1, memory_order_relaxed);
}
OSStatus FSAudioDSPIOProc(AudioObjectID device, const AudioTimeStamp *now,
                        const AudioBufferList *input, const AudioTimeStamp *inputTime,
                        AudioBufferList *output, const AudioTimeStamp *outputTime,
                        void *context) {
    (void)device; (void)now; (void)inputTime; (void)outputTime;
    FSAudioDSPRender(context, input, output);
    return noErr;
}
OSStatus FSAudioDSPSelectInputStreams(AudioObjectID device, AudioDeviceIOProcID proc,
                                    UInt32 streamCount, const UInt32 *enabled) {
    size_t size = offsetof(AudioHardwareIOProcStreamUsage, mStreamIsOn) + sizeof(UInt32) * streamCount;
    AudioHardwareIOProcStreamUsage *usage = calloc(1, size);
    if (!usage) return kAudioHardwareUnspecifiedError;
    usage->mIOProc = (void *)proc;
    usage->mNumberStreams = streamCount;
    memcpy(usage->mStreamIsOn, enabled, sizeof(UInt32) * streamCount);
    AudioObjectPropertyAddress address = { kAudioDevicePropertyIOProcStreamUsage,
                                           kAudioObjectPropertyScopeInput,
                                           kAudioObjectPropertyElementMain };
    OSStatus result = AudioObjectSetPropertyData(device, &address, 0, NULL, (UInt32)size, usage);
    free(usage);
    return result;
}
