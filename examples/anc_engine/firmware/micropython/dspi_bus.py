import time
import struct
from machine import Pin
import rp2

@rp2.asm_pio(
    out_shiftdir=rp2.PIO.SHIFT_LEFT, 
    in_shiftdir=rp2.PIO.SHIFT_LEFT,  
    set_init=(rp2.PIO.OUT_LOW, rp2.PIO.OUT_LOW),
    out_init=(rp2.PIO.OUT_LOW, rp2.PIO.OUT_LOW),
    sideset_init=rp2.PIO.OUT_LOW     
)
def _dual_spi_core():
    pull(block)           .side(0)  
    
    set(pindirs, 3)       .side(0) 
    
    out(pins, 2)          .side(0) [1] 
    nop()                 .side(1) [1] 
    out(pins, 2)          .side(0) [1]
    nop()                 .side(1) [1]
    out(pins, 2)          .side(0) [1]
    nop()                 .side(1) [1]
    out(pins, 2)          .side(0) [1]
    nop()                 .side(1) [1]

    set(pindirs, 0)       .side(0) [1] 
    nop()                 .side(0) [1] 

    nop()                 .side(1) [1] 
    in_(pins, 2)          .side(0) [1] 
    nop()                 .side(1) [1] 
    in_(pins, 2)          .side(0) [1] 
    nop()                 .side(1) [1] 
    in_(pins, 2)          .side(0) [1] 
    nop()                 .side(1) [1] 
    in_(pins, 2)          .side(0) [1] 
    
    push(block)           .side(0)  

class DSPI:
    def __init__(self, cs_pin=1, sck_pin=2, data_base=14, freq=10_000_000, sm_id=0):
        self.cs_pin = Pin(cs_pin, Pin.OUT, value=1) 
        self.sck_pin = Pin(sck_pin, Pin.OUT, value=0)
        self.data_base = Pin(data_base)
        
        for i in range(data_base, data_base + 2):
            Pin(i, Pin.IN, Pin.PULL_DOWN)

        self.sm = rp2.StateMachine(
            sm_id, _dual_spi_core, freq=freq,  
            sideset_base=self.sck_pin,  
            out_base=self.data_base,  
            in_base=self.data_base,  
            set_base=self.data_base
        )
        self.sm.restart() 
        self.sm.active(1)
        
        # Hard Flush of TX/RX hardware queues to clear MicroPython reboot cache
        while self.sm.rx_fifo():
            self.sm.get()
        for _ in range(8):
            self.sm.put(0)
            self.sm.get()

    def transfer(self, data):
        if isinstance(data, str):
            data = data.encode('utf-8')
            
        rx_buffer = bytearray(len(data))
        
        while self.sm.rx_fifo():
            self.sm.get()
        
        self.cs_pin.value(0)
        time.sleep_us(5) 
        
        for i, byte_val in enumerate(data):
            # THE BULLETPROOF FIX: Safely pack bytes into standard C-style 32-bit unsigned integers
            safe_32bit_word = struct.unpack('>I', bytes([byte_val, 0, 0, 0]))[0]
            
            self.sm.put(safe_32bit_word)
            rx_buffer[i] = self.sm.get() & 0xFF
            
        time.sleep_us(2)
        self.cs_pin.value(1)
        time.sleep_us(10) 
        
        return rx_buffer

