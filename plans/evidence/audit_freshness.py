import sys, pathlib, tempfile, subprocess, json, time, os
sys.path.insert(0,r'C:\repos\codedb\scripts')
import e2e_mcp_test as h
B=r'C:\Users\jwvol\AppData\Local\codedb\bin\codedb.exe'
r={}
root=pathlib.Path(tempfile.mkdtemp(prefix='codedb-audit-freshness-'))
subprocess.run(['git','init','-q',str(root)],check=True)
f=root/'watch.ts';f.write_text('export const auditOldCanary = 1;\n',encoding='utf-8')
p=h.MCPProcess(B,[],cwd=r'C:\repos\codedb',command=[B,str(root),'mcp','--no-telemetry'])
try:
    h.do_initialize(p,False);h.wait_for_scan(p)
    time.sleep(3)
    r['before']=h.all_tool_text(p.call_tool('codedb_search',{'query':'auditOldCanary'}))
    st=f.stat();f.write_text('export const auditNewCanary = 1;\n',encoding='utf-8');os.utime(f,ns=(st.st_atime_ns,st.st_mtime_ns))
    time.sleep(5)
    r['after_preserved_mtime']=h.all_tool_text(p.call_tool('codedb_search',{'query':'auditNewCanary'}))
    r['read_after']=h.all_tool_text(p.call_tool('codedb_read',{'path':'watch.ts','raw':True}))
    r['status']=h.all_tool_text(p.call_tool('codedb_status',{}))
finally:p.close()
root2=r'C:\repos\credo_main\src\Autumn'
p=h.MCPProcess(B,[],cwd=r'C:\repos\codedb',command=[B,root2,'mcp','--no-telemetry'])
try:
    h.do_initialize(p,False)
    r['fsharp_references']=h.all_tool_text(p.call_tool('codedb_callers',{'name':'QueryProcess','match_mode':'references','max_results':10},timeout=60))
finally:p.close()
out=pathlib.Path(r'C:\repos\codedb\plans\evidence\2026-10-06-freshness.json');out.write_text(json.dumps(r,indent=2),encoding='utf-8')
print(json.dumps(r,indent=2))
