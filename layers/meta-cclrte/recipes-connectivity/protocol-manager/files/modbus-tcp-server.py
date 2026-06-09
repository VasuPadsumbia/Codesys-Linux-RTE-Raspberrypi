#!/usr/bin/env python3
"""
CCLRTE Modbus TCP Gateway — eth1 (PCIe NIC)
Bridges CODESYS internal data to Modbus TCP clients.
Author: Vasu Padsumbia
"""
import argparse
import socket
import struct
import threading
import logging
import sys

logging.basicConfig(level=logging.INFO, format='%(asctime)s MODBUS-TCP: %(message)s')
log = logging.getLogger(__name__)

MBAP_LEN = 6
COIL_COUNT = 256
REG_COUNT  = 256

# Shared memory (replace with CODESYS SHM interface when available)
coils     = bytearray(COIL_COUNT)
hold_regs = bytearray(REG_COUNT * 2)

def handle_request(data: bytes) -> bytes:
    if len(data) < MBAP_LEN + 2:
        return b''
    tid   = data[0:2]
    proto = data[2:4]
    _len  = data[4:6]
    unit  = data[6]
    fn    = data[7]

    try:
        if fn == 0x01:   # Read Coils
            addr, count = struct.unpack('>HH', data[8:12])
            vals = [coils[addr + i] & 1 for i in range(min(count, COIL_COUNT - addr))]
            byte_count = (len(vals) + 7) // 8
            packed = bytearray(byte_count)
            for i, v in enumerate(vals):
                packed[i // 8] |= (v << (i % 8))
            body = bytes([unit, fn, byte_count]) + bytes(packed)
        elif fn == 0x03:  # Read Holding Registers
            addr, count = struct.unpack('>HH', data[8:12])
            count = min(count, REG_COUNT - addr)
            body = bytes([unit, fn, count * 2]) + bytes(hold_regs[addr*2:(addr+count)*2])
        elif fn == 0x05:  # Write Single Coil
            addr, val = struct.unpack('>HH', data[8:12])
            coils[addr] = 1 if val == 0xFF00 else 0
            body = bytes([unit, fn]) + data[8:12]
        elif fn == 0x06:  # Write Single Register
            addr, val = struct.unpack('>HH', data[8:12])
            struct.pack_into('>H', hold_regs, addr * 2, val)
            body = bytes([unit, fn]) + data[8:12]
        else:
            body = bytes([unit, fn | 0x80, 0x01])  # illegal function
    except Exception:
        body = bytes([unit, fn | 0x80, 0x04])  # server device failure

    length = struct.pack('>H', len(body))
    return tid + proto + length + body

def client_thread(conn, addr):
    log.info(f"Connected: {addr}")
    try:
        while True:
            data = conn.recv(512)
            if not data:
                break
            resp = handle_request(data)
            if resp:
                conn.sendall(resp)
    except Exception:
        pass
    finally:
        conn.close()
        log.info(f"Disconnected: {addr}")

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--iface', default='eth1')
    p.add_argument('--port',  type=int, default=502)
    args = p.parse_args()

    # Bind to specific interface
    try:
        import socket
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE,
                        args.iface.encode() + b'\0')
        sock.bind(('0.0.0.0', args.port))
        sock.listen(5)
        log.info(f"Modbus TCP listening on {args.iface}:{args.port}")
    except PermissionError:
        log.error("Port 502 requires root (or CAP_NET_BIND_SERVICE)")
        sys.exit(1)

    while True:
        conn, addr = sock.accept()
        threading.Thread(target=client_thread, args=(conn, addr), daemon=True).start()

if __name__ == '__main__':
    main()
