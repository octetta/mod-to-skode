#!/bin/python
import math
import sys
import struct
import zipfile
import io
import wave
import os


def vol_to_db(v):
    if v <= 0:
        return -100.0
    return 20.0 * math.log10(v / 64.0) - 10.0


PERIODS = {
    856: 45, 808: 46, 762: 47, 720: 48, 678: 49, 640: 50, 604: 51, 570: 52, 538: 53, 508: 54, 480: 55, 453: 56,
    428: 57, 404: 58, 381: 59, 360: 60, 339: 61, 320: 62, 302: 63, 285: 64, 269: 65, 254: 66, 240: 67, 226: 68,
    214: 69, 202: 70, 190: 71, 180: 72, 170: 73, 160: 74, 151: 75, 143: 76, 135: 77, 127: 78, 120: 79, 113: 80,
}

PROTRACKER_SINE_TABLE = [
    0, 24, 49, 74, 97, 120, 141, 161,
    180, 197, 212, 224, 235, 244, 250, 253,
    255, 253, 250, 244, 235, 224, 212, 197,
    180, 161, 141, 120, 97, 74, 49, 24,
]


def period_to_freq(p):
    if p <= 0:
        return 0.0
    # Period 428 is A3 (220 Hz) in our MIDI note mapping (where WAV framerate=16574 plays 8287 Hz at note 57).
    return 220.0 * (428.0 / p)


def period_to_midi(p):
    if p <= 0:
        return 0.0
    return 57.0 + 12.0 * math.log2(428.0 / p)


def closest_period(p):
    return min(PERIODS.keys(), key=lambda k: abs(k - p)) if p > 0 else 0


def unroll_mod_rows(patterns, sequence, restart_pos):
    """
    Unrolls the MOD sequence into a flat list of (seq_idx, pat_idx, row_idx, row)
    while respecting ProTracker flow control:
      - Bxx (Position Jump)
      - Dxx (Pattern Break, BCD row target)
      - E6x (Pattern Loop)
      - EEx (Pattern Delay)
    Returns (unrolled_rows, seq_start_step, loop_target_step).
    """
    unrolled = []
    seq_start_step = {}
    loop_target_seq = restart_pos if restart_pos < len(sequence) else None

    seq_idx = 0
    next_start_row = 0
    visited_seqs = set()

    while 0 <= seq_idx < len(sequence):
        if seq_idx not in seq_start_step:
            seq_start_step[seq_idx] = len(unrolled)
        visited_seqs.add(seq_idx)

        p_idx = sequence[seq_idx]
        pattern = patterns[p_idx]

        r = next_start_row
        next_start_row = 0
        loop_start_r = [0, 0, 0, 0]
        loop_count = [0, 0, 0, 0]
        jumped = False

        while 0 <= r < 64:
            row = pattern[r]

            # Scan row for flow-control effects (Bxx, Dxx, E6x, EEx)
            pos_jump = None
            pat_break = None
            pat_delay = 0
            e6_loop_target = None

            for c in range(4):
                _, _, eff, param, _ = row[c]
                if eff == 0xB:
                    pos_jump = param
                elif eff == 0xD:
                    pat_break = ((param >> 4) * 10) + (param & 0x0F)
                    if pat_break >= 64:
                        pat_break = 0
                elif eff == 0xE:
                    ext_type = param >> 4
                    ext_val = param & 0x0F
                    if ext_type == 0x6:
                        if ext_val == 0:
                            loop_start_r[c] = r
                        else:
                            if loop_count[c] == 0:
                                loop_count[c] = ext_val
                                e6_loop_target = loop_start_r[c]
                            else:
                                loop_count[c] -= 1
                                if loop_count[c] > 0:
                                    e6_loop_target = loop_start_r[c]
                    elif ext_type == 0xE:
                        pat_delay = ext_val

            unrolled.append((seq_idx, p_idx, r, row, False))
            for _ in range(pat_delay):
                # Pattern delay repeats the row ticks without retriggering notes
                unrolled.append((seq_idx, p_idx, r, row, True))

            if e6_loop_target is not None:
                r = e6_loop_target
                continue

            if pos_jump is not None or pat_break is not None:
                target_seq = pos_jump if pos_jump is not None else (seq_idx + 1)
                target_row = pat_break if pat_break is not None else 0

                if pos_jump is not None and (target_seq in visited_seqs or target_seq >= len(sequence)):
                    # Song loop back to an earlier sequence (or end of song)
                    if target_seq < len(sequence):
                        loop_target_seq = target_seq
                    seq_idx = len(sequence)
                    jumped = True
                    break
                else:
                    seq_idx = target_seq
                    next_start_row = target_row
                    jumped = True
                    break

            r += 1

        if not jumped:
            seq_idx += 1

    loop_target_step = seq_start_step.get(loop_target_seq, None) if loop_target_seq is not None else None
    return unrolled, seq_start_step, loop_target_step, loop_target_seq


def convert_mod(filename, out_file=None, compress_blank=False, extract=False, dedupe=False, max_steps=0, loop=False):
    with open(filename, 'rb') as f:
        data = f.read()

    mod_basename = os.path.basename(filename)
    mod_title = ''.join(c for c in data[:20].decode('ascii', errors='ignore') if 32 <= ord(c) <= 126).strip()
    mod_info = f"{mod_basename} ('{mod_title}')" if mod_title else mod_basename
    mod_info = mod_info.replace('[', '(').replace(']', ')')

    offset = 20
    instruments = []
    for i in range(31):
        sample_data = data[offset:offset+30]
        name = sample_data[:22].decode('ascii', errors='ignore').rstrip('\x00').strip()
        length = struct.unpack('>H', sample_data[22:24])[0] * 2
        finetune = sample_data[24] & 0x0F
        if finetune >= 8:
            finetune -= 16
        volume = min(64, sample_data[25])
        rep_off = struct.unpack('>H', sample_data[26:28])[0] * 2
        rep_len = struct.unpack('>H', sample_data[28:30])[0] * 2
        wants_loop = rep_len > 2
        instruments.append({
            'id': i + 1,
            'name': name,
            'len': length,
            'finetune': finetune,
            'cents': finetune * 12.5,
            'vol': volume,
            'loop_start': rep_off,
            'loop_len': rep_len,
            'wants_loop': wants_loop,
        })
        offset += 30

    raw_credits = []
    for ins in instruments:
        raw_name = ins['name']
        clean = ''.join(c for c in raw_name if 32 <= ord(c) <= 126).strip()
        clean = clean.replace('[', '(').replace(']', ')')
        raw_credits.append(clean)

    while raw_credits and not raw_credits[-1]:
        raw_credits.pop()
    while raw_credits and not raw_credits[0]:
        raw_credits.pop(0)

    credits_lines = []
    prev_empty = False
    for line in raw_credits:
        if not line:
            if not prev_empty:
                credits_lines.append("")
                prev_empty = True
        else:
            credits_lines.append(line)
            prev_empty = False

    song_len = data[offset]
    restart_pos = data[offset+1]
    offset += 2
    sequence = list(data[offset:offset+128][:song_len])
    offset += 128
    magic = data[offset:offset+4].decode('ascii', errors='ignore')
    offset += 4

    num_patterns = max(sequence) + 1 if sequence else 0

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

        # Scan for initial tempo and speed in the first row
        initial_speed = 6
        initial_tempo = 125
        if patterns and sequence:
            for c in range(4):
                _, _, eff, param, _ = patterns[sequence[0]][0][c]
                if eff == 0xF and param > 0:
                    if param < 32:
                        initial_speed = param
                    else:
                        initial_tempo = param

        # Subdivision 96 means 1 master clock tick = 1 ProTracker tick (24 ticks/beat * 4 beats/measure)
        out.write(f"M {initial_tempo} 96\n\n")
        out.write("# === INITIALIZATION ===\n")
        out.write("S0 S1 S2 S3 S4 S5 S6 S7\n")
        out.write("DL 1 0 0 0 0 15 10\n")
        for c in range(4):
            pan = -0.6 if c in (0, 3) else 0.6
            out.write(f"v{c} [ch {c+1}] vt w0 m0 n60 l1 B1 p{pan} t0,0,1,0 s0.002,1 g0.001,2 g0 fbp24 a-100 F0 A0\n")
            out.write(f"v{c+4} [lfo {c+1}] vt w0 m1 n60 l1 B1 t0,0,1,0 a-10 f20000 F0 A0\n")
        out.write("\n")

        inst_by_id = {ins['id']: ins for ins in instruments}
        for inst in instruments:
            if inst['len'] > 2:
                wave_id = 100 + inst['id']
                out.write(f"[samples/inst_{inst['id']:02d}.wav] /ws {wave_id}\n")
                clean_name = ''.join(c for c in inst['name'] if 32 <= ord(c) <= 126).strip()
                clean_name = clean_name.replace('[', '(').replace(']', ')')
                name_to_set = clean_name if clean_name else f"inst_{inst['id']:02d}"
                out.write(f"[{name_to_set}] wt {wave_id}\n")
                if inst['wants_loop']:
                    loop_end = min(inst['len'], inst['loop_start'] + inst['loop_len'])
                    out.write(f"WL {wave_id},{inst['loop_start']},{loop_end}\n")

        out.write("\n")

        unrolled_rows, seq_start_step, loop_target_step, loop_target_seq = unroll_mod_rows(
            patterns, sequence, restart_pos
        )
        total_rows = len(unrolled_rows)
        # Allocate 1 extra step at the end of the song for the natural end/fade trigger
        total_steps = total_rows + 1

        if max_steps > 0:
            skode_steps = max(64, (max_steps // 64) * 64)
            num_skode_patterns = max(1, math.ceil(total_steps / skode_steps))
        else:
            skode_steps = total_steps
            num_skode_patterns = 1

        s_last = skode_steps - 1

        for i in range(num_skode_patterns):
            for c in range(5):
                pat_id = c * num_skode_patterns + i
                out.write(f"y{pat_id} %{initial_speed}\n")

        out.write("# === THE MASTER CONDUCTOR ===\n")
        out.write("# y127 is an empty pattern set as the 'Master' (yp127).\n")
        out.write("# Because it is the master, any pattern launched with 'zq1' (queue start)\n")
        out.write("# will wait perfectly in sync until y127 reaches step 0 (the downbeat).\n")
        out.write(f"y127 %{initial_speed} [v0] x{s_last} yp127\n\n")

        current_vol = [64, 64, 64, 64]
        current_speed = initial_speed
        current_note = [0, 0, 0, 0]
        current_cents = [0.0, 0.0, 0.0, 0.0]
        current_period = [0, 0, 0, 0]
        target_period = [0, 0, 0, 0]
        portamento_speed = [0, 0, 0, 0]
        vib_speed = [0, 0, 0, 0]
        vol_slide_speed = [0, 0, 0, 0]
        vib_depth = [0, 0, 0, 0]
        vib_active = [False, False, False, False]
        vib_applied = [0, 0, 0, 0]
        trem_active = [False, False, False, False]
        trem_applied = [(0, 0), (0, 0), (0, 0), (0, 0)]
        trem_speed = [0, 0, 0, 0]
        trem_depth = [0, 0, 0, 0]
        current_loop = [None, None, None, None]
        current_wave = [None, None, None, None]
        current_inst = [None, None, None, None]
        sample_offset_mem = [0, 0, 0, 0]
        active_vs_offset = [0, 0, 0, 0]
        current_fb = [0.0, 0.0, 0.0, 0.0]

        pattern_text = {}
        for c in range(5):
            for sk_idx in range(num_skode_patterns):
                pattern_text[(c, sk_idx)] = ""

        for global_row_idx, (seq_idx, p_idx, r, row, is_pat_delay_repeat) in enumerate(unrolled_rows):
            sk_pattern_idx = global_row_idx // skode_steps
            abs_r = global_row_idx % skode_steps

            row_speed_cmd = None
            row_tempo_cmd = None
            for scan_c in range(4):
                _, _, s_eff, s_param, _ = row[scan_c]
                if s_eff == 0xF and s_param > 0:
                    if s_param < 32:
                        row_speed_cmd = s_param
                    else:
                        if not (global_row_idx == 0):
                            row_tempo_cmd = s_param

            if row_speed_cmd is not None:
                current_speed = row_speed_cmd

            for c in range(4):
                note, inst, effect, param, period = row[c]
                if is_pat_delay_repeat:
                    note = None
                    inst = 0
                    period = 0

                cmds = []

                if abs_r % 64 == 0:
                    cmds.append(f"v{c}")  # Bind sequence to voice at pattern boundary

                if row_speed_cmd is not None and not is_pat_delay_repeat:
                    cmds.append(f"z%{row_speed_cmd}")
                if row_tempo_cmd is not None and c == 0 and not is_pat_delay_repeat:
                    cmds.append(f"M{row_tempo_cmd},96")

                old_vol = current_vol[c]

                if inst > 0 and inst in inst_by_id:
                    ins = inst_by_id[inst]
                    current_inst[c] = ins
                    current_vol[c] = ins['vol']

                # Portamento parameter memory
                if effect in (0x1, 0x2, 0x3) and param > 0:
                    portamento_speed[c] = param

                # Target period for 0x3 / 0x5
                if period > 0 and effect in (0x3, 0x5):
                    target_period[c] = period

                # Tick-0 extended effects (Fine Porta E1x/E2x, Fine Volume Slide EAx/EBx, Pan E8x)
                ext_type = (param >> 4) if effect == 0xE else None
                ext_val = (param & 0x0F) if effect == 0xE else 0

                if effect == 0xC:
                    current_vol[c] = max(0, min(64, param))
                elif effect == 0xE and not is_pat_delay_repeat:
                    if ext_type == 0xA:  # EAx Fine Volume Slide Up
                        current_vol[c] = min(64, current_vol[c] + ext_val)
                    elif ext_type == 0xB:  # EBx Fine Volume Slide Down
                        current_vol[c] = max(0, current_vol[c] - ext_val)
                    elif ext_type == 0x8:  # E8x Set Panning (0..15 -> -1.0..1.0)
                        pan_val = (ext_val / 7.5) - 1.0
                        cmds.append(f"p{pan_val:.2f}")

                if current_vol[c] != old_vol or (note is not None and effect not in (0x3, 0x5)):
                    cmds.append(f"a{vol_to_db(current_vol[c]):.2f}")

                # Note trigger (in ProTracker, switching waveforms only takes effect when a note is triggered,
                # or for single-cycle wavetable swaps in chiptunes when the sample is a short loop)
                ins = current_inst[c]
                if ins and ins['len'] > 2:
                    should_switch_wave = (note is not None and effect not in (0x3, 0x5)) or (
                        inst > 0 and ins['wants_loop'] and ins['len'] <= 512
                    )
                    if should_switch_wave and current_wave[c] != ins['id']:
                        cmds.append(f"w{100 + ins['id']}")
                        current_wave[c] = ins['id']
                        active_vs_offset[c] = 0
                        # w<id> in Skred resets sv.loop_enabled[v] to sw.loop_enabled[w] (0 for raw WAVs),
                        # so we must always emit B1 when the newly loaded instrument wants looping!
                        if ins['wants_loop']:
                            cmds.append("B1")
                            current_loop[c] = True
                        else:
                            cmds.append("B0")
                            current_loop[c] = False
                        if ins['cents'] != current_cents[c]:
                            cmds.append(f"N0,{ins['cents']:g}")
                            current_cents[c] = ins['cents']

                if note is not None and effect not in (0x3, 0x5):
                    current_note[c] = note
                    current_period[c] = period
                    vib_applied[c] = 0

                    # Handle 9xx Sample Offset
                    if effect == 0x9:
                        if param > 0:
                            sample_offset_mem[c] = param * 256
                        offset_samples = sample_offset_mem[c]
                        if ins and ins['len'] > 2:
                            if offset_samples > 0 and offset_samples < ins['len'] - 2:
                                if active_vs_offset[c] != offset_samples:
                                    cmds.append(f"VS{offset_samples},{ins['len']}")
                                    active_vs_offset[c] = offset_samples
                            elif offset_samples >= ins['len'] - 2:
                                # Offset past end of non-looping sample silences trigger
                                pass
                    else:
                        if active_vs_offset[c] != 0:
                            cmds.append("VS")
                            active_vs_offset[c] = 0

                    note_prefix = ""
                    tick_cursor = 0
                    if effect == 0xE and ext_type == 0xD and ext_val > 0:  # EDx Note Delay
                        note_prefix = f"+-{ext_val} "
                        tick_cursor = ext_val

                    if current_fb[c] != 0.0:
                        cmds.append("fb0")
                        current_fb[c] = 0.0

                    # Exact pitch only when period is not one of the standard ProTracker periods
                    if period not in PERIODS:
                        exact_midi = period_to_midi(period)
                        note_cents = (exact_midi - note) * 100.0
                        note_cmd = f"n{note},{note_cents:.0f}" if abs(note_cents) >= 1.0 else f"n{note}"
                    else:
                        note_cmd = f"n{note}"

                    cmds.append(f"{note_prefix}{note_cmd} l1")
                else:
                    tick_cursor = 0

                # E1x / E2x Fine Portamento (happens once on Tick 0)
                if effect == 0xE and ext_type in (0x1, 0x2) and ext_val > 0 and current_period[c] > 0 and not is_pat_delay_repeat:
                    if ext_type == 0x1:
                        current_period[c] = max(113, current_period[c] - ext_val)
                    else:
                        current_period[c] = min(856, current_period[c] + ext_val)
                    bend_semitones = period_to_midi(current_period[c]) - current_note[c]
                    fb_val = max(-1.0, min(1.0, bend_semitones / 24.0))
                    cmds.append(f"fb{fb_val:.3f}")
                    current_fb[c] = fb_val

                # ECx Note Cut at tick x
                if effect == 0xE and ext_type == 0xC:
                    if ext_val == 0:
                        current_vol[c] = 0
                        cmds.append("a-100.00")
                    elif ext_val < current_speed and ext_val >= tick_cursor:
                        current_vol[c] = 0
                        dt = ext_val - tick_cursor
                        if dt > 0:
                            cmds.append(f"+-{dt} a-100.00")
                            tick_cursor = ext_val
                        else:
                            cmds.append("a-100.00")

                # 4 - Vibrato, 6 - Vibrato + Vol Slide, 7 - Tremolo
                if current_period[c] > 0 and current_note[c] > 0:
                    base_bend = period_to_midi(current_period[c]) - current_note[c]
                    base_fb = max(-1.0, min(1.0, base_bend / 24.0))
                else:
                    base_fb = 0.0

                if effect not in (0x4, 0x6):
                    if vib_active[c]:
                        # Restore unmodulated period bend when vibrato ends
                        if abs(current_fb[c] - base_fb) >= 0.0005:
                            cmds.append(f"fb{base_fb:.3f}" if abs(base_fb) >= 0.0005 else "fb0")
                            current_fb[c] = base_fb
                        vib_active[c] = False
                else:
                    # In ProTracker, on tick 0 of every row, Paula AUDPER is strictly the unmodulated base period.
                    # Restore base_fb on tick 0 if previous row ended on a modulated vibrato offset.
                    if abs(current_fb[c] - base_fb) >= 0.0005:
                        cmds.append(f"fb{base_fb:.3f}" if abs(base_fb) >= 0.0005 else "fb0")
                        current_fb[c] = base_fb

                if effect != 0x7 and trem_active[c]:
                    cmds.append("A")  # Turn off amp mod
                    trem_active[c] = False

                if effect in (0x4, 0x6, 0x7):
                    if effect == 0x4 and param > 0:
                        x = param >> 4
                        y = param & 0x0F
                        if x > 0:
                            vib_speed[c] = x
                        if y > 0:
                            vib_depth[c] = y
                    elif effect == 0x7 and param > 0:
                        x = param >> 4
                        y = param & 0x0F
                        if x > 0:
                            trem_speed[c] = x
                        if y > 0:
                            trem_depth[c] = y

                    if effect in (0x4, 0x6):
                        vib_active[c] = True

                    if effect == 0x7:
                        cur_trem = (trem_speed[c], trem_depth[c])
                        if not trem_active[c] or trem_applied[c] != cur_trem:
                            rate_hz = trem_speed[c] * 0.78
                            d = trem_depth[c] * 0.025
                            o = 1.0 - d
                            cmds.append(f"v{c+4} f{rate_hz:.2f} v{c} A{c+4},{d:.3f},{o:.3f}")
                            trem_active[c] = True
                            trem_applied[c] = cur_trem

                # Tick-by-tick effects (Portamento, Vibrato, Volume Slide, Arpeggio, Retrigger)
                # Note: in Skred's run_program, each +-<dt> is cumulative on `when`!
                if effect in (0xA, 0x5, 0x6) and param > 0:
                    up = param >> 4
                    down = param & 0x0F
                    vol_slide_speed[c] = up if up > 0 else -down

                arp_x = (param >> 4) if (effect == 0x0 and param > 0) else 0
                arp_y = (param & 0x0F) if (effect == 0x0 and param > 0) else 0
                retrig_interval = ext_val if (effect == 0xE and ext_type == 0x9 and ext_val > 0 and note is not None and effect not in (0x3, 0x5)) else 0

                for t in range(1, current_speed):
                    tick_ops = []

                    # Retrigger (E9x)
                    if retrig_interval > 0 and (t % retrig_interval) == 0:
                        tick_ops.append(f"{note_cmd} l1")

                    # Portamento (0x1, 0x2, 0x3, 0x5)
                    if effect in (0x1, 0x2, 0x3, 0x5):
                        speed = portamento_speed[c]
                        if speed > 0 and current_period[c] > 0:
                            prev_period = current_period[c]
                            if effect == 0x1:  # Slide up (period decreases)
                                current_period[c] = max(113, current_period[c] - speed)
                            elif effect == 0x2:  # Slide down (period increases)
                                current_period[c] = min(856, current_period[c] + speed)
                            elif effect in (0x3, 0x5) and target_period[c] > 0:  # Slide to target note
                                if current_period[c] < target_period[c]:
                                    current_period[c] = min(target_period[c], current_period[c] + speed)
                                elif current_period[c] > target_period[c]:
                                    current_period[c] = max(target_period[c], current_period[c] - speed)

                            if current_period[c] != prev_period:
                                current_f_midi = period_to_midi(current_period[c])
                                bend_semitones = current_f_midi - current_note[c]
                                fb_val = max(-1.0, min(1.0, bend_semitones / 24.0))
                                tick_ops.append(f"fb{fb_val:.3f}")
                                current_fb[c] = fb_val

                    # Vibrato (0x4, 0x6) - ProTracker 32-entry sine table on ticks 1..speed-1
                    if effect in (0x4, 0x6) and current_period[c] > 0:
                        vib_pos = vib_applied[c] & 63
                        vib_sin = PROTRACKER_SINE_TABLE[vib_pos & 31]
                        delta_period = (vib_sin * vib_depth[c]) // 128
                        if vib_pos >= 32:
                            delta_period = -delta_period
                        mod_period = max(113, min(856, current_period[c] + delta_period))
                        vib_applied[c] = (vib_applied[c] + vib_speed[c]) & 63
                        bend_semitones = period_to_midi(mod_period) - current_note[c]
                        fb_val = max(-1.0, min(1.0, bend_semitones / 24.0))
                        if abs(fb_val - current_fb[c]) >= 0.0005:
                            tick_ops.append(f"fb{fb_val:.3f}")
                            current_fb[c] = fb_val

                    # Volume Slide (0xA, 0x5, 0x6)
                    if effect in (0xA, 0x5, 0x6):
                        delta = vol_slide_speed[c]
                        if delta != 0:
                            prev_vol = current_vol[c]
                            current_vol[c] = max(0, min(64, current_vol[c] + delta))
                            if current_vol[c] != prev_vol:
                                tick_ops.append(f"a{vol_to_db(current_vol[c]):.2f}")

                    # Arpeggio (0x0)
                    if effect == 0x0 and param > 0 and current_note[c] > 0:
                        step = t % 3
                        arp_offset = arp_x if step == 1 else (arp_y if step == 2 else 0)
                        tick_ops.append(f"n{current_note[c] + arp_offset}")

                    if tick_ops and t >= tick_cursor:
                        dt = t - tick_cursor
                        if dt > 0:
                            cmds.append(f"+-{dt} {' '.join(tick_ops)}")
                            tick_cursor = t
                        else:
                            cmds.append(' '.join(tick_ops))

                pat_end_step = (total_rows - 1) % skode_steps if sk_pattern_idx == num_skode_patterns - 1 else s_last
                if cmds:
                    cmd_str = ' '.join(cmds)
                    words = cmd_str.split()
                    if len(words) > 28:
                        print(f"Warning: Sequence {seq_idx}, row {r}, channel {c} has {len(words)} commands.")
                    pattern_text[(c, sk_pattern_idx)] += f"[{cmd_str}] x{abs_r}\n"
                else:
                    if abs_r == pat_end_step:
                        pattern_text[(c, sk_pattern_idx)] += f"[v{c}] x{abs_r}\n"
                    elif not compress_blank:
                        pattern_text[(c, sk_pattern_idx)] += f"[] x{abs_r}\n"

            # Conductor track (channel 4): sync speed changes and pattern transition control events
            cond_cmds = []
            if row_speed_cmd is not None and not is_pat_delay_repeat:
                cond_cmds.append(f"z%{row_speed_cmd}")
            if sk_pattern_idx < num_skode_patterns - 1 and abs_r == s_last:
                cond_cmds.append(f"ce {sk_pattern_idx}")
            if cond_cmds:
                pattern_text[(4, sk_pattern_idx)] += f"[{' '.join(cond_cmds)}] x{abs_r}\n"

        # Natural song end step: allow the final row to finish completely before firing ce 127
        end_pat_idx = num_skode_patterns - 1
        end_step = (total_steps - 1) % skode_steps
        for c in range(4):
            pattern_text[(c, end_pat_idx)] += f"[v{c}] x{end_step}\n"
        pattern_text[(4, end_pat_idx)] += f"[ce 127] x{end_step}\n"

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

        # Control Event Transitions & End-of-Song Loop
        out.write("\n# === PATTERN TRANSITIONS & END OF SONG LOOP ===\n")
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
        end_cmds = "Z0 v0 s1.5,1 a-100 v1 s1.5,1 a-100 v2 s1.5,1 a-100 v3 s1.5,1 a-100 +1.6 v0 l0 A v1 l0 A v2 l0 A v3 l0 A v4 a-100 l0 v5 a-100 l0 v6 a-100 l0 v7 a-100 l0"
        stop_cmds = "Z0 v0 s1.0,1 a-100 v1 s1.0,1 a-100 v2 s1.0,1 a-100 v3 s1.0,1 a-100 +1.1 v0 l0 A v1 l0 A v2 l0 A v3 l0 A v4 a-100 l0 v5 a-100 l0 v6 a-100 l0 v7 a-100 l0"
        if loop and loop_target_step is not None:
            target_p = loop_target_step // skode_steps
            target_step_in_p = loop_target_step % skode_steps
            target_pats_5 = [str(pat_mapping[(c, target_p)]) for c in range(5)]
            if num_skode_patterns == 1 and target_step_in_p > 0:
                loop_cmds = [f"y{p} zg{target_step_in_p}" for p in target_pats_5]
            else:
                loop_cmds = [f"y{p} z0" for p in last_pats_5] + [f"y{p} z1" for p in target_pats_5] + ["y127 z1"]
                if target_step_in_p > 0:
                    loop_cmds += [f"y{p} zg{target_step_in_p}" for p in target_pats_5]
            out.write(f"[{' '.join(loop_cmds)}] e>127\n")
        else:
            out.write(f"[{end_cmds}] e>127\n")
        out.write("/cex 127,4,127\n\n/cer 1\n\n")

        # Macros
        out.write("# === MACROS ===\n")
        out.write("# The file does not start automatically. Type 'play' to begin, and 'stop' to halt.\n")
        play_cmds = [f"v{c} s0.002,1 l1 y{pat_mapping[(c, 0)]} z1" for c in range(4)] + [
            f"y{pat_mapping[(4, 0)]} z1",
            "y127 z1",
        ]
        efx_cmds = "v0 p0 r1 ds .5 v1 p0 r1 ds .5 v2 p0 r1 ds .5 v3 p0 r1 ds .5 DL 1 0 0 0 0 15 10"
        out.write(f"[play]: {' '.join(play_cmds)};\n")
        out.write(f"[stop]: {stop_cmds};\n")
        out.write(f"[efx!]: {efx_cmds};\n\n")
        nofx_cmds = "v0 p-.6 v1 p.6 v2 p-.6 v3 p.6";
        out.write(f"[nofx]: {nofx_cmds};\n\n");

        # Info banner & credits
        out.write("# === INFO DISPLAY ON LOAD ===\n")
        out.write(f"[{mod_info}] puts\n")
        for line in credits_lines:
            out.write(f"[{line}] puts\n")
        if credits_lines:
            out.write("[] puts\n")
        out.write(f"[play : {' '.join(play_cmds)}] puts\n")
        out.write(f"[stop : {stop_cmds}] puts\n")
        out.write(f"[efx! : {efx_cmds}] puts\n")
        out.write(f"[nofx : {nofx_cmds}] puts\n");

        if out_file:
            print(f"Generated {out_file}", file=sys.stderr)




        
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
    parser.add_argument("-l", "--loop", action="store_true", help="Loop song at end instead of stopping")
    parser.add_argument("--max-steps", type=int, default=0, help="Max steps per Skode pattern (0 = unlimited). Use 128 for older pulp versions.")
    args = parser.parse_args()
    convert_mod(args.filename, out_file=args.output, compress_blank=args.compress, extract=args.extract, dedupe=args.dedupe, max_steps=args.max_steps, loop=args.loop)

