import numpy as np
from pydub import AudioSegment

def convert_wav_for_fpga(input_file, output_file="real_noise.bin", target_fs=8000):
    print(f"Loading lossless audio from '{input_file}'...")
    
    try:
        audio = AudioSegment.from_file(input_file, format="wav")
    except Exception as e:
        print(f"❌ Failed to load audio.\nError: {e}")
        return

    audio = audio.set_channels(1)
    audio = audio.set_frame_rate(target_fs)
    samples = np.array(audio.get_array_of_samples(), dtype=np.float32)
    
    peak_volume = np.max(np.abs(samples))
    if peak_volume == 0:
        print("❌ ERROR: The audio file is completely silent.")
        return
        
    normalized_samples = samples / peak_volume
    scaled_audio = np.clip(normalized_samples * 100, -127, 127).astype(np.int8)
    
    print(f"Writing {len(scaled_audio)} bytes to '{output_file}'...")
    
    # FIX: Write as raw binary bytes instead of a text-based Python list
    with open(output_file, "wb") as f:
        f.write(scaled_audio.tobytes())
        
    print(f"✅ Conversion successful! Upload '{output_file}' to your microcontroller.")

if __name__ == "__main__":
    convert_wav_for_fpga("test.wav")