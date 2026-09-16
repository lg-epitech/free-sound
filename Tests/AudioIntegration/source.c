// Quiet, isolated source for the optional hardware smoke test. Peak amplitude is
// -100 dBFS; this never controls or taps any application belonging to the user.
#include <AudioUnit/AudioUnit.h>
#include <math.h>
#include <stdio.h>
#include <stdatomic.h>
#include <unistd.h>

static double phase = 0;
static _Atomic(UInt32) renderedBuffers = 0;
static OSStatus render(void *context, AudioUnitRenderActionFlags *flags,
                       const AudioTimeStamp *time, UInt32 bus, UInt32 frames,
                       AudioBufferList *data) {
    (void)context; (void)flags; (void)time; (void)bus;
    for (UInt32 frame = 0; frame < frames; frame++) {
        float sample = (float)(sin(phase) * 0.00001);
        phase += 2 * 3.141592653589793 * 440 / 48000;
        if (phase >= 2 * 3.141592653589793) phase -= 2 * 3.141592653589793;
        for (UInt32 b = 0; b < data->mNumberBuffers; b++) {
            for (UInt32 c = 0; c < data->mBuffers[b].mNumberChannels; c++) {
                ((float *)data->mBuffers[b].mData)[frame * data->mBuffers[b].mNumberChannels + c] = sample;
            }
        }
    }
    atomic_fetch_add_explicit(&renderedBuffers, 1, memory_order_relaxed);
    return noErr;
}
int main(void) {
    AudioComponentDescription desc = {kAudioUnitType_Output, kAudioUnitSubType_DefaultOutput,
                                       kAudioUnitManufacturer_Apple, 0, 0};
    AudioComponent component = AudioComponentFindNext(NULL, &desc);
    AudioUnit unit = NULL;
    if (!component || AudioComponentInstanceNew(component, &unit) != noErr) return 1;
    AudioStreamBasicDescription format = {48000, kAudioFormatLinearPCM,
        kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, 8, 1, 8, 2, 32, 0};
    if (AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, sizeof(format)) != noErr) return 2;
    AURenderCallbackStruct callback = {render, NULL};
    if (AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof(callback)) != noErr) return 3;
    if (AudioUnitInitialize(unit) != noErr || AudioOutputUnitStart(unit) != noErr) return 4;
    for (int attempt = 0; attempt < 200 && atomic_load_explicit(&renderedBuffers, memory_order_relaxed) < 20; attempt++) usleep(10000);
    if (atomic_load_explicit(&renderedBuffers, memory_order_relaxed) < 20) return 5;
    puts("ready"); fflush(stdout);
    sleep(15);
    AudioOutputUnitStop(unit);
    AudioUnitUninitialize(unit);
    AudioComponentInstanceDispose(unit);
    return 0;
}
