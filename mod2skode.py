
import math
def vol_to_db(v):
    if v <= 0: return -60.0
    return 20.0 * math.log10(v / 64.0) + 10.0

import sys
import struct
import os
import math

PERIODS = {
    856: 45,    808: 46,    762: 47,    720: 48,    678: 49,    640: 50,    604: 51,    570: 52,    538: 53,    508: 54,    480: 55,    453: 56,
    428: 57,    404: 58,    381: 59,    360: 60,    339: 61,    320: 62,    302: 63,    285: 64,    269: 65,    254: 66,    240: 67,    226: 68,
    214: 69,    202: 70,    190: 71,    180: 72,    170: 73,    160: 74,    151: 75,    143: 76,    135: 77,    127: 78,    120: 79,    113: 80,
}

def closest_period(p):
    return min(PERIODS.keys(), key=lambda k: abs(k - p)) if p > 0 else 0


def convert_mod(filename, compress_blank=False):

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
                row.append((midi_note, inst, effect, param))
            pattern.append(row)
        patterns.append(pattern)
        
    out_sk = os.path.join(os.path.dirname(filename), 'stardust.sk')
    with open(out_sk, 'w') as out:
        out.write("# Stardust Memories\n")
        out.write("M 125 96\n\n")
        
        for inst in instruments:
            if inst['len'] > 2:
                wave_id = 100 + inst['id']
                out.write(f"[samples/inst_{inst['id']:02d}.wav] /ws {wave_id}\n")
                if inst['loop_len'] > 2:
                    out.write(f"WL {wave_id},{inst['loop_start']},{inst['loop_start'] + inst['loop_len']}\n")
                
        out.write("\n")
        
        num_skode_patterns = math.ceil(len(sequence) / 2.0)
        
        for i in range(num_skode_patterns):
            for c in range(4):
                pat_id = c * num_skode_patterns + i
                out.write(f"y{pat_id} %6\n")
                

        out.write("# === THE MASTER CONDUCTOR ===\n")
        out.write("# y127 is an empty 128-step pattern set as the 'Master' (yp127).\n")
        out.write("# Because it is the master, any pattern launched with 'zq1' (queue start)\n")
        out.write("# will wait perfectly in sync until y127 reaches step 0 (the downbeat).\n")
        out.write("y127 %6 [] x127 yp127\n\n")
        
        for i in range(num_skode_patterns - 1):
            next_i = i + 1
            cmds = []
            for c in range(4):
                cur_pat = c * num_skode_patterns + i
                next_pat = c * num_skode_patterns + next_i
                cmds.append(f"y{cur_pat} z0 y{next_pat} zq1")
            
            out.write(f"[{' '.join(cmds)}] e>{i}\n")
            out.write(f"/cex {i},4,{i}\n")
        
        
        out.write("# === END OF SONG LOOP ===\n")
        out.write("# When the final sequence finishes, it emits 'ce 127'.\n")
        out.write("# This string stops the final patterns, and instantly restarts (z1) the first patterns AND the master pattern.\n")
        last_pats = [str(c * num_skode_patterns + num_skode_patterns - 1) for c in range(4)]
        first_pats = [str(c * num_skode_patterns) for c in range(4)]
        loop_cmds = [f"y{p} z0" for p in last_pats] + [f"y{p} z1" for p in first_pats] + ["y127 z1"]
        out.write(f"[{' '.join(loop_cmds)}] e>127\n")
        out.write("/cex 127,4,127\n")
        out.write("\n/cer 1\n\n")
        

        current_vol = [64, 64, 64, 64]
        current_speed = 6
        current_note = [0, 0, 0, 0]
        vib_speed = [0, 0, 0, 0]
        vib_depth = [0, 0, 0, 0]
        vib_active = [False, False, False, False]
        current_loop = [None, None, None, None]
        current_wave = [None, None, None, None]


        for seq_idx, p_idx in enumerate(sequence):
            out.write(f"# --- Sequence {seq_idx} (Pattern {p_idx}) ---\n")
            pattern = patterns[p_idx]
            
            sk_pattern_idx = seq_idx // 2
            row_offset = (seq_idx % 2) * 64
            
            for c in range(4):
                pat_id = c * num_skode_patterns + sk_pattern_idx
                out.write(f"y{pat_id}\n")
                for r, row in enumerate(pattern):
                    note, inst, effect, param = row[c]
                    
                    row_speed_cmd = None
                    for scan_c in range(4):
                        _, _, s_eff, s_param = row[scan_c]
                        if s_eff == 0xF and s_param < 32:
                            row_speed_cmd = s_param
                    
                    if row_speed_cmd is not None:
                        current_speed = row_speed_cmd

                    cmds = []
                    
                    if r == 0 and row_offset == 0:
                        cmds.append(f"v{c} a5 t0,0,1,0") # Assign Voice 0 to Channel 0, Voice 1 to Channel 1...
                    
                    if row_speed_cmd is not None:
                        cmds.append(f"z%{row_speed_cmd}")

                    old_vol = current_vol[c]

                    if inst > 0:
                        if current_wave[c] != inst:
                            cmds.append(f"w{100+inst}")
                            current_wave[c] = inst
                        for ins in instruments:
                            if ins['id'] == inst:
                                current_vol[c] = ins['vol']
                                wants_loop = (ins['loop_len'] > 2)
                                if current_loop[c] != wants_loop:
                                    cmds.append("B1" if wants_loop else "B0")
                                    current_loop[c] = wants_loop
                                break
                    
                    if note is not None:
                        current_note[c] = note
                        cmds.append(f"n{note} l1")

                    if effect == 0xC:
                        current_vol[c] = max(0, min(64, param))
                        
                    if current_vol[c] != old_vol or (note is not None):
                        cmds.append(f"s0 a{vol_to_db(current_vol[c]):.2f}")
                        
                    elif effect == 0xA and param > 0:
                        up = param >> 4
                        down = param & 0x0F
                        delta = up if up > 0 else -down
                        for t in range(1, current_speed):
                            current_vol[c] = max(0, min(64, current_vol[c] + delta))
                            cmds.append(f"+-{t} a{vol_to_db(current_vol[c]):.2f}")
                            

                    # 4 - Vibrato
                    elif effect == 0x4 or effect == 0x6:
                        if effect == 0x4 and param > 0:
                            x = param >> 4
                            y = param & 0x0F
                            if x > 0: vib_speed[c] = x
                            if y > 0: vib_depth[c] = y
                            
                        if not vib_active[c]:
                            rate_hz = vib_speed[c] * 0.78
                            # Depth math: modulator_hz * control = dev_hz
                            # We want a deviation roughly proportional to y. Let's try control = y * 0.5
                            cmds.append(f"v{c+4} f{rate_hz:.2f} v{c} FF0 F{c+4},{vib_depth[c]*0.5:.2f}")
                            vib_active[c] = True
                            
                        if effect == 0x6 and param > 0:
                            # 6 is Vibrato + Volume slide!
                            up = param >> 4
                            down = param & 0x0F
                            delta = up if up > 0 else -down
                            for t in range(1, current_speed):
                                current_vol[c] = max(0, min(64, current_vol[c] + delta))
                                cmds.append(f"+-{t} a{vol_to_db(current_vol[c]):.2f}")
                                
                    if effect != 0x4 and effect != 0x6 and vib_active[c]:
                        # Turn off vibrato
                        cmds.append(f"v{c} F-1")
                        vib_active[c] = False

                    elif effect == 0x0 and param > 0:
                        x = param >> 4
                        y = param & 0x0F
                        for t in range(1, current_speed):
                            step = t % 3
                            offset = 0
                            if step == 1: offset = x
                            elif step == 2: offset = y
                            if current_note[c] > 0:
                                cmds.append(f"+-{t} n{current_note[c] + offset}")
                    
                    abs_r = row_offset + r
                    
                    is_last_seq = (seq_idx == len(sequence) - 1)
                    if is_last_seq and r == 63 and c == 0:
                        cmds.append("ce 127 # LOOP ENTIRE SONG")
                    elif abs_r == 127 and c == 0 and sk_pattern_idx < num_skode_patterns - 1:
                        cmds.append(f"ce {sk_pattern_idx}")
                        
                    if cmds:
                        out.write(f"[{' '.join(cmds)}] x{abs_r}\n")
                    else:
                        if not compress_blank or abs_r == 127:
                            out.write(f"[] x{abs_r}\n")
            out.write("\n")
            

        out.write("# === MACROS ===\n")
        out.write("# The file does not start automatically. Type 'play' to begin, and 'stop' to halt.\n")
        
        play_cmds = [f"y{c * num_skode_patterns} z1" for c in range(4)] + ["y127 z1"]
        lfo_cmds = [f"v{c+4} w0 m1 l1 B1" for c in range(4)]
        pan_cmds = [f"v{c} p{-0.6 if c in [0, 3] else 0.6}" for c in range(4)]
        out.write(f"[play]: {' '.join(pan_cmds + lfo_cmds + play_cmds)};\n")
        
        out.write(f"[stop]: Z0;\n")
        
                
        print(f"Generated {out_sk}")


if __name__ == '__main__':
    compress = '--compress' in sys.argv
    filename = sys.argv[1] if sys.argv[1] != '--compress' else sys.argv[2]
    convert_mod(filename, compress_blank=compress)

