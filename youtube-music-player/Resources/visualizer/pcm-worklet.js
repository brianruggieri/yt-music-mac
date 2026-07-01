// AudioWorkletProcessor fed by native PCM (Task 6).
//
// The page posts interleaved-stereo Float32 chunks ([L0,R0,L1,R1,...]) to
// `port`; we stash them in a ring buffer and deinterleave into the two output
// channels in process(). On underrun we emit silence so the graph never stalls.
class PcmWorkletProcessor extends AudioWorkletProcessor {
    constructor() {
        super();
        // ~0.68 s of stereo @ 48 kHz; power-of-two so wrap is a bitwise mask.
        this.capacity = 1 << 16;             // interleaved samples (L,R,L,R,...)
        this.mask = this.capacity - 1;
        this.ring = new Float32Array(this.capacity);
        this.readPos = 0;
        this.writePos = 0;
        this.available = 0;                  // valid samples currently buffered

        this.port.onmessage = (e) => this._enqueue(e.data);
    }

    // Append an interleaved Float32 chunk, dropping oldest samples on overflow.
    _enqueue(chunk) {
        if (!chunk || chunk.length === 0) return;
        for (let i = 0; i < chunk.length; i++) {
            this.ring[this.writePos] = chunk[i];
            this.writePos = (this.writePos + 1) & this.mask;
            if (this.available < this.capacity) {
                this.available++;
            } else {
                // Buffer full: writePos has caught readPos, so advance read too.
                this.readPos = (this.readPos + 1) & this.mask;
            }
        }
    }

    process(_inputs, outputs) {
        const out = outputs[0];
        const left = out[0];
        const right = out[1] || out[0];     // guard if only one channel allocated
        const frames = left.length;

        for (let i = 0; i < frames; i++) {
            if (this.available >= 2) {
                left[i] = this.ring[this.readPos];
                this.readPos = (this.readPos + 1) & this.mask;
                right[i] = this.ring[this.readPos];
                this.readPos = (this.readPos + 1) & this.mask;
                this.available -= 2;
            } else {
                left[i] = 0;                 // underrun -> silence
                right[i] = 0;
            }
        }
        return true;
    }
}
registerProcessor('pcm-worklet', PcmWorkletProcessor);
