import sys, json, pathlib, subprocess, tempfile, time
sys.path.insert(0,r'C:\repos\codedb\scripts')
import e2e_mcp_test as h
B=r'C:\Users\jwvol\AppData\Local\codedb\bin\codedb.exe'
result={}
root=pathlib.Path(tempfile.mkdtemp(prefix='codedb-audit-extra-'))
subprocess.run(['git','init','-q',str(root)],check=True)
files={'a/index.ts':'export const FromA = 1;\n','b/index.ts':'export const FromB = 2;\n','consumer.ts':'import { FromA } from "./a/index";\nexport const value = FromA;\n','sub/.gitignore':'hidden.ts\n','sub/hidden.ts':'export const auditNestedIgnore = 7;\n','.gitignore':'*.skip.ts\n!keep.skip.ts\n','keep.skip.ts':'export const auditNegationKeep = 9;\n','drop.skip.ts':'export const auditNegationDrop = 1;\n','private.PEM':'synthetic_snapshot_canary\n'}
for path,content in files.items():
    f=root/path;f.parent.mkdir(parents=True,exist_ok=True);f.write_text(content,encoding='utf-8')
p=h.MCPProcess(B,[],cwd=r'C:\repos\codedb',command=[B,str(root),'mcp','--no-telemetry'])
try:
    result['initialize']=h.do_initialize(p,False)
    result['ready']=h.wait_for_scan(p)
    for key,args in [('a/index.ts',{'path':'a/index.ts'}),('b/index.ts',{'path':'b/index.ts'}),('consumer.ts',{'path':'consumer.ts','direction':'depends_on'})]:
        result['deps:'+key]=h.all_tool_text(p.call_tool('codedb_deps',args))
    for query in ['auditNestedIgnore','auditNegationKeep','auditNegationDrop']:
        result['search:'+query]=h.all_tool_text(p.call_tool('codedb_search',{'query':query}))
finally:p.close()
snap=root/'audit.snapshot'
r=subprocess.run([B,str(root),'snapshot',str(snap)],capture_output=True,timeout=60)
result['snapshot']={'exit_code':r.returncode,'contains_sensitive_canary':snap.exists() and b'synthetic_snapshot_canary' in snap.read_bytes()}

# Re-run scenario 1 with the sole correction being RFC-compliant Windows file URIs.
def reply(p,project_path,timeout=5):
    req=p.recv_method('roots/list',timeout=timeout)
    if req is None:return False
    p.send({'jsonrpc':'2.0','id':req['id'],'result':{'roots':[{'uri':pathlib.Path(project_path).resolve().as_uri(),'name':'project'}]}})
    return True
h.reply_roots=reply
rr=h.run_scenario_1_issue346_regression(B,r'C:\repos\codedb')
result['scenario1_correct_uri']=[{'name':r.name,'passed':r.passed,'message':r.message} for r in rr]
out=pathlib.Path(r'C:\repos\codedb\plans\evidence\2026-10-06-extra.json')
out.write_text(json.dumps(result,indent=2),encoding='utf-8')
print(json.dumps(result,indent=2))
