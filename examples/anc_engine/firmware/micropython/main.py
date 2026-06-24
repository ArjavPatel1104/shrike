import math
import time
from dspi_bus import DSPI
import shrike

print("Flashing FPGA with Sign-Error LMS Engine...")
shrike.flash("anc_engine.bin")

def test_hardware_lms_engine():
    bus = DSPI(freq=10_000_000) 
    delay = 3
    
    print("Loading binary audio into RAM...")
    with open("real_noise.bin", "rb") as f:
        ref_bytes = f.read()
        
    samples = len(ref_bytes)
    
    MAX_CSV_SAMPLES = 24000  # 3 seconds max
    if samples > MAX_CSV_SAMPLES:
        samples = MAX_CSV_SAMPLES

    # 1. PRE-ALLOCATE RAM BUFFERS (Super fast, prevents flash lockups)
    print(f"Allocating RAM buffers for {samples} samples...")
    anti_bytes = bytearray(samples)
    err_bytes = bytearray(samples)

    speaker_history = [0, 0, 0] 
    
    print(f"Executing high-speed SPI hardware loop...")
    start_time = time.ticks_ms()
    
    # 2. PHASE 1: HARDWARE LOOP (NO FILE WRITING HERE)
    for i in range(samples):
        raw_ref = ref_bytes[i]
        ref_val = raw_ref if raw_ref < 128 else raw_ref - 256
        
        if i >= delay:
            raw_ear = ref_bytes[i - delay]
            ear_noise = raw_ear if raw_ear < 128 else raw_ear - 256
        else:
            ear_noise = 0
            
        err_val = ear_noise + speaker_history[0]
        err_val = max(-128, min(127, err_val))
        
        payload = bytes([ref_val & 0xFF, err_val & 0xFF])
        rx_buffer = bus.transfer(payload)
        
        raw_anti = rx_buffer[0]
        anti_wave_val = raw_anti if raw_anti < 128 else raw_anti - 256
        
        speaker_history.pop(0)
        speaker_history.append(anti_wave_val)
        
        # Store results directly into high-speed RAM
        anti_bytes[i] = raw_anti
        err_bytes[i] = err_val & 0xFF

    hw_time = time.ticks_diff(time.ticks_ms(), start_time)
    print(f"Hardware execution finished in {hw_time} ms.")

    # 3. PHASE 2: SAVE TO CSV
    filename = "anc_diagnostic_data.csv"
    print(f"Saving data to {filename}... DO NOT UNPLUG!")
    
    with open(filename, "w") as f:
        f.write("Sample,Ref_Mic(Outside),Anti_Wave(Speaker),Err_Mic(Residual_Noise)\n")
        
        for i in range(samples):
            # Reconstruct signed values from our byte arrays
            raw_ref = ref_bytes[i]
            ref_val = raw_ref if raw_ref < 128 else raw_ref - 256
            
            raw_anti = anti_bytes[i]
            anti_val = raw_anti if raw_anti < 128 else raw_anti - 256
            
            raw_err = err_bytes[i]
            err_val = raw_err if raw_err < 128 else raw_err - 256
            
            f.write(f"{i},{ref_val},{anti_val},{err_val}\n")
            
            # Print a progress update so you know it hasn't crashed
            if i > 0 and i % 5000 == 0:
                print(f"   Saved {i} / {samples} samples...")
                
    print(f"Done! Safe to download {filename}.")

if __name__ == "__main__":
    test_hardware_lms_engine()
