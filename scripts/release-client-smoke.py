#!/usr/bin/env python3
"""Actual local clients, synthetic corpus only; never modify user registrations."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import sys
import threading
import time

sys.stdin.reconfigure(encoding='utf-8')
sys.stdout.reconfigure(encoding='utf-8')
sys.stderr.reconfigure(encoding='utf-8')

SPEC = importlib.util.spec_from_file_location('matrix', Path(__file__).with_name('release-matrix.py'))
m = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(m)
BASE = m.PRIVATE / 'clients'

def bridge():
    # Transparent line proxy records the actual client's protocol and tool calls.
    log = Path(sys.argv[2])
    child = subprocess.Popen(sys.argv[3:], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, text=True, encoding='utf-8', bufsize=1)
    lock = threading.Lock()
    def record(direction, text):
        with lock, log.open('a', encoding='utf-8') as f:
            f.write(json.dumps({'direction':direction, 'message':json.loads(text)})+'\n')
    def receive():
        for line in child.stdout:
            record('server',line)
            sys.stdout.write(line)
            sys.stdout.flush()
    def errors():
        for line in child.stderr:
            sys.stderr.write(line)
    threading.Thread(target=receive,daemon=True).start()
    threading.Thread(target=errors,daemon=True).start()
    try:
        for line in sys.stdin:
            record('client',line)
            child.stdin.write(line)
            child.stdin.flush()
    finally:
        child.stdin.close()
        try: child.wait(timeout=3)
        except subprocess.TimeoutExpired:
            child.terminate()
            child.wait(timeout=10)

def fixture():
    root = BASE/'project'
    root.mkdir(parents=True,exist_ok=True)
    (root/'smoke.ts').write_text('export function releaseSmoke() { return 42; }\nexport function caller() { return releaseSmoke(); }\n')
    return root

def configuration(client, profile):
    root = fixture()
    return {'command':sys.executable,
            'args':[str(Path(__file__).resolve()),'bridge',str(BASE/f'{client}-{profile}-wire.jsonl'),
                    str(m.binaries()['candidate']),str(root),'mcp','--no-telemetry'],
            'env':{'CODEDB_CACHE_DIR':str(BASE/f'{client}-{profile}-cache'), 'CODEDB_REQUIRE_GIT_REPO':'0',
                   'CODEDB_NO_AUTO_UPDATE':'1','CODEDB_NO_TELEMETRY':'1','CODEDB_TELEMETRY':'0',
                   'CODEDB_TOOL_PROFILE':profile}}

def codex(profile):
    cfg = configuration('codex', profile)
    isolated = BASE/f'codex-{profile}-home'
    isolated.mkdir(exist_ok=True)
    config = '[features]\nplugins = false\n[analytics]\nenabled = false\n[mcp_servers.release_smoke]\ncommand = '+json.dumps(cfg['command'])+'\nargs = '+json.dumps(cfg['args'])+'\n[mcp_servers.release_smoke.env]\n'
    config += ''.join(k+' = '+json.dumps(v)+'\n' for k,v in cfg['env'].items())
    (isolated/'config.toml').write_text(config)
    p = subprocess.Popen([shutil.which('codex'),'app-server','--stdio'], cwd=fixture(),
                         env={**os.environ, 'CODEX_HOME':str(isolated)}, stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,encoding='utf-8',bufsize=1)
    q, messages, errors = queue.Queue(), [], []
    def read():
        for line in p.stdout: q.put(json.loads(line))
    def err():
        for line in p.stderr: errors.append(line)
    threading.Thread(target=read,daemon=True).start()
    threading.Thread(target=err,daemon=True).start()
    ident = 0
    def rpc(method, params):
        nonlocal ident
        ident += 1
        p.stdin.write(json.dumps({'id':ident,'method':method,'params':params})+'\n')
        p.stdin.flush()
        while True:
            response=q.get(timeout=90)
            messages.append(response)
            if response.get('id') == ident:
                if 'error' in response: raise RuntimeError(str(response))
                return response['result']
    result = {'client':'Codex app-server','version':subprocess.check_output([shutil.which('codex'),'--version'],text=True).strip(),'profile':profile}
    try:
        rpc('initialize',{'clientInfo':{'name':'release_smoke','version':'1'},'capabilities':{'experimentalApi':True}})
        p.stdin.write(json.dumps({'method':'initialized'})+'\n'); p.stdin.flush()
        thread = rpc('thread/start',{'cwd':str(fixture()),'ephemeral':True,'approvalPolicy':'never','sandbox':'read-only'})
        tid = thread['thread']['id']
        result['inventory'] = rpc('mcpServerStatus/list',{'threadId':tid,'serverName':'release_smoke'})
        result['calls'] = []
        for tool,args in [('codedb_status',{}),('codedb_symbol',{'name':'releaseSmoke'}),('codedb_read',{'path':'smoke.ts','line_start':1,'line_end':2})]:
            result['calls'].append(rpc('mcpServer/tool/call',{'threadId':tid,'server':'release_smoke','tool':tool,'arguments':args}))
        result['passed'] = 'releaseSmoke' in json.dumps(result['calls'][-1])
    except Exception as exc:
        result['error'] = repr(exc)
    finally:
        p.stdin.close()
        try: p.wait(timeout=5)
        except subprocess.TimeoutExpired: p.terminate(); p.wait(timeout=10)
        result['stderr'] = errors
        m.save(BASE/f'codex-{profile}.json',result)
    print('codex',profile,result.get('passed',False),result.get('error',''),flush=True)

def claude(profile):
    cfg = configuration('claude',profile)
    path = BASE/f'claude-{profile}-config.json'
    m.save(path,{'mcpServers':{'release_smoke':cfg}})
    argv = [shutil.which('claude'),'-p','Use only release_smoke MCP tools. Call codedb_status, then codedb_symbol for releaseSmoke, then codedb_read smoke.ts lines 1-2. Report the synthetic return value.',
            '--mcp-config',str(path),'--strict-mcp-config','--tools','', '--allowedTools','mcp__release_smoke__*',
            '--no-session-persistence','--setting-sources','', '--disable-slash-commands', '--output-format','stream-json','--verbose']
    try:
        result = subprocess.run(argv,cwd=fixture(),capture_output=True,text=True,encoding='utf-8',timeout=120)
        m.save(BASE/f'claude-{profile}.json',{'version':subprocess.check_output([shutil.which('claude'),'--version'],text=True).strip(),'profile':profile,'exit':result.returncode,'stdout':result.stdout,'stderr':result.stderr})
        print('claude',profile,'exit',result.returncode,flush=True)
    except subprocess.TimeoutExpired as exc:
        m.save(BASE/f'claude-{profile}.json',{'error':'timeout','stdout':str(exc.stdout),'stderr':str(exc.stderr)})
        print('claude',profile,'timeout',flush=True)

if __name__ == '__main__':
    if len(sys.argv)>1 and sys.argv[1]=='bridge': bridge()
    else:
        ap=argparse.ArgumentParser(description=__doc__)
        ap.add_argument('client',choices=['codex','claude'])
        ap.add_argument('--profile',choices=['full','navigation'],default='full')
        args=ap.parse_args()
        globals()[args.client](args.profile)
