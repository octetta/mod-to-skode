#!/bin/python
import math
def vol_to_db(v):
    if v <= 0: return -60.0
    return 20.0 * math.log10(v / 64.0) + 10.0

import sys
import struct
import zipfile
import io
import wave
import os
import os
import math

PERIODS = {
    856: 45,    808: 46,    762: 47,    720: 48,    678: 49,    640: 50,    604: 51,    570: 52,    538: 53,    508: 54,    480: 55,    453: 56,
    428: 57,    404: 58,    381: 59,    360: 60,    339: 61,    320: 62,    302: 63,    285: 64,    269: 65,    254: 66,    240: 67,    226: 68,
    214: 69,    202: 70,    190: 71,    180: 72,    170: 73,    160: 74,    151: 75,    143: 76,    135: 77,    127: 78,    120: 79,    113: 80,
}


def period_to_freq(p):
    if p <= 0: return 0
    return 3546895.0 / p

def period_to_midi(p):
    f = period_to_freq(p)
    if f <= 0: return 0
    return 69.0 + 12.0 * math.log2(f / 440.0)

def closest_period(p):
    return min(PERIODS.keys(), key=lambda k: abs(k - p)) if p > 0 else 0


def convert_mod(filename, out_file=None, compress_blank=False, extract=False, dedupe=False, max_steps=0):

    with open(filename, 'rb') as f:
        data = f.read()
    
    offset = 20
    instruments = []
    for i in range(31):
        sample_data = data[offset:offset+30]
        length = struct.unpack('>H', sample_data[22:24])[0] * 2
        volume = sample_data[25]
        rep_off = struct.unpack('>H', sample_data[26:28])[0] * 2
        rep_len = struct.unpack('>H', sample_data[28:30])[0] * 2
        instruments.append({
            'id': i+1, 'len': length, 'vol': volume, 
            'loop_start': rep_off, 'loop_len': rep_len
        })
        offset += 30
        
    song_len = data[offset]
    restart_pos = data[offset+1]
    offset += 2
    sequence = data[offset:offset+128][:song_len]
    offset += 128
    magic = data[offset:offset+4].decode('ascii', errors='ignore')
    offset += 4
    
    num_patterns = max(sequence) + 1
    
    patterns = []
    for p in range(num_patterns):
        pattern = []
        for r in range(64):
            row = []
            for c in range(4):
                b = data[offset:offset+4]
                offset += 4
                inst = (b[0] & 0xF0) | ((b[2] & 0xF0) >> 4)
                period = ((b[0] & 0x0F) << 8) | b[1]
                effect = b[2] & 0x0F
                param = b[3]
                midi_note = PERIODS.get(closest_period(period)) if period > 0 else None
                row.append((midi_note, inst, effect, param, period))
            pattern.append(row)
        patterns.append(pattern)
        
    sample_data_start = offset
    is_zip = out_file and out_file.endswith('.zip')
    if is_zip:
        out_fd = io.StringIO()
    else:
        out_fd = open(out_file, 'w') if out_file else sys.stdout
    try:
        out = out_fd
        out.write(f"# Converted from {os.path.basename(filename)}\n")
        
        # Scan for initial tempo and speed in the first row(s)
        initial_speed = 6
        initial_tempo = 125
        if patterns:
            for c in range(4):
                _, _, eff, param, _ = patterns[sequence[0]][0][c]
                if eff == 0xF:
                    if param < 32:
                        initial_speed = param
                    else:
                        initial_tempo = param
                        
        ticks_per_measure = initial_speed * 16
        out.write(f"M {initial_tempo} {ticks_per_measure}\n\n")
        out.write("# === INITIALIZATION ===\n")
        out.write("S0 S1 S2 S3 S4 S5 S6 S7\n")
        for c in range(4):
            out.write(f"v{c} w0 m0 n60 l1 B1 p{-0.6 if c in [0, 3] else 0.6} t0,0,1,0 s0 a1 f20000 F0 DD0 DT0 DS0 A0\n")
            out.write(f"v{c+4} w0 m1 n60 l1 B1 t0,0,1,0 a1 f20000 F0 DD0 DT0 DS0 A0\n")
        out.write("\n")
        
        for inst in instruments:
            if inst['len'] > 2:
                wave_id = 100 + inst['id']
                out.write(f"[samples/inst_{inst['id']:02d}.wav] /ws {wave_id}\n")
                if inst['loop_len'] > 2 and not (inst['len'] > 4000 and inst['loop_len'] < 200):
                    out.write(f"WL {wave_id},{inst['loop_start']},{inst['loop_start'] + inst['loop_len']}\n")
                
        out.write("\n")
        
        mods_per_pattern = max(1, max_steps // 64) if max_steps > 0 else len(sequence)
        skode_steps = mods_per_pattern * 64
        s_last = skode_steps - 1
        num_skode_patterns = math.ceil(len(sequence) / mods_per_pattern)
        
        for i in range(num_skode_patterns):
            for c in range(5):
                pat_id = c * num_skode_patterns + i
                out.write(f"y{pat_id} %6\n")
                

        out.write("# === THE MASTER CONDUCTOR ===\n")
        out.write("# y127 is an empty 128-step pattern set as the 'Master' (yp127).\n")
        out.write("# Because it is the master, any pattern launched with 'zq1' (queue start)\n")
        out.write("# will wait perfectly in sync until y127 reaches step 0 (the downbeat).\n")
        out.write(f"y127 %6 [] x{s_last} yp127\n\n")
        
        for i in range(num_skode_patterns - 1):
            next_i = i + 1
            cmds = []
            for c in range(5):
                cur_pat = c * num_skode_patterns + i
                next_pat = c * num_skode_patterns + next_i
                cmds.append(f"y{cur_pat} z0 y{next_pat} zq1")
            
            out.write(f"[{' '.join(cmds)}] e>{i}\n")
            out.write(f"/cex {i},4,{i}\n")
        
        
        out.write("# === END OF SONG LOOP ===\n")
        out.write("# When the final sequence finishes, it emits 'ce 127'.\n")
        last_pats = [str(c * num_skode_patterns + num_skode_patterns - 1) for c in range(4)]
        if restart_pos < song_len:
            target_p = restart_pos // mods_per_pattern
            target_r = (restart_pos % mods_per_pattern) * 64
            target_pats = [str(c * num_skode_patterns + target_p) for c in range(4)]
            # Use zq1 to queue it smoothly, but it will start at step 0 of the target skode pattern.
            # If target_r is 64, this might be slightly off. But Stardust doesn't loop anyway.
            last_pats_5 = [str(c * num_skode_patterns + num_skode_patterns - 1) for c in range(5)]
            target_pats_5 = [str(c * num_skode_patterns + target_p) for c in range(5)]
            loop_cmds = [f"y{p} z0" for p in last_pats_5] + [f"y{p} z1" for p in target_pats_5] + ["y127 z1"]
            out.write(f"[{' '.join(loop_cmds)}] e>127\n")
        else:
            out.write(f"[Z0] e>127\n")
        out.write("/cex 127,4,127\n")
        out.write("\n/cer 1\n\n")
        

        current_vol = [64, 64, 64, 64]
        current_speed = 6
        current_note = [0, 0, 0, 0]
        current_period = [0, 0, 0, 0]
        target_period = [0, 0, 0, 0]
        portamento_speed = [0, 0, 0, 0]
        vib_speed = [0, 0, 0, 0]
        vol_slide_speed = [0, 0, 0, 0]
        vib_depth = [0, 0, 0, 0]
        vib_active = [False, False, False, False]
        trem_active = [False, False, False, False]
        trem_speed = [0, 0, 0, 0]
        trem_depth = [0, 0, 0, 0]
        current_loop = [None, None, None, None]
        current_wave = [None, None, None, None]


        pattern_text = {}
        for c in range(4):
            for sk_idx in range(num_skode_patterns):
                pattern_text[(c, sk_idx)] = ""
                
        for seq_idx, p_idx in enumerate(sequence):
            # out.write(f"# --- Sequence {seq_idx} (Pattern {p_idx}) ---\n")
            pattern = patterns[p_idx]
            
            sk_pattern_idx = seq_idx // mods_per_pattern
            row_offset = (seq_idx % mods_per_pattern) * 64
            
            for c in range(4):
                pat_id = c * num_skode_patterns + sk_pattern_idx
                # out.write(f"y{pat_id}\n")
                for r, row in enumerate(pattern):
                    note, inst, effect, param, period = row[c]
                    
                    row_speed_cmd = None
                    row_tempo_cmd = None
                    for scan_c in range(4):
                        _, _, s_eff, s_param, _ = row[scan_c]
                        if s_eff == 0xF:
                            if s_param < 32:
                                row_speed_cmd = s_param
                            else:
                                if not (seq_idx == 0 and r == 0):
                                    row_tempo_cmd = s_param
                    
                    if row_speed_cmd is not None:
                        current_speed = row_speed_cmd
                    if row_tempo_cmd is not None:
                        # Only apply tempo changes once per row, on voice 0 to save space
                        if c == 0:
                            pass # We'll handle appending to cmds below

                    cmds = []
                    
                    if r == 0 and row_offset == 0:
                        cmds.append(f"v{c}") # Bind sequence to voice
                    
                    if row_speed_cmd is not None:
                        cmds.append(f"z%{row_speed_cmd}")
                    if row_tempo_cmd is not None and c == 0:
                        cmds.append(f"M{row_tempo_cmd},{current_speed * 16}")

                    old_vol = current_vol[c]

                    if inst > 0:
                        if current_wave[c] != inst:
                            cmds.append(f"w{100+inst}")
                            current_wave[c] = inst
                        for ins in instruments:
                            if ins['id'] == inst:
                                current_vol[c] = ins['vol']
                                wants_loop = (ins['loop_len'] > 2) and not (ins['len'] > 4000 and ins['loop_len'] < 200)
                                if current_loop[c] != wants_loop:
                                    cmds.append("B1" if wants_loop else "B0")
                                    current_loop[c] = wants_loop
                                break
                    

                    # Portamento parameter memory
                    if effect in (0x1, 0x2, 0x3, 0x5) and param > 0:
                        portamento_speed[c] = param
                        
                    # Target period for 0x3
                    if period > 0 and effect in (0x3, 0x5):
                        target_period[c] = period
                        
                    # Missing Volume logic
                    old_vol = current_vol[c]
                    
                    if effect == 0xC:
                        current_vol[c] = max(0, min(64, param))
                        
                    if current_vol[c] != old_vol or (note is not None and effect not in (0x3, 0x5)):
                        cmds.append(f"a{vol_to_db(current_vol[c]):.2f}")

                    # Note trigger
                    if note is not None and effect not in (0x3, 0x5):
                        current_note[c] = note
                        current_period[c] = period
                        
                        note_prefix = ""
                        note_suffix = ""
                        if effect == 0xE:
                            ext_type = param >> 4
                            ext_val = param & 0x0F
                            if ext_type == 0x9 and ext_val > 0:  # E9x Retrigger
                                # we handle retriggers by emitting +time n{note} l1
                                pass
                            elif ext_type == 0xD and ext_val > 0:  # EDx Note Delay
                                delay_time = ext_val / 96.0
                                note_prefix = f"+{delay_time:.5f} "
                                
                        cmds.append("fb0") # Reset bend
                        cmds.append(f"{note_prefix}n{note} l1")
                        
                        if effect == 0xE and ext_type == 0x9 and ext_val > 0:
                            for t in range(ext_val, current_speed, ext_val):
                                cmds.append(f"+{t / 96.0:.5f} n{note} l1")
                        
                    # Handle Portamento execution tick-by-tick
                    if effect in (0x1, 0x2, 0x3, 0x5):
                        speed = portamento_speed[c]
                        if speed > 0 and current_period[c] > 0:
                            for t in range(1, current_speed):
                                if effect == 0x1: # Slide up (period decreases)
                                    current_period[c] = max(113, current_period[c] - speed)
                                elif effect == 0x2: # Slide down (period increases)
                                    current_period[c] = min(856, current_period[c] + speed)
                                elif effect in (0x3, 0x5): # Slide to target note
                                    if current_period[c] < target_period[c]:
                                        current_period[c] = min(target_period[c], current_period[c] + speed)
                                    elif current_period[c] > target_period[c]:
                                        current_period[c] = max(target_period[c], current_period[c] - speed)
                                        
                                # Calculate pitch bend in semitones relative to current_note
                                current_f_midi = period_to_midi(current_period[c])
                                bend_semitones = current_f_midi - current_note[c]
                                
                                # Skode fb is normalized -1.0 to 1.0, and default freq_bend_range is 2.0 semitones.
                                # To allow bends larger than 2 semitones, we can emit a parameter change!
                                # fb <val>, fbp <range>. But let's just scale fb assuming a range of 24.
                                # Wait, if we just set `fbp 24` once when we trigger the note, we can use `fb` easily!
                                # Or we can just emit `fbp` if the bend exceeds the current range...
                                # By default range is 2. Let's just emit `fb {bend_semitones / 2.0}` and if it clips, it clips.
                                # Actually, tracker bends easily exceed 2 semitones. 
                                # Let's change the voice's bend range to 12 semitones when a tracker instrument is loaded, 
                                # or just emit `fbp 12`!
                                cmds.append(f"+{t / 96.0:.5f} fb{bend_semitones / 12.0:.3f}")
                                if t == 1: cmds.append("fbp12") # Ensure range is 12

                    if effect in (0xA, 0x5, 0x6) and param > 0:
                        up = param >> 4
                        down = param & 0x0F
                        vol_slide_speed[c] = up if up > 0 else -down
                        
                    if effect in (0xA, 0x5, 0x6):
                        delta = vol_slide_speed[c]
                        if delta != 0:
                            for t in range(1, current_speed):
                                current_vol[c] = max(0, min(64, current_vol[c] + delta))
                                cmds.append(f"+{t / 96.0:.5f} a{vol_to_db(current_vol[c]):.2f}")
                            

                    # 4 - Vibrato, 7 - Tremolo
                    elif effect in (0x4, 0x6, 0x7):
                        if effect == 0x4 and param > 0:
                            x = param >> 4
                            y = param & 0x0F
                            if x > 0: vib_speed[c] = x
                            if y > 0: vib_depth[c] = y
                        elif effect == 0x7 and param > 0:
                            x = param >> 4
                            y = param & 0x0F
                            if x > 0: trem_speed[c] = x
                            if y > 0: trem_depth[c] = y
                            
                        if effect in (0x4, 0x6) and not vib_active[c]:
                            rate_hz = vib_speed[c] * 0.78
                            cmds.append(f"v{c+4} f{rate_hz:.2f} v{c} FF0 F{c+4},{vib_depth[c]*0.5:.2f}")
                            vib_active[c] = True
                            
                        if effect == 0x7 and not trem_active[c]:
                            rate_hz = trem_speed[c] * 0.78
                            cmds.append(f"v{c+4} f{rate_hz:.2f} v{c} A{c+4},{trem_depth[c]*0.05:.2f}")
                            trem_active[c] = True
                            
                        if effect == 0x6 and param > 0:
                            # 6 is Vibrato + Volume slide!
                            up = param >> 4
                            down = param & 0x0F
                            delta = up if up > 0 else -down
                            for t in range(1, current_speed):
                                current_vol[c] = max(0, min(64, current_vol[c] + delta))
                                cmds.append(f"+{t / 96.0:.5f} a{vol_to_db(current_vol[c]):.2f}")
                                
                    if effect not in (0x4, 0x6) and vib_active[c]:
                        cmds.append(f"v{c} F-1")
                        vib_active[c] = False
                        
                    if effect != 0x7 and trem_active[c]:
                        cmds.append(f"v{c} A") # Turn off amp mod
                        trem_active[c] = False

                    elif effect == 0x0 and param > 0:
                        x = param >> 4
                        y = param & 0x0F
                        for t in range(1, current_speed):
                            step = t % 3
                            arp_offset = 0
                            if step == 1: arp_offset = x
                            elif step == 2: arp_offset = y
                            if current_note[c] > 0:
                                cmds.append(f"+{t / 96.0:.5f} n{current_note[c] + arp_offset}")
                    
                    abs_r = row_offset + r
                    
                    pass
                        
                    if cmds:
                        cmd_str = ' '.join(cmds)
                        words = cmd_str.split()
                        if len(words) > 28:
                            print(f"Warning: Sequence {seq_idx}, row {r}, channel {c} has {len(words)} commands.")
                        pattern_text[(c, sk_pattern_idx)] += f"[{cmd_str}] x{abs_r}\n"
                    else:
                        if not compress_blank or abs_r == s_last:
                            pattern_text[(c, sk_pattern_idx)] += f"[] x{abs_r}\n"""
            # out.write("\n")
            

        out.write("# === MACROS ===\n")
        out.write("# The file does not start automatically. Type 'play' to begin, and 'stop' to halt.\n")
        
        play_cmds = [f"v{c} y{pat_mapping[(c, 0)] if 'pat_mapping' in locals() else c * num_skode_patterns} z1" for c in range(5)] + ["v0 y127 z1"]
        
        out.write(f"# Type 'play' to begin.\n")
        out.write(f"[play]: {' '.join(play_cmds)};\n")
        
        out.write(f"[stop]: Z0 v0l0 v1l0 v2l0 v3l0;\n")
        
                
        if out_file:
            print(f"Generated {out_file}", file=sys.stderr)
            
        # Generate conductor track patterns
        for sk_idx in range(num_skode_patterns):
            pat_id = 4 * num_skode_patterns + sk_idx
            pattern_text[(4, sk_idx)] = f"[ce {sk_idx}] x{s_last}\n"
            if sk_idx == num_skode_patterns - 1:
                pattern_text[(4, sk_idx)] = f"[ce 127] x{s_last}\n"
                
        pat_mapping = {}
        if dedupe:
            unique_texts = {}
            for c in range(5):
                for sk_idx in range(num_skode_patterns):
                    text = pattern_text[(c, sk_idx)]
                    if text in unique_texts:
                        pat_mapping[(c, sk_idx)] = unique_texts[text]
                    else:
                        pat_id = c * num_skode_patterns + sk_idx
                        unique_texts[text] = pat_id
                        pat_mapping[(c, sk_idx)] = pat_id
                        out.write(f"y{pat_id}\n{text}")
            print(f"Deduplication: {num_skode_patterns * 5} raw patterns reduced to {len(unique_texts)} unique patterns.")
        else:
            for c in range(5):
                for sk_idx in range(num_skode_patterns):
                    pat_id = c * num_skode_patterns + sk_idx
                    pat_mapping[(c, sk_idx)] = pat_id
                    out.write(f"y{pat_id}\n{pattern_text[(c, sk_idx)]}")
        
        # Macros
        out.write("\n# === MACROS ===\n")
        for i in range(num_skode_patterns - 1):
            next_i = i + 1
            cmds = []
            for c in range(5):
                cur_pat = pat_mapping[(c, i)]
                next_pat = pat_mapping[(c, next_i)]
                cmds.append(f"y{cur_pat} z0 y{next_pat} zq1")
            
            out.write(f"[{' '.join(cmds)}] e>{i}\n")
            out.write(f"/cex {i},4,{i}\n")
            
        last_pats_5 = [str(pat_mapping[(c, num_skode_patterns - 1)]) for c in range(5)]
        if restart_pos < song_len:
            target_p = restart_pos // mods_per_pattern
            target_pats_5 = [str(pat_mapping[(c, target_p)]) for c in range(5)]
            loop_cmds = [f"y{p} z0" for p in last_pats_5] + [f"y{p} z1" for p in target_pats_5] + ["y127 z1"]
            out.write(f"[{' '.join(loop_cmds)}] e>127\n")
        else:
            out.write(f"[Z0] e>127\n")
        out.write("/cex 127,4,127\n\n/cer 1\n")



        
        if is_zip:
            # We need to extract the samples and build the zip
            sk_content = out_fd.getvalue()
            out_fd.close()
            
            with zipfile.ZipFile(out_file, 'w', zipfile.ZIP_DEFLATED) as zf:
                # Add main script
                zf.writestr('main.sk', sk_content)
                
                # Extract samples
                samp_offset = sample_data_start
                for ins in instruments:
                    length = ins['len']
                    if length > 2:
                        raw_data = data[samp_offset:samp_offset+length]
                        
                        # Convert 8-bit signed to 16-bit signed for WAV
                        samples_16 = [ (b if b < 128 else b - 256) * 256 for b in raw_data ]
                        data_16 = struct.pack('<' + 'h'*len(samples_16), *samples_16)
                        
                        wav_io = io.BytesIO()
                        with wave.open(wav_io, 'wb') as w:
                            w.setnchannels(1)
                            w.setsampwidth(2)
                            w.setframerate(16574) # 16574 ensures it plays at 8287Hz when triggered at note 57 (A3)
                            w.writeframes(data_16)
                            
                        zf.writestr(f"samples/inst_{ins['id']:02d}.wav", wav_io.getvalue())
                        
                    samp_offset += length
    finally:
        if not is_zip and out_file:
            out_fd.close()
            
        if not is_zip and extract:
            if not os.path.exists('samples'):
                os.makedirs('samples')
            samp_offset = sample_data_start
            for ins in instruments:
                length = ins['len']
                if length > 2:
                    raw_data = data[samp_offset:samp_offset+length]
                    samples_16 = [ (b if b < 128 else b - 256) * 256 for b in raw_data ]
                    data_16 = struct.pack('<' + 'h'*len(samples_16), *samples_16)
                    wav_io = io.BytesIO()
                    with wave.open(wav_io, 'wb') as w:
                        w.setnchannels(1)
                        w.setsampwidth(2)
                        w.setframerate(16574)
                        w.writeframes(data_16)
                    with open(f"samples/inst_{ins['id']:02d}.wav", 'wb') as wf:
                        wf.write(wav_io.getvalue())
                samp_offset += length
            print("Extracted samples to samples/ directory", file=sys.stderr)

            





if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description="Convert MOD to Skode")
    parser.add_argument("filename", help="Input MOD file")
    parser.add_argument("-o", "--output", help="Output .sk file (default: stdout)", default=None)
    parser.add_argument("-c", "--compress", action="store_true", help="Compress blank lines")
    parser.add_argument("-x", "--extract", action="store_true", help="Extract samples to disk (creates samples/ dir)")
    parser.add_argument("-d", "--dedupe", action="store_true", help="Deduplicate Skode patterns (2-pass)")
    parser.add_argument("--max-steps", type=int, default=0, help="Max steps per Skode pattern (0 = unlimited). Use 128 for older pulp versions.")
    args = parser.parse_args()
    convert_mod(args.filename, out_file=args.output, compress_blank=args.compress, extract=args.extract, dedupe=args.dedupe, max_steps=args.max_steps)

