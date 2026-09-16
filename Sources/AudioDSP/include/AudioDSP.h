#ifndef FREE_SOUND_AUDIO_DSP_H
#define FREE_SOUND_AUDIO_DSP_H

#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>

CF_ASSUME_NONNULL_BEGIN

typedef struct FSAudioDSP FSAudioDSP;

FSAudioDSP * _Nullable FSAudioDSPCreate(void);
void FSAudioDSPDestroy(FSAudioDSP *state);
// Configure only while the device is stopped. Channel numbers are zero based.
void FSAudioDSPConfigure(FSAudioDSP *state, UInt32 inputLeft, UInt32 inputRight,
                        UInt32 outputLeft, UInt32 outputRight, bool monoOutput,
                        double sampleRate);
void FSAudioDSPSetGain(FSAudioDSP *state, float gain);
void FSAudioDSPSetMuted(FSAudioDSP *state, bool muted);
void FSAudioDSPSetBalance(FSAudioDSP *state, float balance);
float FSAudioDSPGetPeak(const FSAudioDSP *state);
UInt64 FSAudioDSPGetCallbackCount(const FSAudioDSP *state);
// Exposed separately to exercise buffer layouts without an audio device.
void FSAudioDSPRender(FSAudioDSP *state, const AudioBufferList *input,
                      AudioBufferList *output);
OSStatus FSAudioDSPIOProc(AudioObjectID device, const AudioTimeStamp *now,
                        const AudioBufferList *input, const AudioTimeStamp *inputTime,
                        AudioBufferList *output, const AudioTimeStamp *outputTime,
                        void * _Nullable context);
// Disables all physical input streams so duplex output devices never feed their
// microphone into this app. The selected streams must contain only tap audio.
OSStatus FSAudioDSPSelectInputStreams(AudioObjectID device, AudioDeviceIOProcID proc,
                                    UInt32 streamCount, const UInt32 *enabled);

CF_ASSUME_NONNULL_END

#endif
