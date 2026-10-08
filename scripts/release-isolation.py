#!/usr/bin/env python3
"""Local release evidence: selected roots, cache reuse, rebuilds and NTFS links.

Only operates on release-matrix.py's ignored copies and synthetic fixtures.
Run after benchmarks, never concurrently with timed measurements.
"""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import threading
import time

spec = importlib.util.spec_from_file_location('matrix', Path(__file__).with_name('release-matrix.py'))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
BASE = m.PRIVATE / 'isolation'
REPORT = {'checks':[], 'five_roots':[]}

def check(name, passed, detail=None):
    REPORT['checks'].append({'name':name,'passed':bool(passed),'detail':detail})
    m.save(BASE/'results.json', REPORT)
    print('PASS' if passed else 'FAIL', name, flush=True)

def snapshot_wait(cache):
    deadline=time.monotonic()+120
    previous=None
    while time.monotonic()<deadline:
        found=[(str(p),p.stat().st_size) for p in cache.rglob('codedb.snapshot')]
        if found and found==previous:return found
        previous=found;time.sleep(1)
    raise RuntimeError('Snapshot not persisted')

def five_roots():
    cache=BASE/'five-cache'
    for name in m.ROOTS:
        source=m.PRIVATE/'caches'/name/'0-candidate'/'.codedb'/'projects'
        for d in source.iterdir():
            if d.is_dir():shutil.copytree(d,cache/'.codedb'/'projects'/d.name,dirs_exist_ok=True)
    questions=json.loads((m.PRIVATE/'golden.json').read_text())
    default=m.PRIVATE/'corpus'/'lm-asp-net'
    p=m.MCP(m.binaries()['candidate'],default,cache,workers=1)
    try:
        p.ready()
        for name in m.ROOTS:
            root=m.PRIVATE/'corpus'/name
            q=questions[name][0]
            # Tree first for every selected project, including the Autumn subroot.
            row={'root':name,'tree':p.call('codedb_tree',{'project':str(root),'depth':1})}
            row['first']=p.call(q['tool'],{**q['arguments'],'project':str(root)})
            row['repeated']=[p.call(q['tool'],{**q['arguments'],'project':str(root)}) for _ in range(3)]
            target=q['expected'][0]['path']
            check(name+' secondary project has expected definition',target in row['first']['text'])
            check(name+' repeated cache results agree',all(r['text']==row['first']['text'] for r in row['repeated']))
            fixture=root/'ReleaseRebuildFixture.ts'
            if fixture.exists():raise RuntimeError('Refusing to replace existing fixture')
            try:
                fixture.write_text('export const releaseRebuildCanary = 42;\n')
                row['force_add']=p.call('codedb_index',{'path':str(root),'force':True},timeout=900)
                row['read_added']=p.call('codedb_search',{'project':str(root),'query':'releaseRebuildCanary','path_glob':fixture.name})
                check(name+' forced add converges',fixture.name+':' in row['read_added']['text'])
                fixture.unlink()
                row['force_delete']=p.call('codedb_index',{'path':str(root),'force':True},timeout=900)
                row['read_deleted']=p.call('codedb_search',{'project':str(root),'query':'releaseRebuildCanary','path_glob':fixture.name})
                check(name+' forced delete converges',fixture.name+':' not in row['read_deleted']['text'])
            finally:fixture.unlink(missing_ok=True)
            REPORT['five_roots'].append(row);m.save(BASE/'results.json',REPORT)
    finally:p.close()

def synthetic():
    parent=BASE/'synthetic'/'parent';child=parent/'child';sibling=BASE/'synthetic'/'sibling'
    for root in (parent,child,sibling):root.mkdir(parents=True,exist_ok=True)
    (parent/'parent.ts').write_text('export const parentOnlyCanary = 1;\n')
    (child/'child.ts').write_text('export const childOnlyCanary = 1;\n')
    (sibling/'outside.ts').write_text('export const OUTSIDE_SYNTHETIC_SECRET = 1;\n')
    cache=BASE/'synthetic-cache'
    for root in (parent,child,sibling):
        p=m.MCP(m.binaries()['candidate'],root,cache)
        try:p.ready();snapshot_wait(cache)
        finally:p.close()
    projects=[]
    for f in (cache/'.codedb'/'projects').glob('*/project.txt'):
        projects.append({'cache':f.parent.name,'root':f.read_text().strip()})
    check('parent child sibling use distinct cache keys',len({r['cache'] for r in projects})==3,projects)
    p=m.MCP(m.binaries()['candidate'],child,cache,roots=True)
    try:
        p.ready()
        before=p.call('codedb_tree')
        check('child tree excludes parent and sibling','child.ts' in before['text'] and 'parent.ts' not in before['text'] and 'outside.ts' not in before['text'])
        p.root=parent
        p.send({'jsonrpc':'2.0','method':'notifications/roots/list_changed','params':{}})
        p.rpc('ping');p.rpc('ping')
        after=p.call('codedb_tree')
        check('roots change cannot broaden explicitly pinned child','child.ts' in after['text'] and 'parent.ts' not in after['text'],after)
        explicit=p.call('codedb_tree',{'project':str(parent)})
        # codedb_tree renders directories on their own line and indents the
        # child entry; accept that stable presentation as the parent-relative
        # path evidence instead of requiring a flattened `child/child.ts`.
        child_relative = 'child/child.ts' in explicit['text'] or ('child/\n  child.ts' in explicit['text'])
        check('explicit parent selection has parent-relative paths','parent.ts' in explicit['text'] and child_relative,explicit)
        back=p.call('codedb_tree')
        check('secondary selection leaves default child isolated','parent.ts' not in back['text'])
    finally:p.close()
    # Junction swaps remain entirely within this owned synthetic directory.
    link=child/'swap'
    assert link.parent.resolve()==child.resolve() and child.is_relative_to(BASE)
    junction_script=BASE/'create-junction.ps1'
    junction_script.write_text('param([string]$Link, [string]$Target)\n$ErrorActionPreference = "Stop"\nNew-Item -ItemType Junction -Path $Link -Target $Target | Out-Null\n')
    command=['pwsh','-NoProfile','-File',str(junction_script),'-Link',str(link),'-Target',str(sibling)]
    made=subprocess.run(command,capture_output=True,text=True)
    if made.returncode:
        check('junction creation available',False,{'limitation':made.stderr});return
    p=m.MCP(m.binaries()['candidate'],child,BASE/'race-cache')
    try:
        p.ready()
        results=[]
        for tool,args in [('codedb_read',{'path':'swap/outside.ts'}),('codedb_search',{'query':'OUTSIDE_SYNTHETIC_SECRET'}),('codedb_query',{'pipeline':[{'op':'read','path':'swap/outside.ts'}]})]:
            results.append(p.call(tool,args))
        check('junction target absent from direct search and query reads',all('export const OUTSIDE_SYNTHETIC_SECRET' not in r['text'] and 'swap/outside.ts:' not in r['text'] for r in results),results)
        failures=[]
        def swap():
            try:
                for _ in range(12):
                    os.rmdir(link) # Windows removes the junction, never its target.
                    link.mkdir()
                    (link/'outside.ts').write_text('export const safeCanary = 1;\n')
                    time.sleep(.015)
                    (link/'outside.ts').unlink();link.rmdir()
                    r=subprocess.run(command,capture_output=True,text=True)
                    if r.returncode:raise RuntimeError(r.stderr)
            except Exception as exc:failures.append(str(exc))
        worker=threading.Thread(target=swap);worker.start()
        reads=[]
        while worker.is_alive():
            reads.append(p.call('codedb_read',{'path':'swap/outside.ts'}))
        worker.join()
        check('junction replacement race never reads outside bytes',not failures and len(reads)>0 and all('OUTSIDE_SYNTHETIC_SECRET' not in r['text'] for r in reads),{'attempts':len(reads),'swaps':12,'errors':failures,'responses':reads})
        check('synthetic junction target remains intact',(sibling/'outside.ts').read_text()=='export const OUTSIDE_SYNTHETIC_SECRET = 1;\n')
    finally:
        p.close()
        if link.exists():os.rmdir(link)

if __name__=='__main__':
    BASE.mkdir(parents=True,exist_ok=True)
    try:synthetic();five_roots()
    except Exception as exc:
        REPORT['error']=repr(exc);m.save(BASE/'results.json',REPORT);raise
    raise SystemExit(0 if all(r['passed'] for r in REPORT['checks']) else 1)
