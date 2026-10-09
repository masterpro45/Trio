"""Luna's bedtime bark: her own synthesized barks, strung into one cute 9 pm alarm."""
import wave, struct, os

SRC = os.path.expanduser("~/claude-pet/sounds")
RATE = 44100


def read(name):
    with wave.open(os.path.join(SRC, name)) as w:
        assert w.getframerate() == RATE and w.getnchannels() == 1 and w.getsampwidth() == 2
        return list(struct.unpack("<%dh" % w.getnframes(), w.readframes(w.getnframes())))


def sil(sec):
    return [0] * int(sec * RATE)


def gain(s, g):
    return [max(-32767, min(32767, int(v * g))) for v in s]


bark, bark3, yip, jingle = read("bark.wav"), read("bark3.wav"), read("yip.wav"), read("jingle.wav")

# Happy double woof, a pause, a firmer woof, an excited yip, and her collar tag.
out = (
    gain(bark3, 1.0) + sil(0.13)
    + gain(bark, 1.0) + sil(0.16)
    + gain(yip, 0.9) + sil(0.10)
    + gain(jingle, 0.55)
)

dst = "/private/tmp/claude-501/-Users-masterpro/6242990c-c25e-4540-92a4-4ffd50df2b51/scratchpad/luna/luna_bark.wav"
with wave.open(dst, "w") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE)
    w.writeframes(struct.pack("<%dh" % len(out), *out))
print(dst, round(len(out) / RATE, 2), "sec")
