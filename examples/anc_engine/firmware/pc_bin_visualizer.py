import numpy as np
import matplotlib.pyplot as plt
import os

def plot_binary_diagnostics():
    files = ["real_noise.bin", "anti_wave.bin", "err_wave.bin"]
    if not all(os.path.exists(f) for f in files):
        print(f"❌ Missing files! Ensure {files} are all downloaded to this folder.")
        return

    print("Loading binary telemetry...")
    # Instantly load binary arrays into numpy
    ref_wave = np.fromfile("real_noise.bin", dtype=np.int8)
    anti_wave = np.fromfile("anti_wave.bin", dtype=np.int8)
    err_wave = np.fromfile("err_wave.bin", dtype=np.int8)

    samples = len(ref_wave)
    time_axis = np.arange(samples)
    print(f"Plotting {samples} samples...")

    lw = 0.5 if samples > 5000 else 1.5
    fig, axes = plt.subplots(3, 1, figsize=(16, 8), sharex=True)
    fig.suptitle(f'Hardware ANC Diagnostics ({samples} samples)', fontsize=16, fontweight='bold')

    axes[0].plot(time_axis, ref_wave, color='tab:blue', linewidth=lw)
    axes[0].set_title('1. Reference Mic (Outside Noise)')
    axes[0].axhline(0, color='black', linewidth=1)

    axes[1].plot(time_axis, anti_wave, color='tab:orange', linewidth=lw)
    axes[1].set_title('2. FPGA Output (Anti-Wave)')
    axes[1].axhline(0, color='black', linewidth=1)

    axes[2].plot(time_axis, err_wave, color='tab:red', linewidth=lw)
    axes[2].set_title('3. Error Mic (Residual Noise at Ear)')
    axes[2].axhline(0, color='black', linewidth=1)

    plt.tight_layout()
    plt.show()

if __name__ == "__main__":
    plot_binary_diagnostics()