import sys, os, json, time, subprocess, tempfile, pathlib, hashlib
sys.path.insert(0, r'C:\repos\codedb\scripts')
from e2e_mcp_test import MCPProcess, all_tool_text

BIN = r'C:\Users\jwvol\AppData\Local\codedb\bin\codedb.exe'
OUT = pathlib.Path(r'C:\repos\codedb\plans\evidence\2026-10-06-audit.json')
REPORT = {'binary': BIN, 'sha256': hashlib.sha256(pathlib.Path(BIN).read_bytes()).hexdigest(), 'synthetic': {}, 'repositories': []}
ENV = {'CODEDB_NO_TELEMETRY':'1', 'NO_COLOR':'1'}

def start(root):
    p = MCPProcess(BIN, [], cwd=r'C:\repos\codedb', command=[BIN, str(root), 'mcp'], env=ENV)
    p.send({'jsonrpc':'2.0','id':1,'method':'initialize','params':{'protocolVersion':'2024-11-05','capabilities':{},'clientInfo':{'name':'audit','version':'1'}}})
    r = p.recv(timeout=30)
    p.send({'jsonrpc':'2.0','method':'notifications/initialized','params':{}})
    return p,r

def call(p,name,args):
    t=time.monotonic()
    r=p.call_tool(name,args,timeout=90)
    text=all_tool_text(r)
    return {'ms':round((time.monotonic()-t)*1000,1),'text':text,'error':None if r is None else r.get('error'),'isError':None if r is None else r.get('result',{}).get('isError')}

def save():
    OUT.parent.mkdir(parents=True,exist_ok=True)
    OUT.write_text(json.dumps(REPORT,indent=2),encoding='utf-8')

base=pathlib.Path(tempfile.mkdtemp(prefix='codedb-audit-20261006-'))
root=base/'project'; root.mkdir()
subprocess.run(['git','init','-q',str(root)],check=True)
files={
    'safe.ts':'export function auditTarget() { return 7; }\nexport function actualCaller() { auditTarget(); }\n/* auditTarget(); */\nconst pattern = /auditTarget()/;\nconst template = `auditTarget()`;\n/*\nauditTarget();\n*/\n',
    '.env':'AUDIT_LOWER_ENV=synthetic_lower_env_canary\n',
    '.ENV':'AUDIT_UPPER_ENV=synthetic_upper_env_canary\n',
    'Credentials.JSON':'{"canary":"synthetic_credentials_canary"}\n',
    'private.PEM':'synthetic_upper_pem_canary\n',
    'private.key':'synthetic_lower_key_canary\n',
    'sub/.gitignore':'nested-hidden.ts\n',
    'sub/nested-hidden.ts':'export const nestedIgnoredCanary = 1;\n',
    'sub/keep.ts':'export const negationKeptCanary = 1;\n',
    '.gitignore':'sub/*.ts\n!sub/keep.ts\n',
}
# Case-insensitive Windows cannot hold .env and .ENV together; use separate folders.
files['upper/.ENV']=files.pop('.ENV')
for name,data in files.items():
    f=root/name; f.parent.mkdir(parents=True,exist_ok=True); f.write_text(data,encoding='utf-8')
outside=base/'outside.txt'; outside.write_text('synthetic_outside_canary\n',encoding='utf-8')
try:
    os.symlink(outside,root/'linked.ts')
    REPORT['synthetic']['symlink_created']=True
except OSError as e:
    REPORT['synthetic']['symlink_created']=False
    REPORT['synthetic']['symlink_error']=str(e)
p,init=start(root)
try:
    REPORT['synthetic']['root']=str(root)
    REPORT['synthetic']['initialize']=init
    REPORT['synthetic']['status']=call(p,'codedb_status',{})
    p.send({'jsonrpc':'2.0','id':900,'method':'tools/list','params':{}})
    listing=p.recv(timeout=20)
    ts=(listing or {}).get('result',{}).get('tools',[])
    REPORT['synthetic']['tools']={'count':len(ts),'schema_bytes':len(json.dumps(ts)),'annotations':{t['name']:t.get('annotations') for t in ts}}
    for name in ['.env','upper/.ENV','Credentials.JSON','private.PEM','private.key','linked.ts',str(outside).replace('\\','/'),str(root/'safe.ts'),str(root/'safe.ts').replace('\\','/')]:
        REPORT['synthetic']['read:'+name]=call(p,'codedb_read',{'path':name,'raw':True})
    for q in ['synthetic_upper','synthetic_credentials','synthetic_outside','nestedIgnoredCanary','negationKeptCanary']:
        REPORT['synthetic']['search:'+q]=call(p,'codedb_search',{'query':q})
    for n in [1,50]:
        REPORT['synthetic']['callers:'+str(n)]=call(p,'codedb_callers',{'name':'auditTarget','max_results':n})
finally:
    p.close(); save()
print('Synthetic probes finished',flush=True)

roots=[
    (r'C:\repos\lm-asp-net','Probe', 'src/Backend/Levelmaster.Domain/Entities/Probe.cs'),
    (r'C:\repos\pro','Startup','src/Startup.cs'),
    (r'C:\repos\invest','Startup','src/Startup.cs'),
    (r'C:\repos\autumn','QueryProcess',None),
    (r'C:\repos\credo_main\src\Autumn','QueryProcess',None),
]
for root,name,path in roots:
    print('Probing '+root,flush=True)
    item={'root':root,'head':subprocess.check_output(['git','-C',root,'rev-parse','HEAD'],text=True).strip()}
    t=time.monotonic(); p,init=start(root)
    try:
        item['initialize_ms']=round((time.monotonic()-t)*1000,1)
        item['initialize_ok']=init is not None and 'result' in init
        item['status']=call(p,'codedb_status',{})
        if root.endswith(r'credo_main\src\Autumn'):
            tree=call(p,'codedb_tree',{'depth':1}); item['tree_summary']=tree['text'][:300]
        item['symbol']=call(p,'codedb_symbol',{'name':name})
        args={'query':name,'max_results':5}
        if 'Autumn' in root or root.endswith('autumn'): args['path_glob']='**/*.fs'
        item['search']=call(p,'codedb_search',args)
        item['callers']=call(p,'codedb_callers',{'name':name,'max_results':20})
        if path and (pathlib.Path(root)/path).exists():
            item['deps']=call(p,'codedb_deps',{'path':path,'direction':'imported_by'})
        # Keep evidence bounded; no whole-file reads of real project content.
        for key in ['symbol','search','callers','deps']:
            if key in item:
                txt=item[key]['text']; item[key]['response_chars']=len(txt); item[key]['text']=txt[:1400]
        item['stderr_tail']=p.stderr_lines()[-4:]
    finally:
        p.close(); REPORT['repositories'].append(item); save()
    print(root+': '+item['status']['text'][:160],flush=True)
print(str(OUT),flush=True)
