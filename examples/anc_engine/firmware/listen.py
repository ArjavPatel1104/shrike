import numpy as np
import wave
import os

def create_wav(filename, data_array, framerate=8000):
    # The binary data is 8-bit signed [-128, 127]. 
    # Standard WAV files prefer 16-bit signed [-32768, 32767].
    # We multiply by 256 to scale the volume up for standard media players.
    audio_data = np.int16(data_array) * 256
    
    with wave.open(filename, 'w') as wav_file:
        wav_file.setnchannels(1)       # Mono audio
        wav_file.setsampwidth(2)       # 2 bytes per sample (16-bit)
        wav_file.setframerate(framerate)
        wav_file.writeframes(audio_data.tobytes())

def generate_audio_from_binaries():
    files = ["real_noise.bin", "anti_wave.bin", "err_wave.bin"]
    
    # Ensure all three binary files are in the same folder as this script
    if not all(os.path.exists(f) for f in files):
        print(f"❌ ERROR: Missing files! Ensure {files} are present.")
        print("Did you remember to download anti_wave.bin and err_wave.bin from the Pico?")
        return

    print("Loading raw binary telemetry...")
    # Instantly load the raw bytes directly into numpy arrays
    ref_wave = np.fromfile("real_noise.bin", dtype=np.int8)
    anti_wave = np.fromfile("anti_wave.bin", dtype=np.int8)
    err_wave = np.fromfile("err_wave.bin", dtype=np.int8)

    # 1. Generate the "Before" Audio (Original Room Noise)
    print("Generating '1_before_anc.wav'...")
    create_wav("1_before_anc.wav", ref_wave)

    # 2. Generate the "After" Audio (Residual Error / What the ear hears)
    print("Generating '2_after_anc.wav'...")
    create_wav("2_after_anc.wav", err_wave)
    
    # 3. Generate the Anti-Wave alone just to hear what the speaker is doing
    print("Generating '3_anti_wave_only.wav'...")
    create_wav("3_anti_wave_only.wav", anti_wave)

    print(f"\n✅ Success! Processed {len(ref_wave)} samples.")
    print("Put on your headphones and play '1_before_anc.wav' followed by '2_after_anc.wav'.")

if __name__ == "__main__":
    generate_audio_from_binaries()