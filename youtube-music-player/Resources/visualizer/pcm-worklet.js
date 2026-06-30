// Minimal AudioWorkletProcessor stub — outputs silence.
// Task 6 implements the real ring-buffer consumer.
class PcmWorkletProcessor extends AudioWorkletProcessor {
    process(inputs, outputs) {
        return true; // keep alive; outputs default to silence
    }
}
registerProcessor('pcm-worklet', PcmWorkletProcessor);
