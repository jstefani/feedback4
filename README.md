# feedback4

4-operator FM synth for norns. Clone of the Organelle PD patch
**Feedback4**: custom algorithm matrix (FM8 expert window), per-op ADSR,
ratio, pan, and a frequency envelope sourced from any operator.

MIDI in. 8-voice polyphony. 25 factory presets from the original
`presets1.txt`.

## install

Copy to `~/dust/code/feedback4/` on the norns. New SuperCollider engine
needs **SYSTEM > RESTART** once, then reload the script.

```
rsync -va --exclude .git --exclude pd . norns.local:~/dust/code/feedback4/
```

## controls

|  |  |
|---|---|
| E1 | page: play / op1–4 / algo / macro |
| **play** | E2 preset · E3 transpose · K1+E3 amp · rotating wireframe of the 4-op patch |
| **op** | E2 ratio · E3 out · hold K2+E A/D · hold K3+E S/R · K1+E pan / env amt |
| **algo** | E2 cell · E3 send amount (4×4 PM matrix) |
| **macro** | hold K2 which · E2 dest · E3 scale · hold K3+E3 value |
| K2 tap | tweak — walk the current patch a little (algorithm stays) |
| K3 tap | randomize — new sparse algorithm, ratios, envelopes |
| panic | PARAMS → **all notes off** |
| pitchbend | live retune; **bend up** / **bend down** in PARAMS (semitones) |
| mod wheel | overdrives FM depth + adds self-feedback; play graphic lifts and fades out |

PARAMS also has **tweak patch** and **randomize patch** triggers.

## architecture (from the PD patch)

Each operator is a phase-mod oscillator (`phasor~` + `cos~`). The 4×4
matrix is how much each op writes into each other op's phase, including
self-feedback (one-block delay, same as PD `throw~`/`catch~`).

ADSR is linear. Velocity scales the attack peak only; sustain is
absolute. Attack / decay / sustain / release and output sliders are
squared, then:

- attack = `sq * 300 + 0.5` ms
- decay = `sq * 1000` ms
- release = `sq * 2000 + 10` ms

Ratio is a free multiplier on the note frequency. Freq env adds
`(chosen op's ADSR * env amt)` onto that ratio.

## original

PD sources live in `pd/Feedback4/`. Organelle patch; desktop mother
patch included for the original UI.
