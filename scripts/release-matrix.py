#!/usr/bin/env python3
"""Local, paired Windows release evaluation; private outputs MUST stay ignored.

No network clients, application builds, original-root edits, or production caches.
Uses queue-based JSON-RPC timing (not the E2E harness's 20 ms polling floor).
Only launch/terminate processes owned by this runner. See docs/release-validation.md.
"""
from __future__ import annotations
import argparse
import concurrent.futures
import ctypes
from ctypes import wintypes
import hashlib
import json
import math
import os
from pathlib import Path
import queue
import re
import shutil
import statistics
import subprocess
import threading
import time

REPO = Path(__file__).resolve().parents[1]
ROOTS = {
    'lm-asp-net': Path('C:/repos/lm-asp-net'),
    'pro': Path('C:/repos/pro'),
    'invest': Path('C:/repos/invest'),
    'autumn': Path('C:/repos/autumn'),
    'credo-autumn': Path('C:/repos/credo_main/src/Autumn'),
}
PRIVATE = REPO / 'plans/evidence/local/release-2026-10-07-final'
PYTHON = Path(os.sys.executable)

def digest(data):
    return hashlib.sha256(data).hexdigest()

def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix('.tmp')
    tmp.write_text(json.dumps(value, indent=2), encoding='utf-8')
    tmp.replace(path)

def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args])

def sensitive(path):
    parts = Path(path).as_posix().lower().split('/')
    return any(p.startswith('.env') or p in {'.ssh', '.aws', '.azure', '.gnupg', '.git', 'secrets', 'credentials'}
               or any(x in p for x in ('credential', 'secret', 'productkey'))
               or p.endswith(('.pem', '.key', '.pfx', '.p12', '.keystore', '.zip', '.7z')) for p in parts)

def prepare():
    """Freeze Git-visible bytes, preserve ignored/generated exclusion metadata locally."""
    PRIVATE.mkdir(parents=True, exist_ok=True)
    reports = {}
    for name, root in ROOTS.items():
        destination = PRIVATE / 'corpus' / name
        if destination.exists():
            raise RuntimeError('Refusing to overwrite frozen corpus: ' + str(destination))
        paths = sorted(set(git(root, 'ls-files', '-z', '--cached', '--others', '--exclude-standard', '--', '.').decode().split('\0')) - {''})
        # Only prune literal directory exclusions, not glob/negation rules.
        # The original rule files are retained for both binaries to interpret.
        ignore = root / '.codedbignore'
        excluded_dirs = []
        if ignore.exists():
            for rule in ignore.read_text().splitlines():
                rule = rule.strip().rstrip('/')
                if rule and not rule.startswith(('#','!')) and not any(c in rule for c in '*?[') and (root/rule).is_dir():
                    excluded_dirs.append(rule.lower()+'/')
        manifest, omitted = [], []
        for rel in paths:
            source = root / rel
            if any(rel.lower().startswith(prefix) for prefix in excluded_dirs):
                omitted.append({'path': rel, 'reason': 'literal .codedbignore directory'})
                continue
            if sensitive(rel) or not source.is_file() or source.is_symlink():
                omitted.append({'path': rel, 'reason': 'sensitive, non-file, link or absent'})
                continue
            # Exclude binary dependencies/build outputs; preserve text oversize files.
            if source.suffix.lower() in {'.dll', '.exe', '.pdb', '.nupkg', '.jpg', '.png', '.ico', '.pdf', '.mp4', '.ttf', '.woff', '.woff2'} or source.name == 'codedb.snapshot':
                omitted.append({'path': rel, 'reason': 'binary/runtime artifact'})
                continue
            data = source.read_bytes()
            target = destination / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            shutil.copystat(source, target)
            manifest.append({'path': rel, 'bytes': len(data), 'sha256': digest(data)})
        status = git(root, 'status', '--porcelain=v1', '-z', '--untracked-files=all', '--', '.').decode()
        reports[name] = {'root': str(root), 'head': git(root, 'rev-parse', 'HEAD').decode().strip(),
                         'git_root': git(root, 'rev-parse', '--show-toplevel').decode().strip(),
                         'status_porcelain_z': status, 'files': manifest, 'omitted': omitted,
                         'corpus_sha256': digest(json.dumps(manifest, sort_keys=True).encode()),
                         'scope': 'Git-visible frozen working tree; sensitive names, binary artifacts, literal .codedbignore directories omitted; no broader monorepo walk'}
        # Separate fake Git repositories pin copies without referring to the real Git root.
        subprocess.run(['git', 'init', '-q', str(destination)], check=True)
        print(name, 'files', len(manifest), 'bytes', sum(f['bytes'] for f in manifest), flush=True)
        save(PRIVATE / 'manifest.json', reports)

class Counters(ctypes.Structure):
    _fields_ = [('cb', wintypes.DWORD), ('PageFaultCount', wintypes.DWORD)] + [(x, ctypes.c_size_t) for x in
        ('PeakWorkingSetSize', 'WorkingSetSize', 'QuotaPeakPagedPoolUsage', 'QuotaPagedPoolUsage',
         'QuotaPeakNonPagedPoolUsage', 'QuotaNonPagedPoolUsage', 'PagefileUsage', 'PeakPagefileUsage')]

def resources(proc):
    handle = wintypes.HANDLE(int(proc._handle))
    counters = Counters()
    counters.cb = ctypes.sizeof(counters)
    if not ctypes.windll.psapi.GetProcessMemoryInfo(handle, ctypes.byref(counters), counters.cb):
        raise ctypes.WinError()
    times = [wintypes.FILETIME() for _ in range(4)]
    if not ctypes.windll.kernel32.GetProcessTimes(handle, *[ctypes.byref(t) for t in times]):
        raise ctypes.WinError()
    seconds = sum((t.dwHighDateTime << 32) + t.dwLowDateTime for t in times[2:]) / 1e7
    return {'rss': counters.WorkingSetSize, 'peak_rss': counters.PeakWorkingSetSize, 'cpu_s': seconds}

class MCP:
    def __init__(self, binary, root, cache, roots=False):
        cache.mkdir(parents=True, exist_ok=True)
        env = {**os.environ, 'HOME': str(cache), 'USERPROFILE': str(cache),
               'CODEDB_CACHE_DIR': str(cache / '.codedb'), 'CODEDB_NO_AUTO_UPDATE': '1',
               'CODEDB_TELEMETRY': '0', 'CODEDB_NO_TELEMETRY': '1', 'CODEDB_REQUIRE_GIT_REPO': '0',
               'CODEDB_MAX_MEMORY_MB': '4096', 'NO_COLOR': '1'}
        # Explicitly identical worker settings in both variants. Autumn's
        # eight-worker partial runs are retained separately as diagnostics.
        env['CODEDB_SCAN_WORKERS'] = '1' if root.name == 'autumn' else '8'
        env.pop('CODEDB_TELEMETRY_URL', None)
        self.started = time.perf_counter()
        self.proc = subprocess.Popen([str(binary), str(root), 'mcp', '--no-telemetry'], cwd=REPO,
                                     env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     encoding='utf-8', text=True, bufsize=1)
        self.q, self.stderr, self.ident = queue.Queue(), [], 0
        self.root = root
        def read():
            try:
                for line in self.proc.stdout:
                    self.q.put(json.loads(line))
            finally:
                self.q.put({'eof': True})
        def errors():
            for line in self.proc.stderr:
                self.stderr.append(line.rstrip())
        threading.Thread(target=read, daemon=True).start()
        threading.Thread(target=errors, daemon=True).start()
        self.init = self.rpc('initialize', {'protocolVersion': '2025-11-25', 'capabilities': {'roots': {'listChanged': True}} if roots else {}, 'clientInfo': {'name': 'release-matrix', 'version': '1'}})
        self.raw_block = 1 if self.init.get('result', {}).get('serverInfo', {}).get('version') == '3.0.1' else 0
        self.send({'jsonrpc': '2.0', 'method': 'notifications/initialized', 'params': {}})

    def send(self, message):
        self.proc.stdin.write(json.dumps(message) + '\n')
        self.proc.stdin.flush()

    def rpc(self, method, params=None, timeout=180):
        self.ident += 1
        ident = self.ident
        self.send({'jsonrpc': '2.0', 'id': ident, 'method': method, 'params': params or {}})
        deadline = time.perf_counter() + timeout
        while True:
            value = self.q.get(timeout=max(.001, deadline-time.perf_counter()))
            if value.get('eof'):
                raise RuntimeError('MCP exited: ' + '\n'.join(self.stderr[-8:]))
            if value.get('method') == 'roots/list':
                self.send({'jsonrpc':'2.0', 'id':value['id'], 'result':{'roots':[{'uri':self.root.as_uri(), 'name':'fixture'}]}})
            elif value.get('id') == ident:
                return value

    def call(self, tool, args=None, timeout=180):
        start = time.perf_counter_ns()
        result = self.rpc('tools/call', {'name':tool, 'arguments':args or {}}, timeout)
        elapsed = (time.perf_counter_ns()-start) / 1e6
        # Guidance is not source data and changes after repeated queries.
        blocks = result.get('result', {}).get('content', [])
        text_blocks = [b['text'] for b in blocks if b.get('type') == 'text']
        body = text_blocks[self.raw_block] if len(text_blocks) > self.raw_block else ''
        return {'ms':elapsed, 'text':body, 'bytes':len(json.dumps(result).encode()),
                'error':result.get('error') or result.get('result', {}).get('isError', False)}

    def ready(self, timeout=900):
        deadline = time.perf_counter()+timeout
        history = []
        while time.perf_counter()<deadline:
            result = self.call('codedb_status', timeout=40)
            history.append({'seconds':time.perf_counter()-self.started, **result, **resources(self.proc)})
            if len(history) % 50 == 0:
                save(PRIVATE/'progress'/f'{self.proc.pid}.json', {'root':str(self.root),'history':history,'stderr':self.stderr})
            match = re.search(r'  scan: (.+)', result['text'])
            if match and match[1].strip() in ('ready', 'budget_exceeded', 'failed'):
                return {'ms':(time.perf_counter()-self.started)*1000, 'state':match[1].strip(), 'history':history}
            time.sleep(.2)
        return {'ms':(time.perf_counter()-self.started)*1000, 'state':'timeout', 'history':history}

    def close(self):
        try:
            self.proc.stdin.close()
            self.proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.proc.terminate()
            self.proc.wait(timeout=10)

def percentile(values, fraction):
    return sorted(values)[max(0, math.ceil(len(values)*fraction)-1)]

def stats(values):
    return {'n':len(values), 'median':statistics.median(values), 'p95':percentile(values,.95),
            'min':min(values), 'max':max(values), 'stdev':statistics.stdev(values) if len(values)>1 else 0}

def binaries():
    return {'baseline':REPO/'.build/release-baseline/zig-out/bin/codedb.exe',
            'candidate':REPO/'.build/release-candidate/bin/codedb.exe'}

def clean_root_snapshot(root):
    assert root.is_relative_to(PRIVATE / 'corpus')
    (root/'codedb.snapshot').unlink(missing_ok=True)

def probe(names):
    for name in names:
        root = PRIVATE/'corpus'/name
        clean_root_snapshot(root)
        p = MCP(binaries()['candidate'], root, PRIVATE/'probe-cache'/name)
        try:
            ready = p.ready()
            save(PRIVATE/f'probe-{name}.json', {'ready':ready,'stderr':p.stderr})
            result = {'ready':ready, 'tools':p.rpc('tools/list'), 'tree':p.call('codedb_tree', {'depth':2}), 'stderr':p.stderr}
            save(PRIVATE/f'probe-{name}.json', result)
            print(name, ready['state'], round(ready['ms']), flush=True)
        finally:
            p.close()

def run(names, repetitions, queries):
    questions = json.loads((PRIVATE/'golden.json').read_text())
    output = PRIVATE/'matrix.json'
    fingerprints = {k:{'path':str(v), 'sha256':digest(v.read_bytes())} for k,v in binaries().items()}
    report = json.loads(output.read_text()) if output.exists() else {'runs':[], 'binaries':fingerprints,
        'golden_sha256':digest((PRIVATE/'golden.json').read_bytes()),
        'manifest_sha256':digest((PRIVATE/'manifest.json').read_bytes()),
        'config':{'memory_mb':4096, 'workers':{'autumn':1,'others':8}, 'optimization':'ReleaseFast','compiler':'0.16.0'}}
    if report['binaries'] != fingerprints or report['golden_sha256'] != digest((PRIVATE/'golden.json').read_bytes()):
        raise RuntimeError('Binary/corpus version changed; archive previous evidence before rerunning')
    for name in names:
        for repetition in range(repetitions):
            for variant in (('baseline','candidate') if repetition%2 == 0 else ('candidate','baseline')):
                if any(r['root']==name and r['repetition']==repetition and r['variant']==variant for r in report['runs']):
                    continue
                root = PRIVATE/'corpus'/name
                clean_root_snapshot(root)
                cache = PRIVATE/'caches'/name/f'{repetition}-{variant}'
                if cache.exists():
                    raise RuntimeError('Nonempty cold cache: '+str(cache))
                row = {'root':name, 'variant':variant, 'repetition':repetition, 'questions':[]}
                p = MCP(binaries()[variant], root, cache)
                try:
                    row['cold'] = p.ready()
                    row['cold_resources'] = resources(p.proc)
                    print(name, repetition, variant, 'cold', row['cold']['state'], round(row['cold']['ms']), flush=True)
                    if row['cold']['state'] != 'ready':
                        continue
                    # Readiness precedes automatic snapshot persistence. Wait for
                    # a stable snapshot before queries/restarts, without reindexing.
                    deadline = time.perf_counter()+120
                    previous = None
                    while time.perf_counter()<deadline:
                        snapshots = list(cache.rglob('codedb.snapshot'))+[root/'codedb.snapshot']
                        sizes = [(str(f),f.stat().st_size) for f in snapshots if f.exists()]
                        if sizes and sizes == previous: break
                        previous = sizes
                        time.sleep(1)
                    row['snapshot_files'] = sizes
                    row['tree'] = p.call('codedb_tree', {'depth':1})
                    row['inventory'] = p.call('codedb_glob', {'pattern':'**/*', 'max_results':100000})
                    for question in questions[name]:
                        args = question['arguments']
                        p.call(question['tool'], args)
                        samples = [p.call(question['tool'], args) for _ in range(queries)]
                        row['questions'].append({'id':question['id'], 'latency_ms':stats([s['ms'] for s in samples]),
                                                  'answer':samples[0], 'response_bytes':stats([s['bytes'] for s in samples]), 'tool_calls':1})
                    before = resources(p.proc)
                    time.sleep(3)
                    after = resources(p.proc)
                    row['idle'] = {'wall_s':3, 'cpu_s':after['cpu_s']-before['cpu_s'], 'one_core_pct':(after['cpu_s']-before['cpu_s'])/3*100, **after}
                    row['stderr'] = p.stderr
                finally:
                    row['stderr'] = p.stderr
                    p.close()
                    report['runs'].append(row)
                    save(output, report)
                # Baseline may save only to root; maintain it for its own warm run.
                p = MCP(binaries()[variant], root, cache)
                try:
                    row['warm'] = p.ready()
                    row['warm_resources'] = resources(p.proc)
                    row['warm_stderr'] = p.stderr
                    print(name, repetition, variant, 'warm', row['warm']['state'], round(row['warm']['ms']), flush=True)
                finally:
                    p.close()
                    save(output, report)
                clean_root_snapshot(root)

def extended(names):
    """Independent warm processes, shared variant cache; updates use synthetic bytes."""
    questions = json.loads((PRIVATE/'golden.json').read_text())
    output = PRIVATE/'extended.json'
    report = json.loads(output.read_text()) if output.exists() else {'concurrency':[], 'updates':[],
        'binaries':{k:digest(v.read_bytes()) for k,v in binaries().items()},
        'config':{'memory_mb':4096, 'workers':{'autumn':1,'others':8}}}
    for name in names:
        root = PRIVATE/'corpus'/name
        for variant in ('baseline','candidate'):
            cache = PRIVATE/'caches'/name/f'0-{variant}'
            for count in (1,4,8):
                if any(r['root']==name and r['variant']==variant and r['agents']==count for r in report['concurrency']): continue
                clean_root_snapshot(root)
                processes=[]
                start=time.perf_counter()
                row={'root':name,'variant':variant,'agents':count}
                try:
                    # Simultaneous starts, with separate pipes and Explorer instances.
                    with concurrent.futures.ThreadPoolExecutor(max_workers=count) as pool:
                        futures=[pool.submit(MCP,binaries()[variant],root,cache) for _ in range(count)]
                        # Keep ownership even if a later startup fails.
                        for future in futures: processes.append(future.result())
                        row['ready']=list(pool.map(lambda p:p.ready(),processes))
                        row['all_ready_ms']=(time.perf_counter()-start)*1000
                        before=[resources(p.proc) for p in processes]
                        time.sleep(5)
                        after=[resources(p.proc) for p in processes]
                        row['aggregate_rss_bytes']=sum(r['rss'] for r in after)
                        row['sum_process_peak_rss_bytes']=sum(r['peak_rss'] for r in after)
                        row['idle_cpu_s']=sum(b['cpu_s']-a['cpu_s'] for a,b in zip(before,after))
                        q=questions[name][0]
                        def work(p): return [p.call(q['tool'],q['arguments']) for _ in range(30)]
                        samples=list(pool.map(work,processes))
                        row['query_ms']=stats([s['ms'] for group in samples for s in group])
                        row['query_errors']=sum(bool(s['error']) for group in samples for s in group)
                except Exception as exc:
                    row['error']=repr(exc)
                finally:
                    for p in processes: p.close()
                    report['concurrency'].append(row);save(output,report)
                print(name,variant,count,'agents',row.get('aggregate_rss_bytes'),row.get('error',''),flush=True)
            if any(r['root']==name and r['variant']==variant for r in report['updates']): continue
            clean_root_snapshot(root)
            p=MCP(binaries()[variant],root,cache)
            fixture=root/'ReleaseFreshnessFixture.ts'
            assert not fixture.exists()
            row={'root':name,'variant':variant,'synthetic':True}
            def until(token,timeout=90):
                start=time.perf_counter()
                while time.perf_counter()-start<timeout:
                    result=p.call('codedb_search',{'query':token,'path_glob':fixture.name,'max_results':5})
                    if fixture.name+':' in result['text']:return (time.perf_counter()-start)*1000
                    time.sleep(.1)
                return None
            try:
                row['ready']=p.ready()
                fixture.write_text('export const releaseBeforeCanary = 1;\n')
                row['addition_ms']=until('releaseBeforeCanary')
                fixture.write_text('export const releaseAfterxCanary = 1;\n')
                row['update_ms']=until('releaseAfterxCanary')
                fixture.unlink()
                start=time.perf_counter()
                while time.perf_counter()-start<90:
                    result=p.call('codedb_search',{'query':'releaseAfterxCanary','path_glob':fixture.name,'max_results':5})
                    if fixture.name+':' not in result['text']:
                        row['deletion_ms']=(time.perf_counter()-start)*1000;break
                    time.sleep(.1)
            except Exception as exc:row['error']=repr(exc)
            finally:
                fixture.unlink(missing_ok=True)
                p.close();report['updates'].append(row);save(output,report)
            print(name,variant,'update',row.get('update_ms'),flush=True)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=['prepare','probe','run','extended'])
    parser.add_argument('--roots', nargs='+', choices=ROOTS, default=list(ROOTS))
    parser.add_argument('--repetitions', type=int, default=3)
    parser.add_argument('--queries', type=int, default=30)
    args = parser.parse_args()
    if os.name != 'nt':
        parser.error('Windows resource instrumentation required')
    if args.phase == 'prepare': prepare()
    if args.phase == 'probe': probe(args.roots)
    if args.phase == 'run': run(args.roots, args.repetitions, args.queries)
    if args.phase == 'extended': extended(args.roots)

if __name__ == '__main__':
    main()
