#!/usr/bin/env python3
"""Observe only the owned synthetic codedb process's TCP sockets and telemetry.

This is bounded socket-table sampling, not packet capture or proof against an
arbitrarily short connection. Integration tests separately exercise opt-in and
failed/successful upload behavior against a loopback endpoint.
"""
import ctypes
import importlib.util
import os
from pathlib import Path
import struct
import threading
import time
spec=importlib.util.spec_from_file_location('matrix',Path(__file__).with_name('release-matrix.py'))
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)

def connections(pid):
    rows=[]
    for family,row_size,pid_offset in ((2,24,20),(23,56,52)):
        size=ctypes.c_ulong(0)
        error=ctypes.windll.iphlpapi.GetExtendedTcpTable(None,ctypes.byref(size),False,family,5,0)
        if error not in (0,122):raise OSError(error,'GetExtendedTcpTable sizing')
        buf=ctypes.create_string_buffer(size.value)
        error=ctypes.windll.iphlpapi.GetExtendedTcpTable(buf,ctypes.byref(size),False,family,5,0)
        if error:raise OSError(error,'GetExtendedTcpTable')
        count=struct.unpack_from('<I',buf.raw)[0]
        for i in range(count):
            offset=4+i*row_size
            if struct.unpack_from('<I',buf.raw,offset+pid_offset)[0]==pid:
                rows.append({'family':family,'raw_socket_row_hex':buf.raw[offset:offset+row_size].hex()})
    return rows

if __name__=='__main__':
    base=m.PRIVATE/'network';root=base/'project';root.mkdir(parents=True,exist_ok=True)
    (root/'synthetic.ts').write_text('export const localNetworkCanary = 42;\n')
    p=m.MCP(m.binaries()['candidate'],root,base/'cache')
    samples=[];errors=[];stop=threading.Event()
    def observe():
        while not stop.is_set():
            try:samples.append({'t':time.monotonic(),'sockets':connections(p.proc.pid)})
            except Exception as exc:errors.append(repr(exc));return
            stop.wait(.01)
    observer=threading.Thread(target=observe);observer.start()
    try:
        p.ready()
        deadline=time.monotonic()+10;calls=0
        while time.monotonic()<deadline:
            p.call('codedb_search',{'query':'localNetworkCanary'})
            p.call('codedb_read',{'path':'synthetic.ts'});calls+=2
            time.sleep(.02)
    finally:
        stop.set();observer.join();p.close()
    report={'binary_sha256':m.digest(m.binaries()['candidate'].read_bytes()),'pid':p.proc.pid,
            'samples':len(samples),'tool_calls':calls,'errors':errors,'observed_sockets':[s for s in samples if s['sockets']],
            'telemetry_files':[str(x) for x in (base/'cache').rglob('telemetry*')],
            'limitation':'TCP IPv4/IPv6 socket-table sampling after process creation; excludes UDP, child processes and connections shorter than sampling interval. No packet capture.',
            'environment':{'CODEDB_TELEMETRY':'0','CODEDB_NO_TELEMETRY':'1','CODEDB_NO_AUTO_UPDATE':'1'}}
    report['passed']=bool(samples) and not errors and not report['observed_sockets'] and not report['telemetry_files']
    m.save(base/'results.json',report)
    print('TCP/telemetry observation',report['passed'],'samples',len(samples),'calls',calls)
    raise SystemExit(0 if report['passed'] else 1)
