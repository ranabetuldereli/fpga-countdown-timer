"""Draw a readable waveform figure from the testbench VCD file.

Usage:  python sim/plot_waveform.py sim/tb_serial_template.vcd docs/waveform.png
Needs:  pip install vcdvcd matplotlib
"""
import sys

import matplotlib.pyplot as plt
from vcdvcd import VCDVCD

VCD_PATH = sys.argv[1] if len(sys.argv) > 1 else "sim/tb_serial_template.vcd"
OUT_PATH = sys.argv[2] if len(sys.argv) > 2 else "docs/waveform.png"
T_END_US = 595  # show tests [1]-[3]: UART input "1205", 'x', start, countdown

vcd = VCDVCD(VCD_PATH)


def series(name):
    """Return [(time_us, int_value), ...] for a signal, ignoring x/z values."""
    sig = next(s for s in vcd.signals if s.endswith(name))
    out = []
    for t, v in vcd[sig].tv:
        try:
            out.append((t / 1e6, int(v, 2)))  # VCD time unit is 1 ps
        except ValueError:
            out.append((t / 1e6, 0))
    return out


def steps(data, t_end):
    xs, ys = [], []
    for i, (t, v) in enumerate(data):
        t_next = data[i + 1][0] if i + 1 < len(data) else t_end
        if t > t_end:
            break
        xs += [t, min(t_next, t_end)]
        ys += [v, v]
    return xs, ys


digital = [
    ("uart_rx", "tb_serial_template.uart_rx"),
    ("rx_data_valid", "dut.rx_data_valid"),
    ("btn[0] (start)", "tb_serial_template.btn[3:0]"),
    ("one_second_tick", "dut.one_second_tick"),
    ("timer_running", "dut.timer_running"),
]

fig, axes = plt.subplots(len(digital) + 1, 1, figsize=(12, 6.5), sharex=True)

for ax, (label, name) in zip(axes, digital):
    data = series(name)
    if label.startswith("btn"):
        data = [(t, v & 1) for t, v in data]
    xs, ys = steps(data, T_END_US)
    ax.plot(xs, ys, color="#1f5fa8", linewidth=1.2, drawstyle="default")
    if label == "one_second_tick":  # 1-cycle pulses are too short to see at this scale
        for t, v in data:
            if v == 1 and t <= T_END_US:
                ax.axvline(t, color="#1f5fa8", linewidth=1.2)
    ax.set_ylim(-0.3, 1.3)
    ax.set_yticks([])
    ax.set_ylabel(label, rotation=0, ha="right", va="center", fontsize=9)
    for side in ("top", "right", "left"):
        ax.spines[side].set_visible(False)

# Display value as a bus: MM:SS
digits = {k: series(f"dut.timer_{k}[3:0]") for k in ("mm_tens", "mm_ones", "ss_tens", "ss_ones")}
times = sorted({t for d in digits.values() for t, _ in d if t <= T_END_US})


def value_at(data, t):
    v = 0
    for tt, vv in data:
        if tt > t:
            break
        v = vv
    return v


ax = axes[-1]
segments = []
for t in times:
    label = "{}{}:{}{}".format(*(value_at(digits[k], t) for k in ("mm_tens", "mm_ones", "ss_tens", "ss_ones")))
    if not segments or segments[-1][1] != label:
        segments.append((t, label))
for i, (t, label) in enumerate(segments):
    t_next = segments[i + 1][0] if i + 1 < len(segments) else T_END_US
    ax.plot([t, t_next], [1, 1], color="#2e7d32", linewidth=1)
    ax.plot([t, t_next], [0, 0], color="#2e7d32", linewidth=1)
    ax.axvline(t, ymin=0.2, ymax=0.8, color="#2e7d32", linewidth=1)
    if t_next - t > 10:
        ax.text((t + t_next) / 2, 0.5, label, ha="center", va="center", fontsize=7)
ax.set_ylim(-0.3, 1.3)
ax.set_yticks([])
ax.set_ylabel("display MM:SS", rotation=0, ha="right", va="center", fontsize=9)
for side in ("top", "right", "left"):
    ax.spines[side].set_visible(False)
ax.set_xlabel("time (µs)")
ax.set_xlim(0, T_END_US)

fig.suptitle('Simulation: "1205" received over UART, then countdown 12:05 -> 11:59', fontsize=11)
fig.tight_layout()
fig.savefig(OUT_PATH, dpi=150)
print("saved", OUT_PATH)
