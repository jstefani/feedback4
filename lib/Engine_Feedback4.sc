// Engine_Feedback4
// 8-voice 4-operator FM. clone of Organelle "Feedback4" (PD):
//   fmMOD.pd   phase-mod oscillator (phasor~ + cos~, index = other ops)
//   ADSRfm.pd  linear vline~ ADSR, velocity peaks attack only
//   OSC-yo.pd  ratio + env-amount, 4x4 throw~/catch~ matrix, equal-power pan
//   voiceFM.pd 4 operators per voice
//   main.pd    poly 6 (8 voice abstractions); we run 8

Engine_Feedback4 : CroneEngine {
	var <pg;
	var <voices;
	var <amp = 0.7;
	var maxVoices = 8;

	// per-op patch, shared by every voice (PD sends to all voices)
	var <atk, <dec, <sus, <rel;
	var <rat, <lvl, <src, <amt, <pan;
	var <mat; // 4x4 row-major: from * 4 + to
	var fmScale = 1.0;
	var fbAdd = 0.0;

	*new { arg context, doneCallback;
		^super.new(context, doneCallback);
	}

	alloc {
		maxVoices = 8;
		atk = 0.0005 ! 4;
		dec = 0.2 ! 4;
		sus = 0.5 ! 4;
		rel = 0.3 ! 4;
		rat = 1.0 ! 4;
		lvl = 0.5 ! 4;
		src = 0.0 ! 4;
		amt = 0.0 ! 4;
		pan = 0.5 ! 4;
		mat = 0.0 ! 16;

		pg = ParGroup.tail(context.xg);

		SynthDef(\Feedback4Voice, {
			arg out, freq = 440, gate = 1, vel = 1.0, amp = 0.7, killGate = 1,
				atk1 = 0.0005, atk2 = 0.0005, atk3 = 0.0005, atk4 = 0.0005,
				dec1 = 0.2, dec2 = 0.2, dec3 = 0.2, dec4 = 0.2,
				sus1 = 0.5, sus2 = 0.5, sus3 = 0.5, sus4 = 0.5,
				rel1 = 0.3, rel2 = 0.3, rel3 = 0.3, rel4 = 0.3,
				rat1 = 1.0, rat2 = 1.0, rat3 = 1.0, rat4 = 1.0,
				lvl1 = 0.5, lvl2 = 0.5, lvl3 = 0.5, lvl4 = 0.5,
				src1 = 0, src2 = 0, src3 = 0, src4 = 0,
				amt1 = 0, amt2 = 0, amt3 = 0, amt4 = 0,
				pan1 = 0.5, pan2 = 0.5, pan3 = 0.5, pan4 = 0.5,
				x11 = 0, x12 = 0, x13 = 0, x14 = 0,
				x21 = 0, x22 = 0, x23 = 0, x24 = 0,
				x31 = 0, x32 = 0, x33 = 0, x34 = 0,
				x41 = 0, x42 = 0, x43 = 0, x44 = 0,
				fmScale = 1, fbAdd = 0;

			var atks, decs, suss, rels, rats, lvls, srcs, amts, pans, matrix;
			var envs, prev, ops, mixL, mixR, relMax, kill, life, envPeak;
			var fs, fb, frq;

			frq = Lag.kr(freq, 0.03);
			fs = Lag.kr(fmScale, 0.08);
			fb = Lag.kr(fbAdd, 0.08);

			atks = [atk1, atk2, atk3, atk4].collect({ arg x; Lag.kr(x, 0.02).max(0) });
			decs = [dec1, dec2, dec3, dec4].collect({ arg x; Lag.kr(x, 0.02).max(0) });
			suss = [sus1, sus2, sus3, sus4].collect({ arg x; Lag.kr(x, 0.02).max(0) });
			rels = [rel1, rel2, rel3, rel4].collect({ arg x; Lag.kr(x, 0.02).max(0) });
			rats = [rat1, rat2, rat3, rat4].collect({ arg x; Lag.kr(x, 0.04) });
			lvls = [lvl1, lvl2, lvl3, lvl4].collect({ arg x; Lag.kr(x, 0.02).max(0) });
			srcs = [src1, src2, src3, src4];
			amts = [amt1, amt2, amt3, amt4].collect({ arg x; Lag.kr(x, 0.04) });
			pans = [pan1, pan2, pan3, pan4].collect({ arg x; Lag.kr(x, 0.005).clip(0, 1) });
			matrix = [
				[Lag.kr(x11, 0.04), Lag.kr(x12, 0.04), Lag.kr(x13, 0.04), Lag.kr(x14, 0.04)],
				[Lag.kr(x21, 0.04), Lag.kr(x22, 0.04), Lag.kr(x23, 0.04), Lag.kr(x24, 0.04)],
				[Lag.kr(x31, 0.04), Lag.kr(x32, 0.04), Lag.kr(x33, 0.04), Lag.kr(x34, 0.04)],
				[Lag.kr(x41, 0.04), Lag.kr(x42, 0.04), Lag.kr(x43, 0.04), Lag.kr(x44, 0.04)]
			];

			// ADSRfm.pd: attack peak = velocity, then decay to absolute sustain
			envPeak = vel.clip(0, 1);
			envs = 4.collect({ arg i;
				EnvGen.ar(
					Env([0, envPeak, suss[i], 0], [atks[i], decs[i], rels[i]], \lin, 2),
					gate
				);
			});

			// throw~/catch~ is one DSP block; LocalIn/LocalOut matches that
			prev = LocalIn.ar(4);
			ops = 4.collect({ arg i;
				var eMod = Select.ar(srcs[i].round.clip(0, 4), [DC.ar(0)] ++ envs);
				var ratio = rats[i] + (eMod * amts[i]);
				var f = (frq * ratio).clip(-20000, 20000);
				var pm = Mix.fill(4, { arg j;
					var extra = 0;
					if (j == i) { extra = fb };
					prev[j] * (matrix[j][i] * fs + extra)
				});
				// fmMOD.pd: cos~(phasor~ + pm). SinOsc phase is radians.
				SinOsc.ar(f, pm * 2pi) * envs[i];
			});
			LocalOut.ar(ops);

			mixL = 0;
			mixR = 0;
			4.do({ arg i;
				var p = pans[i];
				var o = ops[i] * lvls[i];
				// equalPan: cos(pan * pi/2), sin(pan * pi/2)
				mixL = mixL + (o * cos(p * pi / 2));
				mixR = mixR + (o * sin(p * pi / 2));
			});

			// hip~ 5 on each op output; one stereo pair is equivalent
			mixL = HPF.ar(mixL, 5);
			mixR = HPF.ar(mixR, 5);

			kill = EnvGen.kr(Env.asr(0, 1, 0.01), killGate, doneAction: Done.freeSelf);
			relMax = rels[0].max(rels[1]).max(rels[2]).max(rels[3]);
			life = EnvGen.kr(Env.asr(0.001, 1, relMax + 0.08), gate, doneAction: Done.freeSelf);

			// main.pd *~ 0.5 per voice. (life > 0) keeps the lifetime
			// EnvGen in the graph so doneAction actually fires.
			Out.ar(out, [mixL, mixR] * amp * 0.5 * kill * (life > 0));
		}).add;

		context.server.sync;

		voices = Dictionary.new;

		this.addCommand(\noteOn, "iff", { arg msg;
			var id = msg[1], hz = msg[2], vel = msg[3];
			this.stopVoice(id);
			if (voices.size >= maxVoices, {
				var oldest = voices.keys.asArray.sort.first;
				voices[oldest].set(\killGate, 0);
				voices.removeAt(oldest);
			});
			voices[id] = Synth(\Feedback4Voice, this.voiceArgs ++ [
				\out, context.out_b, \freq, hz, \vel, vel, \amp, amp
			], target: pg);
			NodeWatcher.register(voices[id]);
			voices[id].onFree({ voices.removeAt(id); });
		});

		this.addCommand(\noteOff, "i", { arg msg;
			this.stopVoice(msg[1]);
		});

		this.addCommand(\noteKill, "i", { arg msg;
			var id = msg[1];
			if (voices[id].notNil, {
				voices[id].set(\killGate, 0);
				voices.removeAt(id);
			});
		});

		this.addCommand(\stopAll, "", {
			pg.set(\killGate, 0);
			voices.clear;
		});

		this.addCommand(\amp, "f", { arg msg;
			amp = msg[1];
			pg.set(\amp, amp);
		});

		this.addCommand(\freq, "if", { arg msg;
			var id = msg[1], hz = msg[2];
			if (voices[id].notNil, { voices[id].set(\freq, hz); });
		});

		// 0 = patch as written; 1 = 4x FM depth + self-feedback on every op
		this.addCommand(\fmMod, "f", { arg msg;
			var w = msg[1].clip(0, 1);
			fmScale = 1 + (w * 3);
			fbAdd = w * 0.5;
			pg.set(\fmScale, fmScale, \fbAdd, fbAdd);
		});

		// op n, atk, dec, sus, rel, m1, m2, m3, m4, ratio, out, envsrc, envamt, pan
		// times in seconds, out already squared, envsrc 0..4
		this.addCommand(\op, "ifffffffffffff", { arg msg;
			var n = msg[1].asInteger.clip(1, 4);
			var i = n - 1;
			atk[i] = msg[2].clip(0, 20);
			dec[i] = msg[3].clip(0, 20);
			sus[i] = msg[4];
			rel[i] = msg[5].clip(0, 20);
			mat[i * 4 + 0] = msg[6];
			mat[i * 4 + 1] = msg[7];
			mat[i * 4 + 2] = msg[8];
			mat[i * 4 + 3] = msg[9];
			rat[i] = msg[10];
			lvl[i] = msg[11].max(0);
			src[i] = msg[12].clip(0, 4);
			amt[i] = msg[13];
			pan[i] = msg[14].clip(0, 1);
			if (pg.notNil, { pg.set(*this.opPairs(n)); });
		});
	}

	voiceArgs {
		var pairs = [\amp, amp, \fmScale, fmScale, \fbAdd, fbAdd];
		4.do({ arg i;
			var n = i + 1;
			pairs = pairs ++ [
				(\atk ++ n).asSymbol, atk[i],
				(\dec ++ n).asSymbol, dec[i],
				(\sus ++ n).asSymbol, sus[i],
				(\rel ++ n).asSymbol, rel[i],
				(\rat ++ n).asSymbol, rat[i],
				(\lvl ++ n).asSymbol, lvl[i],
				(\src ++ n).asSymbol, src[i],
				(\amt ++ n).asSymbol, amt[i],
				(\pan ++ n).asSymbol, pan[i],
				(\x ++ n ++ 1).asSymbol, mat[i * 4 + 0],
				(\x ++ n ++ 2).asSymbol, mat[i * 4 + 1],
				(\x ++ n ++ 3).asSymbol, mat[i * 4 + 2],
				(\x ++ n ++ 4).asSymbol, mat[i * 4 + 3]
			];
		});
		^pairs;
	}

	opPairs { arg n;
		var i = n - 1;
		^[
			(\atk ++ n).asSymbol, atk[i],
			(\dec ++ n).asSymbol, dec[i],
			(\sus ++ n).asSymbol, sus[i],
			(\rel ++ n).asSymbol, rel[i],
			(\rat ++ n).asSymbol, rat[i],
			(\lvl ++ n).asSymbol, lvl[i],
			(\src ++ n).asSymbol, src[i],
			(\amt ++ n).asSymbol, amt[i],
			(\pan ++ n).asSymbol, pan[i],
			(\x ++ n ++ 1).asSymbol, mat[i * 4 + 0],
			(\x ++ n ++ 2).asSymbol, mat[i * 4 + 1],
			(\x ++ n ++ 3).asSymbol, mat[i * 4 + 2],
			(\x ++ n ++ 4).asSymbol, mat[i * 4 + 3]
		];
	}

	stopVoice { arg id;
		if (voices[id].notNil, {
			voices[id].set(\gate, 0);
			voices.removeAt(id);
		});
	}

	free {
		pg.free;
	}
}
